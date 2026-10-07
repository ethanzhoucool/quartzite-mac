#!/usr/bin/env bash
# Synthesize + place + route a Verilog design for the DE10-Standard.
# usage: compile_rbf.sh <design.v> <pins.qsf> <out.rbf> [top_module]
# env: TOOLCHAIN (default ~/.quartzite/toolchain), DEVICE, YOSYS,
#      NEXTPNR, SEED, NEXTPNR_ARGS (whitespace-separated extra nextpnr flags).
# Side outputs next to <out.rbf>: <name>.json, <name>.yosys.log, <name>.nextpnr.log.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  sed -n '2,6p' "$0"; exit 2
fi
SRC=$1; QSF=$2; OUT=$3; TOP=${4:-}
TOOLCHAIN=${TOOLCHAIN:-$HOME/.quartzite/toolchain}
DEVICE=${DEVICE:-5CSXFC6D6F31C6}
YOSYS=${YOSYS:-yosys}
NEXTPNR=${NEXTPNR:-$TOOLCHAIN/prefix/bin/nextpnr-mistral}
SEED=${SEED:-1}

[[ -f $SRC ]] || { echo "no such file: $SRC" >&2; exit 2; }
[[ -f $QSF ]] || { echo "no such file: $QSF" >&2; exit 2; }
command -v "$YOSYS" >/dev/null || { echo "yosys not found (brew install yosys)" >&2; exit 2; }
[[ -x $NEXTPNR ]] || { echo "nextpnr-mistral not found at $NEXTPNR (run build_toolchain.sh)" >&2; exit 2; }
if [[ -n $TOP && ! $TOP =~ ^[a-zA-Z_][a-zA-Z0-9_\$]*$ ]]; then
  echo "top module must be a Verilog identifier" >&2; exit 2
fi

mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
base=${OUT%.rbf}
# A successful tool must produce fresh artifacts. Failed runs preserve the previous
# output/netlist and publish only their diagnostic logs.
build_dir=$(mktemp -d "$(dirname "$OUT")/.quartzite-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
{
  if [[ -n $TOP ]]; then printf 'hierarchy -check -top %s\n' "$TOP"
  else printf 'hierarchy -check -auto-top\n'; fi
  printf 'synth_intel_alm -family cyclonev'
  if [[ -n $TOP ]]; then printf ' -top %s' "$TOP"; fi
  printf '\nstat\n'
} > "$build_dir/design.ys"

t0=$(date +%s)
if ! "$YOSYS" -q -l "$build_dir/yosys.log" -f "verilog -sv" "$SRC" -s "$build_dir/design.ys" -b json -o "$build_dir/design.json" > "$build_dir/yosys.stderr" 2>&1 \
  || [[ ! -s $build_dir/design.json ]]; then
  cat "$build_dir/yosys.stderr" >&2
  if [[ -f $build_dir/yosys.log ]]; then cp "$build_dir/yosys.log" "$base.yosys.log"; tail -20 "$base.yosys.log" >&2; fi
  echo "yosys failed or did not produce a netlist" >&2; exit 1
fi
cp "$build_dir/yosys.log" "$base.yosys.log"
t1=$(date +%s)
extra_args=()
# Split additional flags without expanding wildcard characters against local files.
read -r -a extra_args <<< "${NEXTPNR_ARGS:-}"
if ! "$NEXTPNR" --device "$DEVICE" --json "$build_dir/design.json" --qsf "$QSF" --rbf "$build_dir/design.rbf" \
  --seed "$SEED" --log "$build_dir/nextpnr.log" ${extra_args[@]+"${extra_args[@]}"} > "$build_dir/nextpnr.stderr" 2>&1 \
  || [[ ! -s $build_dir/design.rbf ]]; then
  cat "$build_dir/nextpnr.stderr" >&2
  if [[ -f $build_dir/nextpnr.log ]]; then cp "$build_dir/nextpnr.log" "$base.nextpnr.log"; tail -20 "$base.nextpnr.log" >&2; fi
  echo "nextpnr-mistral failed or did not produce a bitstream" >&2; exit 1
fi
cp "$build_dir/nextpnr.log" "$base.nextpnr.log"
mv "$build_dir/design.json" "$base.json"
mv "$build_dir/design.rbf" "$OUT"
t2=$(date +%s)
echo "yosys:   $((t1 - t0)) s  ($base.yosys.log)"
echo "nextpnr: $((t2 - t1)) s  ($base.nextpnr.log)"
grep -E "^Info:[[:space:]]+MISTRAL_(COMB|FF|IO):" "$base.nextpnr.log" | sed 's/^Info: */         /' || true
echo "rbf:     $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

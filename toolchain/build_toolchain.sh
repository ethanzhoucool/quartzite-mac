#!/usr/bin/env bash
# Build the open-source Cyclone V toolchain (Mistral + nextpnr-mistral) and the
# openFPGALoader JTAG programmer on Apple Silicon macOS with Homebrew.
# Idempotent: re-running skips work that is already done. Nothing outside
# $TOOLCHAIN is modified except Homebrew formulae (cmake boost eigen xz yosys
# ninja libusb libftdi pkgconf, python3 if missing). No sudo.
#
# Result:
#   $TOOLCHAIN/prefix/bin/nextpnr-mistral            place & route + .rbf writer
#   $TOOLCHAIN/prefix/bin/mistral-cv                 Mistral master: decomp/comp/diff
#   $TOOLCHAIN/prefix/bin/mistral-cv-nextpnr-latest  same tool from the branch nextpnr links
#   $TOOLCHAIN/prefix/bin/openFPGALoader             JTAG programmer (Tools > Programmer)
#
# env: TOOLCHAIN (default ~/.quartzite/toolchain), JOBS, SKIP_BREW=1,
#      SKIP_OPENFPGALOADER=1 (programmer not needed),
#      MISTRAL_COMMIT, MISTRAL_NEXTPNR_COMMIT, NEXTPNR_COMMIT,
#      OPENFPGALOADER_COMMIT (pins below).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PATCHES=$HERE/patches
TOOLCHAIN=${TOOLCHAIN:-$HOME/.quartzite/toolchain}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo /opt/homebrew)

# Commits verified on 2026-10-01 (see docs/TOOLCHAIN_NOTES.md)
MISTRAL_COMMIT=${MISTRAL_COMMIT:-d509238a203aadbb76291ab06543a401df91cf54}         # master
MISTRAL_NEXTPNR_COMMIT=${MISTRAL_NEXTPNR_COMMIT:-6a97d3e}                         # origin/nextpnr-latest
NEXTPNR_COMMIT=${NEXTPNR_COMMIT:-f7455496240cee1a5a6de262be5bdb1d1e7a3911}         # master
# Verified on 2026-10-22 (see docs/PROGRAMMER.md): v1.2.0 plus later master commits
OPENFPGALOADER_COMMIT=${OPENFPGALOADER_COMMIT:-26f96b4294b83108ee66fbfbe4d73bc35d9634a8}  # master

log() { printf '\n==> %s\n' "$*"; }
mkdir -p "$TOOLCHAIN/logs" "$TOOLCHAIN/prefix/bin"
TOOLCHAIN=$(cd "$TOOLCHAIN" && pwd)
cd "$TOOLCHAIN"

# 1. Homebrew formulae ---------------------------------------------------------
if [[ -z ${SKIP_BREW:-} ]]; then
  need=()
  formulae=(cmake boost eigen xz yosys ninja)
  [[ -n ${SKIP_OPENFPGALOADER:-} ]] || formulae+=(libusb libftdi pkgconf)
  for f in "${formulae[@]}"; do
    brew list --versions "$f" >/dev/null 2>&1 || need+=("$f")
  done
  command -v python3 >/dev/null || need+=(python@3)
  if ((${#need[@]})); then log "brew install ${need[*]}"; brew install "${need[@]}"
  else log "brew formulae already installed"; fi
fi

# 2. Sources ---------------------------------------------------------------------
clone() { # url dir commit
  if [[ ! -d $2/.git && ! -f $2/.git ]]; then
    log "cloning $1"
    GIT_TERMINAL_PROMPT=0 git clone "$1" "$2" > "logs/clone_$(basename "$2").log" 2>&1
  fi
  if [[ $(git -C "$2" rev-parse HEAD) != $(git -C "$2" rev-parse "$3^{commit}" 2>/dev/null || echo x) ]]; then
    [[ -z $(git -C "$2" status --porcelain) ]] || { echo "$2 has local changes; refusing to switch commits" >&2; exit 1; }
    git -C "$2" checkout -q "$3"
  fi
}
clone https://github.com/Ravenslofty/mistral mistral "$MISTRAL_COMMIT"
clone https://github.com/YosysHQ/nextpnr nextpnr "$NEXTPNR_COMMIT"
[[ -n ${SKIP_OPENFPGALOADER:-} ]] || clone https://github.com/trabucayre/openFPGALoader openFPGALoader "$OPENFPGALOADER_COMMIT"
if [[ ! -e mistral-nextpnr/.git ]]; then
  log "creating mistral-nextpnr worktree at nextpnr-latest ($MISTRAL_NEXTPNR_COMMIT)"
  git -C mistral worktree add --detach ../mistral-nextpnr "$MISTRAL_NEXTPNR_COMMIT"
fi

# An existing worktree must honor the requested pin too; local patches make
# switching unsafe, so clone() reports that conflict instead of silently using it.
clone https://github.com/Ravenslofty/mistral mistral-nextpnr "$MISTRAL_NEXTPNR_COMMIT"

apply_patch() { # repo patch
  if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then
    echo "   already applied: $(basename "$2") -> $1"
  else
    git -C "$1" apply "$2"; echo "   applied: $(basename "$2") -> $1"
  fi
}
log "applying macOS patches"
apply_patch mistral         "$PATCHES/mistral-macos-embed-bin.patch"
apply_patch mistral-nextpnr "$PATCHES/mistral-macos-embed-bin.patch"
apply_patch mistral-nextpnr "$PATCHES/mistral-nextpnr-latest-lines-overread.patch"
apply_patch nextpnr         "$PATCHES/nextpnr-macos-int64-minmax.patch"

# Homebrew's xz (liblzma) is linked by bare name "lzma" in Mistral.
FLAGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release
       "-DCMAKE_CXX_FLAGS=-I$BREW_PREFIX/include"
       "-DCMAKE_EXE_LINKER_FLAGS=-L$BREW_PREFIX/lib"
       -DCMAKE_PREFIX_PATH="$BREW_PREFIX")

build() { # name srcdir builddir target [extra cmake args...]
  local name=$1 src=$2 bld=$3 target=$4; shift 4
  log "building $name (log: logs/build_$name.log)"
  local t0; t0=$(date +%s)
  cmake -S "$src" -B "$bld" "${FLAGS[@]}" "$@" > "logs/build_$name.log" 2>&1 \
      || { tail -30 "logs/build_$name.log"; exit 1; }
  ninja -C "$bld" -j "$JOBS" $target >> "logs/build_$name.log" 2>&1 \
    || { grep -E "error|FAILED" "logs/build_$name.log" | head -20; exit 1; }
  echo "   done in $(( $(date +%s) - t0 )) s"
}

# 3. Mistral master -> mistral-cv -----------------------------------------------
build mistral mistral build-mistral mistral-cv
install -m755 build-mistral/mistral-cv/mistral-cv prefix/bin/mistral-cv

# 4. Mistral nextpnr-latest -> mistral-cv (same library nextpnr links) ----------
build mistral-nextpnr mistral-nextpnr build-mistral-nextpnr mistral-cv
install -m755 build-mistral-nextpnr/mistral-cv/mistral-cv prefix/bin/mistral-cv-nextpnr-latest

# 5. nextpnr-mistral ------------------------------------------------------------
build nextpnr nextpnr build-nextpnr nextpnr-mistral \
  -DARCH=mistral -DMISTRAL_ROOT="$TOOLCHAIN/mistral-nextpnr" \
  -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DCMAKE_INSTALL_PREFIX="$TOOLCHAIN/prefix"
install -m755 build-nextpnr/nextpnr-mistral prefix/bin/nextpnr-mistral

# 6. openFPGALoader (USB-Blaster / USB-Blaster II JTAG programmer) --------------
# CMSIS-DAP v1 needs hidapi, which the DE10-Standard does not use.
if [[ -z ${SKIP_OPENFPGALOADER:-} ]]; then
  build openFPGALoader openFPGALoader build-openFPGALoader openFPGALoader -DENABLE_CMSISDAP=OFF
  install -m755 build-openFPGALoader/openFPGALoader prefix/bin/openFPGALoader
fi

log "smoke test"
prefix/bin/mistral-cv models | grep 5CSXFC6D6F31C6
prefix/bin/nextpnr-mistral --version 2>&1 | head -1
if [[ -z ${SKIP_OPENFPGALOADER:-} ]]; then
  prefix/bin/openFPGALoader --Version
  prefix/bin/openFPGALoader --list-cables | grep -E '^usb-blasterII '
fi
ls -la prefix/bin

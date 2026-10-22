# Open-source Cyclone V toolchain notes (Mistral + nextpnr-mistral)

Goal: place, route and generate a configuration bitstream for the Intel
Cyclone V **5CSXFC6D6F31C6** (Terasic DE10-Standard) on Apple Silicon macOS
without Quartus, as groundwork for Quartzite producing real programming files.

Status (2026-10-01): **the flow builds and works end to end on this Mac.**
yosys -> nextpnr-mistral -> `.rbf` for the 5CSXFC6D6F31C6, and the bitstreams
check out when decompiled with Mistral's `mistral-cv` (pins and LUT truth
tables, see "Verification"). **None of it has been tried on hardware.** The
output is a raw `.rbf`, not a `.sof`.

## Quick start

```sh
toolchain/build_toolchain.sh                      # ~5 min from scratch, idempotent
toolchain/compile_rbf.sh toolchain/examples/demo4/demo4.v toolchain/examples/demo4/demo4.qsf out/demo4.rbf
toolchain/verify_rbf.py  toolchain/examples/demo4/demo4.spec.json out/demo4.rbf
```

Everything lives in `~/.quartzite/toolchain/` (override with `TOOLCHAIN=`):

| path | what |
|---|---|
| `mistral/` | Mistral master clone (d509238), builds `mistral-cv` |
| `mistral-nextpnr/` | git worktree of the same clone at `origin/nextpnr-latest` (6a97d3e), the `MISTRAL_ROOT` nextpnr is built against |
| `nextpnr/` | nextpnr master clone (f745549) |
| `build-mistral/`, `build-mistral-nextpnr/`, `build-nextpnr/` | ninja build trees |
| `prefix/bin/nextpnr-mistral` | place and route, writes the `.rbf` |
| `prefix/bin/mistral-cv` | Mistral master's bitstream tool (decomp/comp/diff/routes) |
| `prefix/bin/mistral-cv-nextpnr-latest` | the same tool built from the branch nextpnr links |
| `logs/` | clone and build logs |

## Versions

| component | version |
|---|---|
| macOS | 26 (Darwin 25.5.0), Apple Silicon, 8 cores, Command Line Tools only (AppleClang 21) |
| Homebrew | 7.0.4, `/opt/homebrew` |
| yosys | 0.69 (brew bottle; `synth_intel_alm -family cyclonev`) |
| cmake / ninja | 4.4.3 / 1.13.2 |
| boost / eigen | 1.92.0 / 5.0.1 |
| xz (liblzma) | 5.8.3 (already installed) |
| python | 3.14.4 (already installed) |
| Mistral | master `d509238a203aadbb76291ab06543a401df91cf54` (2023-09-03) for mistral-cv; `nextpnr-latest` `6a97d3e` (2022-08-10) for nextpnr |
| nextpnr | master `f7455496240cee1a5a6de262be5bdb1d1e7a3911` (2026-10-01), reports `nextpnr-0.11.1-46-gf7455496` |

Installed formulae: `brew install cmake boost eigen yosys ninja` (55 s, all bottles).
Nothing else was installed and nothing ran with sudo. nextpnr's submodules
(tests, googletest, corrosion, xilinx-meta) are not needed for
`-DARCH=mistral -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF` and were not fetched.

## Why two Mistral checkouts

nextpnr's README says to use Mistral's `nextpnr-latest` branch. That branch
is an ancestor of master; master is 7 commits ahead. **nextpnr does not compile
against master.** Master renamed the core types (`pos_t`, `rnode_t`, `pos2x`,
`rn2t`, ...; commits dc82215 "Gratuitous main types renaming" to d509238
"Convert coords to index everywhere"), which gives about 20 errors in
`nextpnr/mistral/archdefs.h`. So:

- nextpnr-mistral links Mistral `nextpnr-latest` (worktree `mistral-nextpnr/`).
- `mistral-cv` is built from master. For verification it is a second, newer
  decoder that does not share a build with nextpnr. The same tool built from
  `nextpnr-latest` is also installed. On every design tested, both
  decoders give the same routes and LUT masks (for differences in printed
  defaults, see "Open problems"). `verify_rbf.py` passes with either decoder
  (`MISTRAL_CV=.../mistral-cv-nextpnr-latest`) on demo4, gates10 and lut6
  seeds 1-5.

## macOS build workarounds (all in `toolchain/patches/`, applied by build_toolchain.sh)

1. **Apple ld has no `ld -r -b binary`** (`mistral-macos-embed-bin.patch`, both
   Mistral checkouts). libmistral embeds the generated routing databases
   (`<die>-r.bin`, `global.bin`) as objects with GNU ld's binary mode. The
   patch adds a `mistral_embed_bin()` CMake function. On APPLE it writes an
   assembler stub (`.incbin` into `__TEXT,__const` with
   `__binary_<name>_start/_end` labels, which are the C symbols
   `_binary_<name>_start/_end`) and assembles it with clang. Other platforms
   keep the original command.
2. **Bare `lzma` link name.** The generator and mistral-cv use
   `target_link_libraries(... lzma)` with no `find_package`. Configure with
   `-DCMAKE_CXX_FLAGS=-I/opt/homebrew/include -DCMAKE_EXE_LINKER_FLAGS=-L/opt/homebrew/lib`.
3. **Generator segfault on sx120f (old branch only)**
   (`mistral-nextpnr-latest-lines-overread.patch`). In `generator/lines.cc`,
   `LinesParser::next()` copies 63 bytes past the parse pointer into a debug
   buffer (`memcpy(toto, p, 63)`) with no bounds check. For the sx120f
   database, which is the die this board uses, that read crosses the end of the
   buffer. macOS faults there (`EXC_BAD_ACCESS`; ninja shows exit 139 on
   "Generating sx120f-r.bin"). Linux malloc slack hides it. Master removed the
   code. The patch bounds the copy.
4. **libc++ `std::max(int64_t, 8L)`** (`nextpnr-macos-int64-minmax.patch`). On
   macOS `int64_t` is `long long`, so deduction fails in `nextpnr/mistral/pack.cc`
   lines 422 and 475. The patch uses `std::max<int64_t>` / `std::min<int64_t>`.
5. CMake 4.4 warns (CMP0148) about Mistral's `find_package(PythonInterp)`.
   This is harmless.

## Build timings and sizes (8-core M-series, warm disk)

| step | wall | notes |
|---|---|---|
| brew install (5 formulae + deps) | 55 s | bottles |
| clone mistral | ~1.5 min | **1.0 GB** (xz routing databases for 7 dies) |
| clone nextpnr | ~30 s | |
| Mistral master build | 61 s | 76 ninja steps; generator expands sx120f routing to 319 MB |
| Mistral nextpnr-latest build (mistral-cv) | 44 s | |
| nextpnr-mistral build | ~2 min total | 137 steps, includes its own copy of libmistral |
| `prefix/bin/nextpnr-mistral` | 293 MB | all 7 die databases linked in (COMPRESSION_LEVEL=1) |
| `prefix/bin/mistral-cv` | 540 MB | master build |
| toolchain dir total | ~6.7 GB | 1.0 GB clone, 2.0 + 1.1 + 1.3 GB build trees, 1.1 GB prefix (libmistral.a alone is 537 MB in the master tree) |

Fresh-run check: 4 min 20 s from an empty directory (see "Reproducibility").

## Device support (step 2)

- `mistral/data/models.txt`: `model 5CSXFC6D6F31C6 v:sx120f pkg:f31 io:499 gpio:457 ... temp:C speed:6`.
- `mistral-cv models` lists `5CSXFC6D6F31C6  2d02  sx120f  sx120f  f31  896  C  6`.
- `nextpnr-mistral --device 5CSXFC6D6F31C6` imports 2,739,969 wires and 25,465,239 pips
  and reports 83,820 MISTRAL_COMB, 167,640 MISTRAL_FF, 472 MISTRAL_IO, 553 M10K.

## Flow (step 3)

```sh
yosys -p "read_verilog -sv demo4.v; hierarchy -check -top demo4; synth_intel_alm -family cyclonev -top demo4; write_json demo4.json"
nextpnr-mistral --device 5CSXFC6D6F31C6 --json demo4.json --qsf demo4.qsf --rbf demo4.rbf --seed 1
```

`compile_rbf.sh <v> <qsf> <out.rbf> [top]` wraps both commands
(`SEED=`, `NEXTPNR_ARGS=--compress-rbf`, `DEVICE=`). Paths containing spaces or quotes are
supported. Outputs are published only after both tools produce fresh files; a failed run
retains the previous bitstream/netlist and saves its diagnostic logs.

- **QSF support** (`nextpnr/mistral/qsf.cc`): `set_location_assignment PIN_xx -to sig`
  works, and so do bus bits like `SW[0]`. `set_instance_assignment -name X v -to sig` is
  parsed and stored as an IO attribute, but **nothing reads IO_STANDARD**.
  `set_global_assignment` is accepted and ignored. A Quartus-style `.qsf`
  can therefore be passed as is.
- **I/O standard:** `bitstream.cc` hardcodes every output to
  `DRIVE_STRENGTH = V3P3_LVTTL_16MA_LVCMOS_2MA`, `IOCSR_STD = DIS`, weak
  pull-up off. Inputs get weak pull-up off and nothing else. That matches
  "3.3-V LVTTL" in name only. Bank-level VCCIO, slew rate, termination,
  bus-hold and the state of unused pins are not configured. Unused pins keep
  Mistral's defaults, whatever those mean electrically. Quartus defaults
  unused pins to "input tri-stated with weak pull-up".
- Timing: demo4, gates10 and lut6 each take 3-4 s wall in nextpnr (peak RSS
  1.67 GB). Almost all of that is loading the routing graph. Router2 itself
  takes 0.07 s. Yosys takes under 1 s. The first run after a build took 14 s
  (cold cache).
- `.rbf` size: **7,007,204 bytes** uncompressed for any design (full device).
  `--compress-rbf` gives 1,953,121 bytes for gates10, and Mistral decodes and
  verifies that too. Output is deterministic for a fixed seed (same bytes on
  re-run).

## Verification (step 4)

`verify_rbf.py spec.json design.rbf` does this:

1. Runs `mistral-cv decomp 5CSXFC6D6F31C6 design.rbf design.bt`. This is
   Mistral's own decoder, not nextpnr.
2. Checks each constrained pin's GPIO block. An input needs a routed DATAIN
   and output enable off. An output needs a routed DATAOUT (directly, or
   through the hard memory controller's bypass nodes for pads in the HMC
   area), output enable on (the OEIN inverters), and a drive strength.
3. Rebuilds the routed netlist from the decompiled `r` lines and simulates
   each output over the **whole truth table** (2^n rows). It walks from the
   output pad back through routing into ALM LUT masks, recursively, down to
   the input pads. An ALM input with no route must not change the result.
   Any inverter on a data path, any register output, or an ALM in carry
   mode fails the run instead of being guessed.

ALM model: 64-bit `LUT_MASK`.

- 5-LUT halves (TMODE=E_0/BMODE=E_1): top = bits 0-31 on A,B,C,E0,F0;
  bottom = bits 32-63 on A,B,D,E1,F1; address = A + 2B + 4(C|D) + 8E + 16F.
- 6-LUT (Mistral default TMODE=D_E/BMODE=C_E): E = bit 5 picks the half and
  C/D swap between bit 2 and bit 3.
- Inputs are inverted and the mask is stored complemented:
  `out = ~MASK[addr(~inputs)]`.
- MLAB masks are permuted.

This comes from Mistral's LAB documentation (`mistral/docs/lab-cell.pdf`,
`lab-modes.pdf`) and the mapping in `nextpnr/mistral/lab.cc`. It is a separate
implementation of the decoding. The bit semantics, however, come from
Mistral/nextpnr reverse engineering, not from Intel documents.

Sensitivity checks:
- Flipping one LUT row in the decompiled text and recompiling with
  `mistral-cv comp` gives `15/16 rows`.
- Deleting one route gives a "depends on an unrouted input" failure.
- Removing the input inversion from the model gives 1/1024 rows on lut6.
- Removing the 6-LUT C/D swap gives 625/1024 rows on lut6.
- `mistral-cv comp` on the decompiled `.bt` reproduces the nextpnr `.rbf`
  byte for byte.

### Example result (`examples/demo4`, seed default; PASS)

`demo4` is f(w,x,y,z) = Σm(2,3,6,7,9,13,14) (w the MSB, f = w'y + wy'z + xyz') on the
DE10-Standard's SW3..SW0 and LEDR0. nextpnr placed the function in LAB (88,21) ALM 0,
top half (TMODE E_0 / BMODE E_1, two independent 5-LUT halves), next to the right-edge
I/O column:

```
r GPIO.089.025.3:DATAIN.0 ... -> LAB.088.021.0:E0 ; AC30   (w)
r GPIO.089.021.2:DATAIN.0 ... -> LAB.088.021.0:C  ; AB28   (x)
r GPIO.089.025.1:DATAIN.0 ... -> LAB.088.021.0:F0 ; Y27    (y)
r GPIO.089.021.0:DATAIN.0 ... -> LAB.088.021.0:B  ; AB30   (z)
r LAB.088.021.0:FFT1 -> ... -> GPIO.089.011.0:DATAOUT.0 ; AA24   (f; TDFF1.0 = NLUT: combinational)
s GPIO.089.011:DRIVE_STRENGTH.0 V3P3_LVTTL_16MA_LVCMOS_2MA ; AA24   (OEIN.0=1 OEIN.1=0)
s LAB.088.021:LUT_MASK.0 ffffffff.ffcc00f3
```

Input A is unrouted; the verifier enumerates it and both values agree. The decoded
truth table (`verify_rbf.py --table`) gives f = 1 exactly on m = 2, 3, 6, 7, 9, 13, 14,
16/16 rows. The embedded copy of this decoded bitstream in `HardwareSelfTest.swift`
also drives the mutation tests (a flipped LUT entry, a LUT that depends on the unrouted
input, a deleted route, a wrong expected function), which must all be caught.

### Scaling designs (step 5): all PASS on 1024-row tables

| design | what | yosys cells | nextpnr COMB | routed links |
|---|---|---|---|---|
| `examples/gates10` | SW9..0 -> LEDR9..0: AND10, OR10, XOR10, NAND2, NOR2, XNOR2, NOT, BUF, 2:1 MUX, 4-bit A>B (gate level) | 3 ALUT6, 4 ALUT5, 1 ALUT4, 1 ALUT3, 3 ALUT2, 1 NOT, 20 IO | 15 | 267 |
| `examples/lut6` | 10 asymmetric 6-input functions (4:1 mux, 3-bit equality, priority mux, ...) | 6 ALUT6, 4 ALUT5, 1 ALUT3, 1 ALUT2, 20 IO | 14 | ~270 |

- lut6 passes with seeds 1-5. The placements use LABs and MLABs, so the MLAB
  mask permutation and the 6-LUT C/D swap are both exercised.
- The DE10-Standard LEDs LEDR2, 4, 5, 6, 7 and 9 are on the bottom edge,
  inside the HPS SDRAM controller's (HMC) I/O area. Their DATAOUT and OE go
  through HMC bypass nodes (`HMC.025.000:IOINTDQDOUT.n`, `IOINTDQOE.n`).
  nextpnr handles this, and the verifier follows those paths.
- `examples/cmp4` uses a behavioural `>`, which yosys maps to the ALM carry
  chain (5 MISTRAL_ALUT_ARITH). It places, routes and writes an `.rbf`, but
  `verify_rbf.py` reports the carry chain as **not modelled**.

### Quartus bitstream comparison

- Mistral cannot read `.sof`. There is no SOF code in the repo; it reads and
  writes raw `.rbf` only.
- `docs/SOF_FORMAT.md` decodes the `.sof` container separately: Quartzite converts a
  Quartus `.sof` to `.rbf` byte-for-byte as `quartus_cpf` does, and back.
- Quartus inverts LUT inputs too (a real Quartus `.vo` shows inputs such as `!y,!x,!z,!w`
  on dataa/b/c/e), the same convention nextpnr uses. That is the logical netlist, not
  the bitstream.
- On a Quartus 18.1 `.sof` for this part, the bitstream Quartzite extracts decodes with
  `mistral-cv` and passes `verify_rbf.py` with `QZ_FLOAT_INPUT=1` (unrouted ALM inputs
  read as 1, which is how Quartus leaves them).
- `Quartzite --sof-verify <file.qzproj> <file.sof>` runs the Assembler's bitstream check on
  a `.sof` from Quartus. Every pin needs a location assignment. Unrouted LUT inputs are
  assumed to read 1 and the summary says "verified assuming unrouted LUT inputs read 1"
  (`QZ_FLOAT_INPUT=0|1` overrides). Each output's DRIVE_STRENGTH must belong to its board
  pin's I/O standard (`V3P3_LVTTL_*` for 3.3-V LVTTL, `V2P5_*` for 2.5 V). Quartzite's own
  bitstreams are still checked with every value of an unrouted input.

## Open problems / NOT verified

- **No hardware test.** Nothing has been loaded onto a DE10-Standard. All
  checks are against Mistral's reverse-engineered model of the bitstream.
- **sx120f maturity.** Mistral's routing and bitstream model was reverse
  engineered. The most common nextpnr-mistral target, the DE10-Nano's
  5CSEBA6U23I7, maps to the **same sx120f die** (variant se120b, same
  `2d02` idcode per `mistral-cv models`), so the core fabric data is the
  best-exercised part. The **F31 package** pin map (`sx120f-pkg` data for f31)
  and this board's pins are less exercised. nextpnr's README says Cyclone V
  support "is currently experimental and has limited testing". Clocks/PLLs, DSP, M10K,
  HPS, and timing accuracy were not exercised. All designs here are
  combinational.
- **I/O standards are not implemented** (see Flow). Pull-ups, slew, VCCIO
  bank settings and unused-pin state are unverified. The DE10-Standard
  switches and LEDs are on 3.3 V banks, so the hardcoded 3.3-V LVTTL-ish
  drive setting is plausible, but untested.
- **Decoder disagreement on defaults.** Mistral master and nextpnr-latest
  decode identical routes and LUT masks, but they print different
  "non-default" sets:
  - master reports ~48 HMC `IOINTDQ*OE` inverters and 24 `CMUXHR ICLK_SEL`
    settings as non-default even for demo4. For HMC this is a master regression:
    `cv-inv.cc` `DEF_HMC` changed `pn2pi(gpio) == 0` into `!gpio`, which is
    always false.
  - The CMUXHR `iclk_sel` table was restructured in master (165b1da "fix
    issues with cmuxh"). Whether nextpnr-latest's value for those clock-mux
    bits matches what Quartus writes is unknown, and could matter as soon as a
    design uses a clock.

  The `.rbf` bytes are the same either way (`mistral-cv comp` round-trips
  them).
- **Carry chains not verified** (verifier refuses ALMs with ARITH_SEL=ADDER).
  Registers, clocks and LUTRAM are not modelled either.
- **SOF/programming.** The output is `.rbf`. Two things are untested: whether
  Quartus Programmer or `quartus_cpf` will accept it, or a `.sof` wrapped
  around it; and whether a JTAG loader that takes `.rbf` (for example
  openFPGALoader with the DE10-Standard's USB-Blaster II) can configure the
  board with it. The `.rbf` is a plain passive-serial/JTAG image; MSEL and
  compression must match what the loader expects.
- Mistral master is from 2023 and nextpnr-latest from 2022. Neither branch is
  under active development; nextpnr's mistral backend is "undergoing active API
  refactoring".

## Reproducibility

`build_toolchain.sh` pins the three commits above. It applies the four patches
(and skips any that are already applied), re-runs only the missing steps, and
installs into `$TOOLCHAIN/prefix/bin`.

- A re-run with everything in place takes 14 s.
- A from-scratch run into an empty directory
  (`TOOLCHAIN=~/.quartzite/toolchain-fresh-test`, brew already
  satisfied) took **4 min 20 s** wall (clone ~1.5 min, Mistral 61 s, Mistral
  nextpnr-latest 44 s, nextpnr 62 s) and used 6.7 GB.
- The nextpnr-mistral from that fresh build produced a byte-identical
  `lut6.rbf` (seed 1) to the original build.
- `fresh-test/` was only for this check and can be deleted.

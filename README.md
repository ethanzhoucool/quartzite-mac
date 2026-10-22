# Quartzite

A native macOS schematic editor, simulator and compiler for introductory digital-logic
labs that use Intel (Altera) Quartus Prime with a Terasic DE10-Standard board
(Cyclone V 5CSXFC6D6F31C6). It's for Apple Silicon Macs, which can't run Quartus: draw the
circuit, check it, simulate it, then export a real Quartus project to compile and program
on a lab computer.

> **Not affiliated with Intel or Altera.** Quartzite is an independent project. It is not
> made, endorsed or supported by Intel Corporation or Altera Corporation. Quartus, Quartus
> Prime, Cyclone and Intel are trademarks of their owners and are used here only to
> describe compatibility. DE10-Standard is a product of Terasic.

The layout follows Quartus so switching between the two is easy: Project Navigator and
Tasks on the left, `<project>.bdf` / Pin Planner / Assignment Editor / `Waveform.vwf` /
Compilation Report tabs, a Messages pane at the bottom, and the same menu commands and
shortcuts (Start Compilation ⌘L, Start Analysis & Synthesis ⌘K, Pin Planner ⇧⌘N,
Insert Symbol, etc.).

## Status

Young and largely AI-assisted code, backed by extensive automated checks. Know what is
proven and what isn't before relying on it:

| Area | Status |
|---|---|
| Schematic editor, simulation, Quartus-style compile report | Works; covered by self-tests. Some gestures (right-click menu, Hand Tool drag, scroll zoom) have had little hands-on use. |
| Exported `.bdf` / `.qsf` / `.vwf` | Follow real Quartus files and pass an independent geometry and connectivity checker (`ci/bdf_check.py`). Opening a Quartzite export in real Quartus has **not** been confirmed yet. |
| `.sof` container reader/writer | Byte-exact against real Quartus output on 26 public files; `.sof` to `.rbf` matches `quartus_cpf` on 16 pairs (`docs/SOF_FORMAT.md`). |
| Experimental `.sof` generation | Works end to end with the open-source toolchain and is self-verified, but has **never** been loaded by Quartus Programmer or run on a board. DE10-Standard only. |

Keep compiling in Quartus for anything graded.

## Build

```bash
./build_app.sh        # builds Quartzite.app next to the script (Xcode command line tools only)
```

## What it exports

`File > Export Quartus Project...` writes a folder with:

| File | Purpose |
|---|---|
| `<project>.qpf`, `<project>.qsf` | Project and settings: Cyclone V 5CSXFC6D6F31C6, top-level entity, pin locations and each board pin's I/O standard |
| `<project>.bdf` | The schematic in Quartus Block Editor format |
| `Waveform.vwf` | Test vectors counting through every input combination |
| `<project>_pins.qsf` | Pin locations and I/O standards only, for Assignments > Import Assignments |
| `<project>_backup.v` | The same circuit as structural Verilog, as a fallback |
| `README_LAB.txt` | Step-by-step for the lab computer |

## Compiler

`Processing > Start Compilation` runs a real Quartus-style flow on the Mac: Analysis &
Synthesis (exact Quine-McCluskey / Petrick minimization, Cyclone V 6-LUT mapping, LUT
masks), Fitter (pin checks against the DE10-Standard and 5CSXFC6D6F31C6 pin tables,
ALM/LAB packing), Timing Analysis (logic-depth estimate only) and the EDA Netlist Writer
(`simulation/quartzite/<entity>_quartzite.vo`). `Quartzite --compile <file.qzproj> [--report]`
does the same from the command line. Details and sources: `docs/COMPILER_NOTES.md`.

**Experimental .sof.** With the open-source toolchain built (`toolchain/build_toolchain.sh`,
installs into `~/.quartzite/toolchain`) and `Processing > Use Open-Source Fitter and
Assembler` on (the default when the toolchain is found), the Fitter runs yosys +
nextpnr-mistral and the Assembler writes `output_files/<entity>.sof` next to the saved
project, after decoding it again and checking every pin and every truth-table row. The
open-source flow ignores I/O standards and drives outputs at 3.3 V, which suits the
DE10-Standard's switches and LEDs but not every board. Try a trivial design first, with a
Quartus-made `.sof` at hand to reprogram. Without the toolchain the Assembler is skipped
and everything else works as before. CLI: `Quartzite --compile <file.qzproj> --sof <out.sof>`.
Details: `docs/ASSEMBLER_NOTES.md`, `docs/TOOLCHAIN_NOTES.md`.

## Checks

- `Quartzite --selftest` runs the netlist, routing, export, compiler, `.sof` and (when the
  toolchain is installed) hardware-flow checks.
- `Quartzite --export-suite <dir>` exports the reference designs in `TestDesigns.swift`.
- `python3 ci/bdf_check.py <dir>/*` re-reads each exported `.bdf` independently (wire
  endpoints touching ports, same-name wires joined, as Quartus does) and simulates it
  against Quartzite's truth table. It also checks every primitive's drawing and ports,
  including rotated and flipped symbols, against the Quartus library;
  `python3 ci/bdf_check.py --geometry <file.bdf>...` runs only that check (useful on
  .bdf files saved by real Quartus).
- `bash ci/sof_check.sh` runs the `.sof` checks against sample files in `../sof-samples`
  (not included; see `docs/SOF_FORMAT.md` for the public sources).
- `ci/quartus_check.py` compiles the exports with real Quartus Lite 18.1 in GitHub Actions
  when installer links are provided (see `.github/workflows/quartus.yml`).

## License

MIT, see [LICENSE](LICENSE). The optional toolchain is built from third-party open-source
projects under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

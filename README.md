# Quartzite

A native macOS schematic editor, simulator and compiler for introductory digital-logic
labs that use Intel (Altera) Quartus Prime with a Terasic DE10-Standard board
(Cyclone V 5CSXFC6D6F31C6). It's for Apple Silicon Macs, which can't run Quartus: draw the
circuit, check it, simulate it, then export a real Quartus project to compile on a lab
computer. A `.sof` (from Quartus or from Quartzite's experimental flow) can be loaded into
the board straight from the Mac with Tools > Programmer.

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
| Multi-file designs, `.bsf` symbols, the 7447 | Block instances and `.bsf` files match files saved by Quartus Prime 18.0 token for token; covered by self-tests and `bdf_check.py`. Real Quartus has **not** compiled a Quartzite multi-file export yet, and the 7447's behaviour with LTN, RBIN or BIN low follows the TI datasheet, not Quartus. |
| `.sof` container reader/writer | Byte-exact against real Quartus output on 26 public files; `.sof` to `.rbf` matches `quartus_cpf` on 16 pairs (`docs/SOF_FORMAT.md`). |
| Experimental `.sof` generation | Works end to end with the open-source toolchain and is self-verified, but has **never** been loaded by Quartus Programmer or run on a board. DE10-Standard only. |
| Programmer and Board view | Command lines, output parsing and safety checks are tested against a real openFPGALoader build with no board attached. Programming a real DE10-Standard and the live Board view have **not** been tried on hardware yet (`docs/PROGRAMMER.md`). |

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
| `<entity>.bdf` | Each schematic in Quartus Block Editor format: the top-level entity and every file used under it |
| `<entity>.bsf` | The block symbol of each exported file that has one, as Create Symbol Files writes it |
| `Waveform.vwf` | Test vectors counting through every input combination of the top-level entity |
| `<project>_pins.qsf` | Pin locations and I/O standards only, for Assignments > Import Assignments |
| `<project>_backup.v` | The same circuit as structural Verilog, as a fallback (one flat module for multi-file designs) |
| `README_LAB.txt` | Step-by-step for the lab computer |

Files that no block under the top-level entity uses are left out, and the export's
message lists them. A sheet that could only be drawn with a wire touching another net
is refused, with the file named.

## Multi-file designs and library symbols

A project holds several `.bdf` files, as in Quartus:

- **Files.** `File > New...` > Block Diagram/Schematic File adds a file. Each file opens
  in its own tab. The Project Navigator's Hierarchy view shows the instance tree under
  the top-level entity (`FA:inst2`, `7447:inst5`). Its Files view lists every `.bdf`,
  with Set as Top-Level Entity, Create Symbol Files, Rename and Remove File from Project.
- **Symbols.** `File > Create/Update > Create Symbol Files for Current File` makes the
  file's block symbol from its pins and updates the instances that use it.
  `Edit > Update Symbol or Block...` updates the selected instances, every instance of
  that symbol, or all instances.
- **Insert Symbol.** The Symbol dialog lists the project's own blocks under
  Project, the 7447 BCD-to-seven-segment decoder under `others > maxplus2`, and VCC and
  GND under `primitives > other`. Blocks that would make a file contain itself are
  refused, both in this dialog and when pasting.
- **Navigation.** Double-clicking a block opens its file. Hierarchy Up (right-click
  menu) returns to the parent with the same instance selected. Double-clicking a 7447
  shows its function table.
- **Compilation** flattens the hierarchy, so analysis, minimization, simulation and the
  netlist cover the whole design. Messages about a block's contents name the file and
  instance, and double-clicking one opens that file.
- **Limits.** Blocks, the 7447, VCC and GND can't be rotated or flipped yet. Only the
  top-level entity's pins get locations. A design can't use itself.

## Opening Quartus projects

`File > Open...` and `File > Open Project...` also take a Quartus project (`.qpf` or
`.qsf`) or a single block diagram (`.bdf`), such as a project made on a lab computer.
Finder's Open With menu offers Quartzite for `.qpf` and `.bdf` files too; Quartzite
never makes itself the default app for them. The command-line equivalent is
`Quartzite --import <file.qpf|.qsf|.bdf> <out.qzproj>`.

- **What is read.** From the `.qsf`: the device, the top-level entity, every `BDF_FILE`,
  the `set_location_assignment` pin locations and the `IO_STANDARD` lines. Quartus often
  writes `BDF_FILE` with the lab computer's path (`//tsclient/...` or `C:\...`); each file is
  found by its name in the `.qsf`'s folder. Each `.bdf` becomes one file of the design. A
  block whose `.bdf` sits in the same folder but isn't listed is imported too, with a
  message. A lone `.bdf` takes the device and pin locations of a `.qsf` beside it whose
  top-level entity it is.
- **Symbols.** Input and output pins, NOT, AND2-4, OR2-4, NAND2-4, NOR2-4, XOR, XNOR, VCC,
  GND, the 7447 and blocks of the project's own `.bdf` files. Block symbols come from the
  `.bsf` next to the `.bdf`, or from the instance in the parent sheet when there is no
  `.bsf`. Anything else (`lpm_` megafunctions, flip-flops, buses, bidirectional pins,
  Verilog or VHDL blocks) stops the import with a message that names the symbol and the
  file.
- **Connections.** Nets are rebuilt from the wire geometry and the wire and pin names, the
  same way `ci/bdf_check.py` reads an exported `.bdf`. Ports joined by drawn lines become
  Quartzite wires; named wires become net labels. Before the design opens, its
  connectivity is compared with the Quartus nets, so the simulation matches Quartus.
- **Placement.** Symbols keep their Quartus coordinates (Quartzite uses the same units).
  A sheet with negative coordinates is moved right or down by whole grid steps.
  Wires are redrawn by Quartzite's router, so they can take different paths.
- **Input order.** Inputs follow the signal order of the project's waveform (`.vwf`)
  when there is one. Otherwise they are ordered top to bottom.
- **Saving.** The imported design opens unsaved, and the window title says where it came
  from. `Save` asks for a `.qzproj`. `Export Quartus Project...` writes it back for
  Quartus.
- **Not kept.** Quartzite writes each board pin's own I/O standard on export. A different
  `IO_STANDARD` in the `.qsf` is listed in the import messages. Lines and shapes drawn on
  the sheet that are not wires are left out. Rotated VCC, GND, 7447 and block symbols are
  drawn upright; their connections don't change.

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

## Programming the board

Tools > Programmer loads a `.sof` into the DE10-Standard's FPGA over the board's own
USB-Blaster II, like Quartus Programmer, using the open-source
[openFPGALoader](https://github.com/trabucayre/openFPGALoader). One-time setup:

1. **openFPGALoader.** `toolchain/build_toolchain.sh` builds it into
   `~/.quartzite/toolchain/prefix/bin` with the rest of the toolchain
   (`SKIP_OPENFPGALOADER=1` leaves it out). `brew install openfpgaloader` also works.
2. **USB-Blaster II firmware.** The board's programmer needs Intel's `blaster_6810.hex`,
   which comes with every Quartus installation, including the free Lite edition, in
   `<Quartus folder>/quartus/linux64/`. Copy it to your Mac (for example to
   `~/.quartzite/blaster_6810.hex`, which is searched automatically) or choose it in
   Quartzite > Settings > Programmer. Quartzite does not include it.
3. Connect the board's USB-Blaster II port to the Mac and turn the board on.

Then, in the Programmer: **Hardware Setup...** should show `DE-SoC [USB-1]`, **Auto
Detect** reads the chain (`SOCVHPS`, then `5CSXFC6D6F31`), **Add File...** picks the
`.sof` (by default `output_files/<project>.sof`), tick **Program/Configure** on the FPGA
row and click **Start**. The progress bar ends at "100% (Successful)". The design runs
until the board is turned off, as with Quartus. Quartzite checks the `.sof` first and
refuses a file made for a different device.

The **Board** tab shows the switches, push buttons, LEDs and seven-segment displays live,
read over JTAG with boundary-scan SAMPLE, which does not disturb the running design. It
needs the 5CSXFC6D6F31 BSDL file from Intel's website, chosen in Settings.

From Terminal:

```bash
Quartzite --detect [--cable usb-blasterII|usb-blaster] [--firmware blaster_6810.hex] [--bsdl 5CSXFC6D6F31.bsd]
Quartzite --program output_files/lab.sof [--cable ...] [--firmware ...] [--dry-run]
```

`--dry-run` checks and converts the `.sof` and prints the exact openFPGALoader commands
without touching the board. Setup, troubleshooting and what has and hasn't been tested
are in [docs/PROGRAMMER.md](docs/PROGRAMMER.md).

## Checks

- `Quartzite --selftest` runs the netlist, routing, export, compiler, `.sof` and (when the
  toolchain is installed) hardware-flow checks.
- `Quartzite --export-suite <dir>` exports the reference designs in `TestDesigns.swift`,
  including the multi-file `hier_fixture`, `addsub4` and `addsub4_display` and the 7447
  designs.
- `python3 ci/bdf_check.py <dir>/*` re-reads each exported `.bdf` independently (wire
  endpoints touching ports, same-name wires joined, as Quartus does) and simulates it
  against Quartzite's truth table. It also checks every primitive's drawing and ports,
  including rotated and flipped symbols, against the Quartus library;
  `python3 ci/bdf_check.py --geometry <file.bdf>...` runs only that check (useful on
  .bdf files saved by real Quartus).
- The self-test also exports every reference design and `ci/designs` project, imports it
  back and compares the truth table, pin locations, files and blocks. It then exports
  the imported design and imports it again. It imports the Quartus-saved fixtures in
  `ci/fixtures/quartus18/hier`. With `QUARTZITE_PRIVATE_LABS=<folder>`, it also imports
  course projects kept outside the repository and reads them at run time.
- `bash ci/sof_check.sh` runs the `.sof` checks against sample files in `../sof-samples`
  (not included; see `docs/SOF_FORMAT.md` for the public sources).
- `ci/quartus_check.py` compiles the exports with real Quartus Lite 18.1 in GitHub Actions
  when installer links are provided (see `.github/workflows/quartus.yml`). For multi-file
  designs and designs with a 7447 it skips the Verilog-conversion and waveform steps and
  says why.

## License

MIT, see [LICENSE](LICENSE). The optional toolchain is built from third-party open-source
projects under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

# Quartzite

Quartzite is a native macOS app for the digital-logic labs that use Intel (Altera) Quartus
Prime and a Terasic DE10-Standard board (Cyclone V 5CSXFC6D6F31C6). Apple Silicon Macs
can't run Quartus. Quartzite lets you do the lab on the Mac: draw the schematic, simulate
it, compile it, and program the board. It reads and writes real Quartus projects, so you
can move between your Mac and a lab computer.

> **Not affiliated with Intel or Altera.** Quartzite is an independent project. It is not
> made, endorsed or supported by Intel Corporation or Altera Corporation. Quartus, Quartus
> Prime, Cyclone and Intel are trademarks of their owners and are used here only to
> describe compatibility. DE10-Standard is a product of Terasic.

## Features

- **Looks like Quartus.**
  - Project Navigator and Tasks sit on the left.
  - Tabs: one per `.bdf`, then Pin Planner, Assignment Editor, `Waveform.vwf` and the
    Compilation Report.
  - Messages appear at the bottom.
  - The menus and shortcuts are the same: Start Compilation ⌘L, Analysis & Synthesis ⌘K,
    Pin Planner ⇧⌘N, Insert Symbol and so on.
- **Block Editor.**
  - Gates, input and output pins, VCC and GND.
  - The 7447 BCD-to-seven-segment decoder.
  - Your own blocks, made with Create Symbol Files, in multi-file designs.
- **Pin Planner.** Shows the DE10-Standard's switches, buttons, LEDs and HEX displays.
  Assign 7-Segment Digit… and Assign Switches… set many pins in one step.
- **Simulation.** Waveform, truth table and K-maps, with a check against your expected
  minterms.
- **Compilation.**
  - The report, equations and netlist follow Quartus's layout.
  - An optional open-source flow writes a `.sof` on the Mac.
- **Quartus projects, both ways.**
  - Open a `.qpf`/`.qsf`/`.bdf` from a lab computer.
  - Export a project that Quartus opens.
- **Programmer.** Loads a `.sof` into the board over USB, with a live Board view of the
  switches, LEDs and HEX displays.

## Requirements

- macOS 14 or later on an Apple Silicon Mac.
- Xcode Command Line Tools 15.3 or later (`xcode-select --install`), to build the app.
- *Optional,* for writing `.sof` files and programming the board: Homebrew, plus the
  open-source toolchain described under [Compiler](#compiler).

## Install

```bash
git clone https://github.com/ethanzhoucool/quartzite-mac.git
cd quartzite-mac
./build_app.sh                  # builds Quartzite.app in this folder
```

Then:

- Open `Quartzite.app`, or drag it to Applications.
- *Optional:* install [Homebrew](https://brew.sh), then run `toolchain/build_toolchain.sh`
  once for the `.sof` flow and the Programmer. It installs into `~/.quartzite/toolchain` and
  takes about 5 minutes and 7 GB of disk.

## A typical lab

1. **Start the project.** Use File › New Project Wizard…, or File › Open Project… on a
   Quartus `.qpf` you made on a lab computer.
2. **Draw the circuit.**
   - Insert Symbol puts down gates, pins, VCC/GND, the 7447 and your own blocks.
   - Drag from a port to draw a wire.
   - A named wire connects to every other wire with the same name.
3. **Simulate.** Processing › Run Functional Simulation (⌥⌘R), or the button on the
   `Waveform.vwf` tab. It compiles first if needed.
4. **Assign pins** in the Pin Planner by clicking a node, then the switch, LED or segment.
5. **Get it onto the board.** Use either route:
   - **Programmer on the Mac:** save the project, compile with the open-source toolchain
     on (see [Compiler](#compiler)), then open Tools › Programmer and click Start. See
     [Programming the board](#programming-the-board).
   - **Quartus on a lab computer:** File › Export Quartus Project…, then open the `.qpf`
     there and compile.

## Status

Quartzite is new. Know what has been checked before relying on it:

| Area | Status |
|---|---|
| Editor, simulation and compile report | Work and are covered by self-tests. Some gestures (right-click menu, Hand Tool drag, scroll zoom) have had little hands-on use. |
| Exported `.bdf` / `.qsf` / `.vwf` | Follow real Quartus files and pass an independent geometry and connectivity checker (`ci/bdf_check.py`). Opening an export in real Quartus has **not** been confirmed yet. |
| Multi-file designs, `.bsf` symbols, the 7447 | Match files saved by Quartus Prime 18.0 token for token. Real Quartus has **not** compiled a Quartzite multi-file export yet. The 7447's behaviour with LTN, RBIN or BIN low follows the TI datasheet, not Quartus. |
| Opening Quartus projects | Round-trip tested on every reference design, and on projects made and compiled in real Quartus 18.0. |
| `.sof` reader/writer | Byte-exact against real Quartus output on 26 public files. `.sof` → `.rbf` matches `quartus_cpf` on 16 pairs. |
| Experimental `.sof` generation | Works end to end with the open-source toolchain and checks itself, but has **never** been loaded onto a board. |
| Programmer and Board view | Tested against a real openFPGALoader build with no board attached. **Not** yet tried on a real DE10-Standard. |

Keep compiling in Quartus for anything graded.

## Multi-file designs and library symbols

A project holds several `.bdf` files, as in Quartus.

- **Files.**
  - File › New… › Block Diagram/Schematic File adds a file, and each file opens in its
    own tab.
  - The Project Navigator's Hierarchy view shows the instance tree under the top-level
    entity, such as `FA:inst2` and `7447:inst5`.
  - The Files view lists every `.bdf`, with Set as Top-Level Entity, Create Symbol Files,
    Rename and Remove File from Project.
- **Symbols.**
  - File › Create/Update › Create Symbol Files for Current File makes a file's block
    symbol from its pins, and updates the instances that use it.
  - Edit › Update Symbol or Block… updates the selected instances, every instance of that
    symbol, or all instances.
- **Insert Symbol.**
  - The dialog lists your blocks under Project, the 7447 under `others › maxplus2`, and
    VCC and GND under `primitives › other`.
  - A block that would make a file contain itself is refused, both here and when pasting.
- **Navigation.**
  - Double-click a block to open its file. Hierarchy Up (right-click menu) goes back to
    the parent.
  - Double-click a 7447 to see its function table.
- **Compilation** flattens the hierarchy. Messages about a block name the file and
  instance; double-click one to open that file.
- **Limits.**
  - Blocks, the 7447, VCC and GND can't be rotated or flipped yet.
  - Only the top-level entity's pins get locations.

## Opening Quartus projects

File › Open… and File › Open Project… also take a Quartus project (`.qpf` or `.qsf`) or a
single `.bdf`. Finder's Open With menu offers Quartzite for `.qpf` and `.bdf` files, but
Quartzite never makes itself their default app.

- **Read from the `.qsf`:**
  - the device and top-level entity;
  - every `BDF_FILE`, found by file name next to the `.qsf` even when Quartus saved a
    lab-computer path;
  - pin locations and `IO_STANDARD` lines.
- **Symbols:**
  - pins, NOT, AND/OR/NAND/NOR with 2 to 4 inputs, XOR and XNOR;
  - VCC, GND and the 7447;
  - blocks of the project's own `.bdf` files.

  Anything else stops the import with a message naming the symbol and file. That
  includes `lpm_` megafunctions, flip-flops, buses, bidirectional pins, and Verilog or
  VHDL blocks.
- **Connections.**
  - Nets are rebuilt from the wire geometry and wire names, then checked against the
    Quartus nets before the design opens. That makes the simulation match Quartus.
  - Symbols keep their coordinates.
  - Wires are redrawn by Quartzite's router, so their paths can differ.
- **Saving.** The imported design opens unsaved. Save writes a `.qzproj`, and Export
  Quartus Project… writes it back for Quartus.
- **Not kept:**
  - non-default `IO_STANDARD` values, which are listed in the import messages;
  - drawn lines that aren't wires;
  - rotation of VCC, GND, 7447 and block symbols, which are drawn upright with the same
    connections.

## Exporting to Quartus

File › Export Quartus Project… writes a folder with:

| File | Purpose |
|---|---|
| `<project>.qpf`, `<project>.qsf` | Project and settings: device, top-level entity, pin locations, I/O standards |
| `<entity>.bdf` | Every schematic used under the top-level entity, in Quartus Block Editor format |
| `<entity>.bsf` | The block symbol of each file that has one, as Create Symbol Files writes it |
| `Waveform.vwf` | Test vectors counting through every input combination |
| `<project>_pins.qsf` | Pin locations and I/O standards only, for Assignments › Import Assignments |
| `<project>_backup.v` | The same circuit as structural Verilog, as a fallback |
| `README_LAB.txt` | Step-by-step for the lab computer |

Files that nothing under the top-level entity uses are left out, and the export's
message lists them.

## Compiler

Processing › Start Compilation runs a Quartus-style flow on the Mac:

- **Analysis & Synthesis:** exact Quine-McCluskey / Petrick minimization, Cyclone V 6-LUT
  mapping.
- **Fitter:** pin checks against the DE10-Standard and 5CSXFC6D6F31C6 pin tables, plus
  ALM/LAB packing.
- **Timing Analysis:** a logic-depth estimate only.
- **EDA Netlist Writer.**

Details are in [docs/COMPILER_NOTES.md](docs/COMPILER_NOTES.md).

**Experimental `.sof`.** Setup:

- Run `toolchain/build_toolchain.sh`. It installs yosys from Homebrew and builds
  nextpnr-mistral, Mistral and openFPGALoader into `~/.quartzite/toolchain` (about 5
  minutes and 7 GB). To put it elsewhere, run the script with `TOOLCHAIN=<dir>` and start
  Quartzite with `QUARTZITE_TOOLCHAIN=<dir>`.
- Turn on Processing › Use Open-Source Fitter and Assembler (Experimental). It is on by
  default when the toolchain is found.

What it does:

- The Assembler writes `output_files/<entity>.sof` next to the saved project. Without the
  toolchain the Assembler is skipped and everything else still works.
- It then decodes the file again and checks every pin and truth-table row.
- The open-source flow ignores I/O standards and drives outputs at 3.3 V.

Try a simple design first, with a Quartus-made `.sof` at hand. See
[docs/ASSEMBLER_NOTES.md](docs/ASSEMBLER_NOTES.md) and
[docs/TOOLCHAIN_NOTES.md](docs/TOOLCHAIN_NOTES.md).

## Programming the board

Tools › Programmer loads a `.sof` into the DE10-Standard's FPGA over the board's USB-Blaster
II, using the open-source [openFPGALoader](https://github.com/trabucayre/openFPGALoader).
The `.sof` can come from Quartzite or from Quartus.

One-time setup:

1. **openFPGALoader.** `toolchain/build_toolchain.sh` builds it (`SKIP_OPENFPGALOADER=1`
   leaves it out), or install it with `brew install openfpgaloader`.
2. **USB-Blaster II firmware.**
   - The board's programmer needs Intel's `blaster_6810.hex`. It comes with Quartus Prime
     for Linux (any edition, including the free Lite edition), in
     `<Quartus folder>/quartus/linux64/`. Whether Windows installations include it has not
     been checked.
   - Copy it to `~/.quartzite/blaster_6810.hex`, where Quartzite finds it automatically,
     or choose it in Quartzite › Settings › Programmer.
   - Quartzite does not include this file.
3. Connect the board's USB-Blaster II port to the Mac and turn the board on.

Then use it like Quartus Programmer:

1. **Hardware Setup…** should show `DE-SoC [USB-1]`.
2. **Auto Detect** should list `SOCVHPS` and `5CSXFC6D6F31`.
3. **Add File…** picks the `.sof` (by default `output_files/<project>.sof`).
4. Tick **Program/Configure** on the FPGA row and click **Start**. The progress bar ends at
   "100% (Successful)".

The design runs until the board is turned off. Quartzite refuses a `.sof` made for a
different device.

The **Board** tab shows the switches, buttons, LEDs and HEX displays live. It reads them
over JTAG with boundary-scan SAMPLE, which doesn't disturb the running design. It needs the
5CSXFC6D6F31 BSDL file from Intel's website, chosen in Quartzite › Settings › Programmer ›
Board view.

Setup, troubleshooting and test status are in [docs/PROGRAMMER.md](docs/PROGRAMMER.md).

## Command line

The app binary (`Quartzite.app/Contents/MacOS/Quartzite`, written `Quartzite` below) also
runs from Terminal:

| Command | What it does |
|---|---|
| `--compile <file.qzproj> [--report] [--sof <out.sof>]` | Compile, optionally write a `.sof` |
| `--export-project <file.qzproj> <dir>` | Export a Quartus project |
| `--import <file.qpf\|.qsf\|.bdf> <out.qzproj>` | Import a Quartus project |
| `--program <file.sof> [--cable usb-blasterII\|usb-blaster] [--firmware <hex>] [--dry-run]` | Program the board; `--dry-run` checks the file and prints the openFPGALoader commands without touching the board |
| `--detect [--cable …] [--firmware …] [--bsdl <file.bsd>]` | Show the JTAG chain, and the board pins with `--bsdl` |
| `--sof-info <file.sof>`, `--sof-to-rbf <in.sof> <out.rbf>` | Inspect or convert a `.sof` |
| `--selftest` | Run the built-in checks |

## Checks

- `Quartzite --selftest` covers:
  - netlist, routing, export, import round trip, compiler, `.sof` and programmer checks;
  - the hardware flow, when the toolchain is installed.
- `Quartzite --export-suite <dir>` exports the reference designs.
  `python3 ci/bdf_check.py <dir>/*` then re-reads each `.bdf` independently and simulates it against Quartzite's
  truth table.
- `python3 -m unittest discover -s ci` runs the Python checks.
- GitHub Actions run all of the above on macOS and Linux. `ci/quartus_check.py` compiles
  the exports with real Quartus Lite when installer links are provided.

## License

MIT, see [LICENSE](LICENSE). The optional toolchain is built from third-party open-source
projects under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

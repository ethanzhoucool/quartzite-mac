# Open-source Fitter and Assembler (experimental .sof)

When the open-source Cyclone V toolchain is installed, Quartzite's Fitter does real
placement and routing and its Assembler writes a `.sof` for the DE10-Standard
(5CSXFC6D6F31C6). None of it comes from Intel. The file has not yet been loaded by Quartus
Programmer or tested on a board (`docs/SOF_FORMAT.md` section 9 has the test procedure),
so every generated `.sof` comes with a warning, and graded work should still be compiled
in Quartus.

Code: `Toolchain.swift` (finding the tools, running them), `HardwareFlow.swift` (Fitter
and Assembler), `BitstreamVerifier.swift` (decoded-bitstream check), `SOF.swift`
(container), `CompileFlow.swift` (stages and report), `Store+Compile.swift` (app).

## In the app

- **Processing > Use Open-Source Fitter and Assembler (Experimental)** turns it on or off.
  The setting is remembered and is on by default. With it off, or without the toolchain,
  the flow is the logical one: the Fitter checks pins and packs ALMs, and the Assembler is
  skipped with the reason.
- **Where the files go:** `output_files/<entity>.sof` next to the saved `.qzproj`, as in
  Quartus. An unsaved project uses `~/Library/Application Support/Quartzite/output_files/<entity>/`.
  Intermediate files (Verilog, `.qsf`, netlists, logs, `.rbf`, decoded bitstreams) go in
  `output_files/quartzite_pnr/`.
- **Messages:** yosys and nextpnr progress (pin placement, placer, router iterations,
  utilisation) shows in the Messages pane while the tool runs. When the stage ends,
  these lines are replaced by the stage's final messages.
- **Stop Processing** terminates the running tool. The Fitter fails with "stopped by the
  user", and any earlier `.sof` stays as it was.
- **Tasks pane:** under the Fitter, a `Toolchain: on / off / not found` row opens a
  dialog showing where each tool was looked for. Under the Assembler, `Show <entity>.sof`
  reveals the file in Finder. Start Assembler (Tasks, toolbar, Processing > Start) is
  enabled only when the flow is on, and it reruns the Fitter if there is no bitstream yet.
- **Compilation Report:**
  - Fitter > Place and Route (nextpnr-mistral): tool versions, step times and file
    paths; yosys cell counts; nextpnr device utilisation; cell and I/O placement; and
    the bitstream decoded from nextpnr's `.rbf` with its pin and truth-table check.
  - Assembler > Summary: file path, checksum, CRC-16, size, record layout, compiler
    version record, verification result and the experimental notice.
  - Assembler > Generated Files and Assembler > Bitstream Check.
- **Tools > Programmer** explains how to load the `.sof` in Quartus Programmer and
  offers Show in Finder.

## The flow

Fitter (after Quartzite's own pin checks and placement of unassigned pins):

1. Write `<entity>.v` (the schematic as gate-level Verilog) and `<entity>.qsf`. The
   `.qsf` holds every pin at the location the Quartzite Fitter chose.
2. `yosys`: `synth_intel_alm -family cyclonev` produces `<entity>.json`.
3. `nextpnr-mistral --device 5CSXFC6D6F31C6 --seed 1` places, routes and writes a raw
   `.rbf`, plus a report and the routed netlist.
4. `mistral-cv decomp` decodes the `.rbf`, independently of nextpnr.
   `BitstreamVerifier` then rebuilds the routed LUT netlist from the decoded bits and
   simulates every input combination against the schematic.

Assembler:

1. Wrap the `.rbf` in a `.sof` (`SOFFile(wrapping:)`). The default layout is 11 records,
   as Quartus 17.0 and later write them, with an 18.1 compiler-version record.
   `--layout 16` gives the 10-record layout of Quartus 15.1 to 16.1.
2. Write it as `<entity>_unverified.sof` in the work folder, then read it back and check
   the file CRC-16, the payload checksum, the device and the record count.
3. Re-extract the bitstream from the written file (`extractRBF`) and compare every CRAM
   and PRAM bit with nextpnr's.
4. Decode the re-extracted bitstream with `mistral-cv` and check every pin and every
   truth-table row again.
5. Only if all of that passes, move the file to `output_files/<entity>.sof` and write
   `<entity>.sof.quartzite.txt` next to it (a plain-text notice plus the checksum).

Quartzite never overwrites a `.sof` that lacks a matching marker, for example one
compiled by Quartus. The Assembler fails and explains why instead. The CLI's `--sof`
skips this protection, because the user named the file.

## Finding the toolchain

The tools are looked for in this order:

1. `QUARTZITE_YOSYS`, `QUARTZITE_NEXTPNR`, `QUARTZITE_MISTRAL_CV`
2. `$QUARTZITE_TOOLCHAIN/prefix/bin` (default `~/.quartzite/toolchain/prefix/bin`, which
   `toolchain/build_toolchain.sh` fills)
3. `PATH`
4. `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` (an app started from Finder gets a
   minimal `PATH`)

`QUARTZITE_NO_TOOLCHAIN=1` hides the toolchain. The app searches again at the start of
every compilation, so a toolchain built while Quartzite is open is found without a restart.

## Command line and checks

```bash
.build/debug/Quartzite --compile ci/designs/example_sop.qzproj --sof /tmp/Example.sof [--report] [--layout 16] [--seed N] [--work DIR]
.build/debug/Quartzite --snapshot-window ci/designs/example_sop.qzproj /tmp/shots --hardware   # window images of an app compile
.build/debug/Quartzite --selftest       # run from the repo root
```

What the self-test covers (`HardwareSelfTest.swift`):

- The verifier on an embedded decoded example bitstream (`toolchain/examples/demo4`), including mutations it must catch.
- The toolchain locator and the logical fallback.
- With the toolchain, the full flow on every design in `TestDesigns.all`.
- Assembler edge cases: a Quartus `.sof` is left untouched, and layout 16 works.
- A compilation through the app's own `Store`: the `.sof` lands in `output_files/`,
  streamed messages are not duplicated, the report names the file, and Stop Processing
  during nextpnr fails cleanly.

`QUARTZITE_SKIP_HW_SELFTEST=1` skips the parts that need the toolchain (about two minutes).

## Limits

- **Untested** in Quartus Programmer and on hardware. Try a trivial design first, with a
  Quartus-made `.sof` at hand.
- **I/O standards:** nextpnr-mistral ignores `IO_STANDARD`, so outputs get a fixed 3.3-V drive.
- **Design support:** combinational logic only, like the rest of Quartzite. The verifier
  refuses registers, carry chains and LUTRAM instead of guessing.
- **Speed:** yosys + nextpnr take about 15 s per compilation, because nextpnr loads the
  full-device routing graph (about 1.7 GB of memory).

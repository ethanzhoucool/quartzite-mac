# Programmer notes (DE10-Standard over USB from macOS)

Goal: load a `.sof` into the Terasic DE10-Standard's Cyclone V from a Mac, and read the
board's switches, buttons, LEDs and displays, without Quartus or Windows.

Status (2026-10-22): **implemented and tested without hardware.** Every command line,
every piece of openFPGALoader output Quartzite parses, and the safety checks are covered
by `Quartzite --selftest`, using output captured from a real openFPGALoader build on this
Mac with no board attached. **Nothing has been tried on a real board yet.** See "What is
verified" at the end.

## Research findings

### Tool: openFPGALoader

[openFPGALoader](https://github.com/trabucayre/openFPGALoader) (Apache-2.0) is the only
maintained open-source loader that drives both Intel cables and knows the Cyclone V SoC:

- **Cables.** `usb-blasterII` (09fb:6810 before its firmware is loaded, `usb-blasterII_1`
  09fb:6010 after) and `usb-blaster` (FTDI, 09fb:6001), both in `src/cable.hpp`.
  `--list-cables` confirms them in the local build.
- **USB-Blaster II firmware.** The on-board USB-Blaster II is a Cypress FX2 with no
  firmware of its own. openFPGALoader uploads `blaster_6810.hex` (`--probe-firmware`,
  `src/usbBlaster.cpp`, `src/fx2_ll.cpp`), waits for the device to re-enumerate as
  09fb:6010, then talks to it. Without the option it stops with "missing FX2 firmware"
  (unless built with `-DBLASTERII_PATH`, which Quartzite does not use).
- **Devices.** `src/part.hpp` lists `0x02d020dd` as "cyclone V Soc 5CSE*A6/5CSX*6" with
  IR length 10. `0x4ba00477` (the HPS's ARM debug port, "SOCVHPS" in Quartus) is a misc
  device with IR length 4. `src/board.hpp` has `de10nano`, `de0nanoSoc` and `de1Soc`
  entries (all `usb-blasterII`), but none for the DE10-Standard. None is needed, because the
  board entry only picks the cable, and Quartzite passes `-c` itself.
- **Chain order and `--index-chain`.** `Jtag::detectChain` inserts each IDCODE at the
  front, so index 0 is the device nearest TDI. That is the order Quartus lists, so the
  DE10-Standard gives index 0 = SOCVHPS and index 1 = 5CSXFC6D6F31. When no index is
  given, openFPGALoader picks the only FPGA by itself (the HPS is not in its FPGA list).
  Quartzite still passes `--index-chain` with the index Auto Detect found, so a different
  chain cannot send the bitstream to the wrong device. `device_select` puts the other
  devices in BYPASS.
- **Formats.** For Cyclone V SRAM loading (`--write-sram`, the default), openFPGALoader
  accepts **`.rbf` and `.svf` only, not `.sof`** (`src/altera.cpp`). Its own docs say the
  `.rbf` must be **uncompressed**, because the Cyclone V cannot decompress during JTAG
  configuration. Quartzite already converts `.sof` to `.rbf` exactly as
  `quartus_cpf --option=bitstream_compression=off` does (`--sof-to-rbf`, byte-exact on 16
  Quartus pairs, `docs/SOF_FORMAT.md`), so the Programmer converts in memory and refuses
  a compressed `.rbf`.
- **What a load does.** `Altera::programMem` sends JTAG CONFIG_IO-style programming:
  IR 0x002 (PROGRAM), the raw bitstream, IR 0x004 (CHECK_STATUS) with an 864-bit read,
  IR 0x003 (STARTUP) and BYPASS. openFPGALoader does **not** check the CHECK_STATUS result
  ("TBD" in the source). "Done" and exit status 0 therefore mean the bytes were sent, not
  that CONF_DONE went high. Quartus Programmer does check it.
- **Output formats Quartzite parses.** `--detect` prints `index N:` blocks (`src/main.cpp`).
  The progress bar prints whole lines like `Load SRAM: [====   ] 45.00%` when stdout is
  not a terminal, and `\r`-overwritten lines when it is (`src/progressBar.cpp`).
  `--scan-usb` prints a table with vid:pid, probe name, manufacturer, serial and product
  (`src/libusb_ll.cpp`). Colour codes appear only on a terminal.

### The firmware, legally

`blaster_6810.hex` is Intel's and is not redistributable, so Quartzite never ships,
downloads or embeds it. The user supplies it from their own Quartus installation:

- Linux Quartus (any edition and version, including the free Lite edition):
  `<install>/quartus/linux64/blaster_6810.hex`, for example
  `~/intelFPGA_lite/18.0/quartus/linux64/blaster_6810.hex`. This is the path
  openFPGALoader's own error message names.
- Windows installations: whether they contain the same file was not checked.

Quartzite looks for it in this order: Settings > Programmer, `--firmware`,
`QUARTZITE_BLASTER_FIRMWARE`, `~/.quartzite/blaster_6810.hex`, then
`~/intelFPGA_lite/*`, `~/intelFPGA/*`, `~/altera_lite/*`, `~/altera/*`,
`/opt/intelFPGA_lite/*`, `/opt/intelFPGA/*`, `/opt/altera/*` (`quartus/linux64/`).
It only checks that the file is Intel HEX (every line starts with `:` and the last
record is `:00000001FF`). `blaster_6826.hex` is for a different USB-Blaster II
variant that openFPGALoader does not support.

### Getting openFPGALoader onto the Mac

`toolchain/build_toolchain.sh` now builds it next to nextpnr and Mistral, into
`~/.quartzite/toolchain/prefix/bin` (or `$TOOLCHAIN/prefix/bin`). Details:

- It is pinned to master `26f96b4` (2026-10-19, `--Version` prints v1.2.0).
- It adds Homebrew `libusb`, `libftdi` and `pkgconf`.
- It builds with `-DENABLE_CMSISDAP=OFF`, because CMSIS-DAP v1 would need hidapi, which the
  board does not use.
- Building takes about 14 s.
- Set `SKIP_OPENFPGALOADER=1` to leave it out.

The Homebrew fallback is `brew install openfpgaloader` (1.2.0, same dependencies).
Quartzite finds the tool through Settings > Programmer (a file, or a folder holding it),
then `QUARTZITE_OPENFPGALOADER`, the toolchain folder, `PATH`, `/opt/homebrew/bin` and
`/usr/local/bin`.

These were checked on this Mac (macOS 26, Apple Silicon) with no board attached:

| Command | Result |
|---|---|
| `openFPGALoader --list-cables` | lists `usb-blasterII 0x09fb:6810`, `usb-blasterII_1 0x09fb:6010`, `usb-blaster 0x09fb:6001` |
| `openFPGALoader --scan-usb` | "No USB devices found", exit 0 |
| `openFPGALoader -c usb-blasterII --detect` | "missing FX2 firmware ...", exit 1 |
| `openFPGALoader -c usb-blasterII --probe-firmware <placeholder> --detect` | "Waiting reload ... Fail / JTAG init failed with: FX2: fail to open device", exit 1 |
| `openFPGALoader -c usb-blaster --detect` | "unable to open ftdi device: -3 (device not found)", exit 1 |

These outputs are kept in `ci/fixtures/openfpgaloader/`. No kernel driver or
system extension is needed: libusb opens the FX2 from user space.

## How Quartzite uses it

| Action | Command (DE10-Standard, USB-Blaster II) |
|---|---|
| Hardware Setup | `openFPGALoader --scan-usb` |
| Auto Detect | `openFPGALoader -c usb-blasterII --probe-firmware <fw> --detect` |
| Start | `openFPGALoader -c usb-blasterII --probe-firmware <fw> --index-chain 1 --write-sram <tmp>/<name>.rbf` |
| Board view (each refresh) | `openFPGALoader -c usb-blasterII --probe-firmware <fw> --index-chain 1 <tmp>/board_sample.svf` |

With `--cable usb-blaster`, `--probe-firmware` is left out.

Before Start, Quartzite:

1. Reads the `.sof` and runs the same container checks as `--sof-info`: record layout,
   CRC-16 and payload checksum. A damaged file is refused.
2. Compares the `.sof`'s device with the detected FPGA. It refuses when the IDCODE die
   differs (for example a DE1-SoC `5CSEMA5F31C6` file), and also when the die matches but
   the part does not (for example a DE10-Nano `5CSEBA6U23I7` file). The board's
   `5CSXFC6D6F31` accepts `5CSXFC6D6F31C6` files, as Quartus does. The SOCVHPS row
   never takes a file.
3. Converts the file to an uncompressed `.rbf` in the temporary folder
   (`$TMPDIR/quartzite-programmer/`) and loads that.

On macOS, openFPGALoader runs under a pseudo-terminal so that its progress bar arrives
while it runs; on a pipe the C library would hold it until exit.

CLI equivalents:

```bash
Quartzite --detect [--cable usb-blasterII|usb-blaster] [--firmware f.hex] [--tool path] [--bsdl 5CSXFC6D6F31.bsd]
Quartzite --program file.sof [--cable ...] [--firmware ...] [--tool ...] [--dry-run]
```

`--dry-run` validates and converts the file and prints the exact detect and program
commands. It assumes the FPGA is index 1, the DE10-Standard's chain, because it does not
read the chain. A missing tool or firmware prints as a bare name with a note.

## Board view: boundary-scan SAMPLE

**Feasible, and built,** with no patch to openFPGALoader and no new library in
Quartzite.

- **Instruction.** IEEE 1149.1 SAMPLE/PRELOAD (`0000000101` on the Cyclone V) copies the
  level of every I/O pad into the boundary-scan register. The pins stay connected to the
  core, so the running design is not disturbed. EXTEST and every other instruction that
  drives pins are never used.
- **Transport.** openFPGALoader has no "read boundary scan" command, but it plays SVF
  files and compares TDO. Quartzite writes `SIR 10 TDI (005); SDR 1485 TDI (0...)
  TDO (0...) MASK (1FF...F);`. If any captured bit is 1, openFPGALoader prints
  `TDO value <hex> isn't the one expected` with the whole register. If every bit is 0, it
  exits normally. Either way the register is known. The zeros shifted in only preload
  the update latches, which SAMPLE does not connect to the pins.
- **Pin map.** The pin-to-cell map comes from Intel's BSDL file for 5CSXFC6D6F31
  (pre-configuration; `BOUNDARY_LENGTH` 1485). The file is Intel's (Altera copyright and
  license terms), so it is not in the repository. The user downloads it from Intel's
  "BSDL Files" page and chooses it in Settings > Programmer. Quartzite parses
  `INSTRUCTION_LENGTH`, `INSTRUCTION_OPCODE`, `BOUNDARY_LENGTH`, `BOUNDARY_REGISTER` and
  the `PIN_MAP_STRING`. For each of the 66 board pins (SW0-9, KEY0-3, LEDR0-9, HEX0-5
  a-g) it uses the `input` cell of the port on that ball.
- **Check against the real file.** The real file's map was checked locally with
  `QUARTZITE_BSDL=<file> Quartzite --selftest`: 1485 cells, SAMPLE `0000000101`, and all 66
  board pins have an input cell. (SW0 / AB30 is cell 894; LEDR0 / AA24 is cell 954.) The
  CI test uses a synthetic BSDL written for the test in the same syntax.
- **Decoding.** Cell 0 is the first bit out of TDO, and the last hex digit printed by
  openFPGALoader. KEY and HEX are active low, so a low KEY pin is shown pressed and a low
  segment pin is shown lit. A LED pin that is high is lit.
- **Rate.** Each refresh starts openFPGALoader once, which loads no firmware after the
  first time. The view polls again 0.2 s after each read. The expected rate is a few
  reads per second, but it has not been measured on hardware.
- **Pre-configuration BSDL.** Intel warns that it describes the device before
  configuration. For the single-ended 3.3-V LVTTL pins the board uses, the input cell
  still captures the pad. Differential or other special I/O can differ after
  configuration (Quartus can write a post-configuration BSDL); Quartzite only reads the
  66 board pins.
- **Rejected alternative.** openFPGALoader's XVC server (`--xvc`) would give raw JTAG
  over TCP, but its USB-Blaster case is compiled out (`#if 0` in `src/xvc_server.cpp`) and
  it listens on all interfaces. Patching it was not needed.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| openFPGALoader was not found | Run `toolchain/build_toolchain.sh` or `brew install openfpgaloader`, or choose the program in Settings > Programmer |
| The USB-Blaster II needs its firmware file | Copy `blaster_6810.hex` from a Quartus installation and choose it in Settings |
| ... is not an Intel HEX firmware file | The chosen file is not `blaster_6810.hex` |
| No Hardware | Board not connected or not powered. Use the USB-Blaster II port (not the UART or OTG port). Unplug and replug after a failed firmware load. |
| access denied / in use by another program | Quit any program holding the USB-Blaster II (a virtual machine running Quartus, another openFPGALoader) |
| TDO is stuck at 0 | The JTAG chain does not respond; check that the board is powered on |
| Device mismatch | The `.sof` was compiled for another device; set Assignments > Device to 5CSXFC6D6F31C6 and recompile |
| compressed .rbf | Use the `.sof`; Quartzite converts it to an uncompressed `.rbf` |
| Board view: BSDL errors | Choose the 5CSXFC6D6F31 BSDL file, not another device's |

Only the first USB-Blaster found is used. With two boards connected, unplug one.

## What is verified

| Without hardware (here) | Untested until a board is plugged in |
|---|---|
| openFPGALoader builds from `build_toolchain.sh`'s pinned commit; `--Version`, `--list-cables`, `--scan-usb` and `--detect` run and fail cleanly with no board | Firmware upload and re-enumeration of the board's FX2 with a real `blaster_6810.hex` |
| Command lines for both cables, firmware, `--index-chain`, `.sof` and `.rbf` paths, shell quoting | The product string `--scan-usb` reports (assumed "DE-SoC", which is what Quartus shows); the `synthesized/` fixtures |
| Parsing of the captured `--list-cables`, `--scan-usb`, `--detect` failures; `--detect` and progress formats from the source | That the real `--detect` shows index 0 = 0x4BA00477 and index 1 = 0x02D020DD, as expected from the source |
| `.sof` checks, device-mismatch refusal, "No Hardware", missing or bad firmware, compressed `.rbf` refusal, failed-load messages | That `--write-sram` of Quartzite's uncompressed `.rbf` configures the FPGA and the design runs (openFPGALoader does not check CONF_DONE) |
| `.sof` to uncompressed `.rbf` conversion (byte-exact with `quartus_cpf` on 16 pairs, existing tests) | Live Board view: SAMPLE through openFPGALoader's SVF player, refresh rate, and that the pre-configuration BSDL cells read the right pads in user mode |
| BSDL parsing; the real Intel file maps all 66 board pins; SVF generation; TDO decoding (synthetic) | Stopping a load midway (Stop terminates openFPGALoader; the FPGA is then unconfigured) |

## Trying it with the board

1. Build Quartzite (`./build_app.sh`) and the toolchain (`toolchain/build_toolchain.sh`).
2. Copy `blaster_6810.hex` from a Quartus installation to `~/.quartzite/blaster_6810.hex`.
3. Connect the DE10-Standard's USB-Blaster II port to the Mac and turn the board on.
4. In Terminal: `Quartzite.app/Contents/MacOS/Quartzite --detect`. Expect
   `Hardware: DE-SoC [USB-1]` (or the real product name), then
   `Device 1: SOCVHPS IDCODE 0x4BA00477` and `Device 2: 5CSXFC6D6F31 IDCODE 0x02D020DD`.
5. `Quartzite.app/Contents/MacOS/Quartzite --program <project>/output_files/<project>.sof`.
   It should end with `Progress: 100% (Successful)`, and the design should run on the board.
6. Optional: download the 5CSXFC6D6F31 BSDL from Intel and run
   `Quartzite --detect --bsdl <file.bsd>` with a few switches up. The `SW 9..0` line
   should match them.
7. Then the same in the app: Tools > Programmer > Hardware Setup, Auto Detect, Start, and
   the Board tab.

Please save the real output of steps 4 to 6 and use it to replace the files in
`ci/fixtures/openfpgaloader/synthesized/`.

# SRAM Object File (.sof) format, Cyclone V

This is a byte-level description of the Quartus `.sof` container as written by Quartus II 14.0 through
Quartus Prime 25.1 for Cyclone V SoC parts, and of how its payload maps onto the raw binary file (`.rbf`)
that `quartus_cpf` produces from it. It was worked out from 26 sample .sof files, 16 of them with a .rbf from
the same compile (section 8). It is implemented in `Sources/Quartzite/SOF.swift`.

Each claim is tagged:

- **[verified N]**: checked by program on N sample files, or on N .sof/.rbf pairs;
- **[hypothesis]**: fits everything we have, but is unproven or rests on one or two samples.

All multi-byte integers are little-endian. "Mistral" is the open Cyclone V bitstream library
(github.com/Ravenslofty/mistral: `libmistral/cv-files.cc`, `cv-opt.cc`, `cvd-sx120f.cc`, `data/*-mux.txt`).
Its RBF writer is the reference for the .rbf side. Everything on the .sof side, and the Quartus-specific
.rbf details in 3.1 to 3.3, are new.

## 1. Container

```
offset 0   "SOF\0"                  magic                                    [verified 26]
offset 4   u32 0                    reserved                                 [verified 26]
offset 8   u32 record count         equals the number of records             [verified 26]
offset 12  records, back to back to end of file, no padding                  [verified 26]
record:    u16 tag, u32 body length, body[length]
```

Records seen, in the order Quartus writes them **[verified 26]**:

| tag | name | length | written by | contents |
|---|---|---|---|---|
| 0x0001 | compiler version | var | all | ASCII + NUL, e.g. `Quartus Prime Compiler Version 18.1.0 Build 625 09/12/2018 SJ Lite Edition` |
| 0x0002 | device | var | all | part number + NUL, e.g. `5CSXFC6D6F31C6` |
| 0x0003 | IP list | var | all | `Untitled\0` (15 files), or the licensed IP in the design, e.g. `(V6AF7PBCE1LYSSignal Tap;V6AF7PBCECLYSSignal Tap;)\0`, `(V6AF7P0034LYSFFT/IFFT;)\0` (11 files) |
| 0x003B | hash | 17 | 17.0+ | 16 opaque bytes + 0x00 **[verified 22]**. Not the MD5 of the CRAM, the PRAM, both, the option record or the bytes before it **[verified 1]** |
| 0x0012 | option record | 110 | all | design-independent option bits (section 5) |
| 0x0013 | checksum | 16 | all | `00 00 00 00 20 00 20 00 00 00 01 00` **[verified 26]**, then u32 checksum |
| 0x0024 | embedded files | var | all | section 4 |
| 0x0011 | CRAM | 12 + ceil(bits/8) | all | payload record (section 2) |
| 0x0015 | PRAM | 12 + ceil(bits/8) | all | payload record (section 2) |
| 0x0016 | OpenCore Plus | 16 | time-limited files only | `OC++,V6AF7P00A2\0` in the one `_time_limited.sof` sample |
| 0x0033 | unknown | 4 | 15.1+ | `00 00 00 00` **[verified 25]** |
| 0x0008 | file CRC | 2 | all | section 1.1 |

Record sets by version **[verified 26]**: 14.0 writes 9 records; 15.1 and 16.1.2 write 10 (add 0x0033); 17.0.2 to
25.1 write 11 (add 0x003B), plus 0x0016 in a time-limited file.

### 1.1 Checksums

**File CRC (0x0008)** **[verified 26]**: CRC-16/X-25 (also called CRC-16/IBM-SDLC): polynomial 0x1021 reflected
(the shift register uses 0x8408), init 0xFFFF, final xor 0xFFFF. It covers every byte from offset 0 through
the 6-byte header of the 0x0008 record, which is everything except the two CRC bytes, and is stored as u16 LE.
Equivalently, the X-25 register over the whole file, before the final xor, ends at the standard residue 0xF0B8.

**Checksum (0x0013, bytes 12..15)** **[verified 26]**: the sum mod 2^32 of every CRAM payload byte plus every
PRAM payload byte (the 12-byte payload headers are not included). `quartus_cpf` writes the same value into the
.rbf as the JTAG usercode (3.1) **[verified 16 pairs]**. We assume, without having checked, that this is the
"Checksum" column in Quartus Programmer.

How the CRC was found, so nobody repeats the dead ends: CRC-16 with polys 0x8005, 0x1021, 0x3D65, 0x8BB7,
0xA097, 0x0589, 0xC867, 0x5935, 0x755B, 0x1DCF, 0x6F63, 0x2F15 (both reflections, several inits) on assumed
ranges, byte sums, 16-bit sums, XOR and Fletcher-16 all failed. Looking for a configuration whose whole-file
CRC is the same constant on three different files found X-25 at once.

## 2. Payload records (0x0011 CRAM, 0x0015 PRAM)

```
6 bytes   00 00 00 00 00 00
u32       number of bits
u16       1
bytes     ceil(bits/8) bytes; bit k at byte k>>3, bit k&7 (LSB first); unused high bits of the last byte are 0
```
**[verified 26]**. The payload is never compressed, which is why about 95% of a .sof is zero bytes.

The bit counts are Mistral's die geometry: CRAM bits = `cram_sx * cram_sy`, PRAM bits = sum of `pram_sizes`.
25 samples are on the `sx120f` die (5CSEMA5, 5CSEBA6, 5CSXFC6: 7605 x 7024 = 53,417,520 CRAM bits and
99,574 PRAM bits). One sample, 5CSEMA4U23C6, is on `sx50f` (6006 x 5304 = 31,855,824 and 80,505)
**[verified 26]**. The converter below handles sx120f only.

### 2.1 CRAM bit order (sx120f) **[verified 16 pairs]**

SOF bit `k = x + 7605*y` is configuration bit (x, y) in Mistral's coordinates (`cram[x + cram_sx*y]`), **except**
inside the 18 MLAB tiles. Those start at bit-columns 183, 615, 750, 1418, 1769, 2023, 2455, 2806, 3356, 4039,
4589, 5237, 5608, 6277, 6891, 7144, 7279 and 7448, and in each the 30 columns at offset 9..38 are stored permuted:

```
SOF column (base + 9 + q) holds RBF/Mistral column (base + 9 + perm[q])
perm = [2,3,6,7,10,11,27,26,23,22,19,18,15,14,0,1,4,5,8,9,12,13,29,28,25,24,21,20,17,16]
```

The permutation moves whole columns, for every row. Without it, 320 bits (DE10_NANO) to 29,000 bits
(Galaksija) end up in the wrong column; with it, every bit of all 16 pairs matches. These columns hold the MLAB
LUT masks. nextpnr-mistral's `mlab_permute` table describes the same reordering inside a single LUT mask.
Rows 0..31 are always 0 in the SOF **[verified 26]**; in the RBF they are the frame-header area.

### 2.2 PRAM bit order (sx120f) **[verified 16 pairs]**

SOF PRAM bit k enumerates Mistral's `pram[bit][i]` with `bit` from 31 down to 0 and, inside each, `i` from
size[bit]-1 down to 0 (bits 15..31 have size 0). In .rbf terms (`base = 9669 - i - 1`), that is ascending `base`
within each bit plane.

## 3. SOF to RBF (what `quartus_cpf -c x.sof x.rbf` does)

Uncompressed sx120f .rbf, always 7,007,204 bytes **[verified 6 pairs]**:

```
0x00000  0x80 x FF, then "jjjj"
0x00084  option RAM: 32 strips x 40 bits; bit b of strip s is byte 0x84 + (s>>3) + 4*b, mask 0x80 >> (s&7)
0x00124  00 00; CRC-16 of 0x84..0x125 at 0x126; then FF up to byte 1020
1020     43 PRAM frames x 916 bytes. PRAM bit (bit, i) is at 1020 + 4 + (bit>>3) + 4*base + 8*(base/227),
         mask 1 << (bit&7). The last frame starts 2A C5 01. Each frame ends with its CRC-16.
40408    7605 CRAM frames x 916 bytes, one per column x:
           row y >= 32 is frame bit 224 + (31 ^ yb) + 32*ya, ya = (y+16) % 220, yb = (y+16) / 220
           frame 0 starts 84 3E 01; frame 7604 starts 42 9F 00
           bytes 908..911: EDCRC (crc32, poly 0xF4ACFB13, init 1, read lane by lane; Mistral `crc32`),
             0 for frames in the 10 no-EDCRC zones; LUTRAM rows excluded (3.3)
           bytes 914..915: CRC-16 of bytes 0..913
7006588  postamble 1: EC 64, 188 x 00, CRC-16 (192 bytes); postamble 2: AE FB, 8 x 00, CRC-16 (12 bytes)
7006792  412 x FF
```

CRC-16 is Mistral's: polynomial 0x8005 reflected (0xA001), init 0xFFFF, no final xor (the CRC-16/MODBUS
parameters). Mistral's `rbf_save` produces this layout given the CRAM and PRAM arrays. The .sof-specific parts
are sections 2.1 and 2.2 and the option RAM below.

### 3.1 Option RAM

A .sof has no option RAM, so `quartus_cpf` makes one. Over the 16 pairs:

| strip.bit | value | evidence |
|---|---|---|
| everything not listed | fixed template (`CycloneVSX120F.oramTemplate`) | **[verified 16 pairs]** (5CSEBA6 x5, 5CSEMA5 x9, 5CSXFC6 x2) |
| 6.19..6.26 | `idcode`: 0x02 for 5CSEBA6 and 5CSXFC6 (JTAG 0x02D020DD), 0x12 for 5CSEMA5 (0x02D120DD) | **[verified 16]**; the other sx120f parts' values come from Mistral's model table **[hypothesis]** |
| 7.8..7.39 | `jtag_id` = the .sof checksum | **[verified 16]** |
| 6.35 | `compression_dis` (Mistral's name): 1 uncompressed, 0 compressed | **[verified 16]** |
| 4.0 | 1 uncompressed, 0 compressed | **[verified 16]** |
| 5.16..5.39 | `(((L - K) mod 2^22) << 2) \| 1`; L = .rbf length in bytes; K = 305 uncompressed, 357 compressed | **[verified 16]**: 10 distinct compressed lengths, and the uncompressed value 0xABAACD |
| 2.10 | 0 when option-record byte 0x15 bit 2 is 0, else 1 | **[hypothesis, 1 sample]** (Quartus 14.0; byte 0x4C bit 2 is the other candidate) |
| 4.8 | 1 in the Quartus 25.1 file only | **[hypothesis, 1 sample]**; SOF.swift sets it for version >= 25 |

### 3.2 Compressed RBF (`bitstream_compression=on`; MiSTer cores, OpenCL BSPs, HPS FPGA images)

The 916-byte CRAM frames, both postambles and the trailing 0xFF bytes all go through one nibble compressor:
for each byte pair, a 4-bit mask of the non-zero nibbles, then those nibbles, low nibble first (Mistral's
scheme) **[verified 10 pairs]**. Two Quartus details on top of Mistral:

1. **Word alignment (15.1 and later)** **[verified 9 pairs, 15.1 to 25.1]**: Quartus makes up to 7 zero nibbles
   explicit (sets their mask bits), working backwards from the end of postamble 2 (high nibble before low nibble,
   last byte first), until the stream up to the end of postamble 2 is 2 nibbles past a 32-bit boundary. The 412
   0xFF bytes that follow compress to 1030 nibbles, so the whole compressed stream ends on a 32-bit boundary.
2. **Quartus 14.0** **[1 pair]**: no alignment, and 392 trailing 0xFF bytes instead of 412.

The `5.16..5.39` field in 3.1 is then computed from the final length.

### 3.3 LUTRAM and the EDCRC **[verified 2 pairs, 3 LUTRAM tiles]**

When an MLAB tile is used as RAM, Quartus computes the EDCRC of that tile's frames `base+7 ..< base+39` as
if the tile's 86 rows (`2 + 86*ty ..< 2 + 86*ty + 86`) were zero. Those bits change at run time, so error
detection has to skip them. A tile counts as LUTRAM when its `ram_dis` bit (tile offset x+42, y+44) is 0 and
its `write_en` bit (x+42, y+43) is 1; the names and offsets are from Mistral's `mlab-mux.txt`. This was found
on the Quartus 14.0 OpenCL sample, which has one LUTRAM tile, and confirmed on a 15.1 OpenCL sample, which has two.
Mistral/nextpnr do not do this. The per-frame CRC-16, which the FPGA always checks, is self-consistent
either way. The EDCRC only matters when CRC error detection is enabled.

## 4. Embedded files (0x0024) **[verified 26 files, 143 entries]**

A sequence of entries:

```
u32 mtime (Unix seconds; 0 for design_hash.bin)
u16 flags (0x0100 or 0)
u32 name length including NUL
u16 0
u32 data length
name, data
```

The first entry is always `design_hash.bin`: 16 bytes, `00 00`, then the 10-byte `md5_digest_80b` that also appears
in the .jdi, then 4 zero bytes **[verified 26]**. Then come `<project>.jdi` (the `<sld_project_info>` XML), `<project>.sld`
(15.1+), and for Qsys/HPS designs the `.sopcinfo`, `.regmap` and `.debuginfo` files. The latter make HPS-design .sof
files 0.65 to 1 MB larger. Flags are 0x0100 on every sopcinfo/regmap/debuginfo and on 11 of 26 .jdi files. These
files feed SignalTap and System Console, and are presumably not needed for configuration **[hypothesis]**.

## 5. Option record (0x0012)

110 bytes, byte-identical in 24 of 26 files (Quartus 15.1 to 25.1, all four parts, both dies)
**[verified 24]**. It is not a copy of the .rbf option RAM: no 40-bit ORAM strip appears in it at any bit offset,
in either bit order **[verified 1]**. The two exceptions differ in a few bits: SaleTerminal (20.1.1) at bytes 0x01,
0x1E and 0x1F, and the Quartus 14.0 OpenCL file at bytes 0x15 and 0x4C (see 3.1, bit 2.10). Apart from that, its
mapping is unknown. SOF.swift writes the common value, and conversion refuses a .sof whose option record is not 110
bytes (an empty or cut record would otherwise convert with default options).

## 6. RBF to SOF

Inverting section 3 gives the CRAM and PRAM exactly **[verified 16 pairs]**. The .rbf does not carry records 0x0001,
0x0003, 0x003B, 0x0012 or 0x0024. `SOFFile(wrapping:device:options:)` fills them in:

| record | value written |
|---|---|
| 0x0001 | `Quartus Prime Compiler Version 18.1.0 Build 625 09/12/2018 SJ Lite Edition` (`--compiler-version`) |
| 0x0002 | the device given on the command line, upper-cased. It must be one of the 82 sx120f-die parts in `mistral-cv models` (a bare die prefix such as `5CSXFC6` is refused), and its idcode must match the one in the .rbf |
| 0x0003 | `Untitled` |
| 0x003B | a deterministic 128-bit digest of CRAM+PRAM, then 00. This is not Quartus' algorithm, which is unknown. Only with `--layout 17` (the default) |
| 0x0012 | the common 110-byte value |
| 0x0013 | constant prefix + recomputed checksum |
| 0x0024 | `design_hash.bin` from the same digest; with `--project NAME`, also `output_files/NAME.jdi` and, for layout 16 and up, `.sld` |
| 0x0011, 0x0015 | from the .rbf |
| 0x0033 | 4 zero bytes (layout 16 and up) |
| 0x0008 | recomputed CRC |

With `--template original.sof` the template must have valid CRC/checksum and required records,
and its device must match the requested device. Every non-payload record is copied from that file, and the result is byte-identical
to the original **[verified 16 pairs]**. Without a template, the records that differ from Quartus' are 0x0001 (when
the version differs), 0x0003 (when the design has licensed IP), 0x003B, 0x0024 (timestamps, hash, file list) and so
0x0008 **[verified 16 pairs]**.

A .rbf written by nextpnr-mistral differs from the one Quartus would write only in the option RAM: Mistral writes
usercode 0xFFFFFFFF and does not compress the postambles. Wrapping it into a .sof keeps the CRAM and PRAM exactly,
and converting that .sof back gives the Quartus-style option RAM **[verified 2 files from the toolchain agent]**.

## 7. Validation

`ci/sof_check.sh`, which runs `Quartzite --sof-verify ../sof-samples`:

| check | result |
|---|---|
| (a) parse -> serialize byte-identical | 26/26 files |
| stored CRC-16/X-25 and checksum equal recomputed | 26/26 |
| (b) sof -> rbf byte-identical to the Quartus .rbf | **16/16 pairs** (6 uncompressed, 10 compressed) |
| .rbf decodes to exactly the .sof's CRAM and PRAM | 16/16 |
| (c) rbf -> sof with `--template` reproduces the original .sof | 16/16 |
| (d) mistral-cv on the .rbf extracted from a Quartus 18.1 .sof for 5CSXFC6D6F31C6 | below |

`Quartzite --selftest` runs the synthetic tests in `SOFSelfTest.run` (CRC check values, container round trip,
embedded files, EDCRC table against the bit-serial reference, MLAB permutation, encode/decode of a sparse synthetic
bitstream compressed and uncompressed, rbf -> sof -> rbf). No sample files are needed. The tests also cover corrupt PRAM/postambles, malformed SOF
containers/templates, layout validation and XML escaping.

(d) The specimen is a small combinational design compiled by Quartus Prime 18.1 for 5CSXFC6D6F31C6 (kept
private, not in this repository). `mistral-cv decomp` (Mistral master d509238) on the .rbf that Quartzite extracts
from it finds the single ALM the netlist predicts, with its inputs and its output routed to the five assigned pins,
which are configured with 3.3-V LVTTL drive. The LUT equals the `lut_mask` in Quartus' own `.vo` for that design,
put through nextpnr-mistral's physical encoding (inputs inverted by default, mask inverted, C/D swapped in the upper
half) and restricted to the entries the unused inputs can reach; Quartus writes 0 in the unreachable entries.
`toolchain/verify_rbf.py` with `QZ_FLOAT_INPUT=1` (unrouted ALM inputs read as 1) evaluates the decoded design to
the expected truth table on every row. `mistral-cv cycle` (load and save) reproduces the extracted .rbf byte for
byte.

## 8. Samples

None are in git. They live in `../sof-samples/`; `SOURCES.md` there lists each file's repository URL and commit.
They are public GitHub files, downloaded as data and never executed. "Same compile" means the .rbf usercode equals
the .sof checksum. Pairs:

| pair | Quartus | device | .rbf | sof -> rbf |
|---|---|---|---|---|
| sobel/top | 14.0.0 | 5CSEMA5F31C6 | compressed, 1 LUTRAM tile | byte-identical |
| airplane/top | 15.1.0 | 5CSEMA5F31C6 | compressed, 2 LUTRAM tiles | byte-identical |
| insperfb/soc_system | 16.1.2 | 5CSXFC6D6F31C6 | compressed | byte-identical |
| galaksija/Galaksija | 17.0.2 | 5CSEBA6U23I7 | compressed | byte-identical |
| as019/Module5_Sample_HW | 18.1.0 | 5CSEBA6U23I7 | compressed | byte-identical |
| drs/TbdTxFskFull | 18.1.0 | 5CSEMA5F31C6 | compressed | byte-identical |
| fisnar/DE10_NANO_SoC_GHRD | 18.1.0 | 5CSEBA6U23I7 | compressed | byte-identical |
| gcd/DE1_SoC_Computer | 18.1.0 | 5CSEMA5F31C6 | compressed | byte-identical |
| gradbram/soc_system | 18.1.0 | 5CSXFC6D6F31C6 | compressed | byte-identical |
| svgameboy/soc_system | 18.1.0 | 5CSEMA5F31C6 | uncompressed | byte-identical |
| hft/soc_system | 21.1.0 | 5CSEMA5F31C6 | uncompressed | byte-identical |
| peterw/soc_system | 21.1.0 | 5CSEMA5F31C6 | uncompressed | byte-identical |
| yuri/soc_system | 21.1.0 | 5CSEMA5F31C6 | uncompressed | byte-identical |
| karlhan/DE10_NANO | 22.1std.0 | 5CSEBA6U23I7 | uncompressed | byte-identical |
| tinynpu/output_file | 23.1std.1 | 5CSEBA6U23I7 | uncompressed | byte-identical |
| ece554/tcp_packet_receiver_redo | 25.1std.0 | 5CSEMA5F31C6 | compressed | byte-identical |

Unpaired .sof files (container checks only): the private 18.1 specimen (5CSXFC6D6F31C6), clock, saleterm,
silksobel, mdc, sbmicro_fir, sbmicro_iir and fpgatorch (each has an .rbf from a different compile), the gcd
`_time_limited.sof`, and wavegen (5CSEMA4U23C6, sx50f die).

## 9. What remains before "Quartus Programmer accepts a Quartzite-made .sof"

Everything above is checked against files Quartus wrote. Nothing has yet been checked against Quartus reading a
file we wrote. Open questions:

1. Does Programmer validate 0x003B (opaque hash) or the design_hash in 0x0024? If it does, a fresh .sof fails.
   Fallbacks: `--layout 16` (no 0x003B, as Quartus 15.1/16.1 wrote) or `--template` (metadata from a real compile).
2. Does it care which version string 0x0001 holds?
3. 0x0012 is copied from Quartus files for the same part, so it is right, but its meaning is unknown.
4. Programmer presumably checks the 0x0008 CRC and the 0x0002 device against the JTAG chain. Both are reproduced
   exactly (26/26 CRCs).

### Manual test procedure (Quartus Programmer on any PC with Quartus Prime)

You need a control: a `.sof` that Quartus compiled for the DE10-Standard from a small design whose behaviour you
know (for example f = w AND x on SW3/SW2 and LEDR0). On the Mac, from the repo:

```sh
swift build -c release
Q=.build/release/Quartzite
$Q --sof-to-rbf control.sof control.rbf                                   # bitstream from the Quartus file
$Q --rbf-to-sof control.rbf 5CSXFC6D6F31C6 B_q17.sof --project control    # fresh, 11 records (default)
$Q --rbf-to-sof control.rbf 5CSXFC6D6F31C6 C_q16.sof --project control --layout 16 \
   --compiler-version "Quartus Prime Compiler Version 16.1.2 Build 203 01/18/2017 SJ Standard Edition"
$Q --rbf-to-sof control.rbf 5CSXFC6D6F31C6 D_template.sof --template control.sof
cmp D_template.sof control.sof && echo "D is byte-identical to the Quartus file"
$Q --sof-info B_q17.sof                                                   # checksum and CRC must say OK (exit status 1 if not)
```

Copy control.sof, B_q17.sof, C_q16.sof and D_template.sof to the Quartus machine. With the DE10-Standard on
USB-Blaster II:

1. Tools > Programmer, Hardware Setup: DE-SoC (USB-Blaster II), Mode JTAG, Auto Detect. Choose 5CSXFC6D6 for the
   FPGA. The HPS device shows up as well.
2. For each file, starting with the control: select the FPGA row, Change File..., open it. Note whether it loads,
   what the Checksum column shows (it should be the same for all four), and anything in the Messages pane.
3. Tick Program/Configure and press Start. It should finish at 100% (Successful), and the outputs should behave
   exactly as they do with the control.
4. Optional, in a Quartus command shell: `quartus_cpf -c B_q17.sof B.rbf`, then compare with the Mac's control.rbf
   (`fc /b B.rbf control.rbf`). They should be identical.
5. Report which of B, C and D load and configure. If only D works, Programmer checks 0x003B/0x0024 or the version
   string. If none of them works but the control does, compare the Messages text with the open questions above.

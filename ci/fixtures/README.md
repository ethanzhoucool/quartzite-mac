# Quartus 18.0 ground-truth fixtures

These files are kept byte for byte (CRLF line endings included; see `.gitattributes`).
Quartzite's self-test (`HierarchySelfTest`) and `ci/test_bdf_check.py` compare
Quartzite's output with them. Set `QUARTZITE_FIXTURES` to use another copy; with
`QUARTZITE_REQUIRE_FIXTURES=1` a missing fixture is a failure instead of a skip.

All were captured with Quartus Prime 18.0.0 Build 614 Lite Edition.

## `quartus18/hier/`

| File | Written by | How |
|---|---|---|
| `HA.bsf` | Quartus | `HA.bdf` open, File > Create/Update > Create Symbol Files for Current File |
| `BIGBLK.bsf` | Quartus | the same, on `BIGBLK.bdf` |
| `hiertop.bdf` | Quartus | New Block Diagram, Symbol Tool > Project > HA, then Project > BIGBLK, Save As |
| `HA.bdf`, `BIGBLK.bdf` | hand | small test circuits (pins and two gates); Quartus opened and compiled them |
| `hiertest.qpf`, `hiertest.qsf` | hand | the project the files above were made in |
| `GROUND_TRUTH.md` | hand | notes on the `.bsf` format taken from the files above |

The `.bsf` files and `hiertop.bdf` keep the copyright comment Quartus writes into every
file it saves. Quartzite never copies that comment into its own output.

## `quartus18/lab2/`

| File | Written by | How |
|---|---|---|
| `sym7447_template.txt` | Quartus | the `(symbol ...)` of a 7447 (others > maxplus2) from a Quartus-saved `.bdf` |
| `vcc_symbol.txt` | hand, compiled by Quartus | the VCC (primitives > other > vcc) symbol block of a hand-written `.bdf` that Quartus 18.0 compiled without errors |
| `7447_instance.txt` | hand, compiled by Quartus | a 7447 instance (named `bcd7seg`) from the same `.bdf` |

Only these symbol blocks are kept; the course design they came from is not part of
this repository.

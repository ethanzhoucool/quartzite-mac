# Quartus 18.0 Lite: custom block symbols (ground truth)

Captured 2026-10-22 from real Quartus Prime 18.0.0 Build 614 Lite on the
a university lab PC. Every file in this folder except HA.bdf, BIGBLK.bdf,
hiertest.qpf and hiertest.qsf was written by Quartus itself.

| File | How it was made |
|---|---|
| HA.bsf | HA.bdf open → File > Create/Update > Create Symbol Files for Current File |
| BIGBLK.bsf | the same, run on BIGBLK.bdf |
| hiertop.bdf | New Block Diagram → Symbol Tool → Project › HA, then Project › BIGBLK → Save As |

## .bsf format

- CRLF line endings.
- Begins with a `/* WARNING: Do NOT edit ... */` comment, then the Intel copyright comment.
- Then `(header "symbol" (version "1.2"))` and a single `(symbol ...)`.
- `(rect 16 16 X2 Y2)` is the symbol's bounding box. The body rectangle is `(drawing (rectangle (rect 16 16 X2-16 Y2-32)))`.
  - HA (inputs x, y; outputs s, cout): rect 16 16 112 112, body 16 16 80 80.
  - BIGBLK (inputs a_long_input, b; outputs result_out, z): rect 16 16 208 112, body 16 16 176 80.
- Width follows the longest input label and the longest output label: text width at Intel Clear 8pt, then rounded up to a 16-px grid. The minimum body width is 64.
- Block name text: `(text "HA" (rect 5 0 W 19)(font "Intel Clear" (font_size 8)))`.
- Instance text: `(text "inst" (rect 8 75 24 92)(font "Intel Clear" ))`. The rect y-values sit at the bottom of the body; 75 = body bottom 80 − 5.
- Inputs: `(pt 0 32)`, `(pt 0 48)`, ... spaced 16 px apart starting at y = 32, each with `(line (pt 0 y)(pt 16 y))`.
- Outputs: `(pt W y)` where W = symbol width, with `(line (pt W y)(pt W-16 y))`. They use the same y sequence.
- Each port has two texts:
  - `(text "name" (rect 0 0 tw 19) ...)`.
  - The visible label. Inputs: `(rect 21 y-5 21+tw y+14)`. Outputs: `(rect W-21-tw y-5 W-21 y+14)`.
- Measured text widths (tw) at Intel Clear 8pt:

  | Label | tw |
  |---|---|
  | x | 5 |
  | y | 7 |
  | s | 5 |
  | cout | 24 |
  | b | 8 |
  | z | 5 |
  | a_long_input | 76 |
  | result_out | 59 |
  | HA | 17 |
  | BIGBLK | 44 |
  | inst | 16 |
  | inst1 | 22 |

## Instances in a parent .bdf

The block's `(symbol ...)` from the .bsf is pasted **verbatim** into the parent .bdf. Only two things change:
1. The rect is translated to the placement origin, e.g. `(rect 240 272 336 368)` = (x, y, x+96, y+96).
2. "inst" becomes the instance name (inst, inst1, ...).

Port `pt` coordinates stay local to the symbol, the same as for built-in primitives. The parent file header is `(header "graphic" (version "1.4"))`.

The .qsf lists each .bdf with `set_global_assignment -name BDF_FILE X.bdf`. Quartus resolves a block by name: the block name matches the .bdf filename/entity. The .bsf is used only by the editor, but the Symbol dialog lists the project-folder .bsf files under "Project".

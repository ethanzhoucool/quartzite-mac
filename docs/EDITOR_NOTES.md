# Block Editor notes (branch `overnight/editor`)

This branch makes Quartzite's `.bdf` editor look and behave like the Quartus Prime 18.1 Block Editor.

## What was implemented

### Quartus primitive geometry (`Primitives.swift`)
- Every gate and pin is drawn from the exact `(drawing ...)` and `(port ...)` data that Quartus writes. I read it from Quartus-saved `.bdf` files on GitHub (Quartus II 13 to Quartus Prime 20, several of them saved by 18.x). The canvas, the router, the connectivity and the BDF writer all use this one table.
- Two corrections against the old geometry:
  - 3-input gates (AND3, OR3, NAND3, NOR3) are 64 x 48 with ports at y = 16, 24 and 32. They used to be 64 x 64.
  - Input pins are 168 wide (port at x = 168, arrow from 84 to 113). Quartus Prime 17 and later write this; 176 was the Quartus II 13 size. Output pins stay 176.
- Captions follow Quartus: the primitive name and instance name in purple, `INPUT`/`OUTPUT` in purple, `VCC`/`GND` in blue, input port leads in blue, output leads in purple. Each symbol gets a teal dotted frame. A selected symbol gets a blue frame with eight square handles. The grid is an 8-unit dot grid, purple dots mark junctions, and an X marks the open end of a named node. Assigned locations are shown next to pins, as Quartus does with its location annotation.

### Rotate and flip
- `Component.orientation` holds one of `rotate90`, `rotate180`, `rotate270`, `flipx` or `flipy`. Those are the only tags Quartus writes.
- The coordinate convention comes from real Quartus files:
  - `rotate90` maps (x, y) to (y, W - x). This is a quarter turn counter-clockwise on screen.
  - `rotate180` maps (x, y) to (W - x, H - y).
  - `rotate270` maps (x, y) to (H - y, x). This is a quarter turn clockwise.
  - `flipy` maps (x, y) to (W - x, y). This is **Flip Horizontal**.
  - `flipx` maps (x, y) to (x, H - y). This is **Flip Vertical**.
- The export writes every port `pt`, port lead, drawing element and caption rect already transformed. Arc end points are swapped when mirroring. Quarter-turned symbols get `(vertical)` captions. The tag goes after `(drawing ...)`, and for pins it comes before the `VCC` text, exactly where Quartus puts it.
- Rotation pivots on the symbol's centre and snaps to the grid, so ports stay on the 8-unit grid.
- Quartus never writes two tags on one symbol, so it has no way to store a diagonal mirror (a quarter turn combined with a flip). Quartzite refuses those combinations: the button is disabled and its tooltip explains why.
- The router has a general orthogonal candidate generator for rotated ports. Unrotated designs still use the original left-to-right candidates, so their routes are unchanged.

### Block Editor toolbar (`BlockEditorToolbar.swift`)
The buttons follow Quartus order, and each tooltip and accessibility label uses the Quartus name:
- Selection Tool, Zoom Tool, Hand Tool, Text Tool, Symbol Tool, and Pin Tool. The Pin Tool menu offers Input and Output; Bidir is disabled and marked "not supported yet".
- Orthogonal Node Tool, plus Orthogonal Bus Tool, which is disabled with the tooltip "not supported yet".
- Use Rubberbanding and Use Partial Line Selection. Both toggles work.
- Zoom In, Zoom Out, Fit in Window, and Find (⌘F, a popover that selects matching pins, instances, nodes and text).
- Flip Horizontal, Flip Vertical, and Rotate Left 90.

### Canvas (`SchematicCanvas.swift`, `SheetRenderer.swift`)
- The sheet sits in a real `NSScrollView`. This gives native scrolling, zoom with ⌘ or Ctrl + scroll wheel and pinch (both zoom about the cursor), the Hand Tool, and Fit in Window.
- Double-click reads AppKit's click count on mouse-down, recorded by `CanvasHostingView`, so it no longer depends on `NSApp.currentEvent` timing. Two quick taps also count as a fallback. Double-click opens:
  - Pin Properties on a pin
  - Symbol Properties on a symbol
  - Node Properties on a node or named stub
  - in-place editing on text
  - the Symbol window on empty sheet
- The canvas accepts the first click in an inactive window.
- The right-click menu comes from `NSView.menu(for:)`. Right-clicking selects the item under the cursor first. Items: Cut, Copy, Paste, Delete, Rotate by Degrees (90 / 180 / 270), Flip Horizontal, Flip Vertical, Insert > Symbol..., Insert > Pin > Input / Output (Bidir disabled), Insert > Text, Zoom In, Zoom Out, Fit in Window, and Properties.
- Orthogonal Node Tool:
  - The first movement of a drag decides whether the bend goes horizontal-first or vertical-first, and the bend then follows the mouse.
  - Port to port makes a wire.
  - Port to empty space makes a dangling node and opens Node Properties so you can name it. This maps onto the existing `project.labels` net-label mechanism.
  - Empty space to a port does the same.
  - Port to an existing node or wire joins that net.
  - A drag that starts and ends in empty space only shows a status message, because Quartzite's nodes always hang off a port.
- The Selection Tool keeps its port-to-port and port-to-empty-space drags.
- Text Tool: click to type text in place. It is saved in `Project.notes` and exported as a top-level BDF `(text ...)`.
- Rubberbanding off: moving a symbol drops its wires to symbols that didn't move, as Quartus leaves the nodes behind. Net names on ports are kept.
- Partial Line Selection off: a selection rectangle only takes nodes that lie entirely inside it.
- The status bar shows the cursor position in sheet units, like Quartus, plus the current zoom.

### Dialogs (`Sheets.swift`)
- **Symbol**: a Libraries tree (`Project`, `libraries/ > others > maxplus2`, `primitives > logic`, `other`, `pin`), the Name field, Repeat-insert mode, and Insert symbol as block (disabled). The preview sits on a dotted sheet. See "Multi-file designs" below.
- **Pin Properties > General**: Pin name(s); Default value (VCC or GND; it is exported in place of `VCC`); and Location, which is the same setting as the Pin Planner. The note at the top says that bus names and comma-separated lists are not supported.
- **Symbol Properties**: a General tab (symbol name, Instance name, orientation) and a Ports tab (each port's node name).
- **Node Properties > General**: Name.

### Keyboard
- Delete or Backspace deletes symbols, wires, named nodes and text.
- The arrow keys nudge the selection by 8 units.
- ⌘C, ⌘V, ⌘X, ⌘D and ⌘A work as before. ⌘A now also selects text and named nodes.
- Esc ends text editing, then returns to the Selection Tool.
- Typing a letter with a node or wire selected opens Node Properties with that letter already entered, as in Quartus.
- ⌥⌘+, ⌥⌘- and ⌥⌘0 run Zoom In, Zoom Out and Fit in Window.

### Other changes
- `Store.swift` has two small, marked edits:
  - The `Selection` and `Tool` enums have new cases, and `pruneSelection` handles them.
  - `editorPendingName` is the one new stored property.
- `QUARTZITE_SUPPORT_DIR` overrides the autosave folder, so UI tests never touch a real session.
- `App.swift`: `SchematicSnapshot` now delegates to `SchematicImage` in `SheetRenderer.swift`, so exported images show rotated symbols and text correctly. Nothing else in App.swift changed.
- `Model.swift` changes:
  - `GateKind` geometry now reads from the primitive table.
  - `Component` gains `orientation` and `defaultValue`. Both are optional, so old files still load.
  - `Project` gains `notes`, also optional.

## Multi-file designs (branch `hierarchy`)

A project can hold several `.bdf` files; blocks, the 7447 library macro, VCC and GND can be placed. The model, symbol generation, flattening and export are described in `COMPILER_NOTES.md` ("Hierarchy and library macros"). This section covers the editor.

### Files, tabs and the Project Navigator (`App.swift`, `ProjectNavigator.swift`)
- Every open `.bdf` has its own document tab, before the Pin Planner and the other tabs. A tab shows `*` only when that file changed since the last save. The close button appears when more than one file is open; the last one stays open.
- The Project Navigator has a Hierarchy / Files picker:
  - **Hierarchy**: the device, then the top-level entity and its instance tree (`AddSub4:inst`, `FA:inst1`, `HA:inst`, `7447:inst3`). Files that are missing or contain themselves are marked. Double-clicking a block opens its file and remembers the path. Double-clicking a macro, a missing file or a recursive instance opens the parent with that instance selected.
  - **Files**: every `.bdf`, top-level entity in bold, a `.bsf` badge when the file has a symbol, then `Waveform.vwf`, the `.qsf` and the netlist. Right-click: Open, Set as Top-Level Entity, Create Symbol Files for Current File, Rename..., Remove File from Project. A file used as a block, or the top-level file, can't be removed.
- **File > New...** opens Quartus' New dialog: New Quartus Prime Project, or Design Files > Block Diagram/Schematic File with an entity name (default `BlockN`). Names follow the entity rules: valid identifier, unique ignoring case, not reserved.
- **File > Create/Update > Create Symbol Files for Current File** makes the file's symbol and updates every instance of it automatically (decision D2). The status bar and the System messages report "Created HA.bsf; updated N instances".
- **Edit > Update Symbol or Block...** offers Quartus' three choices: selected instances, all instances of the same symbol, or all instances in the file.
- **Project > Set as Top-Level Entity** (⇧⌘J) makes the open file the top. The top-level entity field in the toolbar is a menu of files that does the same. **Project > Add/Remove Files in Project...** shows the Files view.

### Placing and opening blocks (`Sheets.swift`, `SchematicCanvas.swift`, `SchematicView.swift`)
- Insert Symbol lists the project's files that have a symbol under **Project** ("No symbols yet" with a hint when there are none), the **7447** under `others > maxplus2`, and **vcc** and **gnd** under `primitives > other`. A block that would make the open file contain itself (directly or through other files) is shown disabled, with the reason as its tooltip. `Store.placementProblem` gives the same reason to the Symbol Tool and the status bar.
- Paste leaves such blocks out and says so in the status bar ("Left out 1 block(s) (FA) that would make HA contain itself").
- Double-clicking a block opens its file. If it can't (the file is missing), the status bar says why and Symbol Properties opens. Double-clicking a 7447 opens its function table: the 16 digits with LTN, RBIN and BIN high, plus one row for each control input held low.
- The right-click menu adds Open Design File, Hierarchy Up (`X.bdf`) (back to the parent, with the instance selected) and Update Symbol or Block....
- The inspector shows a block's or macro's library path ("Project > HA", "others > maxplus2 > 7447", "primitives > other > vcc"), an Open `X.bdf` button for blocks, and Function Table... for macros. Port names are listed in symbol order: inputs, then outputs, top to bottom.
- **Rotation (decision D1).** Blocks, macros, VCC and GND keep their orientation. Rotate and flip are refused for them in the toolbar, the menu and the inspector, with the tooltip "Rotating blocks is not supported yet".
- Only the top-level entity's pins get locations. Pin Properties and the inspector show the Location picker only on the top file and say so on the others.
- Symbol texts use Intel Clear when it is installed and Arial otherwise, at the size the symbol asks for.

### Messages, Pin Planner and Simulation
- Double-clicking a message about something inside a block opens the file it is in and selects it. The tooltip names that file.
- **Pin Planner** (`PinPlannerView.swift`): the header names the top-level entity. Pins are sorted naturally (`hex0_2` before `hex0_10`) and can be filtered by name. The count shows how many are still unassigned. After a click on the board assigns a pin, the next unassigned pin is selected.
  - **Assign 7-Segment Digit...** puts a group of seven outputs on one display: names ending in 0-6 (`hex5_0` ... `hex5_6`) or `_a` ... `_g` go to HEXd[0] ... HEXd[6] in one undo step.
  - **Assign Switches...** puts the chosen inputs, in order, on SW*n*, SW*n-1*, and so on. Each location keeps one node: a pin that already had it loses it.
- **Simulation** (`SimulationView.swift`): the expected-minterms list is collapsible. Its label says how many outputs have expected minterms and how many mismatch. It starts open for up to 8 outputs. Above 64 rows, or 2000 cells, the truth table is a lazy list whose header stays pinned while it scrolls.

### Drag performance
Routing a sheet takes about 140 ms in a debug build for a 58-symbol top-level file (6 ms in release). A drag step reroutes at once only when the last routing took under 50 ms (`Store.liveRoutingBudget`). Otherwise the symbols move at once, and the wires and named stubs follow when the pointer rests for 0.12 s or the drag ends (`finishLiveEdit`). A drag step that doesn't change any position no longer counts as an edit.

### Checks and measuring hooks
- Self-tests (`RegressionTests.swift`): tabs and file commands; Insert Symbol and paste refuse recursion; messages locate their file; Pin Planner assignment from a clean start (only Assign 7-Segment Digit, Assign Switches and board clicks, no typed locations) for `addsub4_display` and every design in `QUARTZITE_EXTRA_DESIGNS`; deferred routing during drags; and a run from a blank project through the same Store calls as the menus (HA, Create Symbol Files, FA from two HA blocks, a 2-bit adder with a 7447 on HEX0, Pin Planner actions, compilation, simulation, export). `QUARTZITE_E2E_DIR=<dir>` keeps that run's export and `.qzproj`.
- `--snapshot-window <file> <dir>` adds, for multi-file designs, a selected macro and block on the top file (`window_bdf_macro`, `window_bdf_block`), the block's own file (`window_bdf_child`), the Symbol dialog (`dialog_symbol`) and the 7447 function table (`dialog_macro`). It prints the time per 60-point scroll step of each scroll view when the truth table has more than 64 rows, and the time per drag step on the top file.

- `swift build`, then `.build/debug/Quartzite --selftest`: ALL PASSED. New checks:
  - A rotate270 NOT matches the coordinates in `gdevic/A-Z80 alu_mux_8.bdf`.
  - A flipy AND2 matches A-Z80.
  - Orientation composition gives the expected results, and the diagonal mirror is refused.
  - The rotated export contains `(rotate270)` and `(vertical)`.
  - The rotated circuit computes the same function.
- `.build/debug/Quartzite --export-suite /tmp/qz-editor-suite`, then `python3 ci/bdf_check.py /tmp/qz-editor-suite/*`: all PASS. The suite now includes the new `rotated` design, which covers rotate90/180/270, flipx and flipy on gates and pins, plus a text note. The two CI `.qzproj` designs exported with `--export-project` also PASS.
- `bdf_check.py` now also checks each primitive's geometry under its orientation against the Quartus library tables. That check runs inside every normal design check.
- `python3 ci/bdf_check.py --geometry <files>` checked 130 Quartus-saved `.bdf` files from GitHub, covering 3029 primitive symbols and pins. 925 of them are rotated or flipped (304 flipy, 259 rotate270, 257 rotate90, 62 flipx, 43 rotate180), and only 10 differ from the transform. All 10 come from one file with non-standard drawings (`ChenShihuan/.../Auto-detect.bdf`) and one odd pin. The remaining whole-file differences are legacy symbols with no tag and a different drawing, such as old 40-high gates and vertical symbols from earlier libraries. This is what confirms the orientation convention.
- A hand-written `.bdf` in the same style, compiled successfully by real Quartus Prime 18.1 (not part of this repository), also passes `bdf_check.py`.
- Headless renders: `--render-project <file> <dir>` now also writes `<name>_canvas.png`, the editor sheet as it looks on screen. I inspected these renders for the rotated and example designs.
- Interactive checks: I drove an isolated copy of the app (different bundle id, `QUARTZITE_SUPPORT_DIR` pointing at a scratch folder) through accessibility and confirmed:
  - toolbar labels
  - double-click opening Symbol Properties and Pin Properties
  - the Ports tab
  - Rotate Left 90 rerouting the wires
  - Text Tool typing and committing
  - the Symbol window placing a gate
  - a port-to-empty-space drag opening Node Properties and drawing a named stub with its X marker
  - an empty-space-to-port drag with the Node Tool
  - Fit in Window
  - Esc returning to the Selection Tool
  - arrow-key nudge
  - Delete
  - type-to-name keeping the caret after the typed letter

## Known gaps
- The right-click menu, Hand Tool dragging, ⌘-scroll or pinch zoom, and the Find popover's Find All button were not exercised in the automated session. Background automation can't open context menus or send modified scrolls. The code paths are standard AppKit (`menu(for:)`, `scrollWheel`, `magnify`).
- Nodes always hang off a port: a free-floating wire segment that starts and ends in empty space can't be represented. Dangling nodes become named stubs, using the label mechanism. Stub length is chosen by the router (16 or 24 units), not by where you released the mouse.
- Buses, bidirectional pins, conduits, and the diagonal and shape drawing tools are not implemented. The ones shown on the toolbar are disabled with a tooltip.
- The Pin Properties and Symbol Properties Format tabs are omitted. Symbol Properties has no Parameters tab.
- Rotating several selected symbols turns each one about its own centre, not the group as a whole.
- Text widths in caption rects are estimates; Quartus recomputes them when it loads the file.
- `SchematicSnapshot` in `App.swift` now forwards to the shared renderer, which is a small edit in the other agent's file.

## Quartus behaviour I could not confirm
- Keyboard shortcuts for Rotate and Flip in Quartus 18.1. I found none documented, so I added none; ⌘R is already Run Functional Simulation.
- Exactly which buttons sit behind the toolbar's overflow (») in Quartus 18.1. I followed the order in the brief and the Quartus screenshots in the Lab 0 guide (Selection, Zoom, Hand, Text, Symbol, Pin, then the node and bus tools).
- What Quartus does when you flip a symbol that is already rotated a quarter turn. Real files never carry two tags, so Quartzite refuses the combination rather than guess.
- Quartus's exact colours. They were sampled from screenshots.
- Whether Quartus selects symbols that are only partly inside a selection rectangle. Quartzite selects anything the rectangle touches; Use Partial Line Selection applies only to nodes.

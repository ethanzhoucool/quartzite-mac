#if canImport(SwiftUI)
import SwiftUI
import AppKit

// MARK: - Hit testing

/// Finds what is under a point on the sheet (sheet units).
@MainActor
struct SheetHitTester {
    var store: Store

    func port(_ p: CGPoint, radius: CGFloat = 7) -> PortRef? {
        var best: (PortRef, CGFloat)?
        for c in store.project.components.reversed() {
            for i in c.portIndices {
                let q = c.portPoint(i)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d <= radius, d < (best?.1 ?? .infinity) { best = (PortRef(comp: c.id, port: i), d) }
            }
        }
        return best?.0
    }

    func component(_ p: CGPoint) -> Component? {
        store.project.components.reversed().first { c in
            // Pins are grabbed by their name and arrow, not by the long lead.
            if c.kind.isPin { return c.body.insetBy(dx: 0, dy: -2).contains(p) }
            return c.frame.insetBy(dx: 2, dy: 0).contains(p)
        }
    }

    func note(_ p: CGPoint) -> TextNote? {
        store.project.notes?.reversed().first { $0.frame.insetBy(dx: -3, dy: -3).contains(p) }
    }

    func stub(_ p: CGPoint) -> Routing.Stub? {
        store.routing.stubs.first { st in
            if SheetHitTester.distance(p, st.from, st.to) < 4 { return true }
            // The name above the stub is part of it too.
            let mid = CGPoint(x: (st.from.x + st.to.x) / 2, y: min(st.from.y, st.to.y) - 6)
            return abs(p.x - mid.x) < CGFloat(4 * st.name.count + 6) && abs(p.y - mid.y) < 6
        }
    }

    func wire(_ p: CGPoint) -> Wire? {
        store.project.wires.reversed().first { w in
            guard let pts = store.routing.routes[w.id] else { return false }
            return zip(pts, pts.dropFirst()).contains { SheetHitTester.distance(p, $0, $1) < 4 }
        }
    }

    /// The topmost item for selection purposes.
    func item(_ p: CGPoint) -> Selection? {
        if let c = component(p) { return .comp(c.id) }
        if let n = note(p) { return .text(n.id) }
        if let s = stub(p) { return .node(s.port) }
        if let w = wire(p) { return .wire(w.id) }
        return nil
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - AppKit host

/// Hosts the SwiftUI sheet in a real NSScrollView so the Block Editor gets native
/// scrolling plus Quartus-style navigation: ⌘/Ctrl + scroll wheel and pinch zoom
/// about the cursor, the Hand Tool, a right-click menu built for whatever is under
/// the cursor, and reliable double-click detection from AppKit's click count.
@MainActor
struct CanvasHost: NSViewRepresentable {
    var store: Store
    var editor: EditorState

    func makeNSView(context: Context) -> CanvasScrollView {
        let sv = CanvasScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = false
        sv.drawsBackground = true
        sv.backgroundColor = .white
        let host = CanvasHostingView(rootView: AnyView(
            SchematicCanvasContent(store: store, editor: editor).environment(\.colorScheme, .light)))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.translatesAutoresizingMaskIntoConstraints = true
        let size = store.canvasSize
        host.frame = NSRect(x: 0, y: 0, width: size.width * store.zoom, height: size.height * store.zoom)
        sv.documentView = host
        editor.scroller.scrollView = sv

        let store = store, editor = editor
        sv.onZoom = { factor, windowPoint in
            let p = host.convert(windowPoint, from: nil)
            let z = store.zoom
            editor.scroller.zoom(by: factor, store: store, anchor: CGPoint(x: p.x / z, y: p.y / z))
        }
        host.isHandTool = { store.tool == .hand }
        host.onPan = { delta in editor.scroller.pan(by: delta) }
        host.onMouseDown = { count in editor.lastClickCount = count }
        host.menuAt = { p in
            let z = store.zoom
            return CanvasMenu(store: store, editor: editor).menu(at: CGPoint(x: p.x / z, y: p.y / z))
        }
        return sv
    }

    func updateNSView(_ sv: CanvasScrollView, context: Context) {
        let size = store.canvasSize
        let want = NSSize(width: size.width * store.zoom, height: size.height * store.zoom)
        if let doc = sv.documentView, doc.frame.size != want { doc.setFrameSize(want) }
    }
}

final class CanvasScrollView: NSScrollView {
    var onZoom: ((CGFloat, NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            guard dy != 0 else { return }
            onZoom?(exp(dy), event.locationInWindow)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, event.locationInWindow)
    }
}

final class CanvasHostingView: NSHostingView<AnyView> {
    var isHandTool: (() -> Bool)?
    var onPan: ((CGSize) -> Void)?
    var onMouseDown: ((Int) -> Void)?
    var menuAt: ((CGPoint) -> NSMenu?)?
    private var panLast: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    /// Clicking the sheet of an inactive window acts right away, as in Quartus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event.clickCount)
        window?.makeFirstResponder(self)
        if isHandTool?() == true {
            panLast = event.locationInWindow
            NSCursor.closedHand.set()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let last = panLast {
            let p = event.locationInWindow
            onPan?(CGSize(width: p.x - last.x, height: -(p.y - last.y)))
            panLast = p
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if panLast != nil {
            panLast = nil
            NSCursor.openHand.set()
            return
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuAt?(convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Context menu

/// NSMenu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}

/// The Block Editor's right-click menu, with Quartus' items. Right-clicking an item
/// selects it first, as in Quartus.
@MainActor
struct CanvasMenu {
    var store: Store
    var editor: EditorState

    func menu(at p: CGPoint) -> NSMenu {
        let hit = SheetHitTester(store: store)
        if let item = hit.item(p) {
            if !store.selection.contains(item) { store.selection = [item] }
        } else {
            store.selection = []
        }
        let m = NSMenu()
        m.autoenablesItems = false
        let hasComps = !store.selectedComponentIDs.isEmpty
        let canCopy = store.copySelection() != nil
        let hasAny = !store.selection.isEmpty
        m.addItem(ClosureMenuItem("Cut", key: "x", enabled: canCopy) {
            if let fragment = store.cutSelection() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fragment, forType: .string)
            }
        })
        m.addItem(ClosureMenuItem("Copy", key: "c", enabled: canCopy) { _ = store.copyToPasteboard() })
        m.addItem(ClosureMenuItem("Paste", key: "v", enabled: store.canPaste) { store.pasteFromPasteboard() })
        m.addItem(ClosureMenuItem("Delete", key: "\u{8}", modifiers: [], enabled: hasAny) { store.deleteSelected() })
        m.addItem(.separator())

        let rotate = NSMenuItem(title: "Rotate by Degrees", action: nil, keyEquivalent: "")
        let rm = NSMenu()
        rm.autoenablesItems = false
        rm.addItem(ClosureMenuItem("90 (Rotate Left)", enabled: store.canApply(.rotate90)) { store.apply(.rotate90) })
        rm.addItem(ClosureMenuItem("180", enabled: store.canApply(.rotate180)) { store.apply(.rotate180) })
        rm.addItem(ClosureMenuItem("270 (Rotate Right)", enabled: store.canApply(.rotate270)) { store.apply(.rotate270) })
        rotate.submenu = rm
        rotate.isEnabled = hasComps
        m.addItem(rotate)
        m.addItem(ClosureMenuItem("Flip Horizontal", enabled: store.canApply(.flipy)) { store.apply(.flipy) })
        m.addItem(ClosureMenuItem("Flip Vertical", enabled: store.canApply(.flipx)) { store.apply(.flipx) })
        m.addItem(.separator())

        let insert = NSMenuItem(title: "Insert", action: nil, keyEquivalent: "")
        let im = NSMenu()
        im.autoenablesItems = false
        im.addItem(ClosureMenuItem("Symbol...") { store.sheet = .symbolLibrary(at: p) })
        let pin = NSMenuItem(title: "Pin", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        pm.autoenablesItems = false
        pm.addItem(ClosureMenuItem("Input") { store.place(.input, at: p) })
        pm.addItem(ClosureMenuItem("Output") { store.place(.output, at: p) })
        pm.addItem(ClosureMenuItem("Bidir (not supported yet)", enabled: false) {})
        pin.submenu = pm
        im.addItem(pin)
        im.addItem(ClosureMenuItem("Text") {
            editor.editingNote = store.addNote(at: p)
        })
        insert.submenu = im
        m.addItem(insert)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Zoom In") { editor.scroller.zoom(by: 1.25, store: store, anchor: p) })
        m.addItem(ClosureMenuItem("Zoom Out") { editor.scroller.zoom(by: 0.8, store: store, anchor: p) })
        m.addItem(ClosureMenuItem("Fit in Window") {
            editor.scroller.fit(SheetRenderer.contentBounds(store.project), store: store)
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Properties", enabled: propertiesAction != nil) { propertiesAction?() })
        return m
    }

    /// What "Properties" opens for the current selection, if anything.
    var propertiesAction: (() -> Void)? {
        guard store.selection.count == 1, let s = store.selection.first else { return nil }
        let store = store, editor = editor
        switch s {
        case .comp(let id):
            guard let c = store.project.component(id) else { return nil }
            return { store.sheet = c.kind.isPin ? .pin(id) : .symbol(id) }
        case .wire, .node:
            guard let r = store.selectedNodePort else { return nil }
            return { store.editNode(r) }
        case .text(let id):
            return { editor.editingNote = id }
        }
    }
}

// MARK: - SwiftUI sheet

/// The white Block Editor sheet: drawing, mouse tools and keyboard handling.
@MainActor
struct SchematicCanvasContent: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState
    @State private var drag: DragState = .none
    @State private var hoverPort: PortRef?
    @State private var noteDraft = ""
    @State private var lastTap: (time: Date, point: CGPoint)?
    @FocusState private var focused: Bool
    @FocusState private var noteFocused: Bool

    enum DragState {
        case none
        /// Drawing a node; `firstHorizontal` is decided by the first movement, like Quartus.
        case wire(from: PortRef?, start: CGPoint, to: CGPoint, firstHorizontal: Bool?)
        case move(start: CGPoint, origins: [UUID: CGPoint], notes: [UUID: CGPoint], moved: Bool)
        case rubber(start: CGPoint, current: CGPoint)
        case zoomRect(start: CGPoint, current: CGPoint)
        case tap(CGPoint)
    }

    private var hit: SheetHitTester { SheetHitTester(store: store) }

    var body: some View {
        let z = store.zoom
        let size = store.canvasSize
        ZStack(alignment: .topLeading) {
            Canvas { ctx, canvasSize in
                SheetRenderer.drawGrid(&ctx, size: canvasSize, zoom: z)
                ctx.scaleBy(x: z, y: z)
                var o = SheetRenderer.Options()
                o.zoom = z
                o.selection = store.selection
                o.hoverPort = hoverPort
                o.hiddenNote = editor.editingNote
                SheetRenderer(project: store.project, routing: store.routing, options: o).draw(&ctx)
                drawOverlays(&ctx)
            }
            .frame(width: size.width * z, height: size.height * z)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in changed(start: scaled(v.startLocation), at: scaled(v.location)) }
                    .onEnded { v in ended(at: scaled(v.location)) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let s = scaled(p)
                    editor.cursor = s
                    hoverPort = (store.tool == .select || store.tool == .node) ? hit.port(s) : nil
                    cursorForTool.set()
                case .ended:
                    editor.cursor = nil
                    hoverPort = nil
                    NSCursor.arrow.set()
                }
            }
            if let id = editor.editingNote, let n = store.project.notes?.first(where: { $0.id == id }) {
                TextField("Text", text: $noteDraft)
                    .textFieldStyle(.plain)
                    .font(.custom(SheetRenderer.arial, size: 10 * z))
                    .foregroundStyle(.black)
                    .padding(2)
                    .background(Color.white)
                    .overlay(Rectangle().strokeBorder(Theme.qSelect, lineWidth: 1))
                    .frame(width: max(160, n.frame.width * z + 40))
                    .offset(x: CGFloat(n.x) * z - 3, y: CGFloat(n.y) * z - 3)
                    .focused($noteFocused)
                    .onSubmit { commitNote() }
                    .onAppear {
                        noteDraft = n.text
                        noteFocused = true
                    }
                    .onChange(of: noteFocused) { _, f in if !f { commitNote() } }
            }
        }
        .frame(width: size.width * z, height: size.height * z, alignment: .topLeading)
        .background(Color.white)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { store.deleteSelected() }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard editor.editingNote == nil else { return .ignored }
            store.deleteSelected()
            return .handled
        }
        .onKeyPress(phases: .down) { press in typeToName(press) }
        .onMoveCommand { dir in
            guard editor.editingNote == nil else { return }
            switch dir {
            case .left: store.nudgeSelected(dx: -8, dy: 0)
            case .right: store.nudgeSelected(dx: 8, dy: 0)
            case .up: store.nudgeSelected(dx: 0, dy: -8)
            case .down: store.nudgeSelected(dx: 0, dy: 8)
            @unknown default: break
            }
        }
        .onExitCommand {
            if editor.editingNote != nil { commitNote(); return }
            store.tool = .select
            store.selection = []
            drag = .none
            editor.status = nil
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            store.selectAll()
            store.selection.formUnion((store.project.notes ?? []).map { .text($0.id) })
            store.selection.formUnion(store.routing.stubs.map { .node($0.port) })
        }
        .onCopyCommand { store.copySelection().map { [NSItemProvider(object: $0 as NSString)] } ?? [] }
        .onCutCommand {
            store.cutSelection().map { [NSItemProvider(object: $0 as NSString)] } ?? []
        }
        .onPasteCommand(of: [.plainText]) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    Task { @MainActor in store.paste(s) }
                }
            }
        }
        .onChange(of: store.tool) { _, _ in drag = .none }
    }

    private func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / store.zoom, y: p.y / store.zoom) }
    private func snapped(_ p: CGPoint) -> CGPoint { CGPoint(x: Routing.snap(p.x), y: Routing.snap(p.y)) }

    private var cursorForTool: NSCursor {
        switch store.tool {
        case .select: return .arrow
        case .hand: return .openHand
        case .text: return .iBeam
        case .zoom, .node, .place: return .crosshair
        }
    }

    // MARK: Keyboard: type a name on a selected node (Quartus behaviour)

    private func typeToName(_ press: KeyPress) -> KeyPress.Result {
        guard editor.editingNote == nil, store.sheet == nil,
              press.modifiers.isDisjoint(with: [.command, .control, .option]),
              let ch = press.characters.first, ch.isASCII, ch.isLetter || ch.isNumber || ch == "_",
              let ref = store.selectedNodePort else { return .ignored }
        store.editNode(ref, typed: press.characters)
        return .handled
    }

    // MARK: Gestures

    private func changed(start: CGPoint, at p: CGPoint) {
        focused = true
        switch drag {
        case .none:
            editor.status = nil
            begin(start: start, at: p)
        case .wire(let from, let s, _, let first):
            var f = first
            if f == nil, hypot(p.x - s.x, p.y - s.y) >= 4 { f = abs(p.x - s.x) >= abs(p.y - s.y) }
            drag = .wire(from: from, start: s, to: p, firstHorizontal: f)
        case .move(let s, let origins, let notes, let moved):
            let dx = Routing.snap(p.x - s.x), dy = Routing.snap(p.y - s.y)
            if !moved && dx == 0 && dy == 0 { return }
            if !moved { store.checkpoint() }
            store.liveMutate { proj in
                for (id, o) in origins {
                    guard let i = proj.index(of: id) else { continue }
                    proj.components[i].x = max(0, Int(o.x + dx))
                    proj.components[i].y = max(0, Int(o.y + dy))
                }
                for (id, o) in notes {
                    guard let i = proj.notes?.firstIndex(where: { $0.id == id }) else { continue }
                    proj.notes?[i].x = max(0, Int(o.x + dx))
                    proj.notes?[i].y = max(0, Int(o.y + dy))
                }
            }
            drag = .move(start: s, origins: origins, notes: notes, moved: true)
        case .rubber(let s, _):
            drag = .rubber(start: s, current: p)
        case .zoomRect(let s, _):
            drag = .zoomRect(start: s, current: p)
        case .tap:
            break
        }
    }

    private func begin(start: CGPoint, at p: CGPoint) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        switch store.tool {
        case .place, .text:
            drag = .tap(start)
        case .hand:
            drag = .none
        case .zoom:
            drag = .zoomRect(start: start, current: p)
        case .node:
            let port = hit.port(start)
            let s = port.flatMap { r in store.project.component(r.comp)?.portPoint(r.port) } ?? snapped(start)
            drag = .wire(from: port, start: s, to: p, firstHorizontal: nil)
        case .select:
            if let port = hit.port(start) {
                let s = store.project.component(port.comp)?.portPoint(port.port) ?? start
                drag = .wire(from: port, start: s, to: p, firstHorizontal: nil)
            } else if let c = hit.component(start) {
                select(.comp(c.id), shift: shift)
                if store.selection.contains(.comp(c.id)) { startMove(start) } else { drag = .tap(start) }
            } else if let n = hit.note(start) {
                select(.text(n.id), shift: shift)
                if store.selection.contains(.text(n.id)) { startMove(start) } else { drag = .tap(start) }
            } else if let st = hit.stub(start) {
                store.selection = shift ? store.selection.symmetricDifference([.node(st.port)]) : [.node(st.port)]
                drag = .tap(start)
            } else if let w = hit.wire(start) {
                store.selection = shift ? store.selection.symmetricDifference([.wire(w.id)]) : [.wire(w.id)]
                drag = .tap(start)
            } else {
                if !shift { store.selection = [] }
                drag = .rubber(start: start, current: p)
            }
        }
    }

    private func select(_ item: Selection, shift: Bool) {
        if shift { store.selection = store.selection.symmetricDifference([item]) }
        else if !store.selection.contains(item) { store.selection = [item] }
    }

    private func startMove(_ start: CGPoint) {
        var origins: [UUID: CGPoint] = [:]
        for id in store.selectedComponentIDs {
            if let comp = store.project.component(id) { origins[id] = comp.origin }
        }
        var notes: [UUID: CGPoint] = [:]
        for n in store.project.notes ?? [] where store.selection.contains(.text(n.id)) {
            notes[n.id] = CGPoint(x: n.x, y: n.y)
        }
        drag = .move(start: start, origins: origins, notes: notes, moved: false)
    }

    private func ended(at p: CGPoint) {
        let state = drag
        drag = .none
        switch state {
        case .tap(let s):
            switch store.tool {
            case .place(let k): store.place(k, at: p)
            case .text:
                if let n = hit.note(s) {
                    store.selection = [.text(n.id)]
                    editor.editingNote = n.id
                } else {
                    editor.editingNote = store.addNote(at: s)
                }
            default: registerTap(at: s)
            }
        case .wire(let from, let s, _, _):
            finishNode(from: from, start: s, end: p)
        case .move(let s, let origins, _, let moved):
            if moved {
                if !editor.rubberbanding { store.detachWires(movedIDs: Set(origins.keys)) }
            } else {
                registerTap(at: s)
            }
        case .rubber(let s, let c):
            let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
            guard r.width > 3 || r.height > 3 else {
                registerTap(at: s)
                return
            }
            store.selection.formUnion(itemsIn(r))
        case .zoomRect(let s, let c):
            let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
            if r.width > 8 && r.height > 8 {
                editor.scroller.fit(r.insetBy(dx: 32, dy: 32), store: store)
            } else {
                let out = NSEvent.modifierFlags.contains(.option)
                editor.scroller.zoom(by: out ? 0.8 : 1.25, store: store, anchor: s)
            }
        case .none:
            break
        }
    }

    /// Items inside a selection rectangle. Symbols and text are picked when the rectangle
    /// touches them; nodes follow "Use Partial Line Selection".
    private func itemsIn(_ r: CGRect) -> [Selection] {
        let partial = editor.partialLineSelection
        func takes(_ pts: [CGPoint]) -> Bool {
            if partial {
                return zip(pts, pts.dropFirst()).contains { a, b in
                    let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    return r.intersects(seg.insetBy(dx: -0.5, dy: -0.5))
                }
            }
            return pts.allSatisfy { r.contains($0) }
        }
        var out: [Selection] = store.project.components.filter { r.intersects($0.frame) }.map { .comp($0.id) }
        out += (store.project.notes ?? []).filter { r.intersects($0.frame) }.map { .text($0.id) }
        out += store.project.wires.filter { takes(store.routing.routes[$0.id] ?? []) }.map { .wire($0.id) }
        out += store.routing.stubs.filter { takes([$0.from, $0.to]) }.map { .node($0.port) }
        return out
    }

    /// Ends a node drawn with the Orthogonal Node Tool or dragged from a port.
    private func finishNode(from: PortRef?, start: CGPoint, end: CGPoint) {
        let target = hit.port(end)
        let moved = hypot(end.x - start.x, end.y - start.y) > 12
        // Something on the far end that isn't a port: an existing node joins the nets.
        func joinTarget(_ p: CGPoint) -> PortRef? {
            if let st = hit.stub(p) { return st.port }
            if let w = hit.wire(p) { return w.a }
            return nil
        }
        if let a = from, let b = target, a != b {
            store.connect(a, b)
        } else if let a = from, target == nil, moved {
            if let b = joinTarget(end) {
                store.connect(a, b)
            } else if let c = store.project.component(a.comp), c.kind.isPin {
                editor.status = "A node from a pin already carries the pin's name. Draw it to a port to connect."
            } else {
                // Dangling node: name it, as you would by selecting it and typing in Quartus.
                store.editNode(a)
            }
        } else if from == nil, let b = target {
            if let a = joinTarget(start) {
                store.connect(a, b)
            } else if let c = store.project.component(b.comp), c.kind.isPin {
                editor.status = "A node to a pin already carries the pin's name. Start it on a port to connect."
            } else {
                store.editNode(b)
            }
        } else if from == nil && store.tool == .node && moved {
            editor.status = "A node has to start or end on a port. Quartzite keeps nodes attached to ports."
        } else if from == nil && store.tool == .node {
            registerTap(at: start)
        }
    }

    /// Double-click opens the matching Quartus dialog. The click count comes from AppKit
    /// (CanvasHostingView records it on mouse-down); two quick taps also count.
    private func registerTap(at p: CGPoint) {
        let now = Date()
        defer { lastTap = (now, p) }
        let timed = lastTap.map {
            now.timeIntervalSince($0.time) < NSEvent.doubleClickInterval && hypot($0.point.x - p.x, $0.point.y - p.y) < 6
        } ?? false
        guard editor.lastClickCount >= 2 || timed else { return }
        lastTap = nil
        if let c = hit.component(p) {
            store.sheet = c.kind.isPin ? .pin(c.id) : .symbol(c.id)
        } else if let n = hit.note(p) {
            editor.editingNote = n.id
        } else if let st = hit.stub(p) {
            store.editNode(st.port)
        } else if hit.wire(p) != nil {
            if let r = store.selectedNodePort { store.editNode(r) }
            else { editor.status = "This node joins two pins, so it carries their names." }
        } else {
            store.sheet = .symbolLibrary(at: p)
        }
    }

    private func commitNote() {
        guard let id = editor.editingNote else { return }
        editor.editingNote = nil
        store.setNoteText(id, noteDraft)
        focused = true
    }

    // MARK: Overlays

    private func drawOverlays(_ ctx: inout GraphicsContext) {
        let accent = Theme.qSelect
        let lw = max(0.6, 1 / store.zoom)
        switch drag {
        case .wire(let from, let s, let to, let first):
            var path = Path()
            if let a = from, let b = hit.port(to), a != b, let ca = store.project.component(a.comp),
               let cb = store.project.component(b.comp),
               let route = Routing.candidates(ca, a.port, cb, b.port).first {
                path.addLines(route)
            } else {
                let e = hit.port(to).flatMap { r in store.project.component(r.comp)?.portPoint(r.port) } ?? snapped(to)
                let corner = (first ?? true) ? CGPoint(x: e.x, y: s.y) : CGPoint(x: s.x, y: e.y)
                path.addLines([s, corner, e])
            }
            ctx.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.5 * lw, dash: [4, 3]))
        case .rubber(let s, let c), .zoomRect(let s, let c):
            let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
            ctx.fill(Path(r), with: .color(accent.opacity(0.06)))
            ctx.stroke(Path(r), with: .color(accent.opacity(0.7)), style: StrokeStyle(lineWidth: lw, dash: [3, 2]))
        default:
            break
        }
        if case .place(let k) = store.tool, let h = editor.cursor {
            var ghost = ctx
            let s = k.size
            ghost.translateBy(x: Routing.snap(h.x - s.width / 2), y: Routing.snap(h.y - s.height / 2))
            ghost.opacity = 0.5
            let parts = GateDrawing.parts(k)
            ghost.stroke(parts.stroke, with: .color(accent), lineWidth: lw)
            ghost.stroke(parts.inputLeads, with: .color(accent), lineWidth: lw)
            ghost.stroke(parts.outputLeads, with: .color(accent), lineWidth: lw)
        }
    }
}
#endif

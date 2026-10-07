#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Block Editor state that belongs to the open editor rather than the project:
/// toolbar toggles, the cursor position for the status bar, inline text editing.
@MainActor @Observable
final class EditorState {
    /// Quartus "Use Rubberbanding": nodes stay attached to symbols you move.
    var rubberbanding = true
    /// Quartus "Use Partial Line Selection": a selection rectangle also picks nodes it only crosses.
    var partialLineSelection = true
    /// Cursor position in sheet units (shown in the status bar like Quartus).
    var cursor: CGPoint?
    /// One-line feedback shown in the status bar (cleared on the next action).
    var status: String?
    /// Text note being edited in place.
    var editingNote: UUID?
    var findQuery = ""
    var showFind = false

    @ObservationIgnored var scroller = CanvasScroller()
    /// Click count of the last mouse-down on the canvas (2 = double-click), read from AppKit.
    @ObservationIgnored var lastClickCount = 1
}

extension Store {
    var selectedComponentIDs: [UUID] {
        project.components.map { $0.id }.filter { selection.contains(.comp($0)) }
    }

    var selectedNodes: [PortRef] { selection.compactMap { if case .node(let r) = $0 { return r } else { return nil } } }
    var selectedNoteIDs: Set<UUID> { Set(selection.compactMap { if case .text(let id) = $0 { return id } else { return nil } }) }

    // MARK: Rotate / flip

    /// Whether `op` can be applied to every selected symbol (Quartus can't store a
    /// rotation combined with a flip, so some combinations are refused).
    func canApply(_ op: Orientation) -> Bool {
        let comps = selectedComponentIDs.compactMap { project.component($0) }
        return !comps.isEmpty && comps.allSatisfy { $0.orient.then(op) != nil }
    }

    /// Rotates or flips each selected symbol about its own centre.
    @discardableResult
    func apply(_ op: Orientation) -> Bool {
        guard canApply(op) else { return false }
        let ids = Set(selectedComponentIDs)
        mutate { p in
            for i in p.components.indices where ids.contains(p.components[i].id) {
                if let c = p.components[i].applying(op, snap: Routing.snap) { p.components[i] = c }
            }
        }
        return true
    }

    // MARK: Deleting and moving

    /// Delete for every kind of selection: symbols, wires, named nodes and text.
    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let comps = Set(selectedComponentIDs), nodes = selectedNodes, notes = selectedNoteIDs
        let wires = Set(selection.compactMap { if case .wire(let id) = $0 { return id } else { return nil } })
        mutate { p in
            p.components.removeAll { comps.contains($0.id) }
            p.wires.removeAll { wires.contains($0.id) || comps.contains($0.a.comp) || comps.contains($0.b.comp) }
            p.labels = p.labels.filter { key, _ in !comps.contains { key.hasPrefix($0.uuidString) } }
            p.inputOrder.removeAll { comps.contains($0) }
            for id in comps { p.expected.removeValue(forKey: id.uuidString) }
            for r in nodes { p.labels.removeValue(forKey: r.key) }
            p.notes?.removeAll { notes.contains($0.id) }
        }
        selection = []
    }

    func nudgeSelected(dx: Int, dy: Int) {
        let comps = Set(selectedComponentIDs), notes = selectedNoteIDs
        guard !comps.isEmpty || !notes.isEmpty else { return }
        mutate { p in
            for i in p.components.indices where comps.contains(p.components[i].id) {
                p.components[i].x = max(0, p.components[i].x + dx)
                p.components[i].y = max(0, p.components[i].y + dy)
            }
            for i in (p.notes ?? []).indices where notes.contains(p.notes![i].id) {
                p.notes![i].x = max(0, p.notes![i].x + dx)
                p.notes![i].y = max(0, p.notes![i].y + dy)
            }
        }
    }

    /// With rubberbanding off, Quartus leaves the nodes where they were when a symbol
    /// moves, so they no longer touch it. The same happens here: wires between moved
    /// and unmoved symbols are removed (net names on ports are kept).
    func detachWires(movedIDs: Set<UUID>) {
        let cut = project.wires.filter { movedIDs.contains($0.a.comp) != movedIDs.contains($0.b.comp) }
        guard !cut.isEmpty else { return }
        let ids = Set(cut.map { $0.id })
        liveMutate { $0.wires.removeAll { ids.contains($0.id) } }
    }

    // MARK: Text

    func addNote(at p: CGPoint) -> UUID {
        let n = TextNote(text: "", x: Int(Routing.snap(p.x)), y: Int(Routing.snap(p.y)))
        mutate { $0.notes = ($0.notes ?? []) + [n] }
        selection = [.text(n.id)]
        return n.id
    }

    /// Commits text typed in place; empty text removes the note (as in Quartus).
    func setNoteText(_ id: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = project.notes?.firstIndex(where: { $0.id == id }) else { return }
        if t.isEmpty {
            mutate { $0.notes?.remove(at: i) }
            selection.remove(.text(id))
        } else if project.notes?[i].text != t {
            mutate { $0.notes?[i].text = t }
        }
    }

    // MARK: Nodes

    /// Opens Node Properties for the node on a port, optionally with text already typed.
    /// "inst3.IN1" for a gate port, "pin w" for a pin.
    func describe(_ ref: PortRef) -> String {
        guard let c = project.component(ref.comp) else { return "this port" }
        return c.kind.isPin ? "pin \(c.name)" : "\(c.name).\(c.kind.portName(ref.port))"
    }

    func editNode(_ ref: PortRef, typed: String? = nil) {
        editorPendingName = typed
        sheet = .node(ref)
    }

    /// The port that identifies a selected wire or named node, for Node Properties.
    var selectedNodePort: PortRef? {
        guard selection.count == 1, let s = selection.first else { return nil }
        switch s {
        case .node(let r): return r
        case .wire(let id):
            // Name the gate end of the wire; a pin's node already carries the pin's name.
            guard let w = project.wires.first(where: { $0.id == id }) else { return nil }
            return [w.a, w.b].first { project.component($0.comp)?.kind.isPin == false }
        default: return nil
        }
    }

    // MARK: Find

    /// Selects every symbol, pin, named node and text whose name contains `query`.
    func find(_ query: String) -> Set<Selection> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func hit(_ s: String) -> Bool { s.localizedCaseInsensitiveContains(q) }
        var found = Set<Selection>()
        for c in project.components where hit(c.name) || hit(c.kind.bdfName) { found.insert(.comp(c.id)) }
        for (key, name) in project.labels where hit(name) {
            let parts = key.split(separator: "#")
            if parts.count == 2, let u = UUID(uuidString: String(parts[0])), let i = Int(parts[1]) {
                found.insert(.node(PortRef(comp: u, port: i)))
            }
        }
        for n in project.notes ?? [] where hit(n.text) { found.insert(.text(n.id)) }
        return found
    }

    /// Sheet rectangle covering a selection (for scrolling it into view).
    func bounds(of items: Set<Selection>) -> CGRect? {
        var rects: [CGRect] = []
        for s in items {
            switch s {
            case .comp(let id): if let c = project.component(id) { rects.append(c.frame) }
            case .text(let id): if let n = project.notes?.first(where: { $0.id == id }) { rects.append(n.frame) }
            case .node(let r):
                if let st = routing.stubs.first(where: { $0.port == r }) {
                    rects.append(CGRect(x: min(st.from.x, st.to.x), y: min(st.from.y, st.to.y), width: abs(st.to.x - st.from.x) + 1,
                                        height: abs(st.to.y - st.from.y) + 1))
                }
            case .wire(let id):
                if let pts = routing.routes[id], let f = pts.first {
                    rects.append(pts.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) })
                }
            }
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: Clipboard (context menu)

    func copyToPasteboard() -> Bool {
        guard let s = copySelection() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        return true
    }

    func pasteFromPasteboard() {
        if let s = NSPasteboard.general.string(forType: .string) { paste(s) }
    }

    var canPaste: Bool {
        NSPasteboard.general.string(forType: .string)?.hasPrefix(Store.fragmentPrefix) ?? false
    }
}

// MARK: - Scrolling and zoom

/// Talks to the AppKit scroll view that hosts the canvas: zoom about a point,
/// pan (Hand Tool), Fit in Window and scrolling a selection into view.
@MainActor
final class CanvasScroller {
    weak var scrollView: NSScrollView?
    static let zoomRange: ClosedRange<CGFloat> = 0.25...4

    /// The visible part of the sheet in sheet units.
    func visibleSheetRect(zoom: CGFloat) -> CGRect? {
        guard let clip = scrollView?.contentView else { return nil }
        let b = clip.bounds
        return CGRect(x: b.minX / zoom, y: b.minY / zoom, width: b.width / zoom, height: b.height / zoom)
    }

    /// Sets the zoom keeping `anchor` (sheet units) under the same spot on screen
    /// (the centre of the view when no anchor is given).
    func setZoom(_ newZoom: CGFloat, store: Store, anchor: CGPoint? = nil) {
        let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        let old = store.zoom
        guard let sv = scrollView, let doc = sv.documentView else { store.zoom = z; return }
        let clip = sv.contentView
        let a = anchor ?? CGPoint(x: clip.bounds.midX / old, y: clip.bounds.midY / old)
        let onScreen = CGPoint(x: a.x * old - clip.bounds.minX, y: a.y * old - clip.bounds.minY)
        store.zoom = z
        let size = store.canvasSize
        doc.setFrameSize(NSSize(width: size.width * z, height: size.height * z))
        scroll(to: CGPoint(x: a.x * z - onScreen.x, y: a.y * z - onScreen.y))
    }

    func zoom(by factor: CGFloat, store: Store, anchor: CGPoint? = nil) {
        setZoom(store.zoom * factor, store: store, anchor: anchor)
    }

    /// Zooms so the whole design (or `rect`) fits the window.
    func fit(_ rect: CGRect?, store: Store) {
        guard let r = rect?.insetBy(dx: -32, dy: -32), let sv = scrollView else { return }
        let b = sv.contentView.bounds.size
        let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, min(b.width / r.width, b.height / r.height)))
        setZoom(z, store: store)
        scroll(to: CGPoint(x: r.midX * z - b.width / 2, y: r.midY * z - b.height / 2))
    }

    /// Scrolls so `rect` (sheet units) is visible, centring it if it was off screen.
    func reveal(_ rect: CGRect, zoom: CGFloat) {
        guard let sv = scrollView else { return }
        let b = sv.contentView.bounds
        let r = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        if b.contains(r) { return }
        scroll(to: CGPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2))
    }

    func pan(by delta: CGSize) {
        guard let sv = scrollView else { return }
        let b = sv.contentView.bounds
        scroll(to: CGPoint(x: b.minX - delta.width, y: b.minY - delta.height))
    }

    private func scroll(to p: CGPoint) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxX = max(0, doc.frame.width - clip.bounds.width), maxY = max(0, doc.frame.height - clip.bounds.height)
        clip.scroll(to: CGPoint(x: min(maxX, max(0, p.x)), y: min(maxY, max(0, p.y))))
        sv.reflectScrolledClipView(clip)
    }
}
#endif

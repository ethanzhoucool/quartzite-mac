#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Block Editor (.bdf) document, laid out like Quartus: tool strip on top,
/// white sheet in the middle, properties on the right.
@MainActor
struct SchematicView: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState = EditorState.shared

    var body: some View {
        VStack(spacing: 0) {
            BlockEditorToolbar(store: store, editor: editor)
            Divider()
            HStack(spacing: 0) {
                CanvasHost(store: store, editor: editor)
                Divider()
                InspectorView(store: store, editor: editor)
                    .frame(width: 248)
            }
            Divider()
            CanvasStatusBar(store: store, editor: editor)
        }
    }
}

extension EditorState {
    /// Quartzite has a single main window, so one editor state is shared; it survives
    /// switching document tabs.
    static let shared = EditorState()
}

@MainActor
struct CanvasStatusBar: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState

    var body: some View {
        HStack(spacing: 10) {
            Text(editor.status ?? hint)
                .lineLimit(1)
                .foregroundStyle(editor.status == nil ? .secondary : .primary)
            Spacer()
            if let c = editor.cursor {
                Text("\(Int(c.x)), \(Int(c.y))").monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                    .help("Cursor position in Quartus sheet units")
            }
            Button { editor.scroller.zoom(by: 0.8, store: store) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless).help("Zoom Out")
            Text("\(Int((store.zoom * 100).rounded()))%").monospacedDigit().frame(width: 40)
            Button { editor.scroller.zoom(by: 1.25, store: store) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless).help("Zoom In")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }

    private var hint: String {
        switch store.tool {
        case .select:
            return "Drag from a port to draw a node. Double-click a symbol, pin or node for its properties, or empty space to insert a symbol."
        case .zoom: return "Click to zoom in, Option-click to zoom out, or drag a rectangle to zoom to it."
        case .hand: return "Drag to move the sheet."
        case .text: return "Click to type text on the sheet. Click existing text to edit it."
        case .node: return "Drag from a port to another port, a node, or empty space (then name the node). Esc returns to the Selection Tool."
        case .place(let k): return "Click to place \(k.isPin ? k.displayName.lowercased() : k.bdfName.lowercased()). Esc returns to the Selection Tool."
        }
    }
}

// MARK: - Properties panel

@MainActor
struct InspectorView: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if store.selection.count == 1, case .comp(let id) = store.selection.first!, let c = store.project.component(id) {
            componentInspector(c)
        } else if store.selection.count == 1, case .wire(let id) = store.selection.first!,
                  let w = store.project.wires.first(where: { $0.id == id }) {
            wireInspector(w)
        } else if store.selection.count == 1, case .node(let ref) = store.selection.first! {
            nodeInspector(ref)
        } else if store.selection.count == 1, case .text(let id) = store.selection.first!,
                  let n = store.project.notes?.first(where: { $0.id == id }) {
            Text("Text").font(.headline)
            Text(n.text).font(.callout).textSelection(.enabled)
            Text("Exported to the .bdf as free text. Double-click it on the sheet to edit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Edit Text") { editor.editingNote = id }
                Button("Delete", role: .destructive) { store.deleteSelected() }
            }
        } else if store.selection.count > 1 {
            Text("\(store.selection.count) items selected").font(.headline)
            Text("Drag to move them together, ⌘D to duplicate, or ⌫ to delete.").font(.callout).foregroundStyle(.secondary)
            if !store.selectedComponentIDs.isEmpty { orientationControls }
            Button("Delete", role: .destructive) { store.deleteSelected() }
        } else {
            Text("Properties").font(.headline)
            Text("Select a symbol to see its properties. Double-click it to edit, just like in Quartus.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Net names").font(.subheadline.weight(.semibold))
                Text("Wires with the same name are connected, so you can skip long wires: drag a short wire out of a gate input and name it w to connect it to input pin w.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts").font(.subheadline.weight(.semibold))
                shortcut("Start Compilation", "⌘L")
                shortcut("Analysis & Synthesis", "⌘K")
                shortcut("Pin Planner", "⇧⌘N")
                shortcut("Run Functional Simulation", "⌥⌘R")
                shortcut("Duplicate", "⌘D")
                shortcut("Nudge", "Arrow keys")
                shortcut("Zoom", "⌘ scroll / pinch")
                shortcut("Find", "⌘F")
                shortcut("Name a selected node", "Type")
            }
        }
    }

    private func shortcut(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(keys).foregroundStyle(.secondary).monospaced()
        }
        .font(.caption)
    }

    private func componentInspector(_ c: Component) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GateIcon(kind: c.kind).frame(width: 40, height: 24)
                VStack(alignment: .leading) {
                    Text(c.kind.isPin ? (c.kind == .input ? "Input pin" : "Output pin") : c.symbolName.lowercased())
                        .font(.headline)
                    Text(c.kind.isPin ? "primitives > pin" : "primitives > logic").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(c.kind.isPin ? "Pin name" : "Instance name").font(.caption).foregroundStyle(.secondary)
                TextField("", text: Binding(get: { c.name },
                                            set: { v in store.updateComponent(c.id) { $0.name = v.replacingOccurrences(of: " ", with: "_") } }))
                    .textFieldStyle(.roundedBorder)
            }
            orientationControls
            if c.kind.isPin {
                PinLocationPicker(store: store, pin: c)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Port names").font(.subheadline.weight(.semibold))
                    Text("Name a port to connect it to every pin or wire with the same name.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(c.portIndices, id: \.self) { i in
                        let ref = PortRef(comp: c.id, port: i)
                        HStack {
                            Text(c.portName(i)).monospaced().frame(width: 34, alignment: .leading)
                            TextField("unnamed", text: Binding(get: { store.project.labels[ref.key] ?? "" },
                                                               set: { store.setLabel(ref, $0) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            Button("Delete", role: .destructive) { store.deleteSelected() }
        }
    }

    /// Rotate / flip buttons, matching the toolbar's Flip Horizontal, Flip Vertical and Rotate Left 90.
    private var orientationControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Orientation").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([(Orientation.rotate90, "rotate.left", "Rotate Left 90"),
                         (.rotate270, "rotate.right", "Rotate Right 90"),
                         (.flipy, "arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal"),
                         (.flipx, "arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertical")], id: \.0) { op, icon, name in
                    Button { store.apply(op) } label: { Image(systemName: icon) }
                        .disabled(!store.canApply(op))
                        .help(store.canApply(op) ? name : "\(name) is not available: Quartus can't store a quarter turn combined with a flip")
                }
                if store.selectedComponentIDs.count == 1, let c = store.project.component(store.selectedComponentIDs[0]) {
                    Text(c.orient.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nodeInspector(_ ref: PortRef) -> some View {
        let c = store.project.component(ref.comp)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Node").font(.headline)
            Text("Named \(store.project.label(ref) ?? "") on \(c.map { "\($0.name).\($0.portName(ref.port))" } ?? "a port")")
                .font(.callout)
            Text("Every node and pin with the same name is connected, just like in Quartus.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Rename...") { store.editNode(ref) }
                Button("Delete", role: .destructive) { store.deleteSelected() }
            }
        }
    }

    private func wireInspector(_ w: Wire) -> some View {
        func describe(_ r: PortRef) -> String {
            guard let c = store.project.component(r.comp) else { return "?" }
            return c.kind.isPin ? "pin \(c.name)" : "\(c.name).\(c.portName(r.port))"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Node").font(.headline)
            Text("\(describe(w.a)) to \(describe(w.b))").font(.callout)
            if store.routing.labeledWires.contains(w.id) {
                Text("Dashed: this wire can't be drawn without touching another one, so it is exported as two matching net labels. Electrically it's the same wire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let r = store.selectedNodePort {
                Button("Name This Node...") { store.editNode(r) }
            }
            Button("Delete", role: .destructive) { store.deleteSelected() }
        }
    }
}

@MainActor
struct PinLocationPicker: View {
    @Bindable var store: Store
    var pin: Component

    var body: some View {
        let options = BoardPin.de10Standard.filter { $0.isInput == (pin.kind == .input) }
        VStack(alignment: .leading, spacing: 4) {
            Text("Location").font(.caption).foregroundStyle(.secondary)
            Picker("Location", selection: Binding(
                get: { BoardPin.lookup(pin.location)?.pin ?? (pin.location == nil ? "" : "custom") },
                set: { v in
                    guard v != "custom" else { return }
                    store.assign(pin.id, to: v.isEmpty ? nil : v)
                })) {
                Text("Not assigned").tag("")
                ForEach(options) { Text("\($0.label)  (\($0.pin))").tag($0.pin) }
                if pin.location != nil && BoardPin.lookup(pin.location) == nil { Text("Custom: \(pin.location ?? "")").tag("custom") }
            }
            .labelsHidden()
        }
    }
}

#endif

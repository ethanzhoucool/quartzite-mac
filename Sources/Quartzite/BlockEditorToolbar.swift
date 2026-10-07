#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// The Block Editor toolbar along the top of the .bdf document, with the tools in
/// Quartus Prime's order and Quartus' tooltip names.
@MainActor
struct BlockEditorToolbar: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState

    var body: some View {
        HStack(spacing: 1) {
            tool(.select, "Selection Tool (Esc)") { Image(systemName: "cursorarrow") }
            tool(.zoom, "Zoom Tool (click to zoom in, Option-click to zoom out)") { Image(systemName: "magnifyingglass") }
            tool(.hand, "Hand Tool") { Image(systemName: "hand.raised") }
            tool(.text, "Text Tool") { Text("A").font(.system(size: 15, weight: .regular, design: .serif)) }
            StripButton(help: "Symbol Tool", active: isPlacingGate, action: { store.sheet = .symbolLibrary(at: .zero) }) {
                ToolGlyph.symbol.frame(width: 20, height: 14)
            }
            pinTool
            Separator()
            tool(.node, "Orthogonal Node Tool") { ToolGlyph.node(thick: false).frame(width: 16, height: 16) }
            StripButton(help: "Orthogonal Bus Tool (not supported yet: Quartzite designs use single-bit nodes)",
                        action: {}) {
                ToolGlyph.node(thick: true).frame(width: 16, height: 16).opacity(0.35)
            }
            .disabled(true)
            Separator()
            StripButton(help: "Use Rubberbanding", active: editor.rubberbanding,
                        action: { editor.rubberbanding.toggle() }) {
                ToolGlyph.rubberband.frame(width: 18, height: 16)
            }
            StripButton(help: "Use Partial Line Selection", active: editor.partialLineSelection,
                        action: { editor.partialLineSelection.toggle() }) {
                ToolGlyph.partialSelection.frame(width: 18, height: 16)
            }
            Separator()
            StripButton(help: "Zoom In (⌘ scroll or pinch also zooms)", action: { editor.scroller.zoom(by: 1.25, store: store) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            StripButton(help: "Zoom Out", action: { editor.scroller.zoom(by: 0.8, store: store) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            StripButton(help: "Fit in Window", action: { editor.scroller.fit(SheetRenderer.contentBounds(store.project), store: store) }) {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            StripButton(help: "Find (⌘F)", active: editor.showFind, action: { editor.showFind.toggle() }) {
                Image(systemName: "binoculars")
            }
            .keyboardShortcut("f")
            .popover(isPresented: $editor.showFind, arrowEdge: .bottom) { FindPopover(store: store, editor: editor) }
            Separator()
            orientationButton(.flipy, "Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right")
            orientationButton(.flipx, "Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down")
            orientationButton(.rotate90, "Rotate Left 90", "rotate.left")
            Spacer(minLength: 12)
            Button {
                store.insertStarterPins()
            } label: {
                Label("Starter Pins", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Adds inputs w, x, y, z on SW3 to SW0 and output f on LEDR0")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.bar)
    }

    private var isPlacingGate: Bool {
        if case .place(let k) = store.tool { return !k.isPin }
        return false
    }

    private var placingPin: GateKind? {
        if case .place(let k) = store.tool, k.isPin { return k }
        return nil
    }

    private func tool<I: View>(_ t: Tool, _ help: String, @ViewBuilder icon: @escaping () -> I) -> some View {
        StripButton(help: help, active: store.tool == t, action: {
            store.tool = t
            editor.status = nil
        }, icon: icon)
    }

    /// Pin Tool with Quartus' Input / Output / Bidir choices.
    private var pinTool: some View {
        Menu {
            Button("Input") { store.tool = .place(.input) }
            Button("Output") { store.tool = .place(.output) }
            Button("Bidir (not supported yet)") {}.disabled(true)
        } label: {
            ToolGlyph.pin(store: placingPin ?? .input).frame(width: 24, height: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 3)
        .background(placingPin != nil ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        .help("Pin Tool: Input or Output (bidirectional pins are not supported yet)")
    }

    private func orientationButton(_ op: Orientation, _ name: String, _ symbol: String) -> some View {
        let enabled = store.canApply(op)
        let help: String
        if store.selectedComponentIDs.isEmpty {
            help = "\(name) (select a symbol first)"
        } else if !enabled {
            help = "\(name) is not available: Quartus can't store a symbol that is both rotated a quarter turn and flipped. Undo the flip or rotation first."
        } else {
            help = name
        }
        return StripButton(help: help, action: { store.apply(op) }) {
            Image(systemName: symbol).opacity(enabled ? 1 : 0.35)
        }
        .disabled(!enabled)
    }

    private struct Separator: View {
        var body: some View { Divider().frame(height: 18).padding(.horizontal, 5) }
    }
}

/// Find popover (Quartus: Edit > Find): selects matching symbols, pins, nodes and text.
@MainActor
struct FindPopover: View {
    @Bindable var store: Store
    @Bindable var editor: EditorState
    @FocusState private var focused: Bool
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find").font(.headline)
            TextField("Pin, instance, node or text", text: $editor.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(run)
            HStack {
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Find All", action: run).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }

    private func run() {
        let found = store.find(editor.findQuery)
        if found.isEmpty {
            result = "No matches"
            return
        }
        store.selection = found
        result = found.count == 1 ? "1 match selected" : "\(found.count) matches selected"
        if let r = store.bounds(of: found) { editor.scroller.reveal(r, zoom: store.zoom) }
    }
}

/// Quartus-style toolbar glyphs that have no SF Symbol equivalent.
enum ToolGlyph {
    static var symbol: some View {
        Canvas { ctx, size in
            let s = min(size.width / 40, size.height / 26)
            ctx.translateBy(x: (size.width - 40 * s) / 2, y: (size.height - 26 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            var p = Path()
            p.move(to: CGPoint(x: 10, y: 3)); p.addLine(to: CGPoint(x: 20, y: 3))
            p.addArc(center: CGPoint(x: 20, y: 13), radius: 10, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: 10, y: 23)); p.closeSubpath()
            p.move(to: CGPoint(x: 0, y: 8)); p.addLine(to: CGPoint(x: 10, y: 8))
            p.move(to: CGPoint(x: 0, y: 18)); p.addLine(to: CGPoint(x: 10, y: 18))
            p.move(to: CGPoint(x: 30, y: 13)); p.addLine(to: CGPoint(x: 40, y: 13))
            ctx.stroke(p, with: .foreground, lineWidth: 1.6 / s)
        }
    }

    static func pin(store kind: GateKind) -> some View {
        Canvas { ctx, size in
            let s = min(size.width / 44, size.height / 20)
            ctx.translateBy(x: (size.width - 44 * s) / 2, y: (size.height - 20 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            var p = Path()
            let x0: CGFloat = kind == .input ? 0 : 14
            p.move(to: CGPoint(x: x0, y: 5)); p.addLine(to: CGPoint(x: x0 + 22, y: 5))
            p.addLine(to: CGPoint(x: x0 + 27, y: 10)); p.addLine(to: CGPoint(x: x0 + 22, y: 15))
            p.addLine(to: CGPoint(x: x0, y: 15)); p.closeSubpath()
            if kind == .input {
                p.move(to: CGPoint(x: 27, y: 10)); p.addLine(to: CGPoint(x: 44, y: 10))
            } else {
                p.move(to: CGPoint(x: 0, y: 10)); p.addLine(to: CGPoint(x: 14, y: 10))
            }
            ctx.stroke(p, with: .foreground, lineWidth: 1.5 / s)
            ctx.draw(Text(kind == .input ? "in" : "out").font(.system(size: 7, weight: .semibold)),
                     at: CGPoint(x: x0 + 11, y: 10))
        }
    }

    static func node(thick: Bool) -> some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: 3)); p.addLine(to: CGPoint(x: size.width - 4, y: 3))
            p.addLine(to: CGPoint(x: size.width - 4, y: size.height - 2))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: thick ? 3 : 1.4, lineCap: .square))
            ctx.fill(Path(CGRect(x: 0, y: 1, width: 4, height: 4)), with: .foreground)
        }
    }

    static var rubberband: some View {
        Canvas { ctx, size in
            let h = size.height
            ctx.stroke(Path(CGRect(x: 1, y: 1, width: 6, height: 6)), with: .foreground, lineWidth: 1.2)
            ctx.stroke(Path(CGRect(x: size.width - 7, y: h - 7, width: 6, height: 6)), with: .foreground, lineWidth: 1.2)
            var p = Path()
            p.move(to: CGPoint(x: 7, y: 4)); p.addLine(to: CGPoint(x: size.width / 2, y: 4))
            p.addLine(to: CGPoint(x: size.width / 2, y: h - 4)); p.addLine(to: CGPoint(x: size.width - 7, y: h - 4))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
        }
    }

    static var partialSelection: some View {
        Canvas { ctx, size in
            let r = CGRect(x: 1, y: 3, width: size.width * 0.6, height: size.height - 6)
            ctx.stroke(Path(r), with: .foreground, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            var p = Path()
            p.move(to: CGPoint(x: size.width * 0.3, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
            ctx.stroke(p, with: .foreground, lineWidth: 1.6)
        }
    }
}
#endif

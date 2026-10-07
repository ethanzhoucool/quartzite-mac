#if canImport(SwiftUI)
import SwiftUI

/// Draws a Block Editor sheet the way Quartus Prime does: black symbols from the
/// library drawings, purple captions, blue/purple port leads, teal dotted symbol
/// frames, and a blue selection frame with square handles. Shared by the editor
/// canvas, the schematic image export and the headless renders used in tests.
struct SheetRenderer {
    struct Options {
        /// Current zoom, so lines stay about one screen pixel wide like in Quartus.
        var zoom: CGFloat = 1
        var frames = true
        var selection: Set<Selection> = []
        var hoverPort: PortRef? = nil
        /// Marks gate inputs that are not connected yet (a Quartzite aid, not in Quartus).
        var showOpenPorts = true
        var hiddenNote: UUID? = nil
        /// Plain black-and-white output for images.
        var print = false
    }

    var project: Project
    var routing: Routing
    var options = Options()

    private var lw: CGFloat { max(0.6, 1.0 / options.zoom) }

    static let arial = "Arial"

    /// Dot grid on 8-unit spacing, drawn in screen pixels (before scaling by the zoom).
    static func drawGrid(_ ctx: inout GraphicsContext, size: CGSize, zoom: CGFloat) {
        let step: CGFloat = zoom < 0.7 ? 2 : 1
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .tiledImage(Theme.quartusGridTile, origin: .zero,
                                   sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: zoom * step))
    }

    func draw(_ ctx: inout GraphicsContext) {
        let ink = Color.black
        let sel = options.selection
        let select = options.print ? ink : Theme.qSelect

        // Nodes (wires).
        for w in project.wires {
            guard let pts = routing.routes[w.id], pts.count > 1 else { continue }
            let dashed = routing.labeledWires.contains(w.id)
            if dashed && options.print { continue }
            var path = Path()
            path.addLines(pts)
            let selected = sel.contains(.wire(w.id))
            ctx.stroke(path, with: .color(selected ? select : ink.opacity(dashed ? 0.35 : 1)),
                       style: StrokeStyle(lineWidth: selected ? 2 * lw : lw, lineCap: .square, lineJoin: .miter,
                                          dash: dashed ? [5, 4] : []))
        }
        // Named node stubs (net labels): a short node, its name, and Quartus' X on the open end.
        for st in routing.stubs {
            let selected = sel.contains(.node(st.port))
            var path = Path()
            path.move(to: st.from)
            path.addLine(to: st.to)
            let color = selected ? select : ink
            ctx.stroke(path, with: .color(color), lineWidth: selected ? 2 * lw : lw)
            if !options.print {
                var x = Path()
                x.move(to: CGPoint(x: st.to.x - 2.5, y: st.to.y - 2.5)); x.addLine(to: CGPoint(x: st.to.x + 2.5, y: st.to.y + 2.5))
                x.move(to: CGPoint(x: st.to.x - 2.5, y: st.to.y + 2.5)); x.addLine(to: CGPoint(x: st.to.x + 2.5, y: st.to.y - 2.5))
                ctx.stroke(x, with: .color(options.print ? ink : Theme.qPurple), lineWidth: lw)
            }
            let vertical = st.from.x == st.to.x
            let mid = CGPoint(x: (st.from.x + st.to.x) / 2, y: (st.from.y + st.to.y) / 2)
            let text = Text(st.name).font(.custom(Self.arial, size: 8)).foregroundStyle(color)
            if vertical {
                var l = ctx
                l.translateBy(x: mid.x - 1.5, y: mid.y)
                l.rotate(by: .degrees(-90))
                l.draw(text, at: .zero, anchor: .bottom)
            } else {
                ctx.draw(text, at: CGPoint(x: mid.x, y: mid.y - 1), anchor: .bottom)
            }
        }
        for j in routing.junctions {
            ctx.fill(Path(ellipseIn: CGRect(x: j.x - 2.5, y: j.y - 2.5, width: 5, height: 5)),
                     with: .color(options.print ? ink : Theme.qPurple))
        }

        // Free text.
        for n in project.notes ?? [] where n.id != options.hiddenNote {
            let selected = sel.contains(.text(n.id))
            ctx.draw(Text(n.text).font(.custom(Self.arial, size: 10)).foregroundStyle(ink),
                     at: CGPoint(x: n.x, y: n.y), anchor: .topLeading)
            if selected { drawSelectionFrame(&ctx, n.frame.insetBy(dx: -2, dy: -2), color: select) }
        }

        // Symbols and pins.
        let conn = options.showOpenPorts ? Connectivity(project) : nil
        for c in project.components {
            drawSymbol(&ctx, c, selected: sel.contains(.comp(c.id)), conn: conn)
        }
    }

    func drawSymbol(_ ctx: inout GraphicsContext, _ c: Component, selected: Bool, conn: Connectivity?) {
        let ink = Color.black
        let purple = options.print ? Color(white: 0.25) : Theme.qPurple
        let blue = options.print ? Color(white: 0.25) : Theme.qBlue
        let parts = GateDrawing.parts(c)
        if options.frames && !options.print {
            ctx.stroke(Path(c.frame), with: .color(Theme.qFrame), style: StrokeStyle(lineWidth: lw * 0.8, dash: [1, 2]))
        }
        var local = ctx
        local.translateBy(x: CGFloat(c.x), y: CGFloat(c.y))
        local.stroke(parts.stroke, with: .color(ink), lineWidth: lw)
        local.stroke(parts.inputLeads, with: .color(blue), lineWidth: lw)
        local.stroke(parts.outputLeads, with: .color(purple), lineWidth: lw)

        let k = c.kind
        switch k {
        case .input:
            caption(&ctx, "INPUT", Caption.pinDirectionRect(k), c, size: 6, color: purple)
            caption(&ctx, c.name, Caption.pinNameRect(k, c.name), c, size: 8.5, color: ink)
            caption(&ctx, c.defaultValue ?? "VCC", Caption.pinDefaultRect, c, size: 6, color: blue)
        case .output:
            caption(&ctx, "OUTPUT", Caption.pinDirectionRect(k), c, size: 6, color: purple)
            caption(&ctx, c.name, Caption.pinNameRect(k, c.name), c, size: 8.5, color: ink)
        default:
            caption(&ctx, k.bdfName, Caption.typeRect(k), c, size: 6, color: purple)
            caption(&ctx, c.name, Caption.instanceRect(k, c.name), c, size: 8, color: purple, bottom: true)
        }
        if k.isPin, let loc = c.location, !loc.isEmpty, !options.print {
            // Quartus shows an assigned location next to the pin.
            let text = Text(loc).font(.custom(Self.arial, size: 7)).foregroundStyle(Theme.qLocation)
            let f = c.frame
            // Estimated width of 7 pt Arial; when the sheet edge would clip the label, put it above the pin.
            let width = CGFloat(loc.count) * 4.3
            if k == .input && f.minX - 4 - width < 0 {
                ctx.draw(text, at: CGPoint(x: f.minX, y: f.minY - 1), anchor: .bottomLeading)
            } else if k == .input {
                ctx.draw(text, at: CGPoint(x: f.minX - 4, y: f.midY), anchor: .trailing)
            } else {
                ctx.draw(text, at: CGPoint(x: f.maxX + 4, y: f.midY), anchor: .leading)
            }
        }

        if let conn, !options.print {
            for i in k.allPorts.indices where !k.isOutputPort(i) && !k.isPin {
                let ref = PortRef(comp: c.id, port: i)
                let linked = conn.netOf[ref].map { conn.nets[$0].hasExplicitLink } ?? false
                if !linked {
                    let p = c.portPoint(i)
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)),
                               with: .color(Theme.error.opacity(0.8)), lineWidth: lw)
                }
            }
        }
        if let h = options.hoverPort, h.comp == c.id, h.port < k.allPorts.count {
            let p = c.portPoint(h.port)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: r), with: .color(Theme.qSelect.opacity(0.25)))
            ctx.stroke(Path(ellipseIn: r), with: .color(Theme.qSelect), lineWidth: lw)
        }
        if selected { drawSelectionFrame(&ctx, c.frame, color: options.print ? ink : Theme.qSelect) }
    }

    /// Solid frame with eight square handles, as Quartus draws a selected symbol.
    func drawSelectionFrame(_ ctx: inout GraphicsContext, _ r: CGRect, color: Color) {
        ctx.stroke(Path(r), with: .color(color), lineWidth: lw)
        let s = max(3, 4.5 / options.zoom)
        for x in [r.minX, r.midX, r.maxX] {
            for y in [r.minY, r.midY, r.maxY] where !(x == r.midX && y == r.midY) {
                let h = CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
                ctx.fill(Path(h), with: .color(.white))
                ctx.stroke(Path(h), with: .color(color), lineWidth: lw)
            }
        }
    }

    /// A caption placed in its library text box, moved with the symbol's orientation.
    /// Quarter-turned symbols get vertical text, mirrored ones keep readable text.
    private func caption(_ ctx: inout GraphicsContext, _ s: String, _ libRect: CGRect, _ c: Component,
                         size: CGFloat, color: Color, bottom: Bool = false) {
        guard !s.isEmpty else { return }
        let r = c.toSheet(libRect)
        let text = Text(s).font(.custom(Self.arial, size: size)).foregroundStyle(color)
        let o = c.orient
        if o.swapsAxes {
            var l = ctx
            l.translateBy(x: r.midX, y: r.midY)
            l.rotate(by: .degrees(-90))
            l.draw(text, at: .zero, anchor: .center)
        } else {
            // Rotating 180 or flipping vertically moves the box to the other edge of the symbol.
            let atBottom = bottom != (o == .rotate180 || o == .flipx)
            let trailing = o == .flipy || o == .rotate180
            let pt = CGPoint(x: trailing ? r.maxX : r.minX, y: atBottom ? r.maxY : r.minY)
            let anchor: UnitPoint = atBottom ? (trailing ? .bottomTrailing : .bottomLeading) : (trailing ? .topTrailing : .topLeading)
            ctx.draw(text, at: pt, anchor: anchor)
        }
    }

    /// Bounding box of everything on the sheet.
    static func contentBounds(_ p: Project) -> CGRect? {
        let rects = p.components.map { $0.frame } + (p.notes ?? []).map { $0.frame }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}

/// Light render of the whole diagram, cropped to its contents (File > Export Schematic Image).
struct SchematicImage: View {
    var project: Project
    var routing: Routing
    var body: some View {
        let bounds = (SheetRenderer.contentBounds(project) ?? CGRect(x: 0, y: 0, width: 160, height: 80))
            .insetBy(dx: -40, dy: -40)
        Canvas { ctx, _ in
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            var o = SheetRenderer.Options()
            o.print = true
            o.showOpenPorts = false
            SheetRenderer(project: project, routing: routing, options: o).draw(&ctx)
        }
        .frame(width: max(200, bounds.width), height: max(120, bounds.height))
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// The editor canvas exactly as on screen (grid, frames, colours), used for headless renders.
struct SheetPreview: View {
    var project: Project
    var routing: Routing
    var zoom: CGFloat = 1.5
    var body: some View {
        let bounds = (SheetRenderer.contentBounds(project) ?? CGRect(x: 0, y: 0, width: 160, height: 80))
            .insetBy(dx: -48, dy: -48)
        let ox = (bounds.minX / 8).rounded(.down) * 8, oy = (bounds.minY / 8).rounded(.down) * 8
        Canvas { ctx, size in
            SheetRenderer.drawGrid(&ctx, size: size, zoom: zoom)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -ox, y: -oy)
            var o = SheetRenderer.Options()
            o.zoom = zoom
            SheetRenderer(project: project, routing: routing, options: o).draw(&ctx)
        }
        .frame(width: (bounds.maxX - ox) * zoom, height: (bounds.maxY - oy) * zoom)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
#endif

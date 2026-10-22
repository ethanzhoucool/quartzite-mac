#if canImport(SwiftUI)
import SwiftUI

/// Symbol outlines in component-local coordinates (same units as the .bdf), built
/// from the Quartus library drawings in `Primitive.table`.
enum GateDrawing {
    struct Parts {
        var stroke = Path()      // outline (body drawing)
        var fill = Path()        // closed body area (for a light fill / hit testing)
        var inputLeads = Path()  // port leads of input ports
        var outputLeads = Path() // port leads of output ports
    }

    static func parts(_ k: GateKind) -> Parts { parts(k, .none) }

    static func parts(_ c: Component) -> Parts { parts(c.primitive, c.orient) }

    static func parts(_ k: GateKind, _ o: Orientation) -> Parts { parts(k.primitive, o) }

    static func parts(_ prim: Primitive, _ o: Orientation) -> Parts {
        var p = Parts()
        for d in prim.drawing { add(d.oriented(o, in: prim.size), to: &p.stroke) }
        for port in prim.ports where port.pt != port.lineEnd {
            var lead = Path()
            lead.move(to: o.point(port.pt, in: prim.size))
            lead.addLine(to: o.point(port.lineEnd, in: prim.size))
            if port.isOutput { p.outputLeads.addPath(lead) } else { p.inputLeads.addPath(lead) }
        }
        p.fill = Path(o.rect(prim.body, in: prim.size))
        return p
    }

    /// Adds one Quartus drawing element to a path.
    static func add(_ s: Shape, to path: inout Path) {
        switch s {
        case .line(let a, let b):
            path.move(to: a)
            path.addLine(to: b)
        case .circle(let r):
            path.addEllipse(in: r)
        case .rectangle(let r):
            path.addRect(r)
        case .arc(let a, let b, let r):
            // Counter-clockwise on screen from a to b, i.e. decreasing angle in y-down coordinates.
            let c = CGPoint(x: r.midX, y: r.midY), rx = r.width / 2, ry = r.height / 2
            guard rx > 0, ry > 0 else { return }
            let t0 = atan2((a.y - c.y) / ry, (a.x - c.x) / rx)
            var t1 = atan2((b.y - c.y) / ry, (b.x - c.x) / rx)
            while t1 >= t0 { t1 -= 2 * .pi }
            let steps = max(8, Int((t0 - t1) / (.pi / 48)))
            path.move(to: a)
            for i in 1...steps {
                let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(steps)
                path.addLine(to: CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)))
            }
        }
    }
}

/// Small preview icon of a symbol, used in the palette.
struct GateIcon: View {
    var kind: GateKind
    var ink: Color = .primary
    var body: some View {
        Canvas { ctx, size in
            let s = kind.size
            let crop: CGRect
            switch kind.family {
            case .pinIn: crop = CGRect(x: 76, y: 0, width: 96, height: 16)
            case .pinOut: crop = CGRect(x: 0, y: 0, width: 92, height: 16)
            default: crop = CGRect(origin: .zero, size: s)
            }
            let scale = min(size.width / crop.width, size.height / crop.height)
            ctx.translateBy(x: (size.width - crop.width * scale) / 2 - crop.minX * scale,
                            y: (size.height - crop.height * scale) / 2 - crop.minY * scale)
            ctx.scaleBy(x: scale, y: scale)
            let parts = GateDrawing.parts(kind)
            let w = 1.3 / max(scale, 0.3)
            ctx.stroke(parts.stroke, with: .color(ink), lineWidth: w)
            ctx.stroke(parts.inputLeads, with: .color(ink), lineWidth: w)
            ctx.stroke(parts.outputLeads, with: .color(ink), lineWidth: w)
        }
    }
}

#endif

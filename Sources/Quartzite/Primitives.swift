import Foundation

// Quartus primitive geometry and symbol orientation.
//
// Every number in this file was read from .bdf files saved by Quartus itself
// (Quartus II 13 to Quartus Prime 20, including files from Quartus Prime 18.x),
// so the canvas, the router and the exported .bdf all agree with what Quartus
// draws when it loads the file. `ci/bdf_check.py --geometry` re-derives the same
// tables independently and checks them against real Quartus files.

/// How a placed symbol is turned, named exactly like the tag Quartus writes after
/// the symbol's (drawing ...) block. Quartus only ever writes one of these five
/// tags (no combinations), so a symbol can be rotated or flipped, not both at once
/// unless the result is again one of these six states.
///
/// Mapping from library coordinates (x, y) in a W x H symbol to the coordinates
/// Quartus writes, confirmed on rotated NOT/AND/XOR gates and pins:
///   rotate90   (x, y) -> (y, W - x)       a quarter turn counter-clockwise on screen
///   rotate180  (x, y) -> (W - x, H - y)
///   rotate270  (x, y) -> (H - y, x)       a quarter turn clockwise on screen
///   flipy      (x, y) -> (W - x, y)       mirrored left to right (Flip Horizontal)
///   flipx      (x, y) -> (x, H - y)       mirrored top to bottom (Flip Vertical)
enum Orientation: String, Codable, CaseIterable {
    case none, rotate90, rotate180, rotate270, flipx, flipy

    /// Linear part (a, b, c, d) acting on y-down vectors: x' = a dx + b dy, y' = c dx + d dy.
    var matrix: (Int, Int, Int, Int) {
        switch self {
        case .none: return (1, 0, 0, 1)
        case .rotate90: return (0, 1, -1, 0)
        case .rotate180: return (-1, 0, 0, -1)
        case .rotate270: return (0, -1, 1, 0)
        case .flipy: return (-1, 0, 0, 1)
        case .flipx: return (1, 0, 0, -1)
        }
    }

    static func from(_ m: (Int, Int, Int, Int)) -> Orientation? {
        allCases.first { $0.matrix == m }
    }

    /// Applies `op` after this orientation (op ∘ self). Nil when the result is a
    /// diagonal mirror, which Quartus has no tag for.
    func then(_ op: Orientation) -> Orientation? {
        let (a, b, c, d) = op.matrix, (e, f, g, h) = matrix
        return Orientation.from((a * e + b * g, a * f + b * h, c * e + d * g, c * f + d * h))
    }

    var swapsAxes: Bool { self == .rotate90 || self == .rotate270 }
    var isMirror: Bool { self == .flipx || self == .flipy }
    /// The tag written into the .bdf, e.g. "rotate270".
    var bdfTag: String? { self == .none ? nil : rawValue }

    var title: String {
        switch self {
        case .none: return "Normal"
        case .rotate90: return "Rotated 90° left"
        case .rotate180: return "Rotated 180°"
        case .rotate270: return "Rotated 90° right"
        case .flipx: return "Flipped vertically"
        case .flipy: return "Flipped horizontally"
        }
    }

    func size(_ s: CGSize) -> CGSize { swapsAxes ? CGSize(width: s.height, height: s.width) : s }

    func vector(_ v: CGPoint) -> CGPoint {
        let (a, b, c, d) = matrix
        return CGPoint(x: CGFloat(a) * v.x + CGFloat(b) * v.y, y: CGFloat(c) * v.x + CGFloat(d) * v.y)
    }

    /// Maps a point in library coordinates of a symbol of size `s` to oriented local coordinates.
    func point(_ p: CGPoint, in s: CGSize) -> CGPoint {
        let o = size(s)
        let v = vector(CGPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
        return CGPoint(x: v.x + o.width / 2, y: v.y + o.height / 2)
    }

    func rect(_ r: CGRect, in s: CGSize) -> CGRect {
        let a = point(CGPoint(x: r.minX, y: r.minY), in: s), b = point(CGPoint(x: r.maxX, y: r.maxY), in: s)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// One element of a Quartus (drawing ...) block.
enum Shape: Equatable {
    case line(CGPoint, CGPoint)
    /// Quartus arc: part of the ellipse inscribed in the rect, running counter-clockwise
    /// on screen from the first point to the second.
    case arc(CGPoint, CGPoint, CGRect)
    case circle(CGRect)

    func oriented(_ o: Orientation, in s: CGSize) -> Shape {
        switch self {
        case .line(let a, let b): return .line(o.point(a, in: s), o.point(b, in: s))
        case .arc(let a, let b, let r):
            // A mirror reverses the direction of travel, so Quartus swaps the end points.
            let pa = o.point(a, in: s), pb = o.point(b, in: s)
            return o.isMirror ? .arc(pb, pa, o.rect(r, in: s)) : .arc(pa, pb, o.rect(r, in: s))
        case .circle(let r): return .circle(o.rect(r, in: s))
        }
    }
}

struct PortGeometry {
    var pt: CGPoint
    /// The port's lead runs from `pt` to `lineEnd` (equal for pins, which have no lead).
    var lineEnd: CGPoint
    var isOutput: Bool
    var name: String
}

/// A library symbol in Quartus coordinates.
struct Primitive {
    var size: CGSize
    /// In Quartzite port order: inputs IN1...INn, then the output.
    var ports: [PortGeometry]
    var drawing: [Shape]
    /// The drawn body (leads excluded) that wires should not cross.
    var body: CGRect
}

extension GateKind {
    var primitive: Primitive { Primitive.table[self]! }
}

extension Primitive {
    private static func p(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: x, y: y) }
    private static func l(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Shape { .line(p(x1, y1), p(x2, y2)) }
    private static func r(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> CGRect {
        CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
    private static func a(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ rect: CGRect) -> Shape { .arc(p(x1, y1), p(x2, y2), rect) }
    private static func c(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Shape { .circle(r(x1, y1, x2, y2)) }

    /// A gate with inputs at the given y values (leads ending at the given x) and an output.
    private static func gate(_ w: Int, _ h: Int, inputs: [(Int, Int)], out: (Int, Int), single: Bool = false,
                             body: CGRect, _ drawing: [Shape]) -> Primitive {
        var ports = inputs.enumerated().map { i, v in
            PortGeometry(pt: p(0, v.0), lineEnd: p(v.1, v.0), isOutput: false, name: single ? "IN" : "IN\(i + 1)")
        }
        ports.append(PortGeometry(pt: p(w, out.0), lineEnd: p(out.1, out.0), isOutput: true, name: "OUT"))
        return Primitive(size: CGSize(width: w, height: h), ports: ports, drawing: drawing, body: body)
    }

    private static let orOutline2 = [l(14, 13, 25, 13), l(14, 36, 25, 36), a(7, 29, 7, 19, r(-14, 8, 19, 41)),
                                     a(49, 24, 25, 13, r(-6, 13, 57, 76)), a(25, 35, 49, 24, r(-6, -27, 57, 36))]
    private static let norOutline2 = [l(12, 13, 23, 13), l(12, 36, 23, 36), a(5, 29, 5, 19, r(-16, 8, 17, 41)),
                                      a(46, 24, 23, 13, r(-6, 13, 53, 72)), a(23, 35, 46, 24, r(-6, -23, 53, 36)),
                                      c(46, 20, 54, 28)]
    private static let small = r(12, 8, 52, 40)
    private static let tall = r(12, 8, 52, 72)

    static let table: [GateKind: Primitive] = [
        // Quartus Prime 17+ input pin (168 wide; Quartus II 13 used 176).
        .input: Primitive(size: CGSize(width: 168, height: 16),
                          ports: [PortGeometry(pt: p(168, 8), lineEnd: p(168, 8), isOutput: true, name: "")],
                          drawing: [l(84, 12, 109, 12), l(84, 4, 109, 4), l(113, 8, 168, 8), l(84, 12, 84, 4),
                                    l(109, 4, 113, 8), l(109, 12, 113, 8)],
                          body: r(0, 0, 114, 16)),
        .output: Primitive(size: CGSize(width: 176, height: 16),
                           ports: [PortGeometry(pt: p(0, 8), lineEnd: p(0, 8), isOutput: false, name: "")],
                           drawing: [l(0, 8, 52, 8), l(52, 4, 78, 4), l(52, 12, 78, 12), l(52, 12, 52, 4),
                                     l(78, 4, 82, 8), l(82, 8, 78, 12), l(78, 12, 82, 8)],
                           body: r(52, 0, 176, 16)),
        .not: gate(48, 32, inputs: [(16, 13)], out: (16, 39), single: true, body: r(12, 6, 40, 26),
                   [l(13, 25, 13, 7), l(13, 7, 31, 16), l(13, 25, 31, 16), c(31, 12, 39, 20)]),
        .and2: gate(64, 48, inputs: [(16, 14), (32, 14)], out: (24, 42), body: small,
                    [l(14, 12, 30, 12), l(14, 37, 31, 37), l(14, 12, 14, 37), a(31, 37, 30, 12, r(18, 12, 43, 37))]),
        .and3: gate(64, 48, inputs: [(16, 16), (24, 16), (32, 16)], out: (24, 43), body: small,
                    [l(16, 12, 31, 12), l(16, 37, 31, 37), l(16, 12, 16, 37), a(31, 36, 31, 12, r(19, 12, 44, 37))]),
        .and4: gate(64, 80, inputs: [(16, 18), (32, 18), (48, 18), (64, 18)], out: (40, 46), body: tall,
                    [l(18, 28, 34, 28), l(18, 52, 18, 28), l(18, 67, 18, 13), l(34, 53, 18, 53),
                     a(34, 52, 34, 28, r(22, 28, 47, 53))]),
        .or2: gate(64, 48, inputs: [(16, 15), (32, 15)], out: (24, 48), body: small, orOutline2),
        .or3: gate(64, 48, inputs: [(16, 16), (24, 18), (32, 16)], out: (24, 49), body: small, orOutline2),
        .or4: gate(64, 80, inputs: [(16, 13), (32, 15), (48, 15), (64, 13)], out: (40, 48), body: tall,
                   [l(13, 12, 13, 29), l(13, 29, 25, 29), l(13, 67, 13, 51), l(25, 52, 13, 52),
                    a(7, 45, 7, 35, r(-14, 24, 19, 57)), a(49, 40, 25, 29, r(-6, 29, 57, 92)),
                    a(25, 51, 49, 40, r(-6, -11, 57, 52))]),
        .nand2: gate(64, 48, inputs: [(16, 15), (32, 15)], out: (24, 52), body: small,
                     [l(15, 37, 32, 37), l(15, 12, 32, 12), l(15, 36, 15, 12), a(32, 36, 32, 12, r(20, 12, 45, 37)),
                      c(44, 20, 52, 28)]),
        .nand3: gate(64, 48, inputs: [(16, 16), (24, 16), (32, 16)], out: (24, 52), body: small,
                     [l(16, 12, 32, 12), l(16, 36, 16, 12), l(16, 37, 32, 37), a(32, 36, 32, 12, r(20, 12, 45, 37)),
                      c(44, 20, 52, 28)]),
        .nand4: gate(64, 80, inputs: [(16, 18), (32, 18), (48, 18), (64, 18)], out: (40, 54), body: tall,
                     [l(18, 28, 34, 28), l(18, 53, 34, 53), l(18, 67, 18, 13), a(34, 52, 34, 28, r(22, 28, 47, 53)),
                      c(46, 36, 54, 44)]),
        .nor2: gate(64, 48, inputs: [(16, 14), (32, 14)], out: (24, 54), body: small, norOutline2),
        .nor3: gate(64, 48, inputs: [(16, 14), (24, 16), (32, 14)], out: (24, 54), body: small, norOutline2),
        .nor4: gate(64, 80, inputs: [(16, 14), (32, 16), (48, 16), (64, 14)], out: (40, 56), body: tall,
                    [l(14, 29, 14, 13), l(14, 29, 25, 29), l(14, 52, 25, 52), l(14, 67, 14, 51),
                     a(8, 45, 8, 35, r(-13, 24, 20, 57)), a(48, 40, 25, 29, r(-4, 29, 55, 88)),
                     a(25, 51, 48, 40, r(-4, -7, 55, 52)), c(48, 36, 56, 44)]),
        .xor2: gate(64, 48, inputs: [(16, 11), (32, 11)], out: (24, 49), body: small,
                    orOutline2 + [a(8, 36, 8, 12, r(-21, 7, 14, 42))]),
        .xnor2: gate(64, 48, inputs: [(16, 11), (32, 11)], out: (24, 56), body: small,
                     orOutline2 + [a(2, 29, 2, 19, r(-19, 8, 14, 41)), c(48, 20, 56, 28)]),
    ]
}

// MARK: - Captions

/// The texts Quartus places on a symbol, in library coordinates.
enum Caption {
    /// Rough Arial width so text rects resemble Quartus' (it recomputes them on load).
    static func width(_ s: String, size: Int = 8) -> Int { max(6, Int((Double(s.count) * Double(size) * 0.72).rounded()) + 2) }

    /// Primitive name above a gate, e.g. "AND2".
    static func typeRect(_ k: GateKind) -> CGRect {
        CGRect(x: 1, y: 0, width: width(k.bdfName, size: 6) + 4, height: 10)
    }
    /// Instance name under a gate, e.g. "inst3".
    static func instanceRect(_ k: GateKind, _ name: String) -> CGRect {
        let h = k.size.height
        return CGRect(x: 3, y: h - 11, width: CGFloat(width(name)), height: 12)
    }
    static func pinNameRect(_ k: GateKind, _ name: String) -> CGRect {
        k == .input ? CGRect(x: 5, y: 0, width: width(name), height: 12)
                    : CGRect(x: 90, y: 0, width: width(name), height: 12)
    }
    static func pinDirectionRect(_ k: GateKind) -> CGRect {
        k == .input ? CGRect(x: 125, y: 0, width: 28, height: 10) : CGRect(x: 1, y: 0, width: 38, height: 10)
    }
    static let pinDefaultRect = CGRect(x: 128, y: 7, width: 20, height: 10)
    /// Hidden port-name texts Quartus keeps on every gate port.
    static func portTextRect(_ port: PortGeometry) -> CGRect {
        let x = port.isOutput ? port.pt.x - 16 : 2
        return CGRect(x: x, y: port.pt.y - 9, width: 17, height: 12)
    }
}

// MARK: - Placed symbols

extension Component {
    var orient: Orientation { orientation ?? .none }
    /// Size on the sheet (width and height swap for quarter turns).
    var size: CGSize { orient.size(kind.size) }

    /// Library coordinates to sheet coordinates.
    func toSheet(_ p: CGPoint) -> CGPoint {
        let q = orient.point(p, in: kind.size)
        return CGPoint(x: CGFloat(x) + q.x, y: CGFloat(y) + q.y)
    }

    func toSheet(_ r: CGRect) -> CGRect {
        orient.rect(r, in: kind.size).offsetBy(dx: CGFloat(x), dy: CGFloat(y))
    }

    /// Unit vector pointing out of the symbol at a port (the way a wire leaves it).
    func portDirection(_ index: Int) -> CGPoint {
        orient.vector(CGPoint(x: kind.isOutputPort(index) ? 1 : -1, y: 0))
    }

    /// The drawn body on the sheet, which wires should not cross.
    var body: CGRect { toSheet(kind.primitive.body) }

    /// The same symbol after applying `op` (Rotate / Flip), turning about its centre.
    /// Nil when Quartus could not store the result (see `Orientation`).
    func applying(_ op: Orientation, snap: (CGFloat) -> CGFloat) -> Component? {
        guard let o = orient.then(op) else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var c = self
        c.orientation = o == .none ? nil : o
        let s = c.size
        c.x = max(0, Int(snap(centre.x - s.width / 2)))
        c.y = max(0, Int(snap(centre.y - s.height / 2)))
        return c
    }
}

/// Free text placed with the Text Tool; exported as a top-level (text ...) in the .bdf.
struct TextNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var x: Int
    var y: Int

    var frame: CGRect {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let w = lines.map { Caption.width(String($0), size: 10) }.max() ?? 10
        return CGRect(x: x, y: y, width: max(12, w), height: 14 * max(1, lines.count))
    }
}

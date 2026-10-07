import Foundation

/// Orthogonal wire routing shared by the canvas and the .bdf exporter.
///
/// Quartus joins nodes wherever an endpoint touches another node, so a route is
/// only accepted when it never touches a different net (except plain crossings).
/// Wires that cannot be routed safely are exported as named stubs (net labels),
/// a common Quartus technique anyway.
struct Routing {
    struct Segment { var a: CGPoint; var b: CGPoint; var net: Int }
    struct Stub { var port: PortRef; var from: CGPoint; var to: CGPoint; var name: String; var net: Int }

    var routes: [UUID: [CGPoint]] = [:]
    var labeledWires: Set<UUID> = []
    var segments: [Segment] = []
    var stubs: [Stub] = []
    var junctions: [CGPoint] = []
    var warnings: [String] = []

    static let grid: CGFloat = 8

    init(project: Project, conn: Connectivity) {
        let portPoints: [(CGPoint, Int)] = project.components.flatMap { c in
            c.kind.allPorts.indices.compactMap { i -> (CGPoint, Int)? in
                guard let n = conn.netOf[PortRef(comp: c.id, port: i)] else { return nil }
                return (c.portPoint(i), n)
            }
        }
        var occupied: [Segment] = []

        func stubSegment(_ ref: PortRef, length: CGFloat) -> (CGPoint, CGPoint)? {
            guard let c = project.component(ref.comp) else { return nil }
            let p = c.portPoint(ref.port)
            let d = c.portDirection(ref.port)
            return (p, CGPoint(x: p.x + d.x * length, y: p.y + d.y * length))
        }

        func fits(_ pts: [CGPoint], net: Int) -> Bool {
            for (a, b) in zip(pts, pts.dropFirst()) where a != b {
                for o in occupied where o.net != net {
                    if Routing.collinearOverlap(a, b, o.a, o.b) { return false }
                    if Routing.onSegment(a, o.a, o.b) || Routing.onSegment(b, o.a, o.b) { return false }
                    if Routing.onSegment(o.a, a, b) || Routing.onSegment(o.b, a, b) { return false }
                }
                for (pp, pn) in portPoints where pn != net {
                    if Routing.onSegment(pp, a, b) { return false }
                }
            }
            return true
        }

        func occupy(_ pts: [CGPoint], net: Int) {
            for (a, b) in zip(pts, pts.dropFirst()) where a != b { occupied.append(Segment(a: a, b: b, net: net)) }
        }

        var stubbed = Set<PortRef>()
        func addStub(_ ref: PortRef, name: String) {
            guard !stubbed.contains(ref), let net = conn.netOf[ref] else { return }
            for len: CGFloat in [16, 24, 8] {
                guard let (a, b) = stubSegment(ref, length: len) else { return }
                if fits([a, b], net: net) || len == 8 {
                    if !fits([a, b], net: net) { warnings.append("Label '\(name)' touches another wire; check it in Quartus") }
                    stubs.append(Stub(port: ref, from: a, to: b, name: name, net: net))
                    occupy([a, b], net: net)
                    stubbed.insert(ref)
                    return
                }
            }
        }

        // 1. User net labels.
        for (key, raw) in project.labels.sorted(by: { $0.key < $1.key }) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let parts = key.split(separator: "#")
            guard parts.count == 2, let u = UUID(uuidString: String(parts[0])), let p = Int(parts[1]),
                  project.contains(PortRef(comp: u, port: p)) else { continue }
            addStub(PortRef(comp: u, port: p), name: name)
        }

        // 2. Wires: prefer routes that avoid symbol bodies, then any electrically safe route.
        let bodies = project.components.map { Routing.body($0) }
        func clear(_ pts: [CGPoint]) -> Bool {
            zip(pts, pts.dropFirst()).allSatisfy { a, b in !bodies.contains { Routing.crosses(a, b, $0) } }
        }
        var fallback: [Wire] = []
        for w in project.wires {
            guard let ca = project.component(w.a.comp), let cb = project.component(w.b.comp),
                  let net = conn.netOf[w.a], conn.netOf[w.b] != nil else { continue }
            let s = ca.portPoint(w.a.port), t = cb.portPoint(w.b.port)
            let cands = Routing.candidates(ca, w.a.port, cb, w.b.port)
            let chosen = cands.first { fits($0, net: net) && clear($0) } ?? cands.first { fits($0, net: net) }
            if let chosen {
                routes[w.id] = chosen
                occupy(chosen, net: net)
                for (a, b) in zip(chosen, chosen.dropFirst()) where a != b { segments.append(Segment(a: a, b: b, net: net)) }
            } else {
                routes[w.id] = cands.first ?? [s, t]
                labeledWires.insert(w.id)
                fallback.append(w)
            }
        }
        for w in fallback {
            guard let net = conn.netOf[w.a], conn.netOf[w.b] != nil else { continue }
            let name = conn.netName(net, project: project)
            addStub(w.a, name: name)
            addStub(w.b, name: name)
        }

        // 3. Junction dots where a same-net endpoint lands mid-segment.
        var js: [CGPoint] = []
        let drawn = segments + stubs.map { Segment(a: $0.from, b: $0.to, net: $0.net) }
        for s in drawn {
            for e in [s.a, s.b] {
                for o in drawn where o.net == s.net && e != o.a && e != o.b && Routing.onSegment(e, o.a, o.b) {
                    if !js.contains(e) { js.append(e) }
                }
            }
        }
        junctions = js
    }

    static func snap(_ v: CGFloat) -> CGFloat { (v / grid).rounded() * grid }

    /// Candidate routes between two ports, taking each symbol's rotation into account.
    static func candidates(_ ca: Component, _ pa: Int, _ cb: Component, _ pb: Int) -> [[CGPoint]] {
        let s = ca.portPoint(pa), t = cb.portPoint(pb)
        let sOut = ca.kind.isOutputPort(pa), tOut = cb.kind.isOutputPort(pb)
        let ds = ca.portDirection(pa), dt = cb.portDirection(pb)
        let around = ca.frame.union(cb.frame)
        // Unrotated symbols keep the original, hand-tuned left-to-right routes.
        if ds == CGPoint(x: sOut ? 1 : -1, y: 0) && dt == CGPoint(x: tOut ? 1 : -1, y: 0) {
            return candidates(s, t, sOut: sOut, tOut: tOut, around: around)
        }
        return candidates(s, leaving: ds, t, entering: dt, around: around)
    }

    /// General orthogonal candidates: leave `s` along `ds`, arrive at `t` coming out of it along `dt`.
    static func candidates(_ s: CGPoint, leaving ds: CGPoint, _ t: CGPoint, entering dt: CGPoint,
                           around box: CGRect) -> [[CGPoint]] {
        if s == t { return [] }
        var xs: Set<CGFloat> = [snap((s.x + t.x) / 2)]
        var ys: Set<CGFloat> = [snap((s.y + t.y) / 2)]
        var v = min(s.x, t.x)
        while v <= max(s.x, t.x) { xs.insert(v); v += grid }
        v = min(s.y, t.y)
        while v <= max(s.y, t.y) { ys.insert(v); v += grid }
        if !box.isNull {
            for k in 0..<6 {
                let o = 16 + 16 * CGFloat(k)
                xs.insert(snap(box.minX) - o); xs.insert(snap(box.maxX) + o)
                ys.insert(snap(box.minY) - o); ys.insert(snap(box.maxY) + o)
            }
        }
        var out: [[CGPoint]] = []
        for e1 in stride(from: CGFloat(8), through: 32, by: 8) {
            for e2 in stride(from: CGFloat(8), through: 32, by: 8) {
                let a = CGPoint(x: s.x + ds.x * e1, y: s.y + ds.y * e1)
                let b = CGPoint(x: t.x + dt.x * e2, y: t.y + dt.y * e2)
                var mids: [[CGPoint]] = []
                if a.x == b.x || a.y == b.y { mids.append([]) }
                mids.append([CGPoint(x: b.x, y: a.y)])
                mids.append([CGPoint(x: a.x, y: b.y)])
                for m in xs { mids.append([CGPoint(x: m, y: a.y), CGPoint(x: m, y: b.y)]) }
                for m in ys { mids.append([CGPoint(x: a.x, y: m), CGPoint(x: b.x, y: m)]) }
                for mid in mids {
                    let path = dedupe([s, a] + mid + [b, t])
                    guard path.count >= 2, !reversesOnItself(path) else { continue }
                    let first = CGPoint(x: path[1].x - s.x, y: path[1].y - s.y)
                    let n = path.count
                    let last = CGPoint(x: t.x - path[n - 2].x, y: t.y - path[n - 2].y)
                    // Leave along the port's direction and arrive head-on, like a hand-drawn node.
                    if first.x * ds.x + first.y * ds.y > 0 && last.x * dt.x + last.y * dt.y < 0 { out.append(path) }
                }
            }
        }
        func cost(_ p: [CGPoint]) -> CGFloat { length(p) + 12 * CGFloat(max(0, p.count - 2)) }
        var seen = Set<String>()
        return out.sorted { cost($0) < cost($1) }.filter { p in
            seen.insert(p.map { "\($0.x),\($0.y)" }.joined(separator: ";")).inserted
        }
    }

    /// True when a path doubles back over its own previous segment.
    static func reversesOnItself(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 3 else { return false }
        for i in 1..<(pts.count - 1) {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let d1 = CGPoint(x: b.x - a.x, y: b.y - a.y), d2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            if d1.x * d2.x + d1.y * d2.y < 0 { return true }
        }
        return false
    }

    /// Candidate orthogonal paths from s to t, cheapest first. Output ports are left
    /// heading right and input ports are entered from the left, like a hand-drawn schematic.
    static func candidates(_ s: CGPoint, _ t: CGPoint, sOut: Bool = true, tOut: Bool = false,
                           around box: CGRect = .null) -> [[CGPoint]] {
        if s == t { return [] }
        var out: [[CGPoint]] = []
        // Normalise so that `o` leaves rightwards whenever one end is an output.
        let (o, i, oOut, iOut) = (sOut || !tOut) ? (s, t, sOut, tOut) : (t, s, tOut, sOut)
        if oOut && !iOut {
            if i.x - o.x >= 16 {
                if o.y == i.y { out.append([o, i]) }
                var m = o.x + grid
                var mids: [CGFloat] = []
                while m <= i.x - grid { mids.append(m); m += grid }
                let mid = snap((o.x + i.x) / 2)
                mids.sort { abs($0 - mid) < abs($1 - mid) }
                for m in mids where o.y != i.y { out.append([o, CGPoint(x: m, y: o.y), CGPoint(x: m, y: i.y), i]) }
            }
            // Detour: out to the right, along a free row, back in from the left.
            var rows: [CGFloat] = [snap((o.y + i.y) / 2)]
            if !box.isNull {
                for k in 0..<6 { rows.append(snap(box.minY) - 16 - 16 * CGFloat(k)); rows.append(snap(box.maxY) + 16 + 16 * CGFloat(k)) }
            }
            var detours: [[CGPoint]] = []
            for ym in rows {
                for e1 in stride(from: CGFloat(16), through: 48, by: 8) {
                    for e2 in stride(from: CGFloat(16), through: 48, by: 8) {
                        let x1 = o.x + e1, x2 = i.x - e2
                        detours.append([o, CGPoint(x: x1, y: o.y), CGPoint(x: x1, y: ym), CGPoint(x: x2, y: ym),
                                        CGPoint(x: x2, y: i.y), i])
                    }
                }
            }
            out += detours.sorted { length($0) < length($1) }
        } else {
            // Both ends face the same way (e.g. two gate inputs): loop out on that side.
            let dir: CGFloat = oOut ? 1 : -1
            for k in 0..<6 {
                let x = (dir > 0 ? max(o.x, i.x) : min(o.x, i.x)) + dir * (16 + 8 * CGFloat(k))
                out.append([o, CGPoint(x: x, y: o.y), CGPoint(x: x, y: i.y), i])
            }
        }
        return out.map { dedupe($0) }
    }

    static func length(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y) }
    }

    /// Drops repeated and collinear middle points.
    static func dedupe(_ pts: [CGPoint]) -> [CGPoint] {
        var r: [CGPoint] = []
        for p in pts where r.last != p {
            if r.count >= 2 {
                let a = r[r.count - 2], b = r[r.count - 1]
                let forward = (b.x - a.x) * (p.x - b.x) + (b.y - a.y) * (p.y - b.y) > 0
                if forward && ((a.x == b.x && b.x == p.x) || (a.y == b.y && b.y == p.y)) { r.removeLast() }
            }
            r.append(p)
        }
        return r
    }

    /// The drawn body of a symbol (pin leads excluded), which wires should not cross.
    static func body(_ c: Component) -> CGRect { c.body }

    /// Whether an axis-aligned segment passes through the interior of a rectangle.
    static func crosses(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        if a.y == b.y {
            return a.y > r.minY && a.y < r.maxY && max(min(a.x, b.x), r.minX) < min(max(a.x, b.x), r.maxX)
        }
        if a.x == b.x {
            return a.x > r.minX && a.x < r.maxX && max(min(a.y, b.y), r.minY) < min(max(a.y, b.y), r.maxY)
        }
        return false
    }

    static func onSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
        if a.x == b.x { return p.x == a.x && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y) }
        if a.y == b.y { return p.y == a.y && p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) }
        return false
    }

    static func collinearOverlap(_ a1: CGPoint, _ b1: CGPoint, _ a2: CGPoint, _ b2: CGPoint) -> Bool {
        if a1.y == b1.y, a2.y == b2.y, a1.y == a2.y {
            return min(max(a1.x, b1.x), max(a2.x, b2.x)) > max(min(a1.x, b1.x), min(a2.x, b2.x))
        }
        if a1.x == b1.x, a2.x == b2.x, a1.x == a2.x {
            return min(max(a1.y, b1.y), max(a2.y, b2.y)) > max(min(a1.y, b1.y), min(a2.y, b2.y))
        }
        return false
    }
}

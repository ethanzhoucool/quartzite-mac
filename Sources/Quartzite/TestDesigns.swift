import Foundation

/// Reference designs used by the self-test and by CI, which compiles each one in
/// real Quartus and checks Quartus' view of the circuit against our simulator.
enum TestDesigns {
    struct Builder {
        var p = Project()
        /// Symbols of the design's sheets (lowercased entity name), for `block`.
        var symbols: [String: SymbolDef] = [:]
        init(_ name: String) { p.name = name }

        @discardableResult
        mutating func input(_ name: String, x: Int = 32, y: Int, loc: String? = nil) -> Component {
            add(Component(kind: .input, name: name, x: x, y: y, location: loc))
        }
        @discardableResult
        mutating func output(_ name: String, x: Int, y: Int, loc: String? = nil) -> Component {
            add(Component(kind: .output, name: name, x: x, y: y, location: loc))
        }
        @discardableResult
        mutating func gate(_ kind: GateKind, x: Int, y: Int) -> Component {
            add(Component(kind: kind, name: p.nextInstanceName(), x: x, y: y))
        }
        mutating func add(_ c: Component) -> Component { p.components.append(c); return c }
        /// An instance of another sheet of the design (it must have a symbol).
        @discardableResult
        mutating func block(_ entity: String, x: Int, y: Int) -> Component {
            guard let s = symbols[entity.lowercased()] else { preconditionFailure("\(entity) has no symbol") }
            var c = Component(kind: .block, name: p.nextInstanceName(), x: x, y: y)
            c.symbol = s
            return add(c)
        }
        /// A library macro ("7447").
        @discardableResult
        mutating func macro(_ name: String, x: Int, y: Int) -> Component {
            guard let m = MacroLibrary.named(name) else { preconditionFailure("no macro \(name)") }
            var c = Component(kind: .macro, name: p.nextInstanceName(), x: x, y: y)
            c.symbol = MacroLibrary.symbol(m)
            return add(c)
        }
        @discardableResult
        mutating func vcc(x: Int, y: Int) -> Component { add(Component(kind: .vcc, name: p.nextInstanceName(), x: x, y: y)) }
        @discardableResult
        mutating func gnd(x: Int, y: Int) -> Component { add(Component(kind: .gnd, name: p.nextInstanceName(), x: x, y: y)) }
        /// The port of a block, macro or gate with this name ("cin", "OA", "IN2").
        func port(_ c: Component, _ name: String) -> PortRef {
            guard let i = c.portIndex(named: name) else { preconditionFailure("\(c.symbolName) has no port \(name)") }
            return PortRef(comp: c.id, port: i)
        }

        /// Output port of a gate / input pin (the first output of a block or macro).
        func out(_ c: Component) -> PortRef { PortRef(comp: c.id, port: c.portIndices.first { c.isOutputPort($0) } ?? 0) }
        func pin(_ c: Component, _ i: Int) -> PortRef { PortRef(comp: c.id, port: i) }

        mutating func wire(_ a: PortRef, _ b: PortRef) { p.wires.append(Wire(a: a, b: b)) }
        mutating func wire(_ from: Component, to: Component, _ port: Int) { wire(out(from), pin(to, port)) }
        mutating func label(_ r: PortRef, _ name: String) { p.labels[r.key] = name }
    }

    /// Builds a multi-sheet design one sheet at a time.
    struct DesignBuilder {
        var d: DesignProject

        init(_ name: String, top: String? = nil, device: String = CycloneV.device) {
            d = DesignProject(name: name, device: device, topLevelEntity: top ?? name, sheets: [])
        }

        var symbols: [String: SymbolDef] {
            Dictionary(d.sheets.compactMap { s in s.symbol.map { (s.entityName.lowercased(), $0) } }, uniquingKeysWith: { a, _ in a })
        }

        /// A builder for a new sheet that can place blocks of the sheets added so far.
        func builder(_ entity: String) -> Builder {
            var b = Builder(entity)
            b.p.device = d.device
            b.symbols = symbols
            return b
        }

        mutating func sheet(_ b: Builder) {
            var p = b.p
            if p.id == nil { p.id = UUID() }
            d.sheets.append(p)
        }

        /// File > Create/Update > Create Symbol Files for Current File on `entity`.
        @discardableResult
        mutating func createSymbol(_ entity: String) -> SymbolUpdateReport? {
            guard let i = d.sheetIndex(named: entity), let id = d.sheets[i].id else { return nil }
            return d.createSymbol(forSheet: id)
        }
    }

    /// Half adder sheet: s = a XOR b, c = a AND b.
    static func halfAdder(_ db: DesignBuilder, name: String = "HA") -> Builder {
        var b = db.builder(name)
        b.input("a", y: 64)
        b.input("b", y: 112)
        let x = b.gate(.xor2, x: 320, y: 40)
        b.label(b.pin(x, 0), "a"); b.label(b.pin(x, 1), "b")
        let g = b.gate(.and2, x: 320, y: 136)
        b.label(b.pin(g, 0), "a"); b.label(b.pin(g, 1), "b")
        let s = b.output("s", x: 480, y: 56)
        b.wire(x, to: s, 0)
        let c = b.output("c", x: 480, y: 152)
        b.wire(g, to: c, 0)
        return b
    }

    /// Full adder from two half adders: (s1, c1) = HA(x, y), (s, c2) = HA(s1, cin), cout = c1 + c2.
    static func fullAdder(_ db: DesignBuilder, name: String = "FA", half: String = "HA") -> Builder {
        var b = db.builder(name)
        b.input("x", y: 64)
        b.input("y", y: 112)
        b.input("cin", y: 160)
        let h1 = b.block(half, x: 280, y: 40)
        b.label(b.port(h1, "a"), "x"); b.label(b.port(h1, "b"), "y")
        b.label(b.port(h1, "s"), "s1"); b.label(b.port(h1, "c"), "c1")
        let h2 = b.block(half, x: 280, y: 200)
        b.label(b.port(h2, "a"), "s1"); b.label(b.port(h2, "b"), "cin")
        let o = b.gate(.or2, x: 520, y: 280)
        b.label(b.pin(o, 0), "c1")
        b.wire(b.port(h2, "c"), b.pin(o, 1))
        let s = b.output("s", x: 680, y: 224)
        b.wire(b.port(h2, "s"), b.pin(s, 0))
        let co = b.output("cout", x: 680, y: 296)
        b.wire(o, to: co, 0)
        return b
    }

    /// 4-bit adder/subtractor from four FA blocks: S = A + (B xor m) + m, cout the carry.
    static func addSub4(_ db: DesignBuilder, name: String = "AddSub4", full: String = "FA", locations: Bool = true) -> Builder {
        func loc(_ label: String) -> String? { locations ? BoardPin.de10Standard.first { $0.label == label }?.pin : nil }
        var b = db.builder(name)
        var order: [UUID] = []
        for (k, i) in (0..<4).reversed().enumerated() { order.append(b.input("a\(i)", y: 64 + 48 * k, loc: loc("SW\(6 + i)")).id) }
        for (k, i) in (0..<4).reversed().enumerated() { order.append(b.input("b\(i)", y: 272 + 48 * k, loc: loc("SW\(2 + i)")).id) }
        order.append(b.input("m", y: 480, loc: loc("SW0")).id)
        b.p.inputOrder = order
        for i in 0..<4 {
            let x = b.gate(.xor2, x: 240, y: 560 - 160 * i)
            b.label(b.pin(x, 0), "b\(i)"); b.label(b.pin(x, 1), "m"); b.label(b.out(x), "y\(i)")
            let fa = b.block(full, x: 440, y: 520 - 160 * i)
            b.label(b.port(fa, "x"), "a\(i)"); b.label(b.port(fa, "y"), "y\(i)")
            b.label(b.port(fa, "cin"), i == 0 ? "m" : "c\(i)")
            b.label(b.port(fa, "s"), "s\(i)")
            b.label(b.port(fa, "cout"), i == 3 ? "cout" : "c\(i + 1)")
        }
        for i in 0..<4 { b.output("s\(i)", x: 760, y: 64 + 48 * (3 - i), loc: loc("LEDR\(i)")) }
        b.output("cout", x: 760, y: 16, loc: loc("LEDR4"))
        return b
    }

    /// HA -> FA -> AddSub4, top AddSub4: a3..a0 on SW9..SW6, b3..b0 on SW5..SW2, m on SW0,
    /// s3..s0 on LEDR3..LEDR0 and cout on LEDR4.
    static func addSub4Design() -> DesignProject {
        var db = DesignBuilder("AddSub4")
        db.sheet(halfAdder(db))
        db.createSymbol("HA")
        db.sheet(fullAdder(db))
        db.createSymbol("FA")
        db.sheet(addSub4(db))
        db.createSymbol("AddSub4")
        return db.d
    }

    /// DE10-Standard switches SW3..SW0 for w, x, y, z and LEDR0 for f.
    static let starterLocations = ["w": "PIN_AC30", "x": "PIN_AB28", "y": "PIN_Y27", "z": "PIN_AB30", "f": "PIN_AA24"]

    /// Example function used by the tests: f = Σm(2,3,6,7,9,13,14), SOP form with every
    /// wire drawn: f = w'y + w y'z + x y z'
    static func exampleSOP() -> Project {
        var b = Builder("Example")
        let w = b.input("w", y: 64, loc: starterLocations["w"])
        let x = b.input("x", y: 128, loc: starterLocations["x"])
        let y = b.input("y", y: 192, loc: starterLocations["y"])
        let z = b.input("z", y: 256, loc: starterLocations["z"])
        let nw = b.gate(.not, x: 256, y: 320)
        let ny = b.gate(.not, x: 256, y: 384)
        let nz = b.gate(.not, x: 256, y: 448)
        b.wire(w, to: nw, 0); b.wire(y, to: ny, 0); b.wire(z, to: nz, 0)
        let a1 = b.gate(.and2, x: 440, y: 40)
        let a2 = b.gate(.and3, x: 440, y: 192)
        let a3 = b.gate(.and3, x: 440, y: 336)
        b.wire(nw, to: a1, 0); b.wire(y, to: a1, 1)
        b.wire(w, to: a2, 0); b.wire(ny, to: a2, 1); b.wire(z, to: a2, 2)
        b.wire(x, to: a3, 0); b.wire(y, to: a3, 1); b.wire(nz, to: a3, 2)
        let o = b.gate(.or3, x: 640, y: 176)
        b.wire(a1, to: o, 0); b.wire(a2, to: o, 1); b.wire(a3, to: o, 2)
        let f = b.output("f", x: 800, y: 200, loc: starterLocations["f"])
        b.wire(o, to: f, 0)
        b.p.expected[f.id.uuidString] = "2, 3, 6, 7, 9, 13, 14"
        return b.p
    }

    /// Same function in POS form, built from short labelled wires instead of drawn
    /// ones: f = (w + y)(y + z)(w' + y' + z')(w' + x + z)
    static func examplePOS() -> Project {
        var b = Builder("Example_POS")
        for (i, n) in ["w", "x", "y", "z"].enumerated() { b.input(n, y: 64 + 48 * i, loc: starterLocations[n]) }
        func notGate(_ src: String, _ dst: String, y: Int, _ b: inout Builder) {
            let g = b.gate(.not, x: 320, y: y)
            b.label(b.pin(g, 0), src); b.label(b.out(g), dst)
        }
        notGate("w", "wn", y: 280, &b)
        notGate("y", "yn", y: 336, &b)
        notGate("z", "zn", y: 392, &b)
        let s1 = b.gate(.or2, x: 520, y: 48)
        b.label(b.pin(s1, 0), "w"); b.label(b.pin(s1, 1), "y"); b.label(b.out(s1), "s1")
        let s2 = b.gate(.or2, x: 520, y: 128)
        b.label(b.pin(s2, 0), "y"); b.label(b.pin(s2, 1), "z"); b.label(b.out(s2), "s2")
        let s3 = b.gate(.or3, x: 520, y: 208)
        b.label(b.pin(s3, 0), "wn"); b.label(b.pin(s3, 1), "yn"); b.label(b.pin(s3, 2), "zn"); b.label(b.out(s3), "s3")
        let s4 = b.gate(.or3, x: 520, y: 304)
        b.label(b.pin(s4, 0), "wn"); b.label(b.pin(s4, 1), "x"); b.label(b.pin(s4, 2), "z"); b.label(b.out(s4), "s4")
        let p = b.gate(.and4, x: 720, y: 144)
        b.label(b.pin(p, 0), "s1"); b.label(b.pin(p, 1), "s2"); b.label(b.pin(p, 2), "s3"); b.label(b.pin(p, 3), "s4")
        let f = b.output("f", x: 880, y: 176, loc: starterLocations["f"])
        b.wire(p, to: f, 0)
        b.p.expected[f.id.uuidString] = "2, 3, 6, 7, 9, 13, 14"
        return b.p
    }

    /// Every primitive, each driving its own output pin.
    static func allGates() -> Project {
        var b = Builder("AllGates")
        let names = ["a", "b", "c", "d"]
        let sw = BoardPin.de10Standard.filter { $0.kind == .slideSwitch }
        for (i, n) in names.enumerated() { b.input(n, y: 48 + 32 * i, loc: sw[3 - i].pin) }
        var y = 48
        let leds = BoardPin.de10Standard.filter { $0.kind == .led }
        for (k, kind) in GateKind.gates.enumerated() {
            let g = b.gate(kind, x: 360, y: y)
            for i in 0..<kind.arity { b.label(b.pin(g, i), names[i]) }
            let outY = Int(kind.outputPorts[0].y) + y
            let o = b.output("o_\(kind.rawValue)", x: 560, y: outY - 8, loc: k < leds.count ? leds[k].pin : nil)
            b.wire(g, to: o, 0)
            y += Int(kind.size.height) + 24
        }
        return b.p
    }

    /// Routing edge cases: a backwards wire (exported as labels), fan-out, a direct
    /// pin-to-pin wire, ports that touch without a wire, and crossing wires.
    static func tricky() -> Project {
        var b = Builder("Tricky")
        let p = b.input("p", y: 48)
        let q = b.input("q", y: 112)
        let r = b.input("r", y: 176)
        let s = b.input("s", y: 400)
        let g1 = b.gate(.and2, x: 600, y: 48)
        b.wire(p, to: g1, 0); b.wire(q, to: g1, 1)
        let g2 = b.gate(.not, x: 320, y: 240)          // left of its driver: backwards
        b.wire(g1, to: g2, 0)
        let o1 = b.output("o1", x: 800, y: 248)
        b.wire(g2, to: o1, 0)
        let x1 = b.gate(.xor2, x: 600, y: 304)         // fan-out of g2 + crossing wires
        b.wire(g2, to: x1, 0); b.wire(p, to: x1, 1)
        let o2 = b.output("o2", x: 800, y: 320)
        b.wire(x1, to: o2, 0)
        let o3 = b.output("o3", x: 800, y: 176)        // pin to pin
        b.wire(r, to: o3, 0)
        let g3 = b.gate(.not, x: 200, y: 392)          // input touches s's port (200,408)
        let o4 = b.output("o4", x: 800, y: 400)
        b.wire(g3, to: o4, 0)
        _ = s
        return b.p
    }

    /// Rotated and flipped symbols in every orientation Quartus can store, wired in
    /// directions the left-to-right router never sees, plus a free text note.
    static func rotated() -> Project {
        var b = Builder("Rotated")
        func turn(_ c: Component, _ o: Orientation, _ b: inout Builder) -> Component {
            guard let i = b.p.index(of: c.id) else { return c }
            b.p.components[i].orientation = o
            return b.p.components[i]
        }
        let a = b.input("a", y: 64)
        let bb = b.input("b", y: 160)
        let c = turn(b.input("c", x: 400, y: 0), .rotate270, &b)           // points down, port (408,168)
        let d = turn(b.input("d", x: 880, y: 640), .flipy, &b)            // points left, port (880,648)
        let n1 = turn(b.gate(.not, x: 232, y: 200), .rotate270, &b)       // in (248,200) out (248,248)
        b.wire(a, to: n1, 0)
        let g1 = turn(b.gate(.and2, x: 520, y: 280), .rotate180, &b)      // out (520,304)
        b.wire(n1, to: g1, 0); b.wire(c, to: g1, 1)
        let o1 = turn(b.output("o1", x: 328, y: 296), .flipy, &b)         // port (504,304)
        b.wire(g1, to: o1, 0)
        let g2 = turn(b.gate(.or2, x: 640, y: 64), .rotate90, &b)         // ins (656,128) (672,128), out (664,64)
        b.wire(bb, to: g2, 0); b.wire(a, to: g2, 1)
        let o2 = b.output("o2", x: 760, y: 32)
        b.wire(g2, to: o2, 0)
        let g3 = turn(b.gate(.xor2, x: 640, y: 400), .flipy, &b)          // out (640,424), ins (704,416) (704,432)
        b.wire(a, to: g3, 0); b.wire(bb, to: g3, 1)
        let o3 = turn(b.output("o3", x: 400, y: 416), .flipy, &b)
        b.wire(g3, to: o3, 0)
        let g4 = turn(b.gate(.nand2, x: 640, y: 520), .flipx, &b)         // ins (640,552) (640,536), out (704,544)
        b.wire(a, to: g4, 0); b.wire(c, to: g4, 1)
        let o4 = b.output("o4", x: 800, y: 536)
        b.wire(g4, to: o4, 0)
        let n2 = turn(b.gate(.not, x: 760, y: 632), .flipy, &b)           // in (808,648) out (760,648)
        b.wire(d, to: n2, 0)
        let o5 = turn(b.output("o5", x: 520, y: 640), .flipy, &b)         // port (696,648)
        b.wire(n2, to: o5, 0)
        b.p.notes = [TextNote(text: "Rotated and flipped primitives", x: 32, y: 8)]
        return b.p
    }

    static var all: [(String, Project)] {
        [("example_sop", exampleSOP()), ("example_pos", examplePOS()), ("all_gates", allGates()), ("tricky", tricky()),
         ("rotated", rotated())]
    }

    // MARK: - Export for CI

    /// Writes `<dir>/<design>/` Quartus bundles plus `expected.json` (our simulator's truth table).
    static func exportSuite(to dir: URL, designs: [(String, Project)] = all) throws {
        for (folder, p) in designs {
            let (circuit, msgs) = Compiler.compile(p)
            guard let circuit else {
                throw NSError(domain: "Quartzite", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(folder) does not compile: " + msgs.filter { $0.level == .error }.map { $0.text }.joined(separator: "; ")])
            }
            let sim = try SimulationResult.run(circuit, project: p)
            let bundle = try QuartusExport.makeBundle(p, conn: circuit.conn)
            let out = dir.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var files = bundle.files
            if let vo = NetlistWriter.bundleFile(p) { files.append(vo) }
            for f in files {
                let url = out.appendingPathComponent(f.name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.contents.write(to: url, atomically: true, encoding: .utf8)
            }
            let json: [String: Any] = [
                "entity": p.entityName,
                "inputs": sim.inputNames,
                "outputs": sim.outputNames,
                "step_ns": QuartusExport.vwfTiming(sim.inputCount).step,
                "rows": sim.rows.map { r in r.outputs.map { $0 ? "1" : "0" }.joined() },
                "locations": Dictionary(uniqueKeysWithValues: (p.inputPins + p.outputPins).compactMap { c in
                    c.location.map { (c.name, $0) } }),
                "labeled_wires": bundle.notes,
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent("expected.json"))
            try JSONEncoder().encode(p).write(to: out.appendingPathComponent("\(p.entityName).qzproj"))
            print("exported \(folder): \(sim.rows.count) rows, \(bundle.notes.count) notes")
        }
    }
}

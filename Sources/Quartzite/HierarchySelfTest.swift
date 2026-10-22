import Foundation

/// Self-tests for multi-sheet designs, block symbols, library macros and flattening.
/// Called from `SelfTest.run`. Quartus-written fixtures come from `QUARTZITE_FIXTURES`
/// (default ./ci/fixtures/quartus18); without them those checks print SKIP, unless
/// `QUARTZITE_REQUIRE_FIXTURES=1` (CI), which makes a missing fixture a failure.
enum HierarchySelfTest {
    typealias Check = (Bool, String) -> Void

    static var fixturesDir: URL {
        if let e = ProcessInfo.processInfo.environment["QUARTZITE_FIXTURES"], !e.isEmpty { return URL(fileURLWithPath: e, isDirectory: true) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("ci/fixtures/quartus18", isDirectory: true)
    }
    static var requireFixtures: Bool { ProcessInfo.processInfo.environment["QUARTZITE_REQUIRE_FIXTURES"] == "1" }

    /// A fixture's text, or nil (after printing SKIP or failing) when it is missing.
    static func fixture(_ path: String, _ check: Check) -> String? {
        let url = fixturesDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            if requireFixtures { check(false, "fixture \(path) is present (QUARTZITE_REQUIRE_FIXTURES=1)") }
            else { print("  SKIP fixture \(path) not found in \(fixturesDir.path)") }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func tokens(_ s: String) -> [SExprParser.Token] { SExprParser.tokenize(s) }

    /// The text from `(header` on: everything Quartus writes after its comments.
    static func afterComments(_ s: String) -> Substring {
        guard let r = s.range(of: "(header") else { return s[...] }
        return s[r.lowerBound...]
    }

    static func run(_ check: Check) {
        symbols(check)
        model(check)
        sheetOps(check)
        writers(check)
        macros(check)
        flattening(check)
        flow(check)
        references(check)
    }

    /// Truth table rows (outputs as a bit string per row) of a compiled circuit.
    static func rows(_ c: CompiledCircuit) -> [String] {
        let n = c.inputs.count
        return (0..<(1 << n)).map { r in
            c.evaluate((0..<n).map { (r >> (n - 1 - $0)) & 1 == 1 }).outputs.map { $0 ? "1" : "0" }.joined()
        }
    }

    /// Rows of `d`, with output columns named, for an oracle check.
    static func table(_ d: DesignProject, forceFull: Bool = true) -> (inputs: [String], outputs: [String], rows: [[Bool]])? {
        guard let (f, _) = Optional(Flattener.flatten(d, forceFull: forceFull)), let f, let c = Compiler.elaborateFlat(f).0 else { return nil }
        let n = c.inputs.count
        return (c.inputs.map(\.name), c.outputs.map(\.name),
                (0..<(1 << n)).map { r in c.evaluate((0..<n).map { (r >> (n - 1 - $0)) & 1 == 1 }).outputs })
    }

    /// Checks every row of `d` against `oracle` (input values by name -> output values by name).
    static func matches(_ d: DesignProject, _ oracle: ([String: Int]) -> [String: Int]) -> Bool {
        guard let t = table(d) else { return false }
        for (r, outs) in t.rows.enumerated() {
            var ins: [String: Int] = [:]
            for (k, name) in t.inputs.enumerated() { ins[name] = (r >> (t.inputs.count - 1 - k)) & 1 }
            let want = oracle(ins)
            for (k, name) in t.outputs.enumerated() where want[name] != (outs[k] ? 1 : 0) { return false }
        }
        return true
    }

    /// HA and FA (two HA blocks), top FA, symbols created.
    static func haFA() -> DesignProject {
        var db = TestDesigns.DesignBuilder("FA")
        db.sheet(TestDesigns.halfAdder(db))
        db.createSymbol("HA")
        db.sheet(TestDesigns.fullAdder(db))
        db.createSymbol("FA")
        return db.d
    }

    /// The (component name, port name) at both ends of each wire on `sheet`, sorted.
    static func wireEnds(_ d: DesignProject, _ sheet: String) -> [String] {
        guard let s = d.sheet(named: sheet) else { return [] }
        func end(_ r: PortRef) -> String {
            guard let c = s.components.first(where: { $0.id == r.comp }) else { return "?" }
            return "\(c.name).\(c.portName(r.port))"
        }
        return s.wires.map { [end($0.a), end($0.b)].sorted().joined(separator: "-") }.sorted()
    }

    // MARK: - Symbols (plan 1.2)

    /// HA (x, y -> s, cout) and BIGBLK (a_long_input, b -> result_out, z), placed like the fixtures' .bdf files.
    static func fixtureSheet(_ name: String, ins: [String], outs: [String]) -> Project {
        var b = TestDesigns.Builder(name)
        for (k, n) in ins.enumerated() { b.input(n, x: 40, y: 100 + 40 * k) }
        for (k, n) in outs.enumerated() { b.output(n, x: 420, y: 108 + 80 * k) }
        return b.p
    }

    static func symbols(_ check: Check) {
        print("Block symbols (.bsf)")
        check(SExprParser.inline(.list([.atom("font"), .string("Intel Clear")])) == "(font \"Intel Clear\" )",
              "a font without attributes is written as (font \"Intel Clear\" )")
        let ha = SymbolGenerator.symbol(for: fixtureSheet("HA", ins: ["x", "y"], outs: ["s", "cout"]))
        let big = SymbolGenerator.symbol(for: fixtureSheet("BIGBLK", ins: ["a_long_input", "b"], outs: ["result_out", "z"]))
        check(ha.width == 96 && ha.height == 96, "HA symbol is 96 x 96 (got \(ha.width) x \(ha.height))")
        check(big.width == 192 && big.height == 96, "BIGBLK symbol is 192 x 96 (got \(big.width) x \(big.height))")
        let data = try? JSONEncoder().encode(ha)
        check(data.flatMap { try? JSONDecoder().decode(SymbolDef.self, from: $0) } == ha, "SymbolDef survives a JSON round trip")

        for (file, def) in [("hier/HA.bsf", ha), ("hier/BIGBLK.bsf", big)] {
            guard let text = fixture(file, check) else { continue }
            let ours = QuartusExport.bsf(def)
            check(tokens(ours) == tokens(text), "generated \(file) has the same tokens as Quartus' (comments ignored)")
            check(afterComments(ours) == afterComments(text), "generated \(file) is byte-identical to Quartus' after the comments (CRLF)")
            check(!ours.contains("Intel Corporation"), "generated \(file) does not copy Intel's copyright comment")
            if let parsed = try? SymbolDef(parsing: text) {
                check(tokens(QuartusExport.bsf(parsed)) == tokens(text), "\(file) parses and re-writes to the same tokens")
                check(parsed == def, "\(file) parses to the generated symbol")
            } else {
                check(false, "\(file) parses")
            }
        }
        if let t = fixture("lab2/sym7447_template.txt", check) {
            if let def = try? SymbolDef(parsing: t, source: .library, libraryPath: ["others", "maxplus2"]) {
                let back = def.text(rect: CGPoint(x: 744, y: 344), instance: "inst", lineEnding: "\n")
                check(tokens(back) == tokens(t), "7447 template parses and re-writes to the same tokens")
                check(back.trimmingCharacters(in: .newlines) == t.trimmingCharacters(in: .newlines), "7447 template re-writes byte for byte")
                check(def.width == 120 && def.height == 160 && def.ports.count == 15, "7447 is 120 x 160 with 15 ports")
                check(def.ports.map(\.name) == ["LTN", "B", "C", "D", "RBIN", "BIN", "A", "OB", "OC", "OE", "OD", "OF", "OG", "OA", "RBON"],
                      "7447 ports keep the file order")
            } else {
                check(false, "7447 template parses")
            }
        }
        if let t = fixture("lab2/vcc_symbol.txt", check) {
            let ours = BuiltinSymbols.vcc.text(rect: CGPoint(x: 304, y: 208), instance: "vcc_ctl", lineEnding: "\r\n")
            check(ours == t, "VCC symbol matches the compiled Lab 2 sheet byte for byte (instance vcc_ctl)")
        }
        let vcc = Component(kind: .vcc, name: "inst", x: 100, y: 100)
        check(vcc.size == CGSize(width: 32, height: 16) && vcc.portCount == 1 && vcc.isOutputPort(0)
              && vcc.portPoint(0) == CGPoint(x: 116, y: 116) && vcc.portDirection(0) == CGPoint(x: 0, y: 1),
              "VCC: 32 x 16, one output at (16,16) pointing down")
        let gnd = Component(kind: .gnd, name: "inst", x: 100, y: 100)
        check(gnd.size == CGSize(width: 32, height: 32) && gnd.portPoint(0) == CGPoint(x: 116, y: 100) && gnd.portDirection(0) == CGPoint(x: 0, y: -1),
              "GND: 32 x 32, one output at (16,0) pointing up (provisional geometry)")
        var blk = Component(kind: .block, name: "inst", x: 240, y: 272)
        blk.symbol = ha
        check(blk.frame == CGRect(x: 240, y: 272, width: 96, height: 96) && blk.portPoint(0) == CGPoint(x: 240, y: 304)
              && blk.portPoint(3) == CGPoint(x: 336, y: 320) && blk.isOutputPort(2) && !blk.isOutputPort(1)
              && blk.portName(3) == "cout" && blk.portDirection(2) == CGPoint(x: 1, y: 0) && blk.symbolName == "HA",
              "an HA block instance has the symbol's size, ports and names")
    }

    // MARK: - Design model (plan 1.1)

    static func model(_ check: Check) {
        print("Multi-sheet design model")
        let legacy = TestDesigns.exampleSOP()
        let v1 = (try? JSONEncoder().encode(legacy)) ?? Data()
        let d1 = try? DesignProject.load(v1)
        check(d1?.sheets.count == 1 && d1?.topLevelEntity == "Example" && d1?.top?.components.count == legacy.components.count
              && d1?.sheets[0].id != nil, "a version 1 file loads as one sheet with top Example and a sheet id")
        let saved = fixturesDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("designs/example_sop.qzproj")
        if let data = try? Data(contentsOf: saved) {
            let d = try? DesignProject.load(data)
            check(d?.sheets.count == 1 && d?.topLevelEntity == "Example", "ci/designs/example_sop.qzproj (v1) loads with top Example")
        } else if requireFixtures {
            check(false, "ci/designs/example_sop.qzproj is present")
        } else {
            print("  SKIP ci/designs/example_sop.qzproj not found")
        }
        var two = DesignProject(single: legacy)
        var other = fixtureSheet("HA", ins: ["x", "y"], outs: ["s", "cout"])
        other.id = UUID()
        other.symbol = SymbolGenerator.symbol(for: other)
        two.sheets.append(other)
        let enc = try? two.encoded()
        let back = enc.flatMap { try? DesignProject.load($0) }
        check(back.flatMap { try? $0.encoded() } == enc && back?.sheets.count == 2 && back?.sheet(named: "ha")?.symbol == other.symbol,
              "a two-sheet version 2 design survives a save and load unchanged")
        var newer = two
        newer.formatVersion = 3
        check((try? DesignProject.load(try newer.encoded())) == nil, "a file from a newer Quartzite is refused")
        var clash = two
        clash.sheets[1].name = "example"
        check(clash.structuralErrors.contains { $0.contains("same entity name") }, "sheet names that differ only in case are refused")
        var noTop = two
        noTop.topLevelEntity = "Missing"
        check((try? DesignProject.load(try noTop.encoded())) == nil, "a design whose top-level entity is not a sheet is refused")
        check(legacy.symbol == nil && legacy.id == nil
              && !(String(data: (try? JSONEncoder().encode(legacy)) ?? Data(), encoding: .utf8) ?? "").contains("\"symbol\""),
              "a single-sheet project without a symbol still saves without the new keys")
    }

    // MARK: - Writers (plan 1.6)

    /// hiertop with HA at (240,272) "inst" and BIGBLK at (240,720) "inst1", as in the fixture.
    static func hiertop() -> DesignProject {
        var db = TestDesigns.DesignBuilder("hiertop")
        for (n, ins, outs) in [("HA", ["x", "y"], ["s", "cout"]), ("BIGBLK", ["a_long_input", "b"], ["result_out", "z"])] {
            var p = fixtureSheet(n, ins: ins, outs: outs)
            p.id = UUID()
            db.d.sheets.append(p)
            db.createSymbol(n)
        }
        var b = db.builder("hiertop")
        b.block("HA", x: 240, y: 272)
        b.block("BIGBLK", x: 240, y: 720)
        db.sheet(b)
        return db.d
    }

    static func bdf(_ p: Project) -> String { QuartusExport.bdf(p, routing: Routing(project: p, conn: Connectivity(p))) }

    /// Names of the (pin ...) blocks of a .bdf, in file order.
    static func pinNames(_ bdf: String) -> [String] {
        ((try? SExprParser.parse(bdf)) ?? []).filter { $0.head == "pin" }.compactMap { $0.children("text").dropFirst().first?.items.dropFirst().first?.stringValue }
    }

    static func writers(_ check: Check) {
        print("Hierarchical .bdf and .qsf")
        let d = hiertop()
        let top = d.top!
        check(top.components.map(\.name) == ["inst", "inst1"], "hiertop instances are inst and inst1")
        let ours = bdf(top)
        if let t = fixture("hier/hiertop.bdf", check) {
            check(tokens(String(afterComments(ours))) == tokens(String(afterComments(t))),
                  "hiertop.bdf: the HA and BIGBLK instances have the same tokens as Quartus' (lines 22-93)")
        }
        check(!ours.contains("\r"), "a .bdf with blocks uses LF line endings")

        var ha = fixtureSheet("HA", ins: ["y", "x"], outs: ["s"])
        check(pinNames(bdf(ha)) == ["y", "x", "s"], "a sheet without a symbol writes its pins in component order")
        ha.symbol = SymbolGenerator.symbol(for: ha)
        ha.components.append(Component(kind: .input, name: "late", x: 40, y: 20))
        check(ha.symbol?.inputs.map(\.name) == ["y", "x"] && pinNames(bdf(ha)) == ["y", "x", "late", "s"],
              "a sheet with a symbol writes its pins in symbol port order, new pins last")
        ha.components.swapAt(0, 1)
        check(pinNames(bdf(ha)) == ["y", "x", "late", "s"], "symbol port order wins over component order")

        let qsf = QuartusExport.qsf(d, top: top, date: Date(timeIntervalSince1970: 0))
        let files = qsf.split(separator: "\n").filter { $0.contains("BDF_FILE") }
        check(files == ["set_global_assignment -name BDF_FILE hiertop.bdf", "set_global_assignment -name BDF_FILE HA.bdf",
                        "set_global_assignment -name BDF_FILE BIGBLK.bdf"], "the .qsf lists hiertop.bdf, HA.bdf, BIGBLK.bdf (got \(files))")
        check(qsf.contains("TOP_LEVEL_ENTITY hiertop\n"), "the .qsf names hiertop as the top-level entity")
        var unused = d
        _ = try? unused.addSheet(named: "Unused")
        check(!QuartusExport.qsf(unused, top: top, date: Date()).contains("Unused.bdf"), "sheets not used under the top are not listed")
        let legacy = TestDesigns.exampleSOP()
        check(QuartusExport.qsf(legacy, date: Date(timeIntervalSince1970: 0)) == QuartusExport.qsf(DesignProject(single: legacy), top: legacy, date: Date(timeIntervalSince1970: 0)),
              "a one-sheet design writes the same .qsf as before")

        var vg = TestDesigns.Builder("vg")
        vg.vcc(x: 304, y: 208)
        let v = bdf(vg.p)
        if let t = fixture("lab2/vcc_symbol.txt", check) {
            check(v.replacingOccurrences(of: "\"inst\"", with: "\"vcc_ctl\"").contains(t.replacingOccurrences(of: "\r\n", with: "\n")),
                  "a VCC on a sheet is written exactly as Quartus writes it")
        }
    }

    // MARK: - Library macros and VCC/GND (plan 2.1-2.3)

    static func macros(_ check: Check) {
        print("Library macros and VCC/GND")
        let m = MacroLibrary.ttl7447
        check(MacroLibrary.named("7447")?.name == "7447" && MacroLibrary.named("nope") == nil, "MacroLibrary finds the 7447")
        let sym = MacroLibrary.symbol(m)
        check(sym.width == 120 && sym.height == 160 && sym.ports.count == 15 && sym.source == .library
              && sym.libraryPath == ["others", "maxplus2"], "the 7447 symbol is 120 x 160 with 15 ports from others > maxplus2")
        check(Set(sym.inputs.map(\.name)) == Set(m.inputs) && Set(sym.outputs.map(\.name)) == Set(m.outputs),
              "the 7447 symbol's ports are the macro's inputs and outputs")
        if let t = fixture("lab2/sym7447_template.txt", check) {
            check(MacroLibrary.sym7447 + "\n" == t || MacroLibrary.sym7447 == t, "the 7447 symbol text is a byte copy of the Quartus template")
        }

        // Lit segments (a...g) for 0-9; 10-15 follow the plan's table.
        let lit = ["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "cdefg", "abc", "abcdefg", "abcfg"]
        func run(_ n: Int, ltn: Bool = true, rbin: Bool = true, bin: Bool = true) -> [Bool] {
            m.function([n & 1 != 0, n & 2 != 0, n & 4 != 0, n & 8 != 0, ltn, rbin, bin])
        }
        var digitsOK = true, tableOK = true, rbonOK = true
        for n in 0..<16 {
            let out = run(n)
            for (s, seg) in "abcdefg".enumerated() {
                if n < 10 && out[s] != !lit[n].contains(seg) { digitsOK = false }
                if out[s] != MacroLibrary.segmentsOff7447[s].contains(n) { tableOK = false }
            }
            if !out[7] { rbonOK = false }
        }
        check(digitsOK, "7447 shows 0-9 with the TTL shapes (6 without its top bar, 9 without its tail)")
        check(tableOK, "7447 segments match the plan's table for n = 0...15")
        check(rbonOK, "RBON is 1 whenever RBIN = 1")
        var controlsOK = true
        for n in 0..<16 {
            for ltn in [false, true] { for rbin in [false, true] where run(n, ltn: ltn, rbin: rbin, bin: false).prefix(7).contains(false) { controlsOK = false } }
            if run(n, ltn: false, rbin: true).prefix(7).contains(true) || run(n, ltn: false, rbin: false).prefix(7).contains(true) { controlsOK = false }
            let blank = run(n, rbin: false)
            if n == 0 { if blank != Array(repeating: true, count: 7) + [false] { controlsOK = false } }
            else if blank != run(n) { controlsOK = false }
        }
        check(controlsOK, "BIN = 0 blanks, LTN = 0 lights every segment, RBIN = 0 blanks only a 0 and then drives RBON low")

        let net = MacroSynth.netlist(m)
        // Port names such as OF are reserved words at the top level; the flattener renames
        // every internal node, so check a copy with prefixed names.
        var named = net
        for i in named.components.indices where named.components[i].kind.isPin { named.components[i].name = "m_" + named.components[i].name }
        named.labels = named.labels.mapValues { "m_" + $0 }
        let (circuit, msgs) = Compiler.compile(named, checkLocations: false)
        check(circuit != nil, "the 7447 gate model compiles (\(msgs.filter { $0.level == .error }.map(\.text).prefix(3)))")
        check(net.inputPins.map(\.name) == m.inputs && net.outputPins.map(\.name) == m.outputs, "the gate model's pins are the macro's ports, in order")
        if let c = circuit {
            var same = true
            for row in 0..<128 {
                let bits = (0..<7).map { k in (row >> (6 - k)) & 1 == 1 }
                if c.evaluate(bits).outputs != m.function(bits) { same = false }
            }
            check(same, "the 7447 gate model equals its function on all 128 rows")
            print("  info 7447 gate model: \(c.stats.gates) gates (\(c.stats.inverters) NOT), \(c.stats.gateInputs) gate inputs")
        }
        check(net.isFlatNetlist && net.components.allSatisfy { $0.x == 0 }, "the gate model is connected by name only")
        check(MacroLibrary.netlist(m).components.count == net.components.count, "the cached gate model is the same size")

        for (kind, gate, value) in [(GateKind.vcc, GateKind.and2, true), (GateKind.gnd, GateKind.or2, false)] {
            var b = TestDesigns.Builder("const_\(kind.rawValue)")
            let a = b.input("a", y: 64)
            let k = kind == .vcc ? b.vcc(x: 200, y: 120) : b.gnd(x: 200, y: 160)
            let g = b.gate(gate, x: 320, y: 48)
            b.wire(a, to: g, 0)
            b.wire(b.out(k), b.pin(g, 1))
            let f = b.output("f", x: 520, y: 64)
            b.wire(g, to: f, 0)
            let name = kind.bdfName
            let (cc, _) = Compiler.compile(b.p, checkLocations: false)
            check(cc != nil && cc!.stats.gates == 1, "\(name) driving \(gate.bdfName) compiles; \(name) is not counted as a gate")
            if let cc {
                check(cc.evaluate([false]).outputs == [false] && cc.evaluate([true]).outputs == [true],
                      "\(gate.bdfName)(a, \(name)) simulates as a (\(name) = \(value ? 1 : 0))")
                let v = QuartusExport.verilog(b.p, conn: cc.conn)
                check(v.contains("= 1'b\(value ? 1 : 0);"), "the Verilog backup assigns 1'b\(value ? 1 : 0) for \(name)")
                if let syn = try? Synthesizer.run(cc, project: b.p) {
                    check(!syn.removed.contains { $0.kind == kind }, "\(name) is not reported as a redundant gate")
                } else {
                    check(false, "synthesis runs with \(name)")
                }
                check((try? QuartusExport.makeBundle(b.p, conn: cc.conn)) != nil, "a sheet with \(name) exports")
            }
        }
    }

    // MARK: - Flattening and the split compiler (plan 3.1-3.3)

    static func flattening(_ check: Check) {
        print("Flattening")
        for (name, p) in TestDesigns.legacy {
            let d = DesignProject(single: p)
            let fast = Flattener.flatten(d).0, full = Flattener.flatten(d, forceFull: true).0
            let a = fast.flatMap { Compiler.elaborateFlat($0).0 }, b = full.flatMap { Compiler.elaborateFlat($0).0 }
            check(fast?.identity == true && full?.identity == false && a != nil && b != nil && rows(a!) == rows(b!)
                  && a!.inputs.map(\.id) == b!.inputs.map(\.id) && a!.outputs.map(\.id) == b!.outputs.map(\.id),
                  "\(name): the full flattener gives the same truth table and pins as the sheet itself")
            check(Connectivity(p).nets.count == Connectivity(p, geometric: true).nets.count, "\(name): geometric connectivity is the default for drawn sheets")
        }

        var ha = haFA()
        ha.topLevelEntity = "HA"
        check(matches(ha) { ["s": $0["a"]! ^ $0["b"]!, "c": $0["a"]! & $0["b"]!] }, "HA matches s = a xor b, c = a and b")
        let fa = haFA()
        check(matches(fa) { v in
            let t = v["x"]! + v["y"]! + v["cin"]!
            return ["s": t & 1, "cout": t >> 1]
        }, "FA (two HA blocks) is a full adder")
        let add = TestDesigns.addSub4Design()
        let addOracle: ([String: Int]) -> [String: Int] = { v in
            let a = (0..<4).reduce(0) { $0 | v["a\($1)"]! << $1 }, b = (0..<4).reduce(0) { $0 | v["b\($1)"]! << $1 }, m = v["m"]!
            let sum = a + (m == 1 ? b ^ 15 : b) + m
            var out = ["cout": (sum >> 4) & 1]
            for i in 0..<4 { out["s\(i)"] = (sum >> i) & 1 }
            return out
        }
        check(matches(add, addOracle), "AddSub4 (HA -> FA -> AddSub4) adds and subtracts on all 512 rows")
        let (c, msgs, flat) = Compiler.compile(add)
        check(c != nil && flat?.identity == false && !msgs.contains { $0.level == .error }, "AddSub4 compiles as a design")
        check(c?.inputs.map(\.name) == ["a3", "a2", "a1", "a0", "b3", "b2", "b1", "b0", "m"], "AddSub4 keeps the top sheet's input order")
        if let flat {
            check(flat.sheetsUsed == ["AddSub4", "FA", "HA"] && flat.macrosUsed.isEmpty, "AddSub4 uses AddSub4, FA and HA")
            check(flat.project.components.filter { $0.kind.isGate }.count == 4 + 4 * 5, "the flat AddSub4 has 4 XOR + 4 x 5 gates")
            let names = flat.origin.values.map(\.displayPath)
            check(names.contains("FA:inst3|HA:inst1|inst1"), "flat gates keep their hierarchical names (\(names.sorted().prefix(2)))")
            let labels = Set(flat.project.labels.values)
            check(labels.contains("a3") && labels.contains("cout") && labels.contains("c1"), "flat nets keep the top's pin and node names")
            check(Set(flat.project.components.map { $0.name.lowercased() }).count == flat.project.components.count, "flat instance names are unique")
        }
        var renamed = add
        let haID = renamed.sheet(named: "HA")!.id!
        try? renamed.renameSheet(id: haID, to: "HALF")
        check(matches(renamed, addOracle) && Compiler.compile(renamed).0 != nil, "after renaming HA to HALF, AddSub4 still compiles and adds")

        // Negative cases: each gives exactly one error.
        func errors(_ d: DesignProject) -> [String] {
            Compiler.compile(d).1.filter { $0.level == .error && !$0.text.hasPrefix("Design check failed") }.map(\.text)
        }
        var rec = haFA()
        rec.topLevelEntity = "HA"
        let hi = rec.sheetIndex(named: "HA")!
        var self_ = Component(kind: .block, name: "inst9", x: 600, y: 400)
        self_.symbol = rec.sheets[hi].symbol
        rec.sheets[hi].components.append(self_)
        let recErr = errors(rec)
        check(recErr.count == 1 && recErr[0].contains("contains itself"), "a block that contains itself gives one error (\(recErr))")
        // One HA block in a wrapper sheet.
        var wrap = TestDesigns.DesignBuilder("Wrap")
        wrap.sheet(TestDesigns.halfAdder(wrap))
        wrap.createSymbol("HA")
        var wb = wrap.builder("Wrap")
        let p1 = wb.input("p", y: 64), q1 = wb.input("q", y: 112)
        let h = wb.block("HA", x: 240, y: 40)
        wb.wire(wb.out(p1), wb.port(h, "a")); wb.wire(wb.out(q1), wb.port(h, "b"))
        let so = wb.output("so", x: 520, y: 72), co = wb.output("co", x: 520, y: 120)
        wb.wire(wb.port(h, "s"), wb.pin(so, 0)); wb.wire(wb.port(h, "c"), wb.pin(co, 0))
        wrap.sheet(wb)
        check(matches(wrap.d) { ["so": $0["p"]! ^ $0["q"]!, "co": $0["p"]! & $0["q"]!] }, "a block wired with drawn wires flattens like one connected by names")
        var missing = wrap.d
        missing.sheets.removeAll { $0.entityName == "HA" }
        let missErr = errors(missing)
        check(missErr.count == 1 && missErr[0].contains("HA.bdf"), "a missing child sheet gives one error (\(missErr))")
        var stale = wrap.d
        let si = stale.sheetIndex(named: "HA")!
        var haSheet = stale.sheets[si]
        haSheet.components.removeAll { $0.name == "c" }
        let kept = haSheet
        haSheet.wires.removeAll { w in !kept.contains(w.a) || !kept.contains(w.b) }
        let cy = Component(kind: .output, name: "cy", x: 480, y: 152)
        haSheet.components.append(cy)
        let and = haSheet.components.first { $0.kind == .and2 }!
        haSheet.wires.append(Wire(a: PortRef(comp: and.id, port: 2), b: PortRef(comp: cy.id, port: 0)))
        stale.sheets[si] = haSheet
        let staleErr = errors(stale)
        check(staleErr.count == 1 && staleErr[0].hasPrefix("Port 'c' is not in HA.bdf"), "a port the child no longer has gives one error (\(staleErr))")
        check(Flattener.flatten(stale).1.filter { $0.level == .error }.count == 1, "the flattener reports the same port mismatch once")

        var open = haFA()
        let fi = open.sheetIndex(named: "FA")!
        let h2 = open.sheets[fi].components.first { $0.kind == .block && $0.name == "inst1" }!
        open.sheets[fi].labels.removeValue(forKey: PortRef(comp: h2.id, port: h2.portIndex(named: "b")!).key)
        let (oc, om, _) = Compiler.compile(open)
        let warns = om.filter { $0.level == .warning && $0.text.contains("not connected") }
        check(oc != nil && warns.count == 1 && warns[0].sheet == "FA" && warns[0].component == h2.id,
              "an unconnected HA input compiles with one warning that points at the block (\(warns.map(\.text)))")
        if let oc {
            // The second HA computes s1 xor 1 and s1 and 1: s = x xor y xor 1, cout = x y + (x xor y).
            let ins = oc.inputs.map(\.name), outs = oc.outputs.map(\.name)
            let ok = (0..<8).allSatisfy { r in
                var v: [String: Int] = [:]
                for (k, n) in ins.enumerated() { v[n] = (r >> (2 - k)) & 1 }
                let x = v["x"]!, y = v["y"]!
                let out = oc.evaluate(ins.map { v[$0] == 1 }).outputs
                let want = ["s": x ^ y ^ 1, "cout": x & y | (x ^ y)]
                return outs.enumerated().allSatisfy { k, n in (out[k] ? 1 : 0) == want[n] }
            }
            check(ok, "the unconnected HA input acts as 1 (VCC)")
            check(oc.stats.gates == 5 && oc.generated.count == 1, "the default driver is generated, not counted as a gate")
        }

        var mac = TestDesigns.Builder("macro7447_unconnected")
        let a = mac.input("a", y: 64)
        let m = mac.macro("7447", x: 240, y: 40)
        mac.wire(mac.out(a), mac.port(m, "A"))
        mac.label(mac.port(m, "OA"), "seg")
        mac.output("seg", x: 520, y: 64)
        let macErr = errors(DesignProject(single: mac.p))
        check(macErr.count == 6 && macErr.allSatisfy { $0.contains("VCC") }, "each unconnected 7447 input is an error that says to tie it to VCC (\(macErr.count))")
    }

    // MARK: - Compile flow, report and bundle (plan 3.4-3.6)

    static func flow(_ check: Check) {
        print("Hierarchical compile flow and export")
        let d = TestDesigns.addSub4Design()
        let state = CompileFlow.run(d)
        check(!state.failed && state.flat?.identity == false && state.project.isFlatNetlist, "AddSub4 compiles through the full flow (\(state.messages.filter { $0.level == .error }.map(\.text).prefix(2)))")
        let texts = state.messages.map(\.text)
        check(["AddSub4", "FA", "HA"].allSatisfy { e in texts.contains("Found 1 design units, including 1 entities, in source file \(e).bdf") },
              "Analysis & Elaboration reads AddSub4.bdf, FA.bdf and HA.bdf")
        check(texts.contains("Elaborating entity \"AddSub4\" for the top level hierarchy")
              && texts.contains("Elaborating entity \"FA\" for hierarchy \"FA:inst1\"")
              && texts.contains("Elaborating entity \"HA\" for hierarchy \"FA:inst1|HA:inst\""),
              "each entity is elaborated once, with its first hierarchy path")
        let report = ReportText.render(CompileFlow.report(state))
        let rows = report.split(separator: "\n").filter { $0.contains("|AddSub4") && $0.contains("work") }
        check(rows.count == 1 + 4 + 8, "Resource Utilization by Entity has a row for each of the 13 instances (got \(rows.count))")
        check(report.contains("|AddSub4|FA:inst1|HA:inst1") && report.contains("   |FA:inst1|") && report.contains("      |HA:inst|"),
              "entity rows show the indented node and the full hierarchy name")
        check(report.contains("HA.bdf") && report.contains("FA.bdf"), "Source Files Read lists every .bdf")
        if let s = state.synthesis {
            check(s.schematicGates == 24 && s.outputs.allSatisfy { $0.exact }, "synthesis counts the 24 drawn gates and minimizes the 9-input outputs exactly")
        }

        let bundle = try? QuartusExport.makeBundle(d, date: Date(timeIntervalSince1970: 0))
        let names = bundle?.files.map(\.name) ?? []
        check(names == ["AddSub4.qpf", "AddSub4.qsf", "AddSub4.bdf", "FA.bdf", "HA.bdf", "AddSub4.bsf", "FA.bsf", "HA.bsf",
                        "Waveform.vwf", "AddSub4_pins.qsf", "AddSub4_backup.v", "README_LAB.txt"], "the AddSub4 bundle has every .bdf and .bsf (\(names))")
        if let b = bundle {
            func file(_ n: String) -> String { b.files.first { $0.name == n }?.contents ?? "" }
            check(file("AddSub4.qsf").contains("BDF_FILE FA.bdf\nset_global_assignment -name BDF_FILE HA.bdf"), "the .qsf lists FA.bdf and HA.bdf")
            check(file("HA.bsf").hasSuffix("\r\n") && file("HA.bsf").contains("(symbol\r\n"), "the .bsf files use CRLF like Quartus")
            let v = file("AddSub4_backup.v")
            check(v.contains("module AddSub4 (") && v.contains("//     FA:inst1") && v.contains("//       HA:inst1") && !v.contains("FA inst"),
                  "the Verilog backup is one flattened module with the hierarchy in a comment")
            let readme = file("README_LAB.txt")
            check(readme.contains("Route B") && readme.contains("Set as Top-Level Entity") && readme.contains("HA.bdf"), "the README gives both routes")
            let fa = file("FA.bdf")
            check(fa.contains("(text \"HA\" (rect") && fa.contains("(text \"inst1\" (rect"), "FA.bdf places its HA blocks")
        }
        var unused = d
        _ = try? unused.addSheet(named: "Spare")
        let ub = try? QuartusExport.makeBundle(unused)
        check(ub?.notes.contains { $0.contains("Spare.bdf") } == true && ub?.files.contains { $0.name == "Spare.bdf" } == false,
              "an unused sheet is not exported, and the notes say so")
        let vo = NetlistWriter.bundleFile(d)
        check(vo?.name == "simulation/quartzite/AddSub4_quartzite.vo", "the EDA netlist of a design is named after the top")
    }

    // MARK: - Reference designs (plan 5.x)

    /// Compiles `d` through the full flow and checks 0 errors, 0 warnings, and that the
    /// simulation of the flat netlist matches every output's expected minterms.
    @discardableResult
    static func reference(_ name: String, _ d: DesignProject, _ check: Check) -> (FlowState, SimulationResult?) {
        let state = CompileFlow.run(d)
        check(!state.failed && state.errors == 0 && state.warnings == 0,
              "\(name): compiles with 0 errors and 0 warnings (\(state.errors), \(state.warnings): \(state.messages.filter { $0.level != .info }.map(\.text).prefix(3)))")
        guard let c = state.circuit, let sim = try? SimulationResult.run(c, project: state.project) else { return (state, nil) }
        let bad = sim.outputNames.indices.filter { sim.matches(output: $0) != true }.map { sim.outputNames[$0] }
        check(bad.isEmpty && !sim.outputNames.isEmpty, "\(name): all \(sim.rows.count) rows match the expected table (wrong: \(bad.prefix(4)))")
        check((try? QuartusExport.makeBundle(d)) != nil, "\(name): exports without routing warnings")
        return (state, sim)
    }

    /// Lit segments for 0-9 as the 7447 draws them, written out independently of Macros.swift.
    static let glyphs = ["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "cdefg", "abc", "abcdefg", "abcfg"]

    /// The digit an active-low seven-segment display shows (nil when it is not a digit).
    static func decode(_ off: [Bool]) -> Int? {
        let lit = String(zip("abcdefg", off).filter { !$0.1 }.map(\.0))
        return glyphs.firstIndex(of: lit)
    }

    static func references(_ check: Check) {
        print("Reference designs")
        let names = TestDesigns.all.map(\.0)
        check(["macro7447_probe", "bcd_display"].allSatisfy(names.contains), "the 7447 designs are in TestDesigns.all")

        let probe = TestDesigns.macro7447Probe()
        if let sim = reference("macro7447_probe", probe, check).1 {
            check(sim.inputNames == ["BIN", "RBIN", "LTN", "D", "C", "B", "A"] && sim.outputNames.count == 8, "the probe reads BIN first and drives 8 LEDs")
            check(probe.top?.inputPins.map { $0.location } == (0..<7).reversed().map { BoardPin.named("SW\($0)")?.pin },
                  "the probe's inputs are on SW6..SW0")
        }

        let bcd = TestDesigns.bcdDisplay()
        if let sim = reference("bcd_display", bcd, check).1 {
            check((0..<10).allSatisfy { decode(sim.rows[$0].outputs) == $0 }, "bcd_display shows 0-9 on HEX0")
            check(bcd.top?.outputPins.map { $0.location } == (0..<7).map { BoardPin.named("HEX0[\($0)]")?.pin }, "bcd_display drives HEX0[0..6]")
        }
        if let b = try? QuartusExport.makeBundle(bcd) {
            let names = b.files.map(\.name)
            check(names.contains("BcdDisplay.bdf") && !names.contains { $0.hasSuffix(".bsf") }, "a one-sheet design with a macro exports one .bdf and no .bsf")
            let text = b.files.first { $0.name == "BcdDisplay.bdf" }?.contents ?? ""
            if let t = fixture("lab2/7447_instance.txt", check) {
                var i = TestDesigns.Builder("one")
                let m = i.macro("7447", x: 400, y: 72)
                i.p.components[0].name = "bcd7seg"
                _ = m
                check(String(afterComments(bdf(i.p))).contains(t.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)),
                      "a 7447 named bcd7seg at (400, 72) is written as in a .bdf Quartus compiled")
            }
            check(text.contains("(text \"7447\" (rect 44 0 77 16)") && text.contains("(text \"VCC\""), "BcdDisplay.bdf has the 7447 and its VCC")
        }
    }

    // MARK: - Sheet operations (plan 1.4)

    static func sheetOps(_ check: Check) {
        print("Sheet operations")
        let d = haFA()
        check(d.structuralErrors.isEmpty && d.staleInstances().isEmpty, "HA + FA design is well formed and up to date")
        check(d.usedSheets() == ["FA", "HA"] && d.instanceTree().children.map(\.label) == ["HA:inst", "HA:inst1"],
              "FA uses HA twice (got \(d.usedSheets()), \(d.instanceTree().children.map(\.label)))")
        check(d.instanceTree().totalGates == 5, "FA has 5 gates in total (got \(d.instanceTree().totalGates))")

        var r = d
        let haID = r.sheet(named: "HA")!.id!
        check((try? r.renameSheet(id: haID, to: "fa")) == nil, "renaming HA to fa (another sheet's name, any case) is refused")
        check((try? r.renameSheet(id: haID, to: "and")) == nil, "renaming HA to a reserved word is refused")
        check((try? r.renameSheet(id: haID, to: "2HA")) == nil, "renaming HA to an invalid name is refused")
        check((try? r.renameSheet(id: haID, to: "HALF")) != nil, "HA can be renamed to HALF")
        let fa = r.sheet(named: "FA")
        check(r.sheet(named: "HA") == nil && r.sheet(named: "HALF")?.symbol?.name == "HALF"
              && fa?.components.filter { $0.kind == .block }.allSatisfy { $0.symbol?.name == "HALF" && $0.symbol?.nameText.text == "HALF" } == true
              && r.staleInstances().isEmpty && r.usedSheets() == ["FA", "HALF"] && r.structuralErrors.isEmpty,
              "after renaming HA to HALF, FA's blocks are HALF blocks and nothing is stale")
        check(wireEnds(r, "FA") == wireEnds(d, "FA"), "renaming keeps FA's wires")

        var top = d
        let faID = top.sheet(named: "FA")!.id!
        check((try? top.renameSheet(id: faID, to: "Adder")) != nil && top.topLevelEntity == "Adder" && top.name == "Adder",
              "renaming the top sheet renames the top-level entity and the design")
        check((try? top.removeSheet(id: haID)) == nil, "a sheet used as a block can't be removed")
        check((try? top.removeSheet(id: faID)) == nil, "the top-level sheet can't be removed")
        let spare = try? top.addSheet(named: "Spare")
        check(spare != nil && top.usedSheets() == ["Adder", "HA"], "an added sheet that is not instantiated is not used")
        check((try? top.removeSheet(id: spare!)) != nil && top.sheets.count == 2, "an unused sheet can be removed")
        check((try? top.addSheet(named: "ha")) == nil, "adding a sheet whose name clashes in case is refused")

        var rec = d
        check(rec.wouldRecurse(placing: "FA", into: "HA") && rec.wouldRecurse(placing: "HA", into: "HA")
              && !rec.wouldRecurse(placing: "HA", into: "FA"), "wouldRecurse finds direct and indirect recursion")
        check((try? rec.placeBlock("FA", inSheet: haID, x: 600, y: 40)) == nil && rec.sheet(named: "HA")?.components.count == 6,
              "inserting FA into HA is refused")
        let noSym = try? rec.addSheet(named: "Bare")
        check((try? rec.placeBlock("Bare", inSheet: faID, x: 600, y: 400)) == nil, "a sheet without a symbol can't be placed")
        rec.sheets.removeAll { $0.id == noSym }

        var grow = d
        let hi = grow.sheetIndex(named: "HA")!
        grow.sheets[hi].components.append(Component(kind: .input, name: "cin2", x: 32, y: 160))
        let rep = grow.createSymbol(forSheet: haID)
        let ha = grow.sheet(named: "HA")!.symbol!
        check(ha.ports.count == 5 && ha.inputs.map(\.name) == ["a", "b", "cin2"], "adding pin cin2 to HA adds a port to its symbol")
        check(rep.updatedInstances == 2 && rep.addedPorts == ["cin2"] && rep.removedPorts.isEmpty && rep.droppedWires == 0
              && rep.droppedLabels.isEmpty, "createSymbol updates both instances and reports the new port (\(rep.summary))")
        check(wireEnds(grow, "FA") == wireEnds(d, "FA") && grow.sheet(named: "FA")?.labels.count == d.sheet(named: "FA")?.labels.count,
              "after adding cin2, FA keeps every wire and node name on the same ports")
        check(grow.staleInstances().isEmpty, "no instance is stale after createSymbol")

        var shrink = d
        let si = shrink.sheetIndex(named: "HA")!
        let cPin = shrink.sheets[si].components.first { $0.name == "c" }!.id
        shrink.sheets[si].components.removeAll { $0.id == cPin }
        shrink.sheets[si].wires.removeAll { $0.a.comp == cPin || $0.b.comp == cPin }
        let rep2 = shrink.createSymbol(forSheet: haID)
        let before = wireEnds(d, "FA"), after = wireEnds(shrink, "FA")
        check(rep2.removedPorts == ["c"] && rep2.droppedWires == 1 && rep2.droppedLabels == ["c1"],
              "removing pin c reports the removed port, one wire and the node name c1 (\(rep2.summary))")
        check(after.count == before.count - 1 && Set(before).subtracting(after) == ["inst1.c-inst2.IN2"],
              "removing pin c drops exactly its wire (dropped \(Set(before).subtracting(after).sorted()))")
    }
}

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

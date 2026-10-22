import Foundation

/// Self-tests for Quartus project import (`QuartusImport`), called from `SelfTest.run`.
///
/// Every design of the export suite and `ci/designs` is exported, imported and compared (truth
/// table on every row, pin names and locations, sheets and blocks), then the imported design
/// is exported and imported again. The Quartus-saved fixtures in `ci/fixtures/quartus18/hier`
/// are imported and their hierarchy and nets checked.
///
/// With `QUARTZITE_PRIVATE_LABS` set to a folder holding course projects, the projects there
/// are imported too (read at runtime only; nothing from that folder is part of the repository).
enum ImportSelfTest {
    typealias Check = (Bool, String) -> Void

    static func run(_ check: Check) {
        print("Quartus import")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quartzite-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        tclAndPaths(check)
        roundTrips(check, tmp: tmp)
        fixtures(check)
        edgeCases(check, tmp: tmp)
        #if canImport(SwiftUI)
        MainActor.assumeIsolated { openInApp(check, tmp: tmp) }
        #endif
        privateLabs(check, tmp: tmp)
    }

    // MARK: - Helpers

    /// Truth table with named columns (inputs in simulation order).
    struct Table: Equatable { var inputs: [String]; var outputs: [String]; var rows: [[Bool]] }

    static func table(_ d: DesignProject) -> Table? {
        HierarchySelfTest.table(d).map { Table(inputs: $0.inputs, outputs: $0.outputs, rows: $0.rows) }
    }

    static func locations(_ d: DesignProject) -> [String: String] {
        guard let top = d.top else { return [:] }
        var out: [String: String] = [:]
        for c in top.components where c.kind.isPin { out[c.name] = c.location.map { CycloneV.normalize($0) } ?? "" }
        return out
    }

    /// Sheets used under the top and, per sheet, its blocks and macros ("inst2:FA").
    static func structure(_ d: DesignProject) -> [String] {
        d.usedSheets().map { e -> String in
            let s = d.sheet(named: e)!
            let parts = s.components.filter { $0.kind.isHierarchical }.map { "\($0.name):\($0.symbolName)" }.sorted()
            return "\(s.entityName)[\(parts.joined(separator: ","))]"
        }.sorted()
    }

    /// Writes the Quartus bundle of `d` into `dir` and returns the .qpf.
    static func export(_ d: DesignProject, to dir: URL) throws -> URL {
        let bundle = try QuartusExport.makeBundle(d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in bundle.files { try f.contents.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
        return dir.appendingPathComponent("\(d.projectName).qpf")
    }

    static func importFile(_ url: URL) -> (QuartusImport.Result?, String) {
        do { return (try QuartusImport.importProject(at: url), "") } catch { return (nil, error.localizedDescription) }
    }

    // MARK: - Settings parsing

    static func tclAndPaths(_ check: Check) {
        check(QuartusImport.tclWords("set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to w")
              == ["set_instance_assignment", "-name", "IO_STANDARD", "3.3-V LVTTL", "-to", "w"], "qsf: quoted words")
        let s = QuartusImport.settings("""
        # comment
        set_global_assignment -name DEVICE 5CSXFC6D6F31C6
        set_global_assignment -name TOP_LEVEL_ENTITY Top
        set_global_assignment -name BDF_FILE //tsclient/Drives/Lab2/hiertest/Top.bdf
        set_global_assignment -name BDF_FILE "C:\\work\\HA.bdf"
        set_global_assignment -name VERILOG_FILE extra.v
        set_location_assignment PIN_AC30 -to w
        set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to w
        """)
        check(s.device == "5CSXFC6D6F31C6" && s.top == "Top", "qsf: device and top-level entity")
        check(s.bdfFiles.map(QuartusImport.fileName) == ["Top.bdf", "HA.bdf"], "qsf: UNC and Windows BDF_FILE paths resolve by file name")
        check(s.locations.count == 1 && s.locations[0] == ("PIN_AC30", "w") && s.ioStandards.count == 1 && s.ioStandards[0].standard == "3.3-V LVTTL",
              "qsf: location and I/O standard lines")
        check(s.otherFiles.count == 1, "qsf: other design files are noticed")
    }

    // MARK: - Round trips

    static func roundTrips(_ check: Check, tmp: URL) {
        var designs = TestDesigns.all
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("ci/designs", isDirectory: true)
        let saved = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "qzproj" }.sorted { $0.path < $1.path }
        if saved.isEmpty {
            if HierarchySelfTest.requireFixtures { check(false, "ci/designs has saved projects (QUARTZITE_REQUIRE_FIXTURES=1)") }
            else { print("  SKIP ci/designs not found in \(FileManager.default.currentDirectoryPath)") }
        }
        for f in saved {
            guard let data = try? Data(contentsOf: f), let d = try? DesignProject.load(data) else { check(false, "\(f.lastPathComponent) loads"); continue }
            designs.append(("designs_" + f.deletingPathExtension().lastPathComponent, d))
        }
        for (name, d) in designs {
            roundTrip(name, d, check, tmp: tmp)
        }
    }

    /// Export, import, compare; then export the import and import it again.
    static func roundTrip(_ name: String, _ d: DesignProject, _ check: Check, tmp: URL) {
        guard let want = table(d) else { check(false, "\(name): original simulates"); return }
        let qpf: URL
        do { qpf = try export(d, to: tmp.appendingPathComponent(name).appendingPathComponent("a")) } catch {
            check(false, "\(name): exports (\(error.localizedDescription))"); return
        }
        let (r, err) = importFile(qpf)
        guard let imported = r?.design else { check(false, "\(name): imports (\(err))"); return }
        let got = table(imported)
        check(got == want, "\(name): imported truth table is identical (\(want.rows.count) rows)")
        check(locations(imported) == locations(d), "\(name): pin names and locations")
        check(structure(imported) == structure(d) && imported.topLevelEntity.caseInsensitiveCompare(d.topLevelEntity) == .orderedSame,
              "\(name): sheets and blocks")
        check(imported.staleInstances().isEmpty && Compiler.compile(imported).0 != nil, "\(name): imported design compiles with current symbols")
        // Export the imported design and read it back.
        let qpf2: URL
        do { qpf2 = try export(imported, to: tmp.appendingPathComponent(name).appendingPathComponent("b")) } catch {
            check(false, "\(name): imported design exports (\(error.localizedDescription))"); return
        }
        let (r2, err2) = importFile(qpf2)
        check(r2.flatMap { table($0.design) } == want, "\(name): re-exported import simulates identically\(err2.isEmpty ? "" : " (\(err2))")")
    }

    // MARK: - Quartus-saved fixtures

    static func fixtures(_ check: Check) {
        let dir = HierarchySelfTest.fixturesDir.appendingPathComponent("hier", isDirectory: true)
        guard HierarchySelfTest.fixture("hier/hiertop.bdf", check) != nil, HierarchySelfTest.fixture("hier/hiertest.qpf", check) != nil else { return }
        let (r, err) = importFile(dir.appendingPathComponent("hiertop.bdf"))
        guard let d = r?.design else { check(false, "hiertop.bdf imports (\(err))"); return }
        check(d.topLevelEntity == "hiertop" && d.sheets.count == 3, "hiertop.bdf: top hiertop with HA and BIGBLK found next to it")
        let tree = d.instanceTree()
        check(tree.children.map(\.label) == ["HA:inst", "BIGBLK:inst1"] && tree.children.allSatisfy { !$0.missing },
              "hiertop.bdf: hierarchy HA:inst and BIGBLK:inst1")
        check(d.staleInstances().isEmpty, "hiertop.bdf: block instances match HA.bsf and BIGBLK.bsf")
        if let top = d.top, let ha = top.components.first(where: { $0.name == "inst" }), let big = top.components.first(where: { $0.name == "inst1" }) {
            check(ha.x == 240 && ha.y == 272 && big.x == 240 && big.y == 720, "hiertop.bdf: blocks keep their Quartus coordinates")
        } else { check(false, "hiertop.bdf: both blocks present") }
        check(d.sheet(named: "BIGBLK")?.symbol?.ports.map(\.name) == ["a_long_input", "b", "result_out", "z"], "BIGBLK symbol from BIGBLK.bsf")
        if let ha = d.sheet(named: "HA") {
            let conn = Connectivity(ha)
            func net(_ comp: String, _ port: String) -> Int? {
                guard let c = ha.components.first(where: { $0.name == comp }) else { return nil }
                return conn.netOf[PortRef(comp: c.id, port: c.kind.isPin ? 0 : (c.portIndex(named: port) ?? -1))]
            }
            check(net("x", "") != nil && net("x", "") == net("inst", "IN1"), "HA.bdf: x drives OR2 IN1 (two joined connectors)")
            check(net("y", "") != nil && net("y", "") == net("inst", "IN2"), "HA.bdf: y reaches OR2 IN2 through a bend")
            check(net("x", "") == net("inst1", "IN1") && net("y", "") == net("inst1", "IN2"), "HA.bdf: junctions carry x and y on to AND2")
            check(net("s", "") == net("inst", "OUT") && net("cout", "") == net("inst1", "OUT") && net("x", "") != net("y", "") && net("s", "") != net("cout", ""),
                  "HA.bdf: s = OR2, cout = AND2, separate nets stay apart")
        } else { check(false, "HA sheet imported") }
        let (r2, err2) = importFile(dir.appendingPathComponent("hiertest.qpf"))
        if let d2 = r2?.design {
            check(d2.name == "hiertest" && d2.topLevelEntity == "HA" && d2.device == "5CSXFC6D6F31C6" && d2.sheets.map(\.entityName) == ["HA", "BIGBLK"],
                  "hiertest.qpf: project name, top HA, device and both BDF_FILEs")
        } else { check(false, "hiertest.qpf imports (\(err2))") }
    }

    // MARK: - Edge cases

    static func edgeCases(_ check: Check, tmp: URL) {
        let base = TestDesigns.exampleSOP()
        let d = DesignProject(single: base)
        let dir = tmp.appendingPathComponent("edge", isDirectory: true)
        guard let qpf = try? export(d, to: dir) else { check(false, "edge: export"); return }
        let name = d.projectName, entity = d.topLevelEntity
        let qsfURL = dir.appendingPathComponent("\(name).qsf"), bdfURL = dir.appendingPathComponent("\(entity).bdf")
        guard let qsf = try? String(contentsOf: qsfURL, encoding: .utf8), let bdf = try? String(contentsOf: bdfURL, encoding: .utf8) else {
            check(false, "edge: read export"); return
        }
        let want = table(d)
        func variant(_ tag: String, qsf q: String? = nil, bdf b: String? = nil) -> (QuartusImport.Result?, String) {
            let v = tmp.appendingPathComponent("edge_\(tag)", isDirectory: true)
            try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
            try? (q ?? qsf).write(to: v.appendingPathComponent("\(name).qsf"), atomically: true, encoding: .utf8)
            try? (b ?? bdf).write(to: v.appendingPathComponent("\(entity).bdf"), atomically: true, encoding: .utf8)
            try? String(contentsOf: qpf, encoding: .utf8).write(to: v.appendingPathComponent("\(name).qpf"), atomically: true, encoding: .utf8)
            return importFile(v.appendingPathComponent("\(name).qpf"))
        }
        // A BDF_FILE written with the lab PC's network path.
        let unc = qsf.replacingOccurrences(of: "BDF_FILE \(entity).bdf", with: "BDF_FILE //tsclient/Drives/Lab/\(entity)/\(entity).bdf")
        check(variant("unc", qsf: unc).0.flatMap { table($0.design) } == want, "edge: BDF_FILE with a //tsclient path resolves next to the .qsf")
        // A megafunction is refused, naming the symbol and the sheet.
        let lpm = bdf.replacingOccurrences(of: "(text \"AND2\"", with: "(text \"lpm_and\"")
        let (r1, e1) = variant("lpm", bdf: lpm)
        check(r1 == nil && e1.contains("lpm_and") && e1.contains("\(entity).bdf"), "edge: unsupported lpm_and is an error naming the symbol and sheet")
        let dff = bdf.replacingOccurrences(of: "(text \"AND2\"", with: "(text \"DFF\"")
        let (r2, e2) = variant("dff", bdf: dff)
        check(r2 == nil && e2.contains("DFF") && e2.contains("sequential"), "edge: a DFF is refused as sequential")
        // A missing .bdf is reported.
        let (r3, e3) = variant("missing", qsf: qsf + "set_global_assignment -name BDF_FILE Nowhere.bdf\n")
        check(r3 == nil && e3.contains("Nowhere.bdf"), "edge: a missing BDF_FILE is reported")
        // Negative coordinates are moved onto the sheet without changing the circuit.
        let moved = shifted(bdf, dx: -400, dy: -300)
        let (r4, e4) = variant("negative", bdf: moved)
        check(r4.flatMap { table($0.design) } == want && (r4?.design.top?.components.allSatisfy { $0.x >= 0 && $0.y >= 0 } ?? false),
              "edge: negative coordinates are shifted onto the sheet\(e4.isEmpty ? "" : " (\(e4))")")
        // A single .bdf opens with the device and pins of the project next to it.
        let (r5, e5) = importFile(bdfURL)
        check(r5.flatMap { table($0.design) } == want && r5.map { locations($0.design) } == locations(d), "edge: a lone .bdf takes the locations of its project\(e5.isEmpty ? "" : " (\(e5))")")
    }

    /// The .bdf text with every absolute coordinate (rects of top-level items, connector and
    /// junction points) moved by (dx, dy).
    static func shifted(_ bdf: String, dx: Int, dy: Int) -> String {
        var out: [String] = []
        var depth = 0
        var inConnector = false
        for line in bdf.components(separatedBy: "\n") {
            var l = line
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 1 && trimmed.hasPrefix("(rect ") || depth == 0 && trimmed.hasPrefix("(text ") || depth == 0 && trimmed.hasPrefix("(junction") || inConnector && depth == 1 && trimmed.hasPrefix("(pt ") {
                l = move(line, dx: dx, dy: dy)
            }
            if depth == 0 { inConnector = trimmed.hasPrefix("(connector") }
            var inString = false
            for ch in line {
                if ch == "\"" { inString.toggle() }
                if inString { continue }
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    /// Moves the first (rect a b c d) or every (pt x y) on a line.
    static func move(_ line: String, dx: Int, dy: Int) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\((rect|pt) (-?\\d+) (-?\\d+)( (-?\\d+) (-?\\d+))?\\)") else { return line }
        var s = line
        for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            func v(_ i: Int) -> Int? { Range(m.range(at: i), in: line).flatMap { Int(line[$0]) } }
            guard let r = Range(m.range, in: s), let kind = Range(m.range(at: 1), in: line).map({ String(line[$0]) }),
                  let a = v(2), let b = v(3) else { continue }
            var t = "(\(kind) \(a + dx) \(b + dy)"
            if let c = v(5), let e = v(6) { t += " \(c + dx) \(e + dy)" }
            s.replaceSubrange(r, with: t + ")")
            if kind == "rect" { break }
        }
        return s
    }

    #if canImport(SwiftUI)
    /// File > Open on a .qpf: the design opens unsaved and says where it came from.
    @MainActor
    static func openInApp(_ check: Check, tmp: URL) {
        let d = DesignProject(single: TestDesigns.exampleSOP())
        guard let qpf = try? export(d, to: tmp.appendingPathComponent("app", isDirectory: true)) else { check(false, "app: export"); return }
        let store = Store(persist: false)
        store.open(qpf)
        check(store.fileURL == nil && store.dirty && store.importedFrom == qpf.lastPathComponent, "app: an opened .qpf is imported unsaved (\(store.importedFrom ?? "-"))")
        check(table(store.design) == table(d), "app: the imported design simulates like the original")
        check(store.systemMessages.contains { $0.text.hasPrefix("Imported from \(qpf.lastPathComponent)") }, "app: Messages say where the design came from")
    }
    #endif

    // MARK: - Private course projects (QUARTZITE_PRIVATE_LABS)

    static func privateLabs(_ check: Check, tmp: URL) {
        guard let root = ProcessInfo.processInfo.environment["QUARTZITE_PRIVATE_LABS"], !root.isEmpty else { return }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        print("Quartus import: private projects (QUARTZITE_PRIVATE_LABS)")

        // Lab 2: made in and compiled by Quartus 18.0. The expected function comes from the
        // private Quartzite reference project (its expected minterms), never from this file.
        let (r, err) = importFile(base.appendingPathComponent("Lab2/Lab2.qpf"))
        if let d = r?.design, let t = table(d) {
            check(t.rows.count == 16, "Lab2.qpf: 16 rows")
            if let data = try? Data(contentsOf: base.appendingPathComponent("Lab2/quartzite/Lab2_7447.qzproj")), let q = try? DesignProject.load(data),
               let ref = q.top {
                var expected: [String: Set<Int>] = [:]
                for o in ref.outputPins { if let text = ref.expected[o.id.uuidString], let m = Minterms.parse(text) { expected[o.name] = m } }
                let ok = !expected.isEmpty && expected.count == t.outputs.count && t.outputs.enumerated().allSatisfy { k, o in
                    guard let m = expected[o] else { return false }
                    return t.rows.indices.allSatisfy { t.rows[$0][k] == m.contains($0) }
                }
                check(ok, "Lab2.qpf: every output matches the reference's expected minterms on all 16 rows (including the 7447 segments)")
                check(table(q) == t, "Lab2.qpf matches Lab2_7447.qzproj: same truth table and input order")
                check(locations(q) == locations(d), "Lab2.qpf matches Lab2_7447.qzproj: same pin locations")
            } else { check(false, "Lab2/quartzite/Lab2_7447.qzproj loads") }
        } else { check(false, "Lab2.qpf imports and simulates (\(err))") }

        // Lab 3: a Quartzite export, imported back.
        if let data = try? Data(contentsOf: base.appendingPathComponent("Lab3/quartzite/Lab3.qzproj")), let d = try? DesignProject.load(data) {
            roundTrip("Lab3", d, check, tmp: tmp.appendingPathComponent("private"))
            check(table(d)?.rows.count == 512, "Lab3: 512 rows")
        } else { check(false, "Lab3/quartzite/Lab3.qzproj loads") }
    }
}

import Foundation

/// Opens a Quartus project (.qpf, .qsf) or a single block diagram (.bdf) as a Quartzite design.
///
/// Connectivity follows `ci/bdf_check.py`'s `sheet_netlist` exactly: connector end points,
/// junctions and ports that share a point join; a connector end point or junction on the
/// interior of another connector joins it (a port alone on a wire's interior does not); named
/// connectors and pins join every other connector or pin with the same name (case-insensitive).
/// Each sheet is rebuilt with Quartzite wires inside every connected group of ports and net
/// labels for the names, then its connectivity is compared with the Quartus nets; any port
/// Quartus joins that Quartzite does not is wired up, and anything Quartzite would join that
/// Quartus does not is an error.
enum QuartusImport {
    struct Failure: Error, LocalizedError {
        var problems: [String]
        var errorDescription: String? {
            problems.count == 1 ? problems[0] : "The project can't be imported:\n" + problems.map { "• \($0)" }.joined(separator: "\n")
        }
    }

    struct Result {
        var design: DesignProject
        /// Things the import changed or left out (shown as messages, never silent).
        var notes: [String]
    }

    /// File extensions File > Open accepts besides .qzproj.
    static let extensions: Set<String> = ["qpf", "qsf", "bdf"]

    static func canImport(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    // MARK: - Settings (.qsf)

    struct Settings {
        var device: String?
        var top: String?
        /// BDF_FILE values as written (may be absolute or UNC paths from the lab PC).
        var bdfFiles: [String] = []
        /// Other design files (Verilog, VHDL, ...), by assignment name and value.
        var otherFiles: [(kind: String, file: String)] = []
        /// set_location_assignment PIN_x -to name, in file order.
        var locations: [(pin: String, name: String)] = []
        var ioStandards: [(standard: String, name: String)] = []
        var waveform: String?
    }

    /// Splits one Tcl command into words (double quotes and braces group).
    static func tclWords(_ line: String) -> [String] {
        var words: [String] = []
        var cur = "", inQuote = false, depth = 0, started = false
        for ch in line {
            if inQuote {
                if ch == "\"" { inQuote = false } else { cur.append(ch) }
            } else if depth > 0 {
                if ch == "}" { depth -= 1; if depth == 0 { continue } }
                if ch == "{" { depth += 1 }
                cur.append(ch)
            } else if ch == "\"" { inQuote = true; started = true }
            else if ch == "{" { depth = 1; started = true }
            else if ch == " " || ch == "\t" {
                if started || !cur.isEmpty { words.append(cur); cur = ""; started = false }
            } else { cur.append(ch); started = true }
        }
        if started || !cur.isEmpty { words.append(cur) }
        return words
    }

    static func settings(_ text: String) -> Settings {
        var s = Settings()
        let valued: Set<String> = ["-name", "-to", "-from", "-section_id", "-entity", "-tag", "-comment", "-library", "-hdl_version"]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let w = tclWords(line)
            guard let cmd = w.first else { continue }
            var opts: [String: String] = [:], positional: [String] = []
            var i = 1
            while i < w.count {
                if valued.contains(w[i]), i + 1 < w.count { opts[w[i]] = w[i + 1]; i += 2; continue }
                if w[i].hasPrefix("-") && w[i].count > 1 && Int(w[i]) == nil { i += 1; continue }
                positional.append(w[i]); i += 1
            }
            let value = positional.first
            switch cmd {
            case "set_global_assignment":
                guard let name = opts["-name"]?.uppercased(), let value else { continue }
                switch name {
                case "DEVICE": s.device = value
                case "TOP_LEVEL_ENTITY": s.top = value
                case "BDF_FILE": s.bdfFiles.append(value)
                case "VECTOR_WAVEFORM_FILE": s.waveform = value
                case "VERILOG_FILE", "SYSTEMVERILOG_FILE", "VHDL_FILE", "AHDL_FILE", "QSYS_FILE", "QIP_FILE", "TDF_FILE", "GDF_FILE", "EDIF_FILE":
                    s.otherFiles.append((name, value))
                default: break
                }
            case "set_location_assignment":
                guard let value, let to = opts["-to"] else { continue }
                s.locations.append((value, to))
            case "set_instance_assignment":
                guard opts["-name"]?.uppercased() == "IO_STANDARD", let value, let to = opts["-to"] else { continue }
                s.ioStandards.append((value, to))
            default: break
            }
        }
        return s
    }

    /// The last component of a path written on Windows or macOS (`//tsclient/Drives/Lab2/x.bdf`, `C:\a\x.bdf`).
    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    /// A file in `dir` named `name`, ignoring case (Quartus projects come from Windows).
    static func find(_ name: String, in dir: URL) -> URL? {
        let exact = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { dir.appendingPathComponent($0) }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Input pin names in the waveform's signal order (the order Quartus' simulator lists them).
    static func waveformOrder(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "SIGNAL\\(\"([^\"]+)\"\\)") else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Block diagrams (.bdf)

    struct Point: Hashable { var x: Int; var y: Int }

    struct BPin {
        var name: String
        var isInput: Bool
        var rect: [Int]
        var point: Point
        var defaultValue: String?
        var tag: Orientation?
    }

    struct BSymbol {
        var name: String
        var instance: String
        var rect: [Int]
        var ports: [(name: String, isOutput: Bool, point: Point)]
        var tag: Orientation?
        var expr: SExpr
    }

    struct BConnector { var a: Point; var b: Point; var name: String? }

    /// One .bdf, read but not yet interpreted.
    struct BDF {
        var entity: String
        var file: String
        var pins: [BPin] = []
        var symbols: [BSymbol] = []
        var connectors: [BConnector] = []
        var junctions: [Point] = []
        var notes: [TextNote] = []
        var ignoredGraphics = 0
    }

    static let orientationTags: Set<String> = ["rotate90", "rotate180", "rotate270", "flipx", "flipy"]

    /// Drops styling such as (line_width 1) and (color ...) that some Quartus versions add
    /// (as `bdf_check.strip_attrs` does).
    static func stripStyling(_ e: SExpr) -> SExpr {
        guard case .list(let items) = e else { return e }
        return .list(items.filter { !["line_width", "color"].contains($0.head ?? "") }.map(stripStyling))
    }

    static func ints(_ e: SExpr?) -> [Int] { e?.items.dropFirst().compactMap { $0.stringValue.flatMap { Int($0) } } ?? [] }
    static func point(_ e: SExpr?) -> Point? {
        let v = ints(e)
        return v.count == 2 ? Point(x: v[0], y: v[1]) : nil
    }
    static func tag(_ item: SExpr) -> Orientation? {
        for c in item.items where c.items.count == 1 {
            if let h = c.head, orientationTags.contains(h) { return Orientation(rawValue: h) }
        }
        return nil
    }

    static func parseBDF(_ text: String, entity: String, file: String) throws -> BDF {
        let tree: [SExpr]
        do { tree = try SExprParser.parse(text).map(stripStyling) } catch {
            throw Failure(problems: ["\(file): not a readable block diagram (\(error.localizedDescription))"])
        }
        var b = BDF(entity: entity, file: file)
        var problems: [String] = []
        for item in tree {
            switch item.head {
            case "header":
                if item.items.dropFirst().first?.stringValue != "graphic" {
                    problems.append("\(file): not a block diagram (header \(item.items.dropFirst().first?.stringValue ?? "?"))")
                }
            case "pin":
                let texts = item.children("text")
                let name = texts.count > 1 ? texts[1].items.dropFirst().first?.stringValue ?? "" : ""
                let r = ints(item.child("rect"))
                guard r.count == 4, let p = point(item.child("pt")) else { problems.append("\(file): pin \(name) has no rect or point"); continue }
                let isInput = item.child("input") != nil
                guard isInput || item.child("output") != nil else {
                    problems.append("\(file): pin \(name) is bidirectional; Quartzite supports input and output pins only")
                    continue
                }
                if name.contains("[") || name.contains("..") {
                    problems.append("\(file): pin \(name) is a bus; Quartzite supports single-bit pins only")
                    continue
                }
                var def: String? = nil
                if isInput, texts.count > 2, texts[2].items.dropFirst().first?.stringValue?.uppercased() == "GND" { def = "GND" }
                b.pins.append(BPin(name: name, isInput: isInput, rect: r, point: Point(x: r[0] + p.x, y: r[1] + p.y),
                                   defaultValue: def, tag: tag(item)))
            case "symbol":
                let texts = item.children("text")
                let name = texts.first?.items.dropFirst().first?.stringValue ?? "?"
                let inst = texts.count > 1 ? texts[1].items.dropFirst().first?.stringValue ?? "" : ""
                let r = ints(item.child("rect"))
                guard r.count == 4 else { problems.append("\(file): symbol \(name) (\(inst)) has no rect"); continue }
                var ports: [(String, Bool, Point)] = []
                for port in item.children("port") {
                    guard let p = point(port.child("pt")) else { continue }
                    let pn = port.child("text")?.items.dropFirst().first?.stringValue ?? ""
                    ports.append((pn, port.child("output") != nil, Point(x: r[0] + p.x, y: r[1] + p.y)))
                }
                b.symbols.append(BSymbol(name: name, instance: inst, rect: r, ports: ports.map { (name: $0.0, isOutput: $0.1, point: $0.2) },
                                         tag: tag(item), expr: item))
            case "connector":
                let pts = item.children("pt").compactMap(point)
                guard pts.count == 2 else { continue }
                if item.child("bus") != nil {
                    problems.append("\(file): a bus line from (\(pts[0].x), \(pts[0].y)) is not supported; Quartzite supports single-bit wires only")
                    continue
                }
                let name = item.child("text")?.items.dropFirst().first?.stringValue
                b.connectors.append(BConnector(a: pts[0], b: pts[1], name: name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
            case "junction":
                if let p = point(item.child("pt")) { b.junctions.append(p) }
            case "text":
                let r = ints(item.child("rect"))
                if let t = item.items.dropFirst().first?.stringValue, r.count == 4 { b.notes.append(TextNote(text: t, x: r[0], y: r[1])) }
            case "line", "arc", "rectangle", "circle":
                b.ignoredGraphics += 1
            default:
                break
            }
        }
        if !problems.isEmpty { throw Failure(problems: problems) }
        return b
    }

    // MARK: - Nets (bdf_check.sheet_netlist)

    enum Node: Hashable {
        case pin(Int)
        case port(Int, String)
        case seg(Int)
        case junction(Int)
        case name(String)
    }

    struct UnionFind {
        var parent: [Node: Node] = [:]
        mutating func root(_ k: Node) -> Node {
            var k = k
            if parent[k] == nil { parent[k] = k }
            while let p = parent[k], p != k {
                let g = parent[p] ?? p
                parent[k] = g
                k = g
            }
            return k
        }
        mutating func join(_ a: Node, _ b: Node) {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[ra] = rb }
        }
    }

    /// Geometric connectivity (`geo`, without names) and the full nets (`nets`, names joined).
    static func netlist(_ b: BDF) -> (geo: UnionFind, nets: UnionFind) {
        var uf = UnionFind()
        var points: [Point: [Node]] = [:]
        func at(_ p: Point, _ k: Node) { _ = uf.root(k); points[p, default: []].append(k) }
        for (i, p) in b.pins.enumerated() { at(p.point, .pin(i)) }
        for (i, s) in b.symbols.enumerated() { for p in s.ports { at(p.point, .port(i, p.name)) } }
        for (i, c) in b.connectors.enumerated() { at(c.a, .seg(i)); at(c.b, .seg(i)) }
        for (i, j) in b.junctions.enumerated() { at(j, .junction(i)) }
        for (_, keys) in points { for k in keys.dropFirst() { uf.join(keys[0], k) } }
        func on(_ p: Point, _ a: Point, _ c: Point) -> Bool {
            if a.x == c.x && c.x == p.x { return min(a.y, c.y) <= p.y && p.y <= max(a.y, c.y) }
            if a.y == c.y && c.y == p.y { return min(a.x, c.x) <= p.x && p.x <= max(a.x, c.x) }
            return false
        }
        for (p, keys) in points {
            guard keys.contains(where: { if case .seg = $0 { return true }; if case .junction = $0 { return true }; return false }) else { continue }
            for (i, c) in b.connectors.enumerated() where p != c.a && p != c.b && on(p, c.a, c.b) {
                uf.join(keys[0], .seg(i))
            }
        }
        let geo = uf
        for (i, p) in b.pins.enumerated() { uf.join(.pin(i), .name(p.name.lowercased())) }
        for (i, c) in b.connectors.enumerated() { if let n = c.name { uf.join(.seg(i), .name(n.lowercased())) } }
        return (geo, uf)
    }

    // MARK: - Import

    static func importProject(at url: URL) throws -> Result {
        let ext = url.pathExtension.lowercased()
        let dir = url.deletingLastPathComponent()
        var notes: [String] = []
        var settings = Settings()
        var name = url.deletingPathExtension().lastPathComponent
        var sheetFiles: [URL] = []
        var top: String
        switch ext {
        case "qpf", "qsf":
            var qsfURL = url
            if ext == "qpf" {
                let qpf = try readText(url)
                let revision = qpf.components(separatedBy: .newlines).compactMap { line -> String? in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("PROJECT_REVISION") else { return nil }
                    return t.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                }.first
                let rev = (revision?.isEmpty == false ? revision! : name)
                guard let q = find(rev + ".qsf", in: dir) else {
                    throw Failure(problems: ["\(url.lastPathComponent): the settings file \(rev).qsf is not in the same folder"])
                }
                qsfURL = q
                name = url.deletingPathExtension().lastPathComponent
            }
            settings = self.settings(try readText(qsfURL))
            top = settings.top ?? qsfURL.deletingPathExtension().lastPathComponent
            var missing: [String] = []
            for f in settings.bdfFiles {
                if let u = find(fileName(f), in: dir) { sheetFiles.append(u) } else { missing.append("\(qsfURL.lastPathComponent) lists \(f), but \(fileName(f)) is not in \(dir.lastPathComponent)") }
            }
            if !missing.isEmpty { throw Failure(problems: missing) }
            for o in settings.otherFiles {
                notes.append("\(o.kind) \(fileName(o.file)) is not a block diagram and was not imported")
            }
        case "bdf":
            sheetFiles = [url]
            top = url.deletingPathExtension().lastPathComponent
            // Device and pin locations from a project in the same folder whose top is this file.
            let qsfs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".qsf") && !$0.lowercased().hasSuffix("_pins.qsf") }.sorted()
            for q in qsfs {
                guard let t = try? readText(dir.appendingPathComponent(q)) else { continue }
                let s = self.settings(t)
                if s.top?.caseInsensitiveCompare(top) == .orderedSame {
                    settings = s
                    settings.bdfFiles = []
                    notes.append("Device and pin locations taken from \(q)")
                    break
                }
                if settings.device == nil { settings.device = s.device }
            }
        default:
            throw Failure(problems: ["\(url.lastPathComponent) is not a Quartus project (.qpf, .qsf) or block diagram (.bdf)"])
        }
        guard !sheetFiles.isEmpty else { throw Failure(problems: ["\(url.lastPathComponent) lists no block diagram (BDF_FILE) files"]) }

        // Read every sheet, then any block whose .bdf is in the folder but not listed.
        var bdfs: [BDF] = []
        var problems: [String] = []
        func load(_ u: URL) {
            let entity = u.deletingPathExtension().lastPathComponent
            guard !bdfs.contains(where: { $0.entity.caseInsensitiveCompare(entity) == .orderedSame }) else { return }
            do { bdfs.append(try parseBDF(try readText(u), entity: entity, file: u.lastPathComponent)) }
            catch let f as Failure { problems += f.problems }
            catch { problems.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        sheetFiles.forEach(load)
        var k = 0
        while k < bdfs.count {
            for s in bdfs[k].symbols where kind(of: s.name) == nil && MacroLibrary.named(s.name) == nil {
                guard !bdfs.contains(where: { $0.entity.caseInsensitiveCompare(s.name) == .orderedSame }),
                      let u = find(s.name + ".bdf", in: dir) else { continue }
                load(u)
                notes.append(ext == "bdf" ? "\(u.lastPathComponent) (block \(s.name) in \(bdfs[k].file)) imported from the same folder"
                                          : "\(u.lastPathComponent) (block \(s.name) in \(bdfs[k].file)) is not listed in the project; imported from the same folder")
            }
            k += 1
        }
        if !problems.isEmpty { throw Failure(problems: problems) }
        guard bdfs.contains(where: { $0.entity.caseInsensitiveCompare(top) == .orderedSame }) else {
            throw Failure(problems: ["The top-level entity \(top) has no \(top).bdf in the project"])
        }

        // Symbols of the sheets: the .bsf next to it, else the symbol pasted into a parent.
        var symbols: [String: SymbolDef] = [:]
        for b in bdfs {
            guard let u = find(b.entity + ".bsf", in: dir), let text = try? readText(u) else { continue }
            if let s = try? SymbolDef(parsing: text, source: .project) { symbols[b.entity.lowercased()] = s }
            else { notes.append("\(u.lastPathComponent) could not be read; the symbol placed in the parent sheet is used instead") }
        }
        for b in bdfs {
            for s in b.symbols where symbols[s.name.lowercased()] == nil {
                guard bdfs.contains(where: { $0.entity.caseInsensitiveCompare(s.name) == .orderedSame }),
                      let def = try? SymbolDef(stripStyling(s.expr), source: .project) else { continue }
                symbols[s.name.lowercased()] = generic(def)
            }
        }

        let device = settings.device ?? CycloneV.device
        var sheets: [Project] = []
        for b in bdfs {
            do {
                let (p, n) = try sheet(b, symbols: symbols, entities: Set(bdfs.map { $0.entity.lowercased() }), device: device)
                sheets.append(p)
                notes += n
            } catch let f as Failure { problems += f.problems }
        }
        if !problems.isEmpty { throw Failure(problems: problems) }

        let topEntity = bdfs.first { $0.entity.caseInsensitiveCompare(top) == .orderedSame }!.entity
        var d = DesignProject(name: name, device: device, topLevelEntity: topEntity, sheets: sheets)
        guard let ti = d.topIndex else { throw Failure(problems: ["The top-level entity \(top) is not a sheet of the design"]) }

        // Pin locations and I/O standards (top-level pins only, as Quartus uses them).
        var locatedNames = Set<String>()
        for (pin, target) in settings.locations {
            guard let ci = d.sheets[ti].components.firstIndex(where: { $0.kind.isPin && $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                notes.append("Location \(pin) for \(target) was not imported: \(target) is not a pin of \(topEntity).bdf")
                continue
            }
            d.sheets[ti].components[ci].location = CycloneV.normalize(pin)
            locatedNames.insert(target.lowercased())
        }
        for (standard, target) in settings.ioStandards {
            guard let c = d.sheets[ti].components.first(where: { $0.kind.isPin && $0.name.caseInsensitiveCompare(target) == .orderedSame }) else { continue }
            let board = BoardPin.lookup(c.location)
            if board?.ioStandard.caseInsensitiveCompare(standard) != .orderedSame {
                notes.append("I/O standard \"\(standard)\" on \(c.name): Quartzite writes \(board.map { "\"\($0.ioStandard)\" (the \($0.label) standard)" } ?? "no I/O standard") on export")
            }
        }

        // Input order: the waveform's signal order if there is one, else top to bottom.
        let waveCandidates = [settings.waveform.map(fileName), name + ".vwf", "Waveform.vwf"].compactMap { $0 }
        var order: [String] = []
        for w in waveCandidates {
            if let u = find(w, in: dir), let t = try? readText(u) { order = waveformOrder(t); if !order.isEmpty { break } }
        }
        let ins = d.sheets[ti].components.filter { $0.kind == .input }
        func rank(_ c: Component) -> Int { order.firstIndex { $0.caseInsensitiveCompare(c.name) == .orderedSame } ?? Int.max }
        d.sheets[ti].inputOrder = ins.sorted { (rank($0), $0.y, $0.x, $0.name) < (rank($1), $1.y, $1.x, $1.name) }.map(\.id)

        let errors = d.structuralErrors
        if !errors.isEmpty { throw Failure(problems: errors) }
        return Result(design: d, notes: notes)
    }

    /// The primitive for a Quartus symbol name ("AND2", "VCC"), or nil.
    static func kind(of symbolName: String) -> GateKind? {
        let n = symbolName.uppercased()
        if n == "VCC" { return .vcc }
        if n == "GND" { return .gnd }
        return GateKind.gates.first { $0.bdfName == n }
    }

    /// A block symbol as stored on instances: the instance text says "inst" (R7 sizes it).
    static func generic(_ s: SymbolDef) -> SymbolDef {
        var s = s
        s.instanceText.text = "inst"
        s.instanceText.rect[2] = s.instanceText.rect[0] + TextMetrics.intelClear8("inst")
        return s
    }

    static let supportedList = "input and output pins, NOT, AND2-4, OR2-4, NAND2-4, NOR2-4, XOR, XNOR, VCC, GND, the 7447 and blocks of other .bdf files in the project"

    /// Builds one Quartzite sheet from a .bdf.
    static func sheet(_ b: BDF, symbols: [String: SymbolDef], entities: Set<String>, device: String) throws -> (Project, [String]) {
        var p = Project()
        p.name = b.entity
        p.device = device
        p.id = UUID()
        p.symbol = symbols[b.entity.lowercased()]
        var notes: [String] = []
        var problems: [String] = []
        var refs: [Node: PortRef] = [:]

        // Keep coordinates, moved right/down by a whole number of grid steps if any are negative.
        let xs = b.pins.map { $0.rect[0] } + b.symbols.map { $0.rect[0] } + b.notes.map(\.x)
        let ys = b.pins.map { $0.rect[1] } + b.symbols.map { $0.rect[1] } + b.notes.map(\.y)
        func shift(_ v: Int) -> Int { v < 0 ? (-v + 7) / 8 * 8 : 0 }
        let dx = shift(xs.min() ?? 0), dy = shift(ys.min() ?? 0)
        if dx != 0 || dy != 0 { notes.append("\(b.file): moved by (\(dx), \(dy)) so that nothing lies at negative coordinates") }

        /// Places `c` so that its port `port` lands on `at` (bdf coordinates).
        func align(_ c: inout Component, port: Int, at: Point) {
            c.x = 0; c.y = 0
            let q = c.portPoint(port)
            c.x = at.x + dx - Int(q.x)
            c.y = at.y + dy - Int(q.y)
        }

        for (i, pin) in b.pins.enumerated() {
            var c = Component(kind: pin.isInput ? .input : .output, name: pin.name, x: 0, y: 0)
            c.orientation = pin.tag
            c.defaultValue = pin.defaultValue
            align(&c, port: 0, at: pin.point)
            p.components.append(c)
            refs[.pin(i)] = PortRef(comp: c.id, port: 0)
        }
        for (i, s) in b.symbols.enumerated() {
            let what = "\(b.file): \(s.name) \(s.instance.isEmpty ? "" : "(\(s.instance)) ")"
            var c: Component
            if let k = kind(of: s.name) {
                c = Component(kind: k, name: s.instance, x: 0, y: 0)
                if k == .vcc || k == .gnd {
                    if s.tag != nil { notes.append("\(what)is drawn upright (Quartzite does not rotate \(s.name)); its connection is unchanged") }
                } else {
                    c.orientation = s.tag
                }
                guard let first = s.ports.first, let fi = c.portIndex(named: first.name) else {
                    problems.append("\(what)has no ports Quartzite recognises"); continue
                }
                align(&c, port: fi, at: first.point)
            } else if let m = MacroLibrary.named(s.name) {
                c = Component(kind: .macro, name: s.instance, x: s.rect[0] + dx, y: s.rect[1] + dy)
                c.symbol = MacroLibrary.symbol(m)
                if s.tag != nil { notes.append("\(what)is drawn unrotated (Quartzite does not rotate library macros); its connections are unchanged") }
            } else if entities.contains(s.name.lowercased()) {
                guard let sheetSym = symbols[s.name.lowercased()] else { problems.append("\(what)has no symbol"); continue }
                c = Component(kind: .block, name: s.instance, x: s.rect[0] + dx, y: s.rect[1] + dy)
                if let own = try? SymbolDef(s.expr, source: .project), generic(own) != sheetSym {
                    c.symbol = generic(own)
                    notes.append("\(what)differs from \(s.name).bsf; kept as placed (use Update Symbol or Block to refresh it)")
                } else {
                    c.symbol = sheetSym
                }
                if s.tag != nil { notes.append("\(what)is drawn unrotated (Quartzite does not rotate blocks); its connections are unchanged") }
            } else {
                let lower = s.name.lowercased()
                let why: String
                if lower.hasPrefix("lpm_") || lower.hasPrefix("alt") { why = "is a megafunction" }
                else if ["dff", "dffe", "tff", "tffe", "jkff", "jkffe", "srff", "srffe", "latch", "dlatch"].contains(lower) { why = "is a sequential primitive" }
                else { why = "is not a primitive, library macro or block of this project" }
                problems.append("\(what)\(why), which Quartzite does not support. Supported: \(supportedList).")
                continue
            }
            if c.name.isEmpty { c.name = p.nextInstanceName() }
            var ok = true
            for port in s.ports {
                guard let pi = c.portIndex(named: port.name), c.isOutputPort(pi) == port.isOutput else {
                    problems.append("\(what)has a port \(port.name) that Quartzite's \(c.symbolName) does not have")
                    ok = false; continue
                }
                refs[.port(i, port.name)] = PortRef(comp: c.id, port: pi)
            }
            if ok { p.components.append(c) }
        }
        if !problems.isEmpty { throw Failure(problems: problems) }
        if b.ignoredGraphics > 0 { notes.append("\(b.file): \(b.ignoredGraphics) drawn line(s) or shape(s) that are not wires were left out") }
        p.notes = b.notes.isEmpty ? nil : b.notes.map { TextNote(text: $0.text, x: $0.x + dx, y: $0.y + dy) }

        var (geo, nets) = netlist(b)

        // Name spellings: a pin's spelling wins, then the first connector's.
        var spelling: [String: String] = [:]
        for pin in b.pins where spelling[pin.name.lowercased()] == nil { spelling[pin.name.lowercased()] = pin.name }
        for c in b.connectors { if let n = c.name, spelling[n.lowercased()] == nil { spelling[n.lowercased()] = n } }

        // Groups of ports joined by lines: wire each group as a shortest tree.
        var groups: [Node: [Node]] = [:]
        var order: [Node] = []
        for k in refs.keys.sorted(by: { "\($0)" < "\($1)" }) {
            let r = geo.root(k)
            if groups[r] == nil { order.append(r) }
            groups[r, default: []].append(k)
        }
        func pointOf(_ r: PortRef) -> CGPoint { p.component(r.comp)!.portPoint(r.port) }
        for r in order {
            let members = groups[r]!.compactMap { refs[$0] }
            guard members.count > 1 else { continue }
            var inTree = [members[0]], rest = Array(members.dropFirst())
            while !rest.isEmpty {
                var best = (0, 0, CGFloat.infinity)
                for (ti, t) in inTree.enumerated() {
                    let a = pointOf(t)
                    for (ri, q) in rest.enumerated() {
                        let b = pointOf(q)
                        let d = abs(a.x - b.x) + abs(a.y - b.y)
                        if d < best.2 { best = (ti, ri, d) }
                    }
                }
                let q = rest.remove(at: best.1)
                if best.2 > 0 { p.wires.append(Wire(a: inTree[best.0], b: q)) }
                inTree.append(q)
            }
        }
        // Names on lines become net labels on a port of the group (not one already named so).
        var segRoots: [Node: [String]] = [:]
        for (i, c) in b.connectors.enumerated() {
            guard let n = c.name else { continue }
            let s = spelling[n.lowercased()] ?? n
            let r = geo.root(.seg(i))
            if !(segRoots[r] ?? []).contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { segRoots[r, default: []].append(s) }
        }
        for r in order {
            guard let names = segRoots[r] else { continue }
            let members = groups[r]!.compactMap { refs[$0] }
            let pinNames = Set(members.compactMap { m -> String? in
                guard let c = p.component(m.comp), c.kind.isPin else { return nil }
                return c.name.lowercased()
            })
            var free = members.filter { p.component($0.comp)?.kind.isPin == false } + members.filter { p.component($0.comp)?.kind.isPin == true }
            for n in names where !pinNames.contains(n.lowercased()) {
                guard !free.isEmpty else { break }
                p.labels[free.removeFirst().key] = n
            }
        }

        // Compare with the Quartus nets; join what Quartus joins, refuse what it doesn't.
        func check() -> (split: [[PortRef]], merged: [String]) {
            let conn = Connectivity(p)
            var byQuartus: [Node: Set<Int>] = [:]
            var quartusOf: [Int: Node] = [:]
            var merged: [String] = []
            for (k, r) in refs {
                let q = nets.root(k)
                guard let n = conn.netOf[r] else { continue }
                byQuartus[q, default: []].insert(n)
                if let other = quartusOf[n], other != q {
                    let c = p.component(r.comp)!
                    merged.append("\(c.name).\(c.portName(r.port))")
                }
                quartusOf[n] = q
            }
            let split = byQuartus.values.filter { $0.count > 1 }.map { ids in ids.sorted().map { conn.nets[$0].ports[0] } }
            return (split, merged)
        }
        var result = check()
        if !result.merged.isEmpty {
            throw Failure(problems: ["\(b.file): Quartzite would connect ports that Quartus keeps apart (near \(result.merged.sorted().joined(separator: ", "))); move the symbols apart in Quartus and import again"])
        }
        if !result.split.isEmpty {
            for group in result.split { for q in group.dropFirst() { p.wires.append(Wire(a: group[0], b: q)) } }
            result = check()
            if !result.split.isEmpty || !result.merged.isEmpty {
                throw Failure(problems: ["\(b.file): the connections could not be reproduced"])
            }
            notes.append("\(b.file): some nets joined only through unattached names were drawn as wires")
        }
        let errs = p.structuralErrors
        if !errs.isEmpty { throw Failure(problems: errs.map { "\(b.file): \($0)" }) }
        return (p, notes)
    }
}

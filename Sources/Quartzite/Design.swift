import Foundation

/// A Quartzite project with one or more schematic sheets, like a Quartus project with
/// several .bdf files. Each sheet is a `Project`; its `entityName` is both the entity and
/// the .bdf file name. Saved as format version 2; version 1 files hold a single bare
/// `Project` and are wrapped on load.
struct DesignProject: Codable {
    var formatVersion = 2
    /// The .qpf / .qsf name; defaults to the top entity.
    var name: String
    var device: String
    var topLevelEntity: String
    /// One per .bdf.
    var sheets: [Project]

    static let currentFormat = 2

    struct LoadError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(name: String, device: String, topLevelEntity: String, sheets: [Project]) {
        self.name = name
        self.device = device
        self.topLevelEntity = topLevelEntity
        self.sheets = sheets
    }

    /// A one-sheet design (a version 1 file or a new project).
    init(single p: Project) {
        var p = p
        if p.id == nil { p.id = UUID() }
        self.init(name: p.name, device: p.device, topLevelEntity: p.entityName, sheets: [p])
    }

    enum CodingKeys: String, CodingKey { case formatVersion, name, device, topLevelEntity, sheets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? DesignProject.currentFormat
        name = try c.decode(String.self, forKey: .name)
        device = try c.decode(String.self, forKey: .device)
        topLevelEntity = try c.decode(String.self, forKey: .topLevelEntity)
        sheets = try c.decode([Project].self, forKey: .sheets)
    }

    /// Reads a .qzproj of either format.
    static func load(_ data: Data) throws -> DesignProject {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(message: "The file is not a Quartzite project")
        }
        guard dict["sheets"] != nil else {
            return DesignProject(single: try JSONDecoder().decode(Project.self, from: data))
        }
        if let v = dict["formatVersion"] as? Int, v > currentFormat {
            throw LoadError(message: "This project was made by a newer Quartzite (file format \(v)). Update Quartzite to open it.")
        }
        var d = try JSONDecoder().decode(DesignProject.self, from: data)
        for i in d.sheets.indices where d.sheets[i].id == nil { d.sheets[i].id = UUID() }
        let errors = d.structuralErrors
        guard errors.isEmpty else { throw LoadError(message: errors.joined(separator: "; ")) }
        return d
    }

    /// Version 2 JSON, as saved by File > Save.
    func encoded(pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try enc.encode(self)
    }

    /// Problems that make the design unusable (checked on load, like `Project.structuralErrors`).
    var structuralErrors: [String] {
        var errors: [String] = []
        if sheets.isEmpty { errors.append("The design has no sheets") }
        for s in sheets {
            errors += s.structuralErrors.map { "\(s.entityName).bdf: \($0)" }
        }
        var seen: [String: String] = [:]
        for s in sheets {
            let key = s.entityName.lowercased()
            if let other = seen[key] { errors.append("Sheets \(other) and \(s.entityName) have the same entity name") }
            seen[key] = s.entityName
        }
        let ids = sheets.compactMap(\.id)
        if Set(ids).count != ids.count { errors.append("Duplicate sheet IDs") }
        if !sheets.isEmpty && top == nil { errors.append("The top-level entity '\(topLevelEntity)' is not a sheet of the design") }
        return errors
    }

    var top: Project? { sheet(named: topLevelEntity) }
    var topIndex: Int? { sheetIndex(named: topLevelEntity) }

    /// Case-insensitive, as Quartus (and Windows file names) treat entity names.
    func sheet(named n: String) -> Project? { sheetIndex(named: n).map { sheets[$0] } }
    func sheetIndex(named n: String) -> Int? {
        sheets.firstIndex { $0.entityName.caseInsensitiveCompare(n) == .orderedSame }
    }
    func sheetIndex(id: UUID) -> Int? { sheets.firstIndex { $0.id == id } }

    /// File-safe project name for the .qpf and .qsf (the same rules as `Project.entityName`).
    var projectName: String {
        var p = Project()
        p.name = name
        return p.entityName
    }
}

// MARK: - Hierarchy

/// One entity instance in the design hierarchy (Quartus' Project Navigator > Hierarchy).
struct HierarchyNode {
    var entity: String
    /// Instance name in the parent sheet (nil for the top).
    var instance: String?
    var instanceID: UUID?
    var isMacro = false
    /// The block's sheet does not exist.
    var missing = false
    /// The block instantiates one of its own ancestors (not expanded).
    var recursive = false
    var children: [HierarchyNode] = []
    /// Logic gates drawn on this entity's own sheet (for a macro: the gates that model it).
    var ownGates = 0
    var totalGates = 0

    /// "FA:inst2", or the entity alone for the top.
    var label: String { instance.map { "\(entity):\($0)" } ?? entity }

    func walk(_ visit: (HierarchyNode, [HierarchyNode]) -> Void, path: [HierarchyNode] = []) {
        visit(self, path)
        for c in children { c.walk(visit, path: path + [self]) }
    }
}

/// What Create Symbol Files / Update Symbol or Block changed.
struct SymbolUpdateReport {
    var entity: String
    var updatedInstances = 0
    var addedPorts: [String] = []
    var removedPorts: [String] = []
    /// Wires and labels that were attached to ports the new symbol no longer has.
    var droppedWires = 0
    var droppedLabels: [String] = []
    var error: String?

    var summary: String {
        if let error { return error }
        var s = "Created \(entity).bsf; updated \(updatedInstances) instance\(updatedInstances == 1 ? "" : "s")"
        if !addedPorts.isEmpty { s += "; new ports \(addedPorts.joined(separator: ", "))" }
        if !removedPorts.isEmpty { s += "; removed ports \(removedPorts.joined(separator: ", "))" }
        if droppedWires > 0 { s += "; \(droppedWires) wire\(droppedWires == 1 ? "" : "s") to removed ports deleted" }
        if !droppedLabels.isEmpty { s += "; node names removed: \(droppedLabels.joined(separator: ", "))" }
        return s
    }
}

extension GateKind {
    /// A logic primitive (NOT, AND2 ... XNOR).
    var isGate: Bool { GateKind.gates.contains(self) }
}

extension DesignProject {
    struct EditError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Quartus megafunction and library prefixes; an entity with one of them may clash with an Intel entity.
    static func nameWarning(_ n: String) -> String? {
        let l = n.lowercased()
        guard l.hasPrefix("lpm_") || l.hasPrefix("alt") || l.hasPrefix("sld_") else { return nil }
        return "Entity name '\(n)' starts like a Quartus library entity (lpm_, alt..., sld_). Quartus may pick the library entity instead; consider another name."
    }

    /// Checks a new entity / .bdf name against Quartus' rules and the other sheets.
    func validateEntityName(_ n: String, excluding id: UUID? = nil) throws {
        guard Compiler.isValidName(n) else {
            throw EditError(message: "'\(n)' is not a valid entity name. Use letters, digits and _, starting with a letter.")
        }
        guard !Compiler.reserved.contains(n.lowercased()) else { throw EditError(message: "'\(n)' is a reserved word in Verilog, VHDL or AHDL") }
        if let other = sheets.first(where: { $0.id != id && $0.entityName.caseInsensitiveCompare(n) == .orderedSame }) {
            throw EditError(message: "The project already has a file named \(other.entityName).bdf")
        }
        if MacroLibrary.named(n) != nil { throw EditError(message: "'\(n)' is the name of a library macro") }
    }

    /// File > New > Block Diagram/Schematic File: an empty sheet named `n`.
    @discardableResult
    mutating func addSheet(named n: String) throws -> UUID {
        try validateEntityName(n)
        var p = Project()
        p.name = n
        p.device = device
        p.id = UUID()
        sheets.append(p)
        return p.id!
    }

    /// Renames a sheet (its .bdf and entity), the top-level entity if it is the top, its
    /// symbol, and every block instance of it.
    mutating func renameSheet(id: UUID, to n: String) throws {
        guard let i = sheetIndex(id: id) else { throw EditError(message: "No such sheet") }
        let old = sheets[i].entityName
        if old == n { return }
        try validateEntityName(n, excluding: id)
        sheets[i].name = n
        renameReferences(from: old, sheet: i)
    }

    /// After sheet `i` was renamed from `old`: its symbol, every block instance of it and,
    /// if it is the top, the top-level entity (and a design named after it) follow.
    mutating func renameReferences(from old: String, sheet i: Int) {
        let n = sheets[i].entityName
        let wasTop = topLevelEntity.caseInsensitiveCompare(old) == .orderedSame
        func renamed(_ s: SymbolDef) -> SymbolDef {
            var s = s
            s.name = n
            s.nameText.text = n
            s.nameText.rect[2] = s.nameText.rect[0] + TextMetrics.intelClear8(n)
            return s
        }
        if let s = sheets[i].symbol { sheets[i].symbol = renamed(s) }
        for si in sheets.indices {
            for ci in sheets[si].components.indices where sheets[si].components[ci].kind == .block {
                guard let s = sheets[si].components[ci].symbol, s.name.caseInsensitiveCompare(old) == .orderedSame else { continue }
                sheets[si].components[ci].symbol = renamed(s)
            }
        }
        if wasTop {
            if projectName.caseInsensitiveCompare(old) == .orderedSame { name = n }
            topLevelEntity = n
        }
    }

    /// Project > Remove File from Project. The top and sheets used as blocks can't be removed.
    mutating func removeSheet(id: UUID) throws {
        guard let i = sheetIndex(id: id) else { throw EditError(message: "No such sheet") }
        let e = sheets[i].entityName
        if topIndex == i { throw EditError(message: "\(e).bdf is the top-level entity. Set another file as the top first.") }
        if let user = sheets.first(where: { s in s.components.contains { $0.kind == .block && $0.symbol?.name.caseInsensitiveCompare(e) == .orderedSame } }) {
            throw EditError(message: "\(e) is used as a block in \(user.entityName).bdf. Delete those instances first.")
        }
        sheets.remove(at: i)
    }

    /// Project > Set as Top-Level Entity.
    mutating func setTop(_ entity: String) throws {
        guard let s = sheet(named: entity) else { throw EditError(message: "No file named \(entity).bdf in the project") }
        topLevelEntity = s.entityName
    }

    /// The instance tree under `top` (default: the top-level entity). Recursion and missing
    /// sheets end a branch instead of looping.
    func instanceTree(from top: String? = nil) -> HierarchyNode {
        func node(_ entity: String, instance: String?, id: UUID?, path: [String]) -> HierarchyNode {
            guard let s = sheet(named: entity) else {
                return HierarchyNode(entity: entity, instance: instance, instanceID: id, missing: true)
            }
            var n = HierarchyNode(entity: s.entityName, instance: instance, instanceID: id)
            n.ownGates = s.components.filter { $0.kind.isGate }.count
            let here = path + [s.entityName.lowercased()]
            for c in s.components where c.kind.isHierarchical {
                let child = c.symbol?.name ?? "?"
                if c.kind == .macro {
                    var m = HierarchyNode(entity: child, instance: c.name, instanceID: c.id, isMacro: true)
                    m.ownGates = MacroLibrary.named(child).map { MacroLibrary.netlist($0).components.filter { $0.kind.isGate }.count } ?? 0
                    m.totalGates = m.ownGates
                    m.missing = MacroLibrary.named(child) == nil
                    n.children.append(m)
                } else if here.contains(child.lowercased()) {
                    n.children.append(HierarchyNode(entity: child, instance: c.name, instanceID: c.id, recursive: true))
                } else {
                    n.children.append(node(child, instance: c.name, id: c.id, path: here))
                }
            }
            n.totalGates = n.ownGates + n.children.reduce(0) { $0 + $1.totalGates }
            return n
        }
        return node(top ?? topLevelEntity, instance: nil, id: nil, path: [])
    }

    /// Sheets reachable from the top, top first, then depth-first in instance order.
    func usedSheets(from top: String? = nil) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        instanceTree(from: top).walk { n, _ in
            guard !n.isMacro, !n.missing, !n.recursive, seen.insert(n.entity.lowercased()).inserted else { return }
            out.append(n.entity)
        }
        return out
    }

    /// Library macros used under the top, in first-use order.
    func usedMacros(from top: String? = nil) -> [String] {
        var out: [String] = []
        instanceTree(from: top).walk { n, _ in if n.isMacro, !out.contains(n.entity) { out.append(n.entity) } }
        return out
    }

    /// Whether placing a block of `child` into `sheet` would make an entity contain itself.
    func wouldRecurse(placing child: String, into target: String) -> Bool {
        if child.caseInsensitiveCompare(target) == .orderedSame { return true }
        var stack = [child]
        var seen = Set<String>()
        while let e = stack.popLast() {
            guard seen.insert(e.lowercased()).inserted, let s = sheet(named: e) else { continue }
            for c in s.components where c.kind == .block {
                guard let n = c.symbol?.name else { continue }
                if n.caseInsensitiveCompare(target) == .orderedSame { return true }
                stack.append(n)
            }
        }
        return false
    }

    /// Places a block of `entity` (which must have a symbol) on sheet `id`.
    @discardableResult
    mutating func placeBlock(_ entity: String, inSheet id: UUID, x: Int, y: Int, name: String? = nil) throws -> UUID {
        guard let ti = sheetIndex(id: id) else { throw EditError(message: "No such sheet") }
        guard let child = sheet(named: entity) else { throw EditError(message: "No file named \(entity).bdf in the project") }
        guard let sym = child.symbol else {
            throw EditError(message: "\(child.entityName) has no symbol yet. Open \(child.entityName).bdf and use File > Create/Update > Create Symbol Files for Current File.")
        }
        if wouldRecurse(placing: child.entityName, into: sheets[ti].entityName) {
            throw EditError(message: "Can't place \(child.entityName) in \(sheets[ti].entityName).bdf: \(child.entityName) would contain itself")
        }
        var c = Component(kind: .block, name: name ?? sheets[ti].nextInstanceName(), x: x, y: y)
        c.symbol = sym
        sheets[ti].components.append(c)
        return c.id
    }

    /// File > Create/Update > Create Symbol Files for Current File, then (as Quartzite always
    /// does) Update Symbol or Block on every instance.
    @discardableResult
    mutating func createSymbol(forSheet id: UUID) -> SymbolUpdateReport {
        guard let i = sheetIndex(id: id) else { return SymbolUpdateReport(entity: "?", error: "No such sheet") }
        sheets[i].symbol = SymbolGenerator.symbol(for: sheets[i])
        return updateInstances(of: sheets[i].entityName)
    }

    /// Edit > Update Symbol or Block: gives every instance of `entity` the sheet's current
    /// symbol. Wires and node names follow their port by name; those on ports that no longer
    /// exist are removed and reported.
    @discardableResult
    mutating func updateInstances(of entity: String) -> SymbolUpdateReport {
        var report = SymbolUpdateReport(entity: entity)
        guard let child = sheet(named: entity), let sym = child.symbol else {
            report.error = "\(entity) has no symbol. Use File > Create/Update > Create Symbol Files for Current File first."
            return report
        }
        report.entity = child.entityName
        var added = Set<String>(), removed = Set<String>()
        for si in sheets.indices {
            for ci in sheets[si].components.indices where sheets[si].components[ci].kind == .block {
                guard let old = sheets[si].components[ci].symbol, old.name.caseInsensitiveCompare(entity) == .orderedSame else { continue }
                report.updatedInstances += 1
                guard old != sym else { continue }
                var map: [Int: Int] = [:]
                for (oi, op) in old.ports.enumerated() {
                    if let ni = sym.ports.firstIndex(where: { $0.name.caseInsensitiveCompare(op.name) == .orderedSame }) { map[oi] = ni }
                    else { removed.insert(op.name) }
                }
                for np in sym.ports where !old.ports.contains(where: { $0.name.caseInsensitiveCompare(np.name) == .orderedSame }) { added.insert(np.name) }
                let cid = sheets[si].components[ci].id
                sheets[si].components[ci].symbol = sym
                var dropped = 0
                sheets[si].wires = sheets[si].wires.compactMap { w in
                    var w = w
                    for end in [\Wire.a, \Wire.b] where w[keyPath: end].comp == cid {
                        guard let ni = map[w[keyPath: end].port] else { dropped += 1; return nil }
                        w[keyPath: end].port = ni
                    }
                    return w
                }
                report.droppedWires += dropped
                var labels: [String: String] = [:]
                for (k, v) in sheets[si].labels {
                    guard let r = PortRef(key: k), r.comp == cid else { labels[k] = v; continue }
                    if let ni = map[r.port] { labels[PortRef(comp: cid, port: ni).key] = v } else { report.droppedLabels.append(v) }
                }
                sheets[si].labels = labels
            }
        }
        report.addedPorts = added.sorted()
        report.removedPorts = removed.sorted()
        return report
    }

    /// Block instances whose symbol differs from their sheet's current symbol.
    func staleInstances() -> [(sheet: String, component: Component)] {
        var out: [(String, Component)] = []
        for s in sheets {
            for c in s.components where c.kind == .block {
                guard let name = c.symbol?.name, let child = sheet(named: name), let cs = child.symbol, cs != c.symbol else { continue }
                out.append((s.entityName, c))
            }
        }
        return out
    }
}

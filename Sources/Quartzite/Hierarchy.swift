import Foundation

/// Where a component of a flattened design came from.
struct SourceRef: Hashable {
    /// Entity of the sheet to open to find it.
    var sheet: String
    /// The component on that sheet (for gates inside a library macro: the macro instance).
    var component: UUID
    /// Hierarchical name without the top entity, as Quartus prints it: "AddSub4:inst|FA:inst2|HA:inst|inst1".
    var displayPath: String
}

/// A design reduced to one sheet of primitives, connected by node names only.
struct FlatDesign {
    var project: Project
    /// True when `project` is the top sheet itself (it has no blocks or macros).
    var identity: Bool
    /// Components that are not on the top sheet.
    var origin: [UUID: SourceRef]
    /// Components the user never drew: macro internals and default drivers of unconnected block inputs.
    var generated: Set<UUID>
    var hierarchy: HierarchyNode
    var sheetsUsed: [String]
    var macrosUsed: [String]

    /// The hierarchical name of a flat component (its own name on the top sheet).
    func displayName(_ id: UUID) -> String {
        origin[id]?.displayPath ?? project.component(id)?.name ?? "?"
    }
}

enum Flattener {
    /// Flattens the hierarchy under `top` (default: the design's top-level entity). A top sheet
    /// without blocks or macros is used as it is unless `forceFull` is set.
    static func flatten(_ d: DesignProject, top: String? = nil, forceFull: Bool = false) -> (FlatDesign?, [Message]) {
        let topName = top ?? d.topLevelEntity
        guard let t = d.sheet(named: topName) else {
            return (nil, [Message(level: .error, text: "Top-level entity \"\(topName)\" is not a file in the project (no \(topName).bdf)")])
        }
        let tree = d.instanceTree(from: t.entityName)
        if !forceFull && !t.components.contains(where: { $0.kind.isHierarchical }) {
            var p = t
            p.device = d.device
            return (FlatDesign(project: p, identity: true, origin: [:], generated: [], hierarchy: tree,
                               sheetsUsed: [t.entityName], macrosUsed: []), [])
        }
        var b = FlatBuilder(design: d, top: t)
        b.expand(t, entity: t.entityName, path: [], display: "", bindings: [:], isTop: true, inMacro: false,
                 stack: [t.entityName.lowercased()], instance: nil)
        guard !b.messages.contains(where: { $0.level == .error }) else { return (nil, b.messages) }
        let p = b.finish()
        return (FlatDesign(project: p, identity: false, origin: b.origin, generated: b.generated, hierarchy: tree,
                           sheetsUsed: d.usedSheets(from: t.entityName), macrosUsed: d.usedMacros(from: t.entityName)), b.messages)
    }

    /// Points messages about flat components back at the sheet and component the user drew.
    static func remap(_ ms: [Message], _ f: FlatDesign) -> [Message] {
        guard !f.identity else { return ms }
        return ms.map { m in
            var m = m
            if let id = m.component, let o = f.origin[id] {
                m.component = o.component
                m.sheet = o.sheet
            }
            m.children = remap(m.children, f)
            return m
        }
    }
}

/// Builds the flat netlist: every sheet's nets become flat nets joined by union-find through
/// block ports, then each flat net gets one name and every flat port a label.
private struct FlatBuilder {
    struct Candidate {
        /// 0 top input pin, 1 top output pin, 2 top node name, 3 node or pin name inside a block or macro.
        var rank: Int
        var depth: Int
        var order: Int
        var name: String
    }

    let design: DesignProject
    let top: Project
    var components: [Component] = []
    var ports: [(PortRef, Int)] = []
    var parent: [Int] = []
    var candidates: [Int: [Candidate]] = [:]
    var origin: [UUID: SourceRef] = [:]
    var generated = Set<UUID>()
    var messages: [Message] = []
    var counter = 0
    var order = 0
    /// Lower-cased names already taken by components (and the top sheet's node names).
    var taken = Set<String>()

    init(design: DesignProject, top: Project) {
        self.design = design
        self.top = top
        for c in top.components { taken.insert(c.name.lowercased()) }
        for v in top.labels.values { taken.insert(v.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    mutating func newNet() -> Int { parent.append(parent.count); return parent.count - 1 }

    mutating func find(_ i: Int) -> Int {
        var i = i
        while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
        return i
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }

    mutating func syntheticID() -> UUID {
        counter += 1
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", counter))!
    }

    mutating func uniqueName(_ base: String) -> String {
        var n = base, k = 1
        while taken.contains(n.lowercased()) { n = "\(base)_\(k)"; k += 1 }
        taken.insert(n.lowercased())
        return n
    }

    mutating func candidate(_ net: Int, rank: Int, depth: Int, _ name: String) {
        order += 1
        candidates[net, default: []].append(Candidate(rank: rank, depth: depth, order: order, name: name))
    }

    /// Expands one sheet (or macro netlist) whose ports are bound to `bindings` (lower-cased port
    /// name -> flat net). `instance` is the block or macro instance that holds it, on a sheet
    /// the user can open.
    mutating func expand(_ sheet: Project, entity: String, path: [String], display: String, bindings: [String: Int],
                         isTop: Bool, inMacro: Bool, stack: [String], instance: (sheet: String, id: UUID, name: String)?) {
        let conn = Connectivity(sheet)
        var local: [Int] = []
        for _ in conn.nets { local.append(newNet()) }
        func flat(_ c: Component, _ i: Int) -> Int? { conn.netOf[PortRef(comp: c.id, port: i)].map { local[$0] } }
        let prefix = path.joined(separator: "_")
        let depth = path.count

        // Node names on this sheet.
        for (key, raw) in sheet.labels.sorted(by: { $0.key < $1.key }) {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, let r = PortRef(key: key), let ln = conn.netOf[r] else { continue }
            if isTop { candidate(local[ln], rank: 2, depth: 0, n) } else { candidate(local[ln], rank: 3, depth: depth, prefix + "_" + n) }
        }

        for c in sheet.components {
            switch c.kind {
            case .input, .output:
                guard let net = flat(c, 0) else { continue }
                if isTop {
                    components.append(c)
                    ports.append((PortRef(comp: c.id, port: 0), net))
                    candidate(net, rank: c.kind == .input ? 0 : 1, depth: 0, c.name)
                    continue
                }
                candidate(net, rank: 3, depth: depth, prefix + "_" + c.name)
                if let bound = bindings[c.name.lowercased()] {
                    union(net, bound)
                } else if c.kind == .input, let inst = instance {
                    if inMacro {
                        let hint = MacroLibrary.named(entity)?.unconnectedHint ?? ""
                        messages.append(Message(level: .error, text: "Input \(c.name) of \(entity) \"\(display)\" is not connected. \(hint)",
                                                component: inst.id, sheet: inst.sheet))
                        continue
                    }
                    // Quartus drives an unconnected block input with the pin's default value.
                    let gnd = (c.defaultValue ?? "VCC").uppercased() == "GND"
                    let id = syntheticID()
                    let g = Component(kind: gnd ? .gnd : .vcc, name: uniqueName("\(prefix)_\(c.name)_default"), x: 0, y: 0)
                    var placed = g
                    placed.id = id
                    components.append(placed)
                    ports.append((PortRef(comp: id, port: 0), net))
                    generated.insert(id)
                    origin[id] = SourceRef(sheet: inst.sheet, component: inst.id, displayPath: "\(display)|\(c.name)")
                    messages.append(Message(level: .warning,
                                            text: "Input port \(c.name) of \(entity) \"\(display)\" is not connected, so it is driven by \(gnd ? "GND" : "VCC") (the pin's default value)",
                                            component: inst.id, sheet: inst.sheet))
                }
            case .block, .macro:
                let childName = c.symbol?.name ?? "?"
                let childDisplay = (display.isEmpty ? "" : display + "|") + "\(childName):\(c.name)"
                let child: Project?
                if c.kind == .macro {
                    child = MacroLibrary.named(childName).map { MacroLibrary.netlist($0) }
                    if child == nil {
                        messages.append(Message(level: .error, text: "Library macro \(childName) (\(c.name)) is not available in Quartzite",
                                                component: c.id, sheet: entity))
                    }
                } else {
                    child = design.sheet(named: childName)
                    if child == nil {
                        messages.append(Message(level: .error, text: "Block \(c.name) refers to \(childName).bdf, which is not in the project",
                                                component: c.id, sheet: entity))
                    } else if stack.contains(childName.lowercased()) {
                        messages.append(Message(level: .error, text: "\(childName) contains itself (through \"\(childDisplay)\"); a design can't instantiate itself",
                                                component: c.id, sheet: entity))
                        continue
                    }
                }
                guard let child else { continue }
                let pins = Dictionary(child.components.filter { $0.kind.isPin }.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
                var bound: [String: Int] = [:]
                var mismatch = false
                for i in c.portIndices {
                    let name = c.portName(i)
                    guard let pin = pins[name.lowercased()], (pin.kind == .output) == c.isOutputPort(i) else {
                        messages.append(Message(level: .error,
                                                text: "Port '\(name)' of \(c.name) is not \(c.isOutputPort(i) ? "an output" : "an input") of \(childName).bdf. Use File > Create/Update > Create Symbol Files for Current File, then Update Symbol or Block",
                                                component: c.id, sheet: entity))
                        mismatch = true
                        continue
                    }
                    guard let ln = conn.netOf[PortRef(comp: c.id, port: i)] else { continue }
                    let n = conn.nets[ln]
                    if n.hasExplicitLink || n.ports.count > 1 { bound[pin.name.lowercased()] = local[ln] }
                }
                if mismatch { continue }
                let macro = c.kind == .macro
                expand(child, entity: macro ? childName : child.entityName, path: path + [c.name], display: childDisplay, bindings: bound,
                       isTop: false, inMacro: macro, stack: stack + [childName.lowercased()], instance: (entity, c.id, c.name))
            default:
                var g = c
                if !isTop {
                    g.id = syntheticID()
                    g.name = uniqueName(prefix + "_" + c.name)
                    if inMacro, let inst = instance {
                        generated.insert(g.id)
                        origin[g.id] = SourceRef(sheet: inst.sheet, component: inst.id, displayPath: display + "|" + c.name)
                    } else {
                        origin[g.id] = SourceRef(sheet: entity, component: c.id, displayPath: display + "|" + c.name)
                    }
                }
                components.append(g)
                for i in c.portIndices {
                    if let net = flat(c, i) { ports.append((PortRef(comp: g.id, port: i), net)) }
                }
            }
        }
    }

    /// The flat project: one name per net (top pins, then top node names, then the shallowest
    /// inner name, then qz_n<k>), written as a label on every port.
    mutating func finish() -> Project {
        var best: [Int: Candidate] = [:]
        for (net, cs) in candidates {
            let r = find(net)
            for c in cs {
                if let b = best[r], (b.rank, b.depth, b.order) <= (c.rank, c.depth, c.order) { continue }
                best[r] = c
            }
        }
        // Names of the top sheet's pins and nodes belong to their nets.
        var netName: [Int: String] = [:]
        var used = Set(components.filter { !$0.kind.isPin }.map { $0.name.lowercased() })
        for (r, c) in best.sorted(by: { ($0.value.rank, $0.value.depth, $0.value.order) < ($1.value.rank, $1.value.depth, $1.value.order) }) {
            var n = c.name, k = 1
            while used.contains(n.lowercased()) { n = "\(c.name)_\(k)"; k += 1 }
            used.insert(n.lowercased())
            netName[r] = n
        }
        var p = Project()
        p.name = top.name
        p.device = design.device
        p.inputOrder = top.inputOrder
        p.expected = top.expected
        p.isFlatNetlist = true
        p.components = components
        var k = 0
        for (ref, net) in ports {
            let r = find(net)
            if netName[r] == nil {
                var n = "qz_n\(k)"
                while used.contains(n) { k += 1; n = "qz_n\(k)" }
                used.insert(n)
                netName[r] = n
            }
            p.labels[ref.key] = netName[r]
        }
        return p
    }
}

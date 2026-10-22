import Foundation

struct Message: Identifiable, Hashable {
    /// Quartus message types. `criticalWarning` is used for problems Quartus also flags as
    /// critical (for example pins without a location).
    enum Level: Int, CaseIterable { case info, warning, criticalWarning, error

        var title: String {
            switch self {
            case .info: return "Info"
            case .warning: return "Warning"
            case .criticalWarning: return "Critical Warning"
            case .error: return "Error"
            }
        }
    }
    var id = UUID()
    var level: Level
    var text: String
    var component: UUID? = nil
    /// Sub-messages, shown indented under this one (as Quartus groups them).
    var children: [Message] = []
    /// Compilation stage that produced the message (nil for editor messages).
    var stage: String? = nil

    /// "Info: text" lines with children indented four spaces, like a Quartus .rpt file.
    func reportLines(indent: Int = 0) -> [String] {
        [String(repeating: " ", count: indent) + "\(level.title): \(text)"] + children.flatMap { $0.reportLines(indent: indent + 4) }
    }
}

/// Groups every port into nets: ports joined by wires, by equal net labels,
/// and by pin names (a label equal to a pin name connects to that pin, as in Quartus).
struct Connectivity {
    struct Net {
        var id: Int
        var ports: [PortRef]
        var names: [String]          // pin names and labels on this net
        var drivers: [PortRef]
        var sinks: [PortRef]
        var hasExplicitLink: Bool     // touched by any wire or label
    }

    var nets: [Net] = []
    var netOf: [PortRef: Int] = [:]
    /// Pairs of ports that overlap on the canvas (connected implicitly).
    var touching: [(PortRef, PortRef)] = []

    init(_ project: Project) {
        guard project.structuralErrors.isEmpty else { return }
        var all: [PortRef] = []
        for c in project.components {
            for i in c.portIndices { all.append(PortRef(comp: c.id, port: i)) }
        }
        var index: [PortRef: Int] = [:]
        for (i, p) in all.enumerated() { index[p] = i }
        var parent = Array(all.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }

        var linked = Set<Int>()
        // Quartus connects ports that sit on the same point, even without a wire.
        // Generated netlists have no geometry.
        var byPoint: [String: Int] = [:]
        for c in project.components where !project.isFlatNetlist {
            for i in c.portIndices {
                let pt = c.portPoint(i)
                let key = "\(Int(pt.x)),\(Int(pt.y))"
                guard let me = index[PortRef(comp: c.id, port: i)] else { continue }
                if let other = byPoint[key] {
                    union(other, me); linked.insert(other); linked.insert(me)
                    touching.append((PortRef(comp: c.id, port: i), all[other]))
                } else {
                    byPoint[key] = me
                }
            }
        }
        for w in project.wires {
            guard let a = index[w.a], let b = index[w.b] else { continue }
            union(a, b); linked.insert(a); linked.insert(b)
        }
        // Names: pin names + labels.
        var byName: [String: [Int]] = [:]
        var nameOfPort: [Int: [String]] = [:]
        for c in project.components where c.kind.isPin {
            let n = c.name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, let i = index[PortRef(comp: c.id, port: 0)] else { continue }
            byName[n, default: []].append(i)
            nameOfPort[i, default: []].append(n)
        }
        for (key, raw) in project.labels {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            let parts = key.split(separator: "#")
            guard parts.count == 2, let u = UUID(uuidString: String(parts[0])), let p = Int(parts[1]),
                  let i = index[PortRef(comp: u, port: p)] else { continue }
            byName[n, default: []].append(i)
            nameOfPort[i, default: []].append(n)
            linked.insert(i)
        }
        for (_, members) in byName where members.count > 1 {
            for m in members.dropFirst() { union(members[0], m); linked.insert(m); linked.insert(members[0]) }
        }

        var rootToNet: [Int: Int] = [:]
        let comps = Dictionary(uniqueKeysWithValues: project.components.map { ($0.id, $0) })
        for (i, p) in all.enumerated() {
            let r = find(i)
            let nid: Int
            if let existing = rootToNet[r] { nid = existing } else {
                nid = nets.count
                rootToNet[r] = nid
                nets.append(Net(id: nid, ports: [], names: [], drivers: [], sinks: [], hasExplicitLink: false))
            }
            nets[nid].ports.append(p)
            for n in nameOfPort[i] ?? [] where !nets[nid].names.contains(n) { nets[nid].names.append(n) }
            if linked.contains(i) { nets[nid].hasExplicitLink = true }
            if let c = comps[p.comp], c.isOutputPort(p.port) { nets[nid].drivers.append(p) } else { nets[nid].sinks.append(p) }
            netOf[p] = nid
        }
    }

    /// Preferred printable name: input pin, then output pin, then a label, then a generated name.
    func netName(_ id: Int, project: Project) -> String {
        let net = nets[id]
        for p in net.ports {
            if let c = project.component(p.comp), c.kind == .input { return c.name }
        }
        for p in net.ports {
            if let c = project.component(p.comp), c.kind == .output { return c.name }
        }
        if let n = net.names.first { return n }
        // Automatic labels must not join a different named net or collide with a
        // Verilog instance. Reserve every user name, including unused labels.
        let used = Set(project.components.map { $0.name.lowercased() }
                       + project.labels.values.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let base = "qz_net\(id)"
        var name = base, suffix = 1
        while used.contains(name.lowercased()) { name = "\(base)_\(suffix)"; suffix += 1 }
        return name
    }
}

struct CompiledCircuit {
    var conn: Connectivity
    var inputs: [Component]
    var outputs: [Component]
    var gateOrder: [Component]
    var stats: Stats

    struct Stats {
        var gates = 0
        var inverters = 0
        var inputInverters = 0
        var gateInputs = 0
        var cost: Int { gates + gateInputs }
        var costWithoutInputInverters: Int { (gates - inputInverters) + (gateInputs - inputInverters) }
    }

    func evaluate(_ inputBits: [Bool]) -> (outputs: [Bool], nets: [Int: Bool]) {
        var value: [Int: Bool] = [:]
        for (pin, bit) in zip(inputs, inputBits) {
            if let n = conn.netOf[PortRef(comp: pin.id, port: 0)] { value[n] = bit }
        }
        for g in gateOrder {
            assert(!g.kind.isHierarchical, "blocks and macros are flattened before evaluation")
            let ins = (0..<g.kind.arity).map { i -> Bool in
                guard let n = conn.netOf[PortRef(comp: g.id, port: i)] else { return false }
                return value[n] ?? false
            }
            if let n = conn.netOf[PortRef(comp: g.id, port: g.kind.arity)] { value[n] = g.kind.evaluate(ins) }
        }
        let outs = outputs.map { o -> Bool in
            guard let n = conn.netOf[PortRef(comp: o.id, port: 0)] else { return false }
            return value[n] ?? false
        }
        return (outs, value)
    }
}

enum Compiler {
    /// Verilog, VHDL and AHDL keywords plus Quartus primitive names; any of these as a node name
    /// can break Quartus' generated netlists, so they are rejected up front.
    static let reserved: Set<String> = [
        // Verilog
        "and", "or", "not", "nand", "nor", "xor", "xnor", "buf", "bufif0", "bufif1", "notif0", "notif1",
        "module", "endmodule", "input", "output", "inout", "wire", "reg", "tri", "supply0", "supply1",
        "assign", "begin", "end", "if", "else", "case", "endcase", "always", "initial", "integer", "real",
        "parameter", "localparam", "for", "while", "repeat", "forever", "task", "function", "endfunction",
        "posedge", "negedge", "default", "generate", "genvar", "time", "event", "logic",
        // VHDL
        "entity", "signal", "is", "in", "out", "port", "architecture", "of", "library", "use", "all",
        "constant", "variable", "process", "then", "elsif", "when", "others", "to", "downto", "map", "mod", "rem",
        "abs", "new", "null", "open", "range", "record", "select", "type", "until", "wait", "with",
        "bus", "buffer", "component", "configuration", "file", "loop", "next", "on", "return", "shared", "sla",
        "sll", "sra", "srl", "subtype", "transport", "units", "access", "after", "alias", "array", "assert",
        "attribute", "block", "body", "disconnect", "exit", "group", "guarded", "impure", "inertial", "label",
        "linkage", "literal", "package", "postponed", "procedure", "pure", "register", "reject", "report", "ror", "rol",
        // AHDL / Quartus
        "gnd", "vcc", "node", "table", "design", "device", "title", "subdesign", "bidir", "bits", "buried",
        "clique", "defaults", "define", "div", "include", "machine", "options", "parameters", "require",
        "returns", "segments", "severity", "states", "tri_state_node", "connected_pins", "help_id", "log2",
        "and2", "and3", "and4", "or2", "or3", "or4", "nand2", "nand3", "nand4", "nor2", "nor3", "nor4",
        "dff", "tff", "jkff", "srff", "latch", "lcell", "global", "carry", "cascade", "soft", "exp", "opndrn",
    ]

    static func isValidName(_ s: String) -> Bool {
        guard let f = s.first, f.isASCII, f.isLetter else { return false }
        return s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    static func compile(_ project: Project, checkLocations: Bool = true) -> (CompiledCircuit?, [Message]) {
        var msgs: [Message] = []
        func err(_ t: String, _ c: UUID? = nil) { msgs.append(Message(level: .error, text: t, component: c)) }
        func warn(_ t: String, _ c: UUID? = nil) { msgs.append(Message(level: .warning, text: t, component: c)) }
        func info(_ t: String) { msgs.append(Message(level: .info, text: t)) }

        info("Checking \(project.entityName) for device \(project.device) (Cyclone V, DE10-Standard)")
        let structuralErrors = project.structuralErrors
        if !structuralErrors.isEmpty {
            structuralErrors.forEach { err($0) }
            return (nil, msgs)
        }
        if !project.device.hasPrefix("5C") || !project.device.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            err("Device '\(project.device)' must be a Cyclone V device code (for example 5CSXFC6D6F31C6)")
        }
        let conn = Connectivity(project)
        let pins = project.components.filter { $0.kind.isPin }
        let inputs = project.inputPins
        let outputs = project.outputPins

        if inputs.isEmpty { err("The design has no input pins") }
        if outputs.isEmpty { err("The design has no output pins") }

        // Names
        var seen: [String: Component] = [:]
        for p in pins {
            let n = p.name.trimmingCharacters(in: .whitespaces)
            if n.isEmpty { err("A \(p.kind.displayName.lowercased()) has no name", p.id); continue }
            if !isValidName(p.name) { err("Pin name '\(p.name)' is not a valid identifier (letters, digits, _; must start with a letter)", p.id) }
            if reserved.contains(n.lowercased()) { err("Pin name '\(n)' is a reserved word", p.id) }
            if let other = seen[n.lowercased()] {
                err("Pin name '\(n)' is used more than once (\(other.name))", p.id)
            }
            seen[n.lowercased()] = p
            if n.caseInsensitiveCompare(project.entityName) == .orderedSame {
                err("Pin name '\(n)' is the same as the top-level entity name", p.id)
            }
        }
        for (key, raw) in project.labels {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            let owner = UUID(uuidString: String(key.split(separator: "#").first ?? ""))
            if !isValidName(n) { err("Net label '\(n)' is not a valid identifier", owner) }
            if reserved.contains(n.lowercased()) { err("Net label '\(n)' is a reserved word", owner) }
        }
        var gateNames = Set<String>()
        var labelNames = Set<String>()
        for raw in project.labels.values {
            let n = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !n.isEmpty { labelNames.insert(n) }
        }
        for g in project.components where !g.kind.isPin {
            if !isValidName(g.name) { err("Instance name '\(g.name)' is not a valid identifier", g.id) }
            if reserved.contains(g.name.lowercased()) { err("Instance name '\(g.name)' is a reserved word", g.id) }
            if labelNames.contains(g.name.lowercased()) { err("Instance name '\(g.name)' is also used as a net label", g.id) }
            if !gateNames.insert(g.name.lowercased()).inserted { err("Instance name '\(g.name)' is used more than once", g.id) }
            if seen[g.name.lowercased()] != nil { err("Instance name '\(g.name)' clashes with a pin name", g.id) }
        }

        // Names that differ only in capitalisation are ambiguous in Quartus.
        var spellings: [String: Set<String>] = [:]
        for p in pins { spellings[p.name.lowercased(), default: []].insert(p.name) }
        for raw in project.labels.values {
            let n = raw.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { spellings[n.lowercased(), default: []].insert(n) }
        }
        for (_, s) in spellings where s.count > 1 {
            err("Names \(s.sorted().map { "'\($0)'" }.joined(separator: " and ")) differ only in capitalisation. Quartus may treat them as the same node; use one spelling.")
        }

        // Connectivity checks
        func describe(_ p: PortRef) -> String {
            guard let c = project.component(p.comp) else { return "?" }
            if c.kind.isPin { return "pin '\(c.name)'" }
            return "\(c.name) (\(c.symbolName)).\(c.portName(p.port))"
        }
        for (a, b) in conn.touching {
            warn("\(describe(a)) and \(describe(b)) sit on the same point, so they are connected. Move one if that wasn't intended.", a.comp)
        }
        for net in conn.nets {
            let name = conn.netName(net.id, project: project)
            let distinct = Set(net.names)
            if distinct.count > 1 {
                warn("Net carries several names (\(distinct.sorted().joined(separator: ", "))). Quartus may reject a node with two names; use one label per wire.",
                     net.ports.first?.comp)
            }
            if net.drivers.count > 1 {
                err("Net '\(name)' has \(net.drivers.count) drivers: \(net.drivers.map(describe).joined(separator: ", "))",
                    net.drivers.first?.comp)
            }
            if net.drivers.isEmpty {
                for s in net.sinks {
                    guard let c = project.component(s.comp) else { continue }
                    if c.kind == .output { err("Output pin '\(c.name)' is not driven by anything", c.id) }
                    else { err("Input \(c.portName(s.port)) of \(c.name) (\(c.symbolName)) is not connected", c.id) }
                }
            } else if net.sinks.isEmpty {
                for d in net.drivers {
                    guard let c = project.component(d.comp) else { continue }
                    if c.kind == .input { warn("Input pin '\(c.name)' does not drive any logic", c.id) }
                    else { warn("Output of \(c.name) (\(c.symbolName)) is not used", c.id) }
                }
            }
        }

        // Locations
        var locSeen: [String: Component] = [:]
        for p in pins where checkLocations {
            guard let loc = p.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else {
                warn("Pin '\(p.name)' has no location assignment. Quartus will pick a random pin, so the switch/LED will not work.", p.id)
                continue
            }
            if loc.uppercased().range(of: "^PIN_[A-Z]+[0-9]+$", options: .regularExpression) == nil { err("Location '\(loc)' for '\(p.name)' should look like PIN_AB30", p.id) }
            if let other = locSeen[loc.uppercased()] { err("Pins '\(other.name)' and '\(p.name)' are both assigned to \(loc)", p.id) }
            locSeen[loc.uppercased()] = p
            if let bp = BoardPin.lookup(loc), bp.isInput != (p.kind == .input) {
                warn("'\(p.name)' is an \(p.kind == .input ? "input" : "output") but \(loc) is \(bp.label)", p.id)
            }
        }

        // Topological order of gates (detects combinational loops).
        let gates = project.components.filter { !$0.kind.isPin }
        var driverGateOfNet: [Int: UUID] = [:]
        for g in gates { if let n = conn.netOf[PortRef(comp: g.id, port: g.kind.arity)] { driverGateOfNet[n] = g.id } }
        var indeg: [UUID: Int] = [:]
        var dependents: [UUID: [UUID]] = [:]
        for g in gates {
            indeg[g.id] = 0
        }
        for g in gates {
            for i in 0..<g.kind.arity {
                if let n = conn.netOf[PortRef(comp: g.id, port: i)], let d = driverGateOfNet[n] {
                    indeg[g.id, default: 0] += 1
                    dependents[d, default: []].append(g.id)
                }
            }
        }
        var queue = gates.filter { indeg[$0.id] == 0 }.map { $0.id }
        var order: [UUID] = []
        while let id = queue.first {
            queue.removeFirst()
            order.append(id)
            for dep in dependents[id] ?? [] {
                indeg[dep]! -= 1
                if indeg[dep] == 0 { queue.append(dep) }
            }
        }
        if order.count < gates.count {
            let stuck = gates.filter { !order.contains($0.id) }.map { $0.name }
            err("Combinational loop detected through: \(stuck.joined(separator: ", "))", gates.first { !order.contains($0.id) }?.id)
        }

        var stats = CompiledCircuit.Stats()
        for g in gates where g.kind.isGate {
            stats.gates += 1
            stats.gateInputs += g.kind.arity
            if g.kind == .not {
                stats.inverters += 1
                if let n = conn.netOf[PortRef(comp: g.id, port: 0)],
                   conn.nets[n].drivers.contains(where: { project.component($0.comp)?.kind == .input }) {
                    stats.inputInverters += 1
                }
            }
        }

        let errors = msgs.filter { $0.level == .error }.count
        let warnings = msgs.filter { $0.level == .warning }.count
        info("Logic: \(stats.gates) gates (\(stats.inverters) NOT), \(stats.gateInputs) gate inputs, \(inputs.count) input pins, \(outputs.count) output pins")
        info("Cost = gates + gate inputs = \(stats.cost)  (not counting the \(stats.inputInverters) input inverters: \(stats.costWithoutInputInverters))")
        if errors == 0 {
            info("Design check passed: \(errors) errors, \(warnings) warnings")
        } else {
            msgs.append(Message(level: .error, text: "Design check failed: \(errors) errors, \(warnings) warnings"))
        }
        let byID = Dictionary(uniqueKeysWithValues: gates.map { ($0.id, $0) })
        let circuit = errors == 0
            ? CompiledCircuit(conn: conn, inputs: inputs, outputs: outputs, gateOrder: order.compactMap { byID[$0] }, stats: stats)
            : nil
        return (circuit, msgs)
    }
}

struct SimulationResult {
    var inputNames: [String]
    var outputNames: [String]
    var outputIDs: [UUID]
    /// rows[i] = (input bits MSB first, outputs)
    var rows: [(inputs: [Bool], outputs: [Bool])]
    var expected: [Set<Int>?]
    var invalidExpected: Set<UUID> = []

    static let maxInputs = 10

    static func validateInputCount(_ n: Int) throws {
        guard (0...maxInputs).contains(n) else {
            throw NSError(domain: "Quartzite", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Exhaustive simulation and waveform export are limited to \(maxInputs) inputs (\(n) found)"])
        }
    }

    var inputCount: Int { inputNames.count }

    func matches(output o: Int) -> Bool? {
        if invalidExpected.contains(outputIDs[o]) { return false }
        guard let exp = expected[o] else { return nil }
        return exp.allSatisfy { rows.indices.contains($0) }
            && rows.indices.allSatisfy { rows[$0].outputs[o] == exp.contains($0) }
    }

    static func run(_ circuit: CompiledCircuit, project: Project) throws -> SimulationResult {
        let n = circuit.inputs.count
        try validateInputCount(n)
        var rows: [(inputs: [Bool], outputs: [Bool])] = []
        for i in 0..<(1 << n) {
            let bits = (0..<n).map { k in (i >> (n - 1 - k)) & 1 == 1 }
            rows.append((bits, circuit.evaluate(bits).outputs))
        }
        return SimulationResult(inputNames: circuit.inputs.map { $0.name },
                                outputNames: circuit.outputs.map { $0.name },
                                outputIDs: circuit.outputs.map { $0.id },
                                rows: rows,
                                expected: circuit.outputs.map { Minterms.parse(project.expected[$0.id.uuidString] ?? "") },
                                invalidExpected: Set(circuit.outputs.compactMap { output in
                                    let text = project.expected[output.id.uuidString] ?? ""
                                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Minterms.parse(text) == nil ? output.id : nil
                                }))
    }
}

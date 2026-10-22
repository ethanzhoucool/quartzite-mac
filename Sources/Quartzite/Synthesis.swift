import Foundation

/// A network of Cyclone V 6-input LUTs (one `cyclonev_lcell_comb` in normal mode each).
struct LUTNetwork {
    enum Signal: Hashable {
        case constant(Bool)
        case input(Int)      // input pin index (circuit.inputs order, MSB first)
        case lut(Int)
    }

    struct LUT {
        var name: String
        var inputs: [Signal]          // dataa, datab, ... in order
        /// Local truth table: bit j of the index is the value of inputs[j].
        var table: UInt64
        var level: Int
        var drivesOutputs: [Int] = []

        /// The 64-bit mask as Quartus encodes `lut_mask` with inputs on dataa, datab, ...
        var mask: UInt64 { LUTMask.replicate(table, inputs: inputs.count) }
        static let ports = ["dataa", "datab", "datac", "datad", "datae", "dataf"]
    }

    var inputNames: [String]
    var outputNames: [String]
    var luts: [LUT] = []
    var outputs: [Signal] = []

    func name(of s: Signal) -> String {
        switch s {
        case .constant(let v): return v ? "VCC" : "GND"
        case .input(let k): return inputNames[k]
        case .lut(let i): return luts[i].name
        }
    }

    /// Evaluates every LUT for one input vector (LUTs are stored in topological order).
    func evaluate(_ bits: [Bool]) -> (outputs: [Bool], luts: [Bool]) {
        var vals = [Bool](repeating: false, count: luts.count)
        func value(_ s: Signal) -> Bool {
            switch s {
            case .constant(let v): return v
            case .input(let k): return bits[k]
            case .lut(let i): return vals[i]
            }
        }
        for (i, l) in luts.enumerated() {
            var idx = 0
            for (j, s) in l.inputs.enumerated() where value(s) { idx |= 1 << j }
            vals[i] = (l.table >> UInt64(idx)) & 1 == 1
        }
        return (outputs.map(value), vals)
    }

    /// Minimized equation of LUT i in terms of its inputs, Quartus notation.
    func equation(_ i: Int) -> String {
        let l = luts[i]
        let k = l.inputs.count
        // Put inputs[0] at the highest position so the equation reads in port order.
        let tt = TruthTable(n: k) { m in
            var idx = 0
            for j in 0..<k where (m >> (k - 1 - j)) & 1 == 1 { idx |= 1 << j }
            return (l.table >> UInt64(idx)) & 1 == 1
        }
        let names = (0..<k).map { p in name(of: l.inputs[k - 1 - p]) }
        return Equation.sop(Minimizer.minimize(on: tt).cubes, names: names)
    }

    var depth: Int { luts.map { $0.level }.max() ?? 0 }
}

/// Everything Analysis & Synthesis derives from an elaborated circuit.
struct SynthesisResult {
    struct OutputFunction {
        var name: String
        var id: UUID
        var table: TruthTable            // over all inputs (input k at bit n-1-k)
        var support: [Int]               // input indices the output depends on
        var minimized: Bool              // false if the support was too large to minimize
        var exact: Bool
        var method: String
        var primeCount: Int
        var sop: [Cube]                  // cubes over all inputs' bit positions
        var posOff: [Cube]               // OFF-set cubes; each is one POS sum
        var sopEquation: String
        var posEquation: String
        var textbookSOP: String
        var textbookPOS: String
        var sopCost: (gates: Int, inputs: Int)
        var posCost: (gates: Int, inputs: Int)
        var driver: LUTNetwork.Signal
        var constant: Bool? { table.constantValue }
    }

    struct RemovedGate {
        enum Reason { case noFanout, constant(Bool), passThrough(String), duplicate(String), equalsInput(String, inverted: Bool) }
        var name: String
        var kind: GateKind
        var id: UUID
        var reason: Reason

        var explanation: String {
            switch reason {
            case .noFanout: return "does not feed any output pin"
            case .constant(let v): return "output is always \(v ? 1 : 0) (stuck at \(v ? "VCC" : "GND"))"
            case .passThrough(let n): return "output always equals its input \(n)"
            case .duplicate(let g): return "computes the same function as \(g)"
            case .equalsInput(let n, let inv): return "output always equals \(inv ? "NOT " : "")input pin \(n)"
            }
        }
    }

    struct Resources {
        var lutsByInputs: [Int: Int]     // 6, 5, 4, 3 (meaning <= 3)
        var luts: Int
        var alms: Int
        var almPacking: [[Int]]          // LUT indices per ALM
        var inputPins: Int
        var outputPins: Int
        var maxFanoutNode: String
        var maxFanout: Int
        var totalFanout: Int
        var averageFanout: Double
        var deviceResources: Int { inputPins + outputPins + luts }
    }

    var inputNames: [String]
    var outputs: [OutputFunction]
    var network: LUTNetwork
    var removed: [RemovedGate]
    var unusedInputs: [String]
    var sharedTerms: [(term: String, outputs: [String])]
    var resources: Resources
    var schematicGates: Int
    var schematicGateInputs: Int

    var names: Equation.Names { (0..<inputNames.count).map { inputNames[inputNames.count - 1 - $0] } }
}

enum Synthesizer {
    /// Largest support that is minimized exactly (2^12 minterms).
    static let minimizeLimit = 12

    enum Failure: Error, CustomStringConvertible {
        case tooManyInputs(Int)
        var description: String {
            switch self {
            case .tooManyInputs(let n):
                return "Quartzite synthesis supports up to \(TruthTable.maxInputs) input pins; the design has \(n)"
            }
        }
    }

    /// Truth table of every net, computed gate by gate (unconnected gate inputs read 0,
    /// as in the schematic simulator).
    static func netTables(_ c: CompiledCircuit) -> [Int: TruthTable] {
        let n = c.inputs.count
        var t: [Int: TruthTable] = [:]
        for (k, pin) in c.inputs.enumerated() {
            if let net = c.conn.netOf[PortRef(comp: pin.id, port: 0)] { t[net] = .variable(n - 1 - k, n: n) }
        }
        let zero = TruthTable(n: n)
        for g in c.gateOrder {
            assert(!g.kind.isHierarchical, "blocks and macros are flattened before synthesis")
            let ins = (0..<g.kind.arity).map { i -> TruthTable in
                guard let net = c.conn.netOf[PortRef(comp: g.id, port: i)] else { return zero }
                return t[net] ?? zero
            }
            let r: TruthTable
            switch g.kind.family {
            case .not: r = !ins[0]
            case .and: r = ins.dropFirst().reduce(ins[0], &)
            case .or: r = ins.dropFirst().reduce(ins[0], |)
            case .nand: r = !ins.dropFirst().reduce(ins[0], &)
            case .nor: r = !ins.dropFirst().reduce(ins[0], |)
            case .xor, .xnor:
                var x = TruthTable(n: n)
                for m in 0..<x.size { x[m] = ins.filter { $0[m] }.count % 2 == 1 }
                r = g.kind.family == .xor ? x : !x
            case .pinIn, .pinOut: r = ins.first ?? zero
            case .vcc: r = !zero
            case .gnd, .symbol: r = zero
            }
            if let net = c.conn.netOf[PortRef(comp: g.id, port: g.kind.arity)] { t[net] = r }
        }
        return t
    }

    static func outputTables(_ c: CompiledCircuit) -> [TruthTable] {
        let t = netTables(c)
        let zero = TruthTable(n: c.inputs.count)
        return c.outputs.map { o in c.conn.netOf[PortRef(comp: o.id, port: 0)].flatMap { t[$0] } ?? zero }
    }

    static func run(_ c: CompiledCircuit, project: Project) throws -> SynthesisResult {
        let n = c.inputs.count
        guard n <= TruthTable.maxInputs else { throw Failure.tooManyInputs(n) }
        let inputNames = c.inputs.map { $0.name }
        let names: Equation.Names = (0..<n).map { inputNames[n - 1 - $0] }
        let tables = netTables(c)
        let zero = TruthTable(n: n)
        let outTables = c.outputs.map { o in c.conn.netOf[PortRef(comp: o.id, port: 0)].flatMap { tables[$0] } ?? zero }

        // Redundant gates.
        let removed = redundantGates(c, tables: tables, project: project)

        // Two-level minimization per output, over its support, one output per thread.
        var results = [SynthesisResult.OutputFunction?](repeating: nil, count: c.outputs.count)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: c.outputs.count) { i in
                let o = c.outputs[i]
                buf[i] = minimizeOutput(outTables[i], name: o.name, id: o.id, n: n, names: names)
            }
        }
        var outs = results.map { $0! }

        // Technology mapping to 6-input LUTs.
        var mapper = LUTMapper(n: n, inputNames: inputNames)
        for (i, o) in outs.enumerated() {
            let s = mapper.signal(for: o.table, owner: o.name)
            outs[i].driver = s
            if case .lut(let li) = s { mapper.luts[li].drivesOutputs.append(i) }
        }
        var net = LUTNetwork(inputNames: inputNames, outputNames: c.outputs.map { $0.name })
        net.luts = mapper.luts
        net.outputs = outs.map { $0.driver }

        // Inputs no output depends on.
        let used = Set(outs.flatMap { $0.support })
        let unused = inputNames.indices.filter { !used.contains($0) }.map { inputNames[$0] }

        // Product terms shared by several outputs' minimal SOPs.
        var termOwners: [Cube: [String]] = [:]
        for o in outs where o.minimized && o.constant == nil {
            for cube in o.sop where cube.literalCount > 1 { termOwners[cube, default: []].append(o.name) }
        }
        let shared = termOwners.filter { $0.value.count > 1 }.keys.sorted()
            .map { (term: Equation.sop([$0], names: names), outputs: termOwners[$0]!) }

        var gates = 0, gateInputs = 0
        for g in c.gateOrder where g.kind.isGate && !c.generated.contains(g.id) { gates += 1; gateInputs += g.kind.arity }

        return SynthesisResult(inputNames: inputNames, outputs: outs, network: net, removed: removed,
                               unusedInputs: unused, sharedTerms: shared,
                               resources: resources(net, inputs: n, outputs: c.outputs.count),
                               schematicGates: gates, schematicGateInputs: gateInputs)
    }

    /// Minimal SOP and POS of one output over its support. Outputs that depend on more than
    /// 8 inputs are minimized with `Minimizer.wideLimits`.
    static func minimizeOutput(_ f: TruthTable, name: String, id: UUID, n: Int, names: Equation.Names) -> SynthesisResult.OutputFunction {
        let supportBits = f.support
        let support = supportBits.map { n - 1 - $0 }
        var sop: [Cube] = [], off: [Cube] = []
        var exact = true, minimized = true, method = "", primes = 0
        if let v = f.constantValue {
            sop = v ? [Cube(value: 0, care: 0)] : []
            off = v ? [] : [Cube(value: 0, care: 0)]
            method = "constant"
        } else if supportBits.count <= minimizeLimit {
            let k = supportBits.count
            // Local function over the support, local bit j = global bit supportBits[k-1-j].
            func local(_ g: TruthTable) -> TruthTable {
                TruthTable(n: k) { m in
                    var gm = 0
                    for j in 0..<k where (m >> j) & 1 == 1 { gm |= 1 << supportBits[k - 1 - j] }
                    return g[gm]
                }
            }
            func lift(_ cube: Cube) -> Cube {
                var v: UInt32 = 0, care: UInt32 = 0
                for j in 0..<k where cube.care & (1 << UInt32(j)) != 0 {
                    let gb = UInt32(1) << UInt32(supportBits[k - 1 - j])
                    care |= gb
                    if cube.value & (1 << UInt32(j)) != 0 { v |= gb }
                }
                return Cube(value: v, care: care)
            }
            let lf = local(f)
            let limits = k > 8 ? Minimizer.wideLimits : nil
            let r = Minimizer.minimize(on: lf, limits: limits)
            let rOff = Minimizer.minimize(on: !lf, limits: limits)
            sop = r.cubes.map(lift).sorted()
            off = rOff.cubes.map(lift).sorted()
            exact = r.exact && rOff.exact
            method = r.method
            primes = r.primeCount
        } else {
            minimized = false
            exact = false
            method = "not minimized (depends on \(supportBits.count) inputs; limit \(minimizeLimit))"
        }
        return SynthesisResult.OutputFunction(
            name: name, id: id, table: f, support: support, minimized: minimized, exact: exact, method: method,
            primeCount: primes, sop: sop, posOff: off,
            sopEquation: minimized ? Equation.sop(sop, names: names) : "(not minimized)",
            posEquation: minimized ? Equation.pos(offCubes: off, names: names) : "(not minimized)",
            textbookSOP: minimized ? Equation.textbookSOP(sop, names: names) : "",
            textbookPOS: minimized ? Equation.textbookPOS(offCubes: off, names: names) : "",
            sopCost: Equation.cost(sop, pos: false, bits: n), posCost: Equation.cost(off, pos: true, bits: n),
            driver: .constant(false))
    }

    // MARK: - Redundant logic

    static func redundantGates(_ c: CompiledCircuit, tables: [Int: TruthTable], project: Project) -> [SynthesisResult.RemovedGate] {
        let n = c.inputs.count
        var driverOfNet: [Int: Component] = [:]
        for g in c.gateOrder { if let net = c.conn.netOf[PortRef(comp: g.id, port: g.kind.arity)] { driverOfNet[net] = g } }
        // Gates in the fan-in cone of an output pin.
        var live = Set<UUID>()
        var stack = c.outputs.compactMap { c.conn.netOf[PortRef(comp: $0.id, port: 0)] }
        var seenNets = Set<Int>()
        while let net = stack.popLast() {
            guard seenNets.insert(net).inserted, let g = driverOfNet[net] else { continue }
            live.insert(g.id)
            for i in 0..<g.kind.arity { if let m = c.conn.netOf[PortRef(comp: g.id, port: i)] { stack.append(m) } }
        }
        var removed: [SynthesisResult.RemovedGate] = []
        var earlier: [(TruthTable, String)] = []
        let zero = TruthTable(n: n)
        for g in c.gateOrder where g.kind.isGate {
            let gname = c.displayNames[g.id] ?? g.name
            guard !c.generated.contains(g.id) else { continue }
            guard live.contains(g.id) else {
                removed.append(.init(name: gname, kind: g.kind, id: g.id, reason: .noFanout))
                continue
            }
            guard let outNet = c.conn.netOf[PortRef(comp: g.id, port: g.kind.arity)] else { continue }
            let f = tables[outNet] ?? zero
            let inNets = (0..<g.kind.arity).compactMap { c.conn.netOf[PortRef(comp: g.id, port: $0)] }
            var reason: SynthesisResult.RemovedGate.Reason?
            if let v = f.constantValue {
                reason = .constant(v)
            } else if let same = inNets.first(where: { tables[$0] == f }) {
                reason = .passThrough(c.conn.netName(same, project: project))
            } else if let dup = earlier.first(where: { $0.0 == f }) {
                reason = .duplicate(dup.1)
            } else if let k = (0..<n).first(where: { f == .variable(n - 1 - $0, n: n) }) {
                reason = .equalsInput(c.inputs[k].name, inverted: false)
            } else if g.kind.family != .not, let k = (0..<n).first(where: { f == !TruthTable.variable(n - 1 - $0, n: n) }) {
                reason = .equalsInput(c.inputs[k].name, inverted: true)
            }
            if let reason { removed.append(.init(name: gname, kind: g.kind, id: g.id, reason: reason)) }
            earlier.append((f, gname))
        }
        return removed
    }

    // MARK: - Resources

    /// Pairs LUTs into ALMs. A Cyclone V ALM in normal mode holds one function of up to six
    /// inputs, or two functions of up to five inputs each that together use at most the
    /// ALM's eight data inputs (4+4, 5+3, 5+4 sharing one, 5+5 sharing two).
    static func packALMs(_ luts: [LUTNetwork.LUT]) -> [[Int]] {
        let order = luts.indices.sorted { luts[$0].inputs.count != luts[$1].inputs.count ? luts[$0].inputs.count > luts[$1].inputs.count : $0 < $1 }
        var placed = Set<Int>()
        var alms: [[Int]] = []
        func signals(_ i: Int) -> Set<LUTNetwork.Signal> { Set(luts[i].inputs.filter { if case .constant = $0 { return false } else { return true } }) }
        for i in order where !placed.contains(i) {
            placed.insert(i)
            guard luts[i].inputs.count <= 5 else { alms.append([i]); continue }
            let si = signals(i)
            var best: Int?
            var bestShared = -1
            for j in order where !placed.contains(j) && luts[j].inputs.count <= 5 {
                let sj = signals(j)
                guard si.union(sj).count <= 8 else { continue }
                let shared = si.intersection(sj).count
                if shared > bestShared { best = j; bestShared = shared }
            }
            if let j = best { placed.insert(j); alms.append([i, j]) } else { alms.append([i]) }
        }
        return alms
    }

    static func resources(_ net: LUTNetwork, inputs: Int, outputs: Int) -> SynthesisResult.Resources {
        var byInputs: [Int: Int] = [6: 0, 5: 0, 4: 0, 3: 0]
        for l in net.luts { byInputs[min(6, max(3, l.inputs.count)), default: 0] += 1 }
        let packing = packALMs(net.luts)
        var fanout: [LUTNetwork.Signal: Int] = [:]
        for l in net.luts { for s in l.inputs { if case .constant = s { continue }; fanout[s, default: 0] += 1 } }
        for s in net.outputs { if case .constant = s { continue }; fanout[s, default: 0] += 1 }
        let total = fanout.values.reduce(0, +)
        var nodes: [(String, Int)] = (0..<inputs).map { ("\(net.inputNames[$0])~input", fanout[.input($0)] ?? 0) }
        nodes += net.luts.indices.map { (net.luts[$0].name, fanout[.lut($0)] ?? 0) }
        let maxNode = nodes.max { $0.1 < $1.1 } ?? ("", 0)
        let nodeCount = inputs + net.luts.count
        return SynthesisResult.Resources(
            lutsByInputs: byInputs, luts: net.luts.count, alms: packing.count, almPacking: packing,
            inputPins: inputs, outputPins: outputs, maxFanoutNode: maxNode.0, maxFanout: maxNode.1,
            totalFanout: total, averageFanout: nodeCount == 0 ? 0 : Double(total) / Double(nodeCount))
    }
}

/// Maps truth tables onto 6-input LUTs: functions of up to six inputs become one LUT;
/// larger ones are split by Shannon expansion on one or two variables, with the cofactors
/// mapped recursively and a final LUT selecting between them. Identical LUTs are shared.
struct LUTMapper {
    let n: Int
    let inputNames: [String]
    var luts: [LUTNetwork.LUT] = []
    private var index: [Key: Int] = [:]
    private var costMemo: [TruthTable: Int] = [:]
    private var counters: [String: Int] = [:]

    private struct Key: Hashable { var inputs: [LUTNetwork.Signal]; var table: UInt64 }

    init(n: Int, inputNames: [String]) {
        self.n = n
        self.inputNames = inputNames
    }

    private func input(_ bit: Int) -> LUTNetwork.Signal { .input(n - 1 - bit) }

    mutating func signal(for f: TruthTable, owner: String) -> LUTNetwork.Signal {
        if let v = f.constantValue { return .constant(v) }
        let sup = f.support
        if sup.count == 1 && f == .variable(sup[0], n: n) { return input(sup[0]) }
        if sup.count <= 6 {
            var table: UInt64 = 0
            for idx in 0..<(1 << sup.count) {
                var m = 0
                for (j, b) in sup.enumerated() where (idx >> j) & 1 == 1 { m |= 1 << b }
                if f[m] { table |= 1 << UInt64(idx) }
            }
            return lut(inputs: sup.map(input), table: table, owner: owner)
        }
        let split = chooseSplit(f, sup)
        var cof: [LUTNetwork.Signal] = []
        for a in 0..<(1 << split.count) {
            var g = f
            for (j, b) in split.enumerated() { g = g.cofactor(b, (a >> j) & 1 == 1) }
            cof.append(signal(for: g, owner: owner))
        }
        var data: [LUTNetwork.Signal] = []
        for s in cof { if case .constant = s { continue }; if !data.contains(s) { data.append(s) } }
        let inputs = split.map(input) + data
        var table: UInt64 = 0
        for idx in 0..<(1 << inputs.count) {
            let a = idx & ((1 << split.count) - 1)
            let v: Bool
            switch cof[a] {
            case .constant(let c): v = c
            default: v = (idx >> (split.count + data.firstIndex(of: cof[a])!)) & 1 == 1
            }
            if v { table |= 1 << UInt64(idx) }
        }
        return lut(inputs: inputs, table: table, owner: owner)
    }

    private mutating func lut(inputs: [LUTNetwork.Signal], table: UInt64, owner: String) -> LUTNetwork.Signal {
        let key = Key(inputs: inputs, table: table)
        if let i = index[key] { return .lut(i) }
        let k = counters[owner, default: 0]
        counters[owner] = k + 1
        let level = 1 + (inputs.compactMap { s -> Int? in if case .lut(let i) = s { return luts[i].level } else { return nil } }.max() ?? 0)
        luts.append(LUTNetwork.LUT(name: "\(owner)~\(k)", inputs: inputs, table: table, level: level))
        index[key] = luts.count - 1
        return .lut(luts.count - 1)
    }

    /// Estimated LUT count for f.
    private mutating func cost(_ f: TruthTable) -> Int {
        if f.constantValue != nil { return 0 }
        if let c = costMemo[f] { return c }
        let sup = f.support
        let c: Int
        if sup.count == 1 && f == .variable(sup[0], n: n) { c = 0 }
        else if sup.count <= 6 { c = 1 }
        else { c = splitCost(f, chooseSplit(f, sup)) }
        costMemo[f] = c
        return c
    }

    private mutating func splitCost(_ f: TruthTable, _ split: [Int]) -> Int {
        var seen = Set<TruthTable>()
        var total = 1
        for a in 0..<(1 << split.count) {
            var g = f
            for (j, b) in split.enumerated() { g = g.cofactor(b, (a >> j) & 1 == 1) }
            if seen.insert(g).inserted { total += cost(g) }
        }
        return total
    }

    private mutating func chooseSplit(_ f: TruthTable, _ sup: [Int]) -> [Int] {
        if sup.count > 12 { return [sup[0]] }
        var singles: [(Int, Int)] = []
        for b in sup { singles.append((splitCost(f, [b]), b)) }
        singles.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var best = (singles[0].0, [singles[0].1])
        if sup.count >= 8 {
            let top = singles.prefix(4).map { $0.1 }
            for i in top.indices { for j in top.indices where j > i {
                let pair = [top[i], top[j]]
                let c = splitCost(f, pair)
                if c < best.0 { best = (c, pair) }
            } }
        }
        return best.1
    }
}

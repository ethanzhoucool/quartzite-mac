import Foundation

/// Self-tests for the compiler: minimizer, LUT masks, technology mapping, Fitter and the
/// EDA netlist. Called from `SelfTest.run`.
enum CompilerSelfTest {
    /// Deterministic pseudo-random numbers so failures are reproducible.
    struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    }

    static func run(_ check: (Bool, String) -> Void) {
        print("LUT mask encoding")
        // Cyclone V lut_mask: bit i holds the output for dataa = bit 0 of i ... dataf = bit 5.
        // This convention was checked against a real Quartus 18.1 netlist during development.
        let single: [(Int, String)] = [(0, "64'hAAAAAAAAAAAAAAAA"), (1, "64'hCCCCCCCCCCCCCCCC"), (2, "64'hF0F0F0F0F0F0F0F0"),
                                       (3, "64'hFF00FF00FF00FF00"), (4, "64'hFFFF0000FFFF0000"), (5, "64'hFFFFFFFF00000000")]
        for (port, want) in single {
            var ports: [LUTMask.Port?] = Array(repeating: nil, count: 6)
            ports[port] = .init(variable: 0)
            let got = LUTMask.hex(LUTMask.mask(ports: ports) { $0 & 1 == 1 })
            check(got == want, "lut_mask of a single input on data\(["a", "b", "c", "d", "e", "f"][port]) is \(want) (got \(got))")
        }
        // Example f = Σm(2,3,6,7,9,13,14) with w as the MSB, mapped like Quartus maps inputs:
        // dataa = !y, datab = !x, datac = !z, datae = !w (inverted inputs, datad/dataf unused).
        let example: Set<UInt32> = [2, 3, 6, 7, 9, 13, 14]
        // Variables: w = bit 3, x = bit 2, y = bit 1, z = bit 0, so the assignment is the minterm number.
        let ports: [LUTMask.Port?] = [.init(variable: 1, inverted: true), .init(variable: 2, inverted: true),
                                      .init(variable: 0, inverted: true), nil, .init(variable: 3, inverted: true), nil]
        let mask = LUTMask.mask(ports: ports) { example.contains($0) }
        var expectMask: UInt64 = 0
        for i in 0..<64 {
            let a = i & 1, b = (i >> 1) & 1, c = (i >> 2) & 1, e = (i >> 4) & 1
            let m = (1 - e) << 3 | (1 - b) << 2 | (1 - a) << 1 | (1 - c)
            if example.contains(UInt32(m)) { expectMask |= 1 << UInt64(i) }
        }
        check(mask == expectMask, "inverted-input mask matches an independent derivation (\(LUTMask.hex(mask)))")
        // Same function with plain inputs on dataa..datad, as Quartzite maps it.
        let ttEx = TruthTable(n: 4, minterms: example.map { Int($0) })
        var local: UInt64 = 0
        for idx in 0..<16 {
            // dataa = w (bit 3) ... datad = z (bit 0)
            var m = 0
            for j in 0..<4 where (idx >> j) & 1 == 1 { m |= 1 << (3 - j) }
            if ttEx[m] { local |= 1 << UInt64(idx) }
        }
        let direct = LUTMask.mask(ports: [.init(variable: 3), .init(variable: 2), .init(variable: 1), .init(variable: 0), nil, nil]) { example.contains($0) }
        check(LUTMask.replicate(local, inputs: 4) == direct, "replicated local table equals the general mask encoder")

        print("Minimizer")
        let names = ["z", "y", "x", "w"]   // names[bit position]
        let rEx = Minimizer.minimize(on: ttEx)
        let sopTerms = Set(Equation.textbookSOP(rEx.cubes, names: names).components(separatedBy: " + "))
        check(sopTerms == ["w'y", "wy'z", "xyz'"], "example SOP = w'y + wy'z + xyz' (got \(Equation.textbookSOP(rEx.cubes, names: names)))")
        let quartusTerms = Set(Equation.sop(rEx.cubes, names: names).components(separatedBy: " # "))
        check(quartusTerms == ["(!w & y)", "(w & !y & z)", "(x & y & !z)"], "Quartus notation (got \(Equation.sop(rEx.cubes, names: names)))")
        let posEx = Minimizer.minimize(on: !ttEx)
        let posText = Equation.textbookPOS(offCubes: posEx.cubes, names: names)
        let posTerms = Set(posText.dropFirst().dropLast().components(separatedBy: ")("))
        // Two minimal POS forms exist: the fourth sum can be (w' + x + z) or (w' + x + y').
        let posCore: Set<String> = ["w + y", "y + z", "w' + y' + z'"]
        check(posTerms.count == 4 && posCore.isSubset(of: posTerms) && !posTerms.isDisjoint(with: ["w' + x + z", "w' + x + y'"]),
              "example POS has 4 sums: (w + y)(y + z)(w' + y' + z') and (w' + x + z) or (w' + x + y') (got \(posText))")
        let cEx = Equation.cost(rEx.cubes, pos: false, bits: 4)
        check(cEx.gates == 7 && cEx.inputs == 14, "example SOP cost 7 gates / 14 inputs (got \(cEx))")
        // Cyclic core (no essential primes) forces Petrick's method: Σm(0,1,2,5,6,7).
        let cyclic = TruthTable(n: 3, minterms: [0, 1, 2, 5, 6, 7])
        let rc = Minimizer.minimize(on: cyclic)
        check(rc.cubes.count == 3 && rc.essentialCount == 0 && rc.method.contains("Petrick"), "cyclic cover solved by Petrick's method (3 terms)")
        check(Minimizer.minimize(on: TruthTable(n: 3)).cubes.isEmpty && Equation.sop([], names: names) == "GND", "constant 0 is GND")
        check(Equation.sop(Minimizer.minimize(on: .constant(true, n: 3)).cubes, names: names) == "VCC", "constant 1 is VCC")

        // Random functions: the cover must equal the function, and for 3 and 4 inputs its
        // term count must match a brute-force minimum over all subsets of primes.
        var rng = LCG(s: 2277)
        var coverOK = true, minimalOK = true, exactOK = true
        for trial in 0..<300 {
            let n = trial < 200 ? 3 + trial % 2 : 5 + trial % 6      // 3..4 brute-forced, 5..10 checked
            var f = TruthTable(n: n)
            let density: UInt64 = n <= 7 ? 2 : 4
            for m in 0..<f.size where rng.next() % density == 0 { f[m] = true }
            let r = Minimizer.minimize(on: f)
            let back = TruthTable(n: n) { m in r.cubes.contains { $0.covers(m) } }
            if back != f { coverOK = false }
            if !r.exact { exactOK = false; print("    note: inexact cover for a random \(n)-input function (\(r.method))") }
            if n <= 4, !f.isZero, Minimizer.primeImplicants(on: f).count <= 16 {
                let primes = Minimizer.primeImplicants(on: f)
                var best = Int.max
                for subset in 1..<(1 << primes.count) where subset.nonzeroBitCount < best {
                    let chosen = primes.indices.filter { subset >> $0 & 1 == 1 }.map { primes[$0] }
                    if f.minterms.allSatisfy({ m in chosen.contains { $0.covers(m) } }) { best = subset.nonzeroBitCount }
                }
                if f.isOne { best = 1 }
                if r.cubes.count != best { minimalOK = false }
            }
        }
        check(coverOK, "300 random functions (3-10 inputs): minimized SOP equals the function")
        check(minimalOK, "200 random 3-4 input functions: term count equals brute-force minimum")
        check(exactOK, "random functions (5-7 inputs dense, 8-10 inputs sparse) solved exactly")

        print("Technology mapping")
        var mapOK = true, sizeOK = true
        for trial in 0..<24 {
            let n = 4 + trial % 7            // 4..10 inputs
            var f = TruthTable(n: n)
            for m in 0..<f.size where rng.next() % 3 == 0 { f[m] = true }
            var mapper = LUTMapper(n: n, inputNames: (0..<n).map { "i\($0)" })
            let s = mapper.signal(for: f, owner: "f")
            var net = LUTNetwork(inputNames: (0..<n).map { "i\($0)" }, outputNames: ["f"])
            net.luts = mapper.luts
            net.outputs = [s]
            for m in 0..<f.size {
                let bits = (0..<n).map { (m >> (n - 1 - $0)) & 1 == 1 }
                if net.evaluate(bits).outputs[0] != f[m] { mapOK = false }
            }
            if mapper.luts.contains(where: { $0.inputs.count > 6 }) { sizeOK = false }
            if n <= 6 && mapper.luts.count != 1 { sizeOK = false }
        }
        check(mapOK, "random 4-10 input functions: LUT network matches the truth table")
        check(sizeOK, "every LUT has at most 6 inputs; <= 6-input functions use one LUT")

        // ALM packing rules.
        func lut(_ k: Int, _ base: Int) -> LUTNetwork.LUT {
            LUTNetwork.LUT(name: "l", inputs: (0..<k).map { .input(base + $0) }, table: 0, level: 1)
        }
        check(Synthesizer.packALMs([lut(4, 0), lut(4, 10)]).count == 1, "two independent 4-input LUTs share one ALM")
        check(Synthesizer.packALMs([lut(5, 0), lut(3, 10)]).count == 1, "5-input + independent 3-input share one ALM")
        check(Synthesizer.packALMs([lut(5, 0), lut(5, 10)]).count == 2, "two independent 5-input LUTs need two ALMs")
        check(Synthesizer.packALMs([lut(5, 0), lut(5, 3)]).count == 1, "5-input LUTs sharing two inputs share one ALM")
        check(Synthesizer.packALMs([lut(6, 0), lut(2, 10)]).count == 2, "a 6-input LUT fills an ALM")

        flow(check)

        print("Board and device pins")
        check(CycloneV.pins.count == 896, "896 package balls")
        check(CycloneV.pins.values.filter { $0.isUserIO }.count == 457, "457 user I/O balls")
        check(BoardPin.all.allSatisfy { CycloneV.pin($0.pin)?.isUserIO == true }, "every board pin is a user I/O ball")
        check(Set(BoardPin.all.map { $0.pin }).count == BoardPin.all.count, "no board pin listed twice")
        check(BoardPin.named("SW0")?.pin == "PIN_AB30" && BoardPin.named("LEDR0")?.pin == "PIN_AA24"
              && BoardPin.named("HEX5[6]")?.pin == "PIN_AB21" && BoardPin.named("CLOCK_50")?.pin == "PIN_AF14",
              "spot checks SW0, LEDR0, HEX5[6], CLOCK_50")
        check(BoardPin.named("SW0")?.bank == "5B" && BoardPin.named("LEDR0")?.bank == "5A", "banks from the Quartus package table")
    }

    /// The full flow on every reference design: the LUT netlist (in memory and as written
    /// Verilog text) must reproduce the schematic simulation exactly.
    static func flow(_ check: (Bool, String) -> Void) {
        print("Compile flow on TestDesigns.all")
        for (name, d) in TestDesigns.all {
            let state = CompileFlow.run(d)
            check(!state.failed, "\(name): full compilation succeeds (\(state.errors) errors, \(state.warnings) warnings)")
            guard let c = state.circuit, let s = state.synthesis, let text = state.netlist else { continue }
            guard let sim = try? SimulationResult.run(c, project: state.project) else { check(false, "Reference design simulation failed"); continue }
            var memOK = true, textOK = true
            for row in sim.rows {
                if s.network.evaluate(row.inputs).outputs != row.outputs { memOK = false }
                let ins = Dictionary(uniqueKeysWithValues: zip(sim.inputNames, row.inputs))
                if let outs = NetlistWriter.simulate(text, inputs: ins) {
                    if sim.outputNames.map({ outs[$0] }) != row.outputs.map({ Optional($0) }) { textOK = false }
                } else { textOK = false }
            }
            check(memOK, "\(name): LUT network matches the schematic simulation on all \(sim.rows.count) rows")
            check(textOK, "\(name): written .vo netlist simulates to the same truth table")
            check(state.run(.assembler)?.status == .skipped, "\(name): Assembler is reported as skipped")
            check(state.summary?.text.hasPrefix("Quartzite Full Compilation was successful") == true, "\(name): ends with the Full Compilation line")
            let report = ReportText.render(CompileFlow.report(state))
            check(report.contains("Logic utilization (in ALMs)") && !report.contains("Quartus Prime Version"), "\(name): report renders")
        }

        print("Example synthesis")
        let exampleRun = CompileFlow.run(TestDesigns.exampleSOP())
        if let s = exampleRun.synthesis {
            check(s.network.luts.count == 1 && s.resources.alms == 1, "Example maps to one 4-input LUT in one ALM")
            check(s.outputs[0].textbookSOP.split(separator: "+").count == 3, "Example minimal SOP has 3 terms (\(s.outputs[0].textbookSOP))")
            check(s.removed.isEmpty, "Example has no redundant gates")
            check(s.resources.deviceResources == 6, "Example: 4 inputs + 1 output + 1 logic cell = 6 device resources")
        } else {
            check(false, "Example synthesizes")
        }
        check(exampleRun.fit?.io.allSatisfy { $0.assignedByUser } == true, "Example pins all user-assigned")
        check(exampleRun.messages.contains { $0.text == "Quartzite Full Compilation was successful. 0 errors, 0 warnings" }, "Example compiles with 0 errors, 0 warnings")

        print("Fitter checks")
        func compiled(_ change: (inout Project) -> Void) -> FlowState {
            var p = TestDesigns.exampleSOP()
            change(&p)
            return CompileFlow.run(p)
        }
        func idx(_ p: Project, _ n: String) -> Int { p.components.firstIndex { $0.name == n }! }
        func all(_ st: FlowState) -> [Message] { st.messages.flatMap { [$0] + $0.children } }
        let bad = compiled { $0.components[idx($0, "w")].location = "PIN_ZZ99" }
        check(bad.failed && all(bad).contains { $0.text.contains("does not exist") }, "nonexistent location is an error")
        let gnd = compiled { $0.components[idx($0, "w")].location = "PIN_A2" }
        check(gnd.failed && all(gnd).contains { $0.text.contains("GND") }, "a GND ball is rejected")
        let dup = compiled { $0.components[idx($0, "w")].location = "PIN_AB28" }
        check(dup.failed && all(dup).contains { $0.text.hasPrefix("Can't place multiple pins assigned to pin location PIN_AB28") }, "two pins on one location is an error")
        let none = compiled { $0.components[idx($0, "f")].location = nil }
        check(!none.failed && all(none).contains { $0.level == .criticalWarning && $0.text.hasPrefix("No exact pin location assignment(s) for 1 pins of 5 total pins") },
              "missing location is a critical warning")
        check(none.fit?.io.first { $0.name == "f" }.map { !$0.assignedByUser && BoardPin.lookup($0.location) == nil } == true,
              "unassigned pin placed on a free non-board pin")
        let swOut = compiled { $0.components[idx($0, "f")].location = "PIN_AA30" }
        check(all(swOut).contains { $0.level == .warning && $0.text.contains("SW9") }, "output on a switch is a warning")

        print("Synthesis warnings")
        var b = TestDesigns.Builder("Stuck")
        let a = b.input("a", y: 32, loc: "PIN_AB30")
        let bb = b.input("b", y: 96, loc: "PIN_Y27")
        let na = b.gate(.not, x: 240, y: 32)
        b.wire(a, to: na, 0)
        let g = b.gate(.and2, x: 400, y: 32)          // a & !a = 0
        b.wire(a, to: g, 0); b.wire(na, to: g, 1)
        let o = b.output("o", x: 600, y: 40, loc: "PIN_AA24")
        b.wire(g, to: o, 0)
        let g2 = b.gate(.or2, x: 400, y: 160)         // b | b = b
        b.wire(bb, to: g2, 0); b.wire(bb, to: g2, 1)
        let o2 = b.output("o2", x: 600, y: 168, loc: "PIN_AB23")
        b.wire(g2, to: o2, 0)
        let st = CompileFlow.run(b.p)
        check(st.messages.contains { $0.text == "Output pins are stuck at VCC or GND" && $0.children.contains { $0.text == "Pin \"o\" is stuck at GND" } },
              "constant output reported as stuck at GND")
        check(st.synthesis?.removed.contains { $0.name == g.name } == true, "AND(a, NOT a) reported as redundant")
        check(st.synthesis?.removed.contains { $0.name == g2.name } == true, "OR(b, b) reported as redundant")
        check(st.synthesis?.network.outputs[1] == .input(1), "o2 = b needs no LUT")
    }
}

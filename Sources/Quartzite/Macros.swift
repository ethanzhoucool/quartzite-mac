import Foundation

// MARK: - VCC and GND

/// The constant primitives in Quartus' primitives > other library.
enum BuiltinSymbols {
    /// From a .bdf that Quartus Prime 18.0 compiled (ci/fixtures/quartus18/lab2/vcc_symbol.txt).
    static let vccText = """
    (symbol
    \t(rect 304 208 336 224)
    \t(text "VCC" (rect 7 0 27 10)(font "Arial" (font_size 6)))
    \t(text "inst" (rect 3 5 26 17)(font "Arial" )(invisible))
    \t(port
    \t\t(pt 16 16)
    \t\t(output)
    \t\t(text "1" (rect 19 7 27 19)(font "Courier New" (bold))(invisible))
    \t\t(text "1" (rect 19 7 27 19)(font "Courier New" (bold))(invisible))
    \t\t(line (pt 16 16)(pt 16 8))
    \t)
    \t(drawing
    \t\t(line (pt 8 8)(pt 24 8))
    \t)
    )
    """

    // PROVISIONAL until CT-0b P1-4: the GND primitive as it appears in older Quartus-saved
    // .bdf files (32 x 32, output at the top, a triangle below the bar).
    static let gndText = """
    (symbol
    \t(rect 304 240 336 272)
    \t(text "GND" (rect 8 16 29 26)(font "Arial" (font_size 6)))
    \t(text "inst" (rect 3 21 26 33)(font "Arial" )(invisible))
    \t(port
    \t\t(pt 16 0)
    \t\t(output)
    \t\t(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
    \t\t(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
    \t\t(line (pt 16 8)(pt 16 0))
    \t)
    \t(drawing
    \t\t(line (pt 8 8)(pt 16 16))
    \t\t(line (pt 16 16)(pt 24 8))
    \t\t(line (pt 8 8)(pt 24 8))
    \t)
    )
    """

    static let vcc: SymbolDef = try! SymbolDef(parsing: vccText, source: .library, libraryPath: ["primitives", "other"])
    static let gnd: SymbolDef = try! SymbolDef(parsing: gndText, source: .library, libraryPath: ["primitives", "other"])
    static let vccPrimitive = vcc.primitive
    static let gndPrimitive = gnd.primitive
}

// MARK: - Library macros
//
// Adding another maxplus2 part (74283 adder, 74138 decoder, 74151 multiplexer, ...):
//  1. Place the part in Quartus, save the .bdf, and paste its (symbol ...) block into a
//     raw string below, byte for byte (tabs and all).
//  2. Write a MacroDef with the input and output port names and its function (outputs for
//     inputs, both in the order you list them), and add it to `MacroLibrary.all`.
// That is all: the symbol, the gate model (`MacroSynth`), simulation, synthesis and export
// follow from those two pieces.

/// A Quartus library macro (a "maxplus2" TTL part). Quartzite places it with Quartus'
/// own symbol text and models its function as a truth table.
struct MacroDef {
    enum UnconnectedInputs { case error }

    var name: String
    /// Folder in the Symbol dialog, e.g. ["others", "maxplus2"].
    var library: [String]
    /// The (symbol ...) exactly as Quartus writes it into a .bdf.
    var symbolText: String
    var inputs: [String]
    var outputs: [String]
    var unconnectedInputs: UnconnectedInputs = .error
    /// Advice shown with the "input not connected" error.
    var unconnectedHint: String
    /// Output values (in `outputs` order) for input values (in `inputs` order).
    var function: ([Bool]) -> [Bool]
    var description: String
}

enum MacroLibrary {
    static let all: [MacroDef] = [ttl7447]

    static func named(_ n: String) -> MacroDef? { all.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }

    private static let symbols: [String: SymbolDef] = Dictionary(uniqueKeysWithValues: all.map { m in
        (m.name.lowercased(), try! SymbolDef(parsing: m.symbolText, source: .library, libraryPath: m.library))
    })

    /// The macro's symbol, parsed once.
    static func symbol(_ m: MacroDef) -> SymbolDef { symbols[m.name.lowercased()]! }

    private static let netlists: [String: Project] = Dictionary(uniqueKeysWithValues: all.map { ($0.name.lowercased(), MacroSynth.netlist($0)) })

    /// Gates that model the macro (see `MacroSynth`), built once.
    static func netlist(_ m: MacroDef) -> Project { netlists[m.name.lowercased()] ?? MacroSynth.netlist(m) }

    // MARK: 7447

    /// BCD to seven-segment decoder with active-low outputs (others > maxplus2 > 7447).
    static let ttl7447 = MacroDef(
        name: "7447", library: ["others", "maxplus2"], symbolText: sym7447,
        inputs: ["A", "B", "C", "D", "LTN", "RBIN", "BIN"],
        outputs: ["OA", "OB", "OC", "OD", "OE", "OF", "OG", "RBON"],
        unconnectedHint: "Tie unused control inputs (LTN, RBIN, BIN) to VCC (primitives > other > vcc).",
        function: bcdTo7Segment,
        description: "BCD to seven-segment decoder. Outputs are active low: a segment is lit when its output is 0. D is the MSB.")

    /// Segments a...g that are off for each digit n = 8D + 4C + 2B + A (LTN = RBIN = BIN = 1).
    static let segmentsOff7447: [Set<Int>] = [
        [1, 4, 6, 10, 11, 12, 14, 15],
        [5, 6, 10, 11, 13, 14, 15],
        [2, 10, 12, 13, 14, 15],
        [1, 4, 7, 9, 12, 15],
        [1, 3, 4, 5, 7, 9, 11, 12, 13, 15],
        [1, 2, 3, 7, 10, 11, 15],
        [0, 1, 7, 15],
    ]

    /// (A, B, C, D, LTN, RBIN, BIN) -> (OA ... OG, RBON). BIN = 0 blanks the display, LTN = 0
    /// lights every segment, and RBIN = 0 blanks a 0 (ripple blanking).
    static func bcdTo7Segment(_ v: [Bool]) -> [Bool] {
        let n = (v[0] ? 1 : 0) + (v[1] ? 2 : 0) + (v[2] ? 4 : 0) + (v[3] ? 8 : 0)
        let ltn = v[4], rbin = v[5], bin = v[6]
        let zeroBlank = ltn && !rbin && n == 0
        let segments = segmentsOff7447.map { off in !bin ? true : (!ltn ? false : (zeroBlank ? true : off.contains(n))) }
        // PROVISIONAL: RBON does not depend on BIN here; confirm with the 7447 probe in CT-1.
        return segments + [!zeroBlank]
    }

    /// The 7447 symbol exactly as Quartus Prime 18.0 writes it into a .bdf
    /// (ci/fixtures/quartus18/lab2/sym7447_template.txt).
    static let sym7447 = #"""
    (symbol
    	(rect 744 344 864 504)
    	(text "7447" (rect 44 0 77 16)(font "Arial" (font_size 10)))
    	(text "inst" (rect 3 149 18 159)(font "Arial" (font_size 6)))
    	(port
    		(pt 0 88)
    		(input)
    		(text "LTN" (rect 21 80 43 94)(font "Arial" (font_size 8)))
    		(text "LTN" (rect 21 80 43 94)(font "Arial" (font_size 8)))
    		(line (pt 0 88)(pt 8 88))
    	)
    	(port
    		(pt 0 40)
    		(input)
    		(text "B" (rect 21 32 29 46)(font "Arial" (font_size 8)))
    		(text "B" (rect 21 32 29 46)(font "Arial" (font_size 8)))
    		(line (pt 0 40)(pt 16 40))
    	)
    	(port
    		(pt 0 56)
    		(input)
    		(text "C" (rect 21 48 29 62)(font "Arial" (font_size 8)))
    		(text "C" (rect 21 48 29 62)(font "Arial" (font_size 8)))
    		(line (pt 0 56)(pt 16 56))
    	)
    	(port
    		(pt 0 72)
    		(input)
    		(text "D" (rect 21 64 29 78)(font "Arial" (font_size 8)))
    		(text "D" (rect 21 64 29 78)(font "Arial" (font_size 8)))
    		(line (pt 0 72)(pt 16 72))
    	)
    	(port
    		(pt 0 104)
    		(input)
    		(text "RBIN" (rect 21 96 48 110)(font "Arial" (font_size 8)))
    		(text "RBIN" (rect 21 96 48 110)(font "Arial" (font_size 8)))
    		(line (pt 0 104)(pt 8 104))
    	)
    	(port
    		(pt 0 120)
    		(input)
    		(text "BIN" (rect 21 112 39 126)(font "Arial" (font_size 8)))
    		(text "BIN" (rect 21 112 39 126)(font "Arial" (font_size 8)))
    		(line (pt 0 120)(pt 8 120))
    	)
    	(port
    		(pt 0 24)
    		(input)
    		(text "A" (rect 21 16 30 30)(font "Arial" (font_size 8)))
    		(text "A" (rect 21 16 30 30)(font "Arial" (font_size 8)))
    		(line (pt 0 24)(pt 16 24))
    	)
    	(port
    		(pt 120 40)
    		(output)
    		(text "OB" (rect 81 32 98 46)(font "Arial" (font_size 8)))
    		(text "OB" (rect 85 32 102 46)(font "Arial" (font_size 8)))
    		(line (pt 104 40)(pt 120 40))
    	)
    	(port
    		(pt 120 56)
    		(output)
    		(text "OC" (rect 81 48 98 62)(font "Arial" (font_size 8)))
    		(text "OC" (rect 85 48 102 62)(font "Arial" (font_size 8)))
    		(line (pt 104 56)(pt 120 56))
    	)
    	(port
    		(pt 120 88)
    		(output)
    		(text "OE" (rect 81 80 97 94)(font "Arial" (font_size 8)))
    		(text "OE" (rect 86 80 102 94)(font "Arial" (font_size 8)))
    		(line (pt 104 88)(pt 120 88))
    	)
    	(port
    		(pt 120 72)
    		(output)
    		(text "OD" (rect 81 64 98 78)(font "Arial" (font_size 8)))
    		(text "OD" (rect 85 64 102 78)(font "Arial" (font_size 8)))
    		(line (pt 104 72)(pt 120 72))
    	)
    	(port
    		(pt 120 104)
    		(output)
    		(text "OF" (rect 81 96 97 110)(font "Arial" (font_size 8)))
    		(text "OF" (rect 86 96 102 110)(font "Arial" (font_size 8)))
    		(line (pt 104 104)(pt 120 104))
    	)
    	(port
    		(pt 120 120)
    		(output)
    		(text "OG" (rect 81 112 99 126)(font "Arial" (font_size 8)))
    		(text "OG" (rect 84 112 102 126)(font "Arial" (font_size 8)))
    		(line (pt 104 120)(pt 120 120))
    	)
    	(port
    		(pt 120 24)
    		(output)
    		(text "OA" (rect 81 16 99 30)(font "Arial" (font_size 8)))
    		(text "OA" (rect 84 16 102 30)(font "Arial" (font_size 8)))
    		(line (pt 104 24)(pt 120 24))
    	)
    	(port
    		(pt 120 136)
    		(output)
    		(text "RBON" (rect 65 128 99 142)(font "Arial" (font_size 8)))
    		(text "RBON" (rect 79 128 113 142)(font "Arial" (font_size 8)))
    		(line (pt 112 136)(pt 120 136))
    	)
    	(drawing
    		(text "BCD TO 7SEG" (rect 25 145 105 159)(font "Arial" (font_size 8)))
    		(line (pt 16 16)(pt 104 16))
    		(line (pt 16 144)(pt 104 144))
    		(line (pt 16 144)(pt 16 16))
    		(line (pt 104 144)(pt 104 16))
    		(circle (rect 8 116 16 124))
    		(circle (rect 8 100 16 108))
    		(circle (rect 8 84 16 92))
    		(circle (rect 104 132 112 140))
    	)
    )

    """#
}

// MARK: - Gate models

/// Builds the gates that model a macro from its truth table: each output's ON-set is
/// minimized exactly, complemented inputs share one NOT each, products are AND2/3/4 trees
/// and sums OR2/3/4 trees. Everything is connected by node names (`isFlatNetlist`).
enum MacroSynth {
    static func netlist(_ m: MacroDef) -> Project {
        var p = Project()
        p.name = "macro_\(m.name)"
        p.isFlatNetlist = true
        let n = m.inputs.count
        var drivers: [String: PortRef] = [:]
        for name in m.inputs {
            let c = Component(kind: .input, name: name, x: 0, y: 0)
            p.components.append(c)
            drivers[name] = PortRef(comp: c.id, port: 0)
            p.inputOrder.append(c.id)
        }
        var outPins: [Component] = []
        for (k, name) in m.outputs.enumerated() {
            // Output pins are listed by y, so y keeps the macro's order.
            let c = Component(kind: .output, name: name, x: 0, y: k)
            p.components.append(c)
            outPins.append(c)
        }
        var gateCount = 0, netCount = 0
        func fresh() -> String { netCount += 1; return "t\(netCount)" }
        @discardableResult
        func gate(_ kind: GateKind, _ ins: [String], _ out: String) -> String {
            let c = Component(kind: kind, name: "g\(gateCount)", x: 0, y: 0)
            gateCount += 1
            p.components.append(c)
            for (i, net) in ins.enumerated() { p.labels[PortRef(comp: c.id, port: i).key] = net }
            p.labels[PortRef(comp: c.id, port: ins.count).key] = out
            drivers[out] = PortRef(comp: c.id, port: ins.count)
            return out
        }
        /// One gate of `kinds` (2, 3, 4 inputs) over `nets`, or a tree of them for more than 4.
        func tree(_ nets: [String], _ kinds: [GateKind], out: String) -> String {
            var level = nets
            while level.count > 4 {
                var next: [String] = []
                for start in stride(from: 0, to: level.count, by: 4) {
                    let chunk = Array(level[start..<min(start + 4, level.count)])
                    next.append(chunk.count == 1 ? chunk[0] : gate(kinds[chunk.count - 2], chunk, fresh()))
                }
                level = next
            }
            return gate(kinds[level.count - 2], level, out)
        }
        var inverted: [Int: String] = [:]
        func literal(_ k: Int, positive: Bool) -> String {
            if positive { return m.inputs[k] }
            if let s = inverted[k] { return s }
            let s = gate(.not, [m.inputs[k]], "\(m.inputs[k])_n")
            inverted[k] = s
            return s
        }
        let ands: [GateKind] = [.and2, .and3, .and4], ors: [GateKind] = [.or2, .or3, .or4]
        for (o, pin) in outPins.enumerated() {
            let on = TruthTable(n: n) { row in
                m.function((0..<n).map { k in (row >> (n - 1 - k)) & 1 == 1 })[o]
            }
            if on.isZero || on.isOne {
                let c = Component(kind: on.isOne ? .vcc : .gnd, name: "g\(gateCount)", x: 0, y: 0)
                gateCount += 1
                p.components.append(c)
                p.wires.append(Wire(a: PortRef(comp: c.id, port: 0), b: PortRef(comp: pin.id, port: 0)))
                continue
            }
            let cubes = Minimizer.minimize(on: on).cubes
            func product(_ c: Cube, out: String?) -> String {
                let lits = (0..<n).compactMap { k -> String? in
                    let bit = UInt32(1) << UInt32(n - 1 - k)
                    return c.care & bit == 0 ? nil : literal(k, positive: c.value & bit != 0)
                }
                return lits.count == 1 ? lits[0] : tree(lits, ands, out: out ?? fresh())
            }
            let result: String
            if cubes.count == 1 {
                result = product(cubes[0], out: pin.name)
            } else {
                result = tree(cubes.map { product($0, out: nil) }, ors, out: pin.name)
            }
            if result != pin.name, let d = drivers[result] {
                p.wires.append(Wire(a: d, b: PortRef(comp: pin.id, port: 0)))
            }
        }
        return p
    }
}

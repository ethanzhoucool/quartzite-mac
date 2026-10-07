import Foundation

/// Independent check of a Cyclone V bitstream, ported from `toolchain/verify_rbf.py`.
///
/// The bitstream is decompiled by Mistral's `mistral-cv decomp` (not by nextpnr) into its
/// text form (`.bt`). This file parses that text, checks every design pin's I/O block, and
/// rebuilds the routed LUT netlist so each output can be simulated over the whole truth
/// table and compared with the schematic simulation.
///
/// ALM model (Mistral's documentation and nextpnr-mistral's bit mapping; see
/// docs/TOOLCHAIN_NOTES.md): a 64-bit LUT_MASK per ALM. 5-LUT halves (TMODE=E_0, BMODE=E_1):
/// top = bits 0-31 on A,B,C,E0,F0; bottom = bits 32-63 on A,B,D,E1,F1. 6-LUT (Mistral default
/// TMODE=D_E, BMODE=C_E): E selects the half, C/D swap between bit 2 and bit 3 in the upper
/// half. Inputs are inverted and the mask is stored complemented: out = ~MASK[addr(~inputs)].
/// MLAB masks are permuted. An unrouted ALM input must not change the result (every value is
/// tried), so the check does not depend on what an unconnected input reads on silicon.
struct DecodedBitstream {
    struct SettingKey: Hashable { var block: String; var mux: String; var index: Int }
    struct Inversion { var value: String; var pin: String; var alias: String }

    var device = ""
    /// Routing: destination node -> source node.
    var routes: [String: String] = [:]
    /// Pin-attached routing node -> package pin (from the decoder's comments).
    var routePins: [String: String] = [:]
    var settings: [SettingKey: String] = [:]
    /// Package pin -> (key, value) of its GPIO block settings.
    var gpioSettings: [String: [(key: SettingKey, value: String)]] = [:]
    var inversions: [String: Inversion] = [:]

    struct ParseError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(text: String) throws {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let body: Substring, comment: Substring
            if let r = line.range(of: " ; ") { body = line[..<r.lowerBound]; comment = line[r.upperBound...] } else { body = Substring(line); comment = "" }
            let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let kind = parts.first else { continue }
            switch kind {
            case "m":
                if parts.count > 1 { device = parts[1] }
            case "r":
                guard parts.count >= 3 else { continue }
                let src = parts[1], dst = parts[2]
                if let old = routes[dst], old != src { throw ParseError(message: "node \(dst) has two drivers: \(old) and \(src)") }
                routes[dst] = src
                var pins = comment.split(separator: " ").map(String.init)
                for node in [src, dst] where (node.hasPrefix("GPIO.") || node.hasPrefix("HMC.")) && !pins.isEmpty {
                    routePins[node] = pins.removeFirst()
                }
            case "s":
                guard parts.count >= 3, let key = DecodedBitstream.settingKey(parts[1]) else { continue }
                settings[key] = parts[2]
                if key.block.hasPrefix("GPIO."), let pin = comment.split(separator: " ").first {
                    gpioSettings[String(pin), default: []].append((key, parts[2]))
                }
            case "i":
                guard parts.count >= 3 else { continue }
                let fields = comment.isEmpty ? [""] : comment.components(separatedBy: " ; ")
                let pin = fields[0].trimmingCharacters(in: .whitespaces)
                // HMC-area inverters print the GPIO node they stand for last.
                let alias = fields.count > 1 ? (fields.last!.split(separator: " ").last.map(String.init) ?? parts[1]) : parts[1]
                inversions[parts[1]] = Inversion(value: parts[2], pin: pin, alias: alias)
            default:
                continue
            }
        }
    }

    /// "LAB.088.021:LUT_MASK.1" -> (LAB.088.021, LUT_MASK, 1); a missing index is -1.
    static func settingKey(_ s: String) -> SettingKey? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let block = String(s[..<colon])
        guard block.split(separator: ".").count == 3 else { return nil }
        var rest = String(s[s.index(after: colon)...])
        var idx = -1
        if let dot = rest.lastIndex(of: "."), let n = Int(rest[rest.index(after: dot)...]) {
            idx = n
            rest = String(rest[..<dot])
        }
        guard !rest.isEmpty, rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return SettingKey(block: block, mux: rest, index: idx)
    }

    func setting(_ block: String, _ mux: String, _ idx: Int) -> String? { settings[SettingKey(block: block, mux: mux, index: idx)] }

    /// Pin -> its pin-attached routing nodes.
    var pinNodes: [String: [String]] {
        var d: [String: [String]] = [:]
        for (node, pin) in routePins { d[pin, default: []].append(node) }
        return d
    }

    /// Inverters that turn a pin's output buffer on. nextpnr drives OE by inverting the
    /// constant OEIN inputs: an output has OEIN.0 inverted (1) and/or OEIN.1 not inverted (0).
    func outputEnables(_ pin: String) -> [String] {
        inversions.filter { $0.value.pin == pin && (($0.value.alias.hasSuffix(":OEIN.0") && $0.value.value == "1") || ($0.value.alias.hasSuffix(":OEIN.1") && $0.value.value == "0")) }
            .map { $0.key }.sorted()
    }

    /// Every package pin whose output buffer is enabled.
    var drivenPins: Set<String> {
        var s = Set<String>()
        for (_, v) in inversions where (v.alias.hasSuffix(":OEIN.0") && v.value == "1") || (v.alias.hasSuffix(":OEIN.1") && v.value == "0") {
            if !v.pin.isEmpty { s.insert(v.pin) }
        }
        return s
    }

    /// ALMs and LABs that carry logic configuration (LUT masks, LUT modes, output selects).
    var configuredALMs: [(block: String, alm: Int)] {
        var s = Set<String>()
        var out: [(String, Int)] = []
        for k in settings.keys where (k.block.hasPrefix("LAB.") || k.block.hasPrefix("MLAB.")) && k.index >= 0
            && ["LUT_MASK", "TMODE", "BMODE", "TDFF0", "TDFF1", "TDFF1L", "BDFF0", "BDFF1", "BDFF1L", "ARITH_SEL"].contains(k.mux) {
            let id = "\(k.block).\(k.index)"
            if s.insert(id).inserted { out.append((k.block, k.index)) }
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// "LAB.088.021" -> "LAB (X88, Y21)".
    static func blockLabel(_ block: String) -> String {
        let p = block.split(separator: ".")
        guard p.count == 3, let x = Int(p[1]), let y = Int(p[2]) else { return block }
        return "\(p[0]) (X\(x), Y\(y))"
    }
}

/// The result of checking a decoded bitstream against the design.
struct BitstreamCheck {
    struct PinRow {
        var name: String
        var pin: String          // without PIN_
        var isInput: Bool
        var used: Bool           // false for an input no output depends on
        var node: String         // decoded GPIO/HMC routing node, or "--"
        var outputEnabled: Bool
        var drive: String?
        var config: [String]
        var ok: Bool
        var note: String
    }
    struct ALMHalf: Hashable {
        var block: String
        var alm: Int
        var half: Int
        var sixInput: Bool
        var mask: String
        var mode: String { sixInput ? "6-LUT" : (half == 0 ? "top 5-LUT" : "bottom 5-LUT") }
    }

    var routedLinks = 0
    var settingsCount = 0
    var pins: [PinRow] = []
    var strayDrivenPins: [String] = []
    var inputNames: [String] = []
    var outputNames: [String] = []
    var rows = 0
    var rowsMatching = 0
    var outputRowsCorrect: [Int] = []
    var mismatches: [String] = []
    var evaluationError: String?
    var almHalves: [ALMHalf] = []
    var configuredALMs = 0
    var configuredLABs = 0
    var failures: [String] = []

    var passed: Bool { failures.isEmpty }
    var pinsOK: Int { pins.filter { $0.ok }.count }

    var summary: String {
        if let e = evaluationError { return "FAILED: \(e)" }
        return (passed ? "Passed" : "FAILED") + ": \(pinsOK)/\(pins.count) pins, \(rowsMatching)/\(rows) truth-table rows match the schematic simulation"
    }
}

enum BitstreamVerifier {
    struct Spec {
        var inputs: [(name: String, pin: String)]       // first = MSB of the row index
        var outputs: [(name: String, pin: String)]
        /// Inputs no output depends on (allowed to have no route).
        var unusedInputs: Set<String> = []
        /// Expected output values for a row index.
        var expected: (Int) -> [Bool]
    }

    static func strip(_ pin: String) -> String { pin.hasPrefix("PIN_") ? String(pin.dropFirst(4)) : pin }

    static func check(_ bt: DecodedBitstream, spec: Spec) -> BitstreamCheck {
        var r = BitstreamCheck()
        r.routedLinks = bt.routes.count
        r.settingsCount = bt.settings.count
        r.inputNames = spec.inputs.map { $0.name }
        r.outputNames = spec.outputs.map { $0.name }
        let cfg = bt.configuredALMs
        r.configuredALMs = cfg.count
        r.configuredLABs = Set(cfg.map { $0.block }).count
        let pinNodes = bt.pinNodes
        func matches(_ s: String, _ suffixes: [String]) -> Bool {
            // ":(DATAIN|\w*DIN)\.\d+$" / ":(DATAOUT|\w*DOUT)\.\d+$"
            guard let colon = s.lastIndex(of: ":") else { return false }
            let port = s[s.index(after: colon)...]
            guard let dot = port.lastIndex(of: "."), Int(port[port.index(after: dot)...]) != nil else { return false }
            let name = port[..<dot]
            return suffixes.contains { name.hasSuffix($0) } && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        var inNodes: [String: Int] = [:]
        for (k, (name, rawPin)) in spec.inputs.enumerated() {
            let pin = strip(rawPin)
            let nodes = (pinNodes[pin] ?? []).filter { matches($0, ["DATAIN", "DIN"]) }.sorted()
            let oe = bt.outputEnables(pin)
            let cfgs = (bt.gpioSettings[pin] ?? []).map { "\($0.key.mux)=\($0.value)" }.sorted()
            let drive = (bt.gpioSettings[pin] ?? []).first { $0.key.mux == "DRIVE_STRENGTH" }?.value
            let used = !spec.unusedInputs.contains(name)
            var ok: Bool, note: String
            if used {
                ok = nodes.count == 1 && oe.isEmpty && drive == nil
                note = ok ? "input buffer routed into the logic, output driver off" : (oe.isEmpty ? (nodes.isEmpty ? "no route from this pin" : "unexpected configuration") : "OUTPUT DRIVER ENABLED on an input pin")
            } else {
                ok = oe.isEmpty && drive == nil && nodes.count <= 1
                note = ok ? "not used by the design; output driver off" : "OUTPUT DRIVER ENABLED on an unused input pin"
            }
            r.pins.append(.init(name: name, pin: pin, isInput: true, used: used, node: nodes.first ?? "--", outputEnabled: !oe.isEmpty,
                                drive: drive, config: cfgs, ok: ok, note: note))
            if !ok { r.failures.append("input \(name) (PIN_\(pin)): \(note)") }
            for n in nodes { inNodes[n] = k }
        }
        var outNodes: [Int: String] = [:]
        for (k, (name, rawPin)) in spec.outputs.enumerated() {
            let pin = strip(rawPin)
            let nodes = (pinNodes[pin] ?? []).filter { matches($0, ["DATAOUT", "DOUT"]) }.sorted()
            let oe = bt.outputEnables(pin)
            let cfgs = (bt.gpioSettings[pin] ?? []).map { "\($0.key.mux)=\($0.value)" }.sorted()
            let drives = (bt.gpioSettings[pin] ?? []).filter { $0.key.mux == "DRIVE_STRENGTH" }.map { $0.value }
            let ok = nodes.count == 1 && !oe.isEmpty && drives.count == 1
            let note = ok ? "output driver on, data routed from the logic" : (nodes.isEmpty ? "no data route to this pin" : (oe.isEmpty ? "output driver not enabled" : "no drive strength configured"))
            r.pins.append(.init(name: name, pin: pin, isInput: false, used: true, node: nodes.first ?? "--", outputEnabled: !oe.isEmpty,
                                drive: drives.first, config: cfgs, ok: ok, note: note))
            if !ok { r.failures.append("output \(name) (PIN_\(pin)): \(note)") }
            if let n = nodes.first { outNodes[k] = n }
        }
        // No pin outside the design may drive.
        let outPins = Set(spec.outputs.map { strip($0.pin) })
        r.strayDrivenPins = bt.drivenPins.subtracting(outPins).sorted()
        if !r.strayDrivenPins.isEmpty {
            r.failures.append("output drivers enabled on pins that are not design outputs: \(r.strayDrivenPins.map { "PIN_\($0)" }.joined(separator: ", "))")
        }

        // Truth table.
        do {
            let net = try Netlist(bt, inputs: inNodes)
            let outs = try spec.outputs.indices.map { k -> Netlist.Ref? in
                guard let n = outNodes[k] else { return nil }
                return try net.resolve(n)
            }
            let n = spec.inputs.count
            r.rows = 1 << n
            r.outputRowsCorrect = [Int](repeating: 0, count: spec.outputs.count)
            var env = [Bool](repeating: false, count: n)
            for idx in 0..<(1 << n) {
                for k in 0..<n { env[k] = (idx >> (n - 1 - k)) & 1 == 1 }
                let exp = spec.expected(idx)
                net.reset()
                var rowOK = true
                for (k, ref) in outs.enumerated() {
                    guard let ref else { rowOK = false; continue }
                    let got = try net.value(ref, env)
                    if got == exp[k] { r.outputRowsCorrect[k] += 1 } else {
                        rowOK = false
                        if r.mismatches.count < 8 {
                            let bits = (0..<n).map { env[$0] ? "1" : "0" }.joined()
                            r.mismatches.append("row \(idx) (\(spec.inputs.map { $0.name }.joined(separator: ","))=\(bits)): \(spec.outputs[k].name) is \(got ? 1 : 0) in the bitstream, \(exp[k] ? 1 : 0) in the schematic")
                        }
                    }
                }
                if rowOK { r.rowsMatching += 1 }
            }
            r.almHalves = net.usedHalves.sorted { ($0.block, $0.alm, $0.half) < ($1.block, $1.alm, $1.half) }
            if r.rowsMatching != r.rows {
                r.failures.append("\(r.rowsMatching)/\(r.rows) truth-table rows match the schematic simulation" + (r.mismatches.first.map { "; first mismatch: \($0)" } ?? ""))
            }
        } catch {
            r.evaluationError = error.localizedDescription
            r.failures.append("netlist evaluation: \(error.localizedDescription)")
        }
        return r
    }

    struct EvalError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The routed LUT netlist rebuilt from the decoded routes, compiled once and evaluated per row.
    final class Netlist {
        enum Ref { case input(Int), half(Int) }
        struct Half {
            var info: BitstreamCheck.ALMHalf
            var mask: UInt64
            var sixInput: Bool
            var half: Int
            var sources: [Ref?]   // per LUT input pin, nil = unrouted
        }
        static let mlabPermute = [0, 1, 4, 5, 8, 9, 12, 13, 29, 28, 25, 24, 21, 20, 17, 16,
                                  2, 3, 6, 7, 10, 11, 14, 15, 31, 30, 27, 26, 23, 22, 19, 18,
                                  32, 33, 36, 37, 40, 41, 44, 45, 61, 60, 57, 56, 53, 52, 49, 48,
                                  34, 35, 38, 39, 42, 43, 46, 47, 63, 62, 59, 58, 55, 54, 51, 50]
        static let topOuts = ["FFT0": "TDFF0", "FFT1": "TDFF1", "FFT1L": "TDFF1L"]
        static let botOuts = ["FFB0": "BDFF0", "FFB1": "BDFF1", "FFB1L": "BDFF1L"]

        let bt: DecodedBitstream
        let inputs: [String: Int]
        var halves: [Half] = []
        private var halfIndex: [String: Int] = [:]
        private var building: Set<String> = []
        private var memo: [Int8] = []
        /// QZ_FLOAT_INPUT=0|1 pins unrouted ALM inputs to that value; by default every value is tried.
        let fixedFloat: Int? = ProcessInfo.processInfo.environment["QZ_FLOAT_INPUT"].flatMap { $0 == "0" ? 0 : ($0 == "1" ? 1 : nil) }

        init(_ bt: DecodedBitstream, inputs: [String: Int]) throws {
            self.bt = bt
            self.inputs = inputs
        }

        var usedHalves: Set<BitstreamCheck.ALMHalf> { Set(halves.map { $0.info }) }

        func reset() {
            if memo.count != halves.count { memo = [Int8](repeating: -1, count: halves.count) } else {
                for i in memo.indices { memo[i] = -1 }
            }
        }

        /// Follows the routing back from `node` to its driver.
        func resolve(_ node: String, depth: Int = 0) throws -> Ref {
            guard depth < 64 else { throw EvalError(message: "combinational depth > 64 (loop?)") }
            var chain = [node]
            var cur = node
            var seen: Set<String> = [node]
            while let src = bt.routes[cur] {
                guard seen.insert(src).inserted else { throw EvalError(message: "routing loop at \(src)") }
                chain.append(src)
                cur = src
            }
            for n in chain where bt.inversions[n] != nil {
                throw EvalError(message: "routing node \(n) has a non-default inversion; not modelled")
            }
            if let k = inputs[cur] { return .input(k) }
            // (LAB|MLAB).xxx.yyy.alm:PIN
            guard let colon = cur.lastIndex(of: ":") else { throw EvalError(message: "net \(node) is driven by unsupported source \(cur)") }
            let left = cur[..<colon], pin = String(cur[cur.index(after: colon)...])
            let lp = left.split(separator: ".")
            guard lp.count == 4, lp[0] == "LAB" || lp[0] == "MLAB", let alm = Int(lp[3]) else {
                throw EvalError(message: "net \(node) is driven by unsupported source \(cur)")
            }
            let block = lp[0...2].joined(separator: ".")
            return .half(try half(block: block, alm: alm, pin: pin, depth: depth))
        }

        private func half(block: String, alm: Int, pin: String, depth: Int) throws -> Int {
            let half: Int, sel: String
            if let s = Netlist.topOuts[pin] { half = 0; sel = s } else if let s = Netlist.botOuts[pin] { half = 1; sel = s } else {
                throw EvalError(message: "unsupported ALM output \(block).\(alm):\(pin)")
            }
            let key = "\(block).\(alm).\(half)"
            if let i = halfIndex[key] { return i }
            guard building.insert(key).inserted else { throw EvalError(message: "combinational loop through \(key)") }
            defer { building.remove(key) }
            guard bt.setting(block, sel, alm) == "NLUT" else {
                throw EvalError(message: "\(block).\(alm):\(pin) is a register output (\(sel) is not NLUT); sequential logic is not modelled")
            }
            let tmode = bt.setting(block, "TMODE", alm) ?? "D_E"
            let bmode = bt.setting(block, "BMODE", alm) ?? "C_E"
            if (bt.setting(block, "ARITH_SEL", alm) ?? "LUT") != "LUT" {
                throw EvalError(message: "\(block).\(alm): ALM in arithmetic (carry-chain) mode; not modelled")
            }
            var maskText = bt.setting(block, "LUT_MASK", alm)
            var mask: UInt64 = ~0
            if let t = maskText {
                guard let v = UInt64(t.replacingOccurrences(of: ".", with: ""), radix: 16) else { throw EvalError(message: "bad LUT_MASK \(t)") }
                mask = v
                if block.hasPrefix("MLAB.") {
                    var orig: UInt64 = 0
                    for i in 0..<64 where (v >> UInt64(Netlist.mlabPermute[i])) & 1 == 1 { orig |= 1 << UInt64(i) }
                    mask = orig
                }
            } else { maskText = "(default)" }
            let pins: [String], six: Bool
            if tmode == "E_0" && bmode == "E_1" {
                six = false
                pins = ["A", "B", half == 0 ? "C" : "D", half == 0 ? "E0" : "E1", half == 0 ? "F0" : "F1"]
            } else if tmode == "D_E" && bmode == "C_E" {
                six = true
                pins = ["A", "B", "C", "D", half == 0 ? "E0" : "E1", half == 0 ? "F0" : "F1"]
            } else {
                throw EvalError(message: "\(block).\(alm): TMODE/BMODE \(tmode)/\(bmode) not modelled")
            }
            var sources: [Ref?] = []
            for p in pins {
                let node = "\(block).\(alm):\(p)"
                sources.append(bt.routes[node] != nil ? try resolve(node, depth: depth + 1) : nil)
            }
            let info = BitstreamCheck.ALMHalf(block: block, alm: alm, half: half, sixInput: six, mask: maskText ?? "")
            halves.append(Half(info: info, mask: mask, sixInput: six, half: half, sources: sources))
            let i = halves.count - 1
            halfIndex[key] = i
            return i
        }

        func value(_ ref: Ref, _ env: [Bool]) throws -> Bool {
            switch ref {
            case .input(let k): return env[k]
            case .half(let i): return try halfValue(i, env)
            }
        }

        private func halfValue(_ i: Int, _ env: [Bool]) throws -> Bool {
            if memo.count != halves.count { reset() }
            if memo[i] >= 0 { return memo[i] == 1 }
            let h = halves[i]
            var vals = [Int](repeating: 0, count: h.sources.count)
            var floating: [Int] = []
            for (k, s) in h.sources.enumerated() {
                if let s { vals[k] = try value(s, env) ? 1 : 0 } else { floating.append(k) }
            }
            var seen0 = false, seen1 = false
            let combos = fixedFloat != nil ? 1 : (1 << floating.count)
            for c in 0..<combos {
                var v = vals
                for (j, k) in floating.enumerated() { v[k] = fixedFloat ?? ((c >> j) & 1) }
                let n = v.map { 1 - $0 }   // ALM inputs are inverted
                let bit: Int
                if !h.sixInput {
                    bit = 32 * h.half + (n[0] | n[1] << 1 | n[2] << 2 | n[3] << 3 | n[4] << 4)
                } else {
                    let e = n[4]
                    let cd = e == 0 ? (n[2] << 2 | n[3] << 3) : (n[3] << 2 | n[2] << 3)
                    bit = n[0] | n[1] << 1 | cd | n[5] << 4 | e << 5
                }
                let out = 1 - Int((h.mask >> UInt64(bit)) & 1)
                if out == 1 { seen1 = true } else { seen0 = true }
                if seen0 && seen1 { break }
            }
            if seen0 && seen1 {
                throw EvalError(message: "\(h.info.block).\(h.info.alm) half \(h.half): output depends on an unrouted input")
            }
            // Re-allocate if halves grew during evaluation (it cannot: all are built in resolve()).
            memo[i] = seen1 ? 1 : 0
            return seen1
        }
    }
}

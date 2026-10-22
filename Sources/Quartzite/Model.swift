import Foundation

/// Every symbol the editor can place. Geometry matches the Quartus primitive
/// library so exported .bdf coordinates line up exactly with what is drawn.
enum GateKind: String, Codable, CaseIterable, Identifiable {
    case input, output, not
    case and2, and3, and4
    case or2, or3, or4
    case nand2, nand3, nand4
    case nor2, nor3, nor4
    case xor2, xnor2
    /// Constant drivers (primitives > other > vcc / gnd).
    case vcc, gnd
    /// An instance of another sheet of the project (`Component.symbol` names it).
    case block
    /// A library macro such as the 7447 (`Component.symbol` names it).
    case macro

    var id: String { rawValue }

    enum Family { case pinIn, pinOut, not, and, or, nand, nor, xor, xnor, vcc, gnd, symbol }

    var family: Family {
        switch self {
        case .input: return .pinIn
        case .output: return .pinOut
        case .not: return .not
        case .and2, .and3, .and4: return .and
        case .or2, .or3, .or4: return .or
        case .nand2, .nand3, .nand4: return .nand
        case .nor2, .nor3, .nor4: return .nor
        case .xor2: return .xor
        case .xnor2: return .xnor
        case .vcc: return .vcc
        case .gnd: return .gnd
        case .block, .macro: return .symbol
        }
    }

    var isPin: Bool { self == .input || self == .output }

    /// Blocks and macros stand for a whole sub-design; they are flattened before elaboration.
    var isHierarchical: Bool { self == .block || self == .macro }

    /// Number of logic inputs.
    var arity: Int {
        switch self {
        case .input, .vcc, .gnd, .block, .macro: return 0
        case .output, .not: return 1
        case .and2, .or2, .nand2, .nor2, .xor2, .xnor2: return 2
        case .and3, .or3, .nand3, .nor3: return 3
        case .and4, .or4, .nand4, .nor4: return 4
        }
    }

    /// Primitive name in the Quartus symbol library.
    var bdfName: String {
        switch self {
        case .input: return "INPUT"
        case .output: return "OUTPUT"
        case .not: return "NOT"
        case .xor2: return "XOR"
        case .xnor2: return "XNOR"
        case .block: return "BLOCK"
        case .macro: return "MACRO"
        default: return rawValue.uppercased()
        }
    }

    var displayName: String {
        switch self {
        case .input: return "Input Pin"
        case .output: return "Output Pin"
        case .block: return "Block"
        case .macro: return "Library Macro"
        default: return bdfName
        }
    }

    /// Size in library coordinates (see `Primitive.table` for the Quartus geometry).
    var size: CGSize { primitive.size }

    var inputPorts: [CGPoint] { primitive.ports.filter { !$0.isOutput }.map { $0.pt } }

    var outputPorts: [CGPoint] { primitive.ports.filter { $0.isOutput }.map { $0.pt } }

    var allPorts: [CGPoint] { inputPorts + outputPorts }

    func isOutputPort(_ index: Int) -> Bool { index >= inputPorts.count }

    /// Port names used by the Quartus primitives (IN1..INn / OUT, NOT uses IN).
    func portName(_ index: Int) -> String {
        if isPin { return "" }
        if isOutputPort(index) { return "OUT" }
        if self == .not { return "IN" }
        return "IN\(index + 1)"
    }

    func evaluate(_ inputs: [Bool]) -> Bool {
        switch family {
        case .pinIn, .pinOut: return inputs.first ?? false
        case .not: return !(inputs.first ?? false)
        case .and: return inputs.allSatisfy { $0 }
        case .or: return inputs.contains(true)
        case .nand: return !inputs.allSatisfy { $0 }
        case .nor: return !inputs.contains(true)
        case .xor: return inputs.filter { $0 }.count % 2 == 1
        case .xnor: return inputs.filter { $0 }.count % 2 == 0
        case .vcc: return true
        case .gnd: return false
        case .symbol:
            assertionFailure("blocks and macros are flattened before evaluation")
            return false
        }
    }

    static let gates: [GateKind] = [.not, .and2, .and3, .and4, .or2, .or3, .or4,
                                    .nand2, .nand3, .nand4, .nor2, .nor3, .nor4, .xor2, .xnor2]

    /// Kinds placed straight from the primitives library (blocks and macros need a symbol).
    static let placeable: [GateKind] = gates + [.input, .output, .vcc, .gnd]
}

struct Component: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: GateKind
    /// Pin name for pins, instance name ("inst3") for gates.
    var name: String
    var x: Int
    var y: Int
    /// FPGA pin location such as "PIN_AC30" (pins only).
    var location: String? = nil
    /// Rotation or flip, written as the matching Quartus tag (nil = as in the library).
    var orientation: Orientation? = nil
    /// Input pins only: the "Default value" from Pin Properties ("VCC" when nil, or "GND").
    var defaultValue: String? = nil
    /// Blocks and macros: the symbol this instance was placed (or last updated) with.
    var symbol: SymbolDef? = nil

    var origin: CGPoint { CGPoint(x: x, y: y) }
    var frame: CGRect { CGRect(origin: origin, size: size) }

    func portPoint(_ index: Int) -> CGPoint { toSheet(portPoints[index]) }
}

struct PortRef: Codable, Hashable {
    var comp: UUID
    var port: Int
    var key: String { "\(comp.uuidString)#\(port)" }

    init(comp: UUID, port: Int) { self.comp = comp; self.port = port }

    init?(key: String) {
        let parts = key.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let comp = UUID(uuidString: String(parts[0])), let port = Int(parts[1]) else { return nil }
        self.init(comp: comp, port: port)
    }
}

struct Wire: Codable, Identifiable, Hashable {
    var id = UUID()
    var a: PortRef
    var b: PortRef
}

struct Project: Codable {
    var name: String = "Lab1"
    var components: [Component] = []
    var wires: [Wire] = []
    /// Net labels attached to ports, keyed by PortRef.key.
    var labels: [String: String] = [:]
    /// Input pins ordered MSB first for simulation.
    var inputOrder: [UUID] = []
    /// Expected minterm list per output pin (keyed by uuidString).
    var expected: [String: String] = [:]
    var device: String = "5CSXFC6D6F31C6"
    /// Free text from the Block Editor's Text Tool (optional so older files still load).
    var notes: [TextNote]? = nil
    /// Identifies the sheet inside a multi-sheet design (nil in single-sheet v1 files).
    var id: UUID? = nil
    /// This sheet's .bsf, made by Create Symbol Files for Current File.
    var symbol: SymbolDef? = nil
    /// A generated netlist (macro internals, flattened designs): connected by labels only,
    /// so geometry such as ports on the same point is ignored. Never saved.
    var isFlatNetlist = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case name, components, wires, labels, inputOrder, expected, device, notes, id, symbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        components = try c.decode([Component].self, forKey: .components)
        wires = try c.decode([Wire].self, forKey: .wires)
        labels = try c.decode([String: String].self, forKey: .labels)
        inputOrder = try c.decode([UUID].self, forKey: .inputOrder)
        expected = try c.decode([String: String].self, forKey: .expected)
        device = try c.decode(String.self, forKey: .device)
        notes = try c.decodeIfPresent([TextNote].self, forKey: .notes)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        symbol = try c.decodeIfPresent(SymbolDef.self, forKey: .symbol)
        let errors = structuralErrors
        guard errors.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: errors.joined(separator: "; ")))
        }
    }

    /// Check before routing or building UUID dictionaries; JSON decoding alone does
    /// not ensure that IDs are unique or wire/label endpoints actually exist.
    var structuralErrors: [String] {
        var errors: [String] = []
        if Set(components.map(\.id)).count != components.count { errors.append("Duplicate component IDs") }
        if Set(wires.map(\.id)).count != wires.count { errors.append("Duplicate wire IDs") }
        let notes = notes ?? []
        if Set(notes.map(\.id)).count != notes.count { errors.append("Duplicate text note IDs") }
        for wire in wires where !contains(wire.a) || !contains(wire.b) {
            errors.append("Wire \(wire.id) references a missing component or invalid port")
        }
        for key in labels.keys {
            if let ref = PortRef(key: key), contains(ref) { continue }
            errors.append("Invalid net label endpoint '\(key)'")
        }
        return errors
    }

    func contains(_ ref: PortRef) -> Bool {
        component(ref.comp).map { (0..<$0.portCount).contains(ref.port) } ?? false
    }

    func component(_ id: UUID) -> Component? { components.first { $0.id == id } }
    func index(of id: UUID) -> Int? { components.firstIndex { $0.id == id } }

    func label(_ ref: PortRef) -> String? {
        guard let s = labels[ref.key]?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    var inputPins: [Component] {
        let pins = components.filter { $0.kind == .input }
        var seen = Set<UUID>()
        let ordered = inputOrder.compactMap { id in seen.insert(id).inserted ? pins.first { $0.id == id } : nil }
        let rest = pins.filter { p in !inputOrder.contains(p.id) }.sorted { $0.name < $1.name }
        return ordered + rest
    }

    var outputPins: [Component] {
        components.filter { $0.kind == .output }.sorted { ($0.y, $0.name) < ($1.y, $1.name) }
    }

    /// A Quartus-friendly identifier for the top-level entity / file names.
    var entityName: String {
        let cleaned = name.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" ? $0 : "_" }
        var s = String(cleaned)
        if s.isEmpty { s = "Lab1" }
        if let f = s.first, !f.isLetter { s = "p_" + s }
        if Compiler.reserved.contains(s.lowercased()) { s = "p_" + s }
        return s
    }

    func nextInstanceName() -> String {
        let used = Set(components.map { $0.name })
        if !used.contains("inst") { return "inst" }
        var n = 1
        while used.contains("inst\(n)") { n += 1 }
        return "inst\(n)"
    }

    func nextPinName(for kind: GateKind) -> String {
        let used = Set(components.map { $0.name.lowercased() })
        let pool = kind == .input ? ["w", "x", "y", "z", "a", "b", "c", "d", "e"] : ["f", "g", "h"]
        if let n = pool.first(where: { !used.contains($0) }) { return n }
        let base = kind == .input ? "in" : "out"
        var n = 1
        while used.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }
}

/// DE10-Standard board resources wired to FPGA pins.
///
/// Pin numbers were taken from the Terasic DE10-Standard golden top settings file
/// (DE10_Standard_golden_top.qsf, Terasic System Builder output, as committed in
/// github.com/ffxx283/WM8731_Audio) and cross-checked against two other sources:
/// github.com/menotti/ld labs/DE10_standard.qsf (67 of these signals) and the
/// "All Package Pins" table Quartus Prime wrote when it fitted that golden top
/// (106 signals, 0 mismatches). I/O standards are the ones the Terasic golden top assigns.
/// I/O banks come from the Quartus package pin table in `CycloneV`.
struct BoardPin: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case slideSwitch = "Slide switch"
        case pushButton = "Push button"
        case led = "Red LED"
        case sevenSegment = "7-segment display"
        case clock = "Clock"
        case gpio = "GPIO header"
    }

    /// Board name as in Terasic's files: SW0, KEY0, LEDR0, HEX0[0], CLOCK_50, GPIO[0].
    var label: String
    var pin: String
    var isInput: Bool
    var kind: Kind
    var activeLow = false
    var ioStandard: String
    /// Extra detail shown in pickers ("segment a", "50 MHz").
    var detail: String = ""
    var id: String { pin }

    var bank: String? { CycloneV.pin(pin)?.bank }
    var direction: String { kind == .gpio ? "Bidir" : (isInput ? "Input" : "Output") }
    /// Label plus detail, e.g. "HEX0[0] (segment a, active low)".
    var longLabel: String {
        var parts: [String] = []
        if !detail.isEmpty { parts.append(detail) }
        if activeLow { parts.append("active low") }
        return parts.isEmpty ? label : "\(label) (\(parts.joined(separator: ", ")))"
    }

    /// Switches, push buttons, LEDs, 7-segment displays and clocks (the resources the
    /// pin pickers offer). GPIO header pins are in `gpio`.
    static let de10Standard: [BoardPin] = {
        let sw = ["PIN_AB30", "PIN_Y27", "PIN_AB28", "PIN_AC30", "PIN_W25",
                  "PIN_V25", "PIN_AC28", "PIN_AD30", "PIN_AC29", "PIN_AA30"]
        let key = ["PIN_AJ4", "PIN_AK4", "PIN_AA14", "PIN_AA15"]
        let led = ["PIN_AA24", "PIN_AB23", "PIN_AC23", "PIN_AD24", "PIN_AG25",
                   "PIN_AF25", "PIN_AE24", "PIN_AF24", "PIN_AB22", "PIN_AC22"]
        let hex = [
            ["PIN_W17", "PIN_V18", "PIN_AG17", "PIN_AG16", "PIN_AH17", "PIN_AG18", "PIN_AH18"],
            ["PIN_AF16", "PIN_V16", "PIN_AE16", "PIN_AD17", "PIN_AE18", "PIN_AE17", "PIN_V17"],
            ["PIN_AA21", "PIN_AB17", "PIN_AA18", "PIN_Y17", "PIN_Y18", "PIN_AF18", "PIN_W16"],
            ["PIN_Y19", "PIN_W19", "PIN_AD19", "PIN_AA20", "PIN_AC20", "PIN_AA19", "PIN_AD20"],
            ["PIN_AD21", "PIN_AG22", "PIN_AE22", "PIN_AE23", "PIN_AG23", "PIN_AF23", "PIN_AH22"],
            ["PIN_AF21", "PIN_AG21", "PIN_AF20", "PIN_AG20", "PIN_AE19", "PIN_AF19", "PIN_AB21"],
        ]
        let segments = ["a", "b", "c", "d", "e", "f", "g"]
        var all: [BoardPin] = []
        all += sw.enumerated().map { BoardPin(label: "SW\($0.offset)", pin: $0.element, isInput: true, kind: .slideSwitch, ioStandard: "3.3-V LVTTL") }
        all += key.enumerated().map { BoardPin(label: "KEY\($0.offset)", pin: $0.element, isInput: true, kind: .pushButton, activeLow: true, ioStandard: "3.3-V LVTTL") }
        all += led.enumerated().map { BoardPin(label: "LEDR\($0.offset)", pin: $0.element, isInput: false, kind: .led, ioStandard: "3.3-V LVTTL") }
        for (d, pins) in hex.enumerated() {
            all += pins.enumerated().map { BoardPin(label: "HEX\(d)[\($0.offset)]", pin: $0.element, isInput: false, kind: .sevenSegment,
                                                    activeLow: true, ioStandard: "3.3-V LVTTL", detail: "segment \(segments[$0.offset])") }
        }
        all += [
            BoardPin(label: "CLOCK_50", pin: "PIN_AF14", isInput: true, kind: .clock, ioStandard: "3.3-V LVTTL", detail: "50 MHz"),
            BoardPin(label: "CLOCK2_50", pin: "PIN_AA16", isInput: true, kind: .clock, ioStandard: "3.3-V LVTTL", detail: "50 MHz"),
            BoardPin(label: "CLOCK3_50", pin: "PIN_Y26", isInput: true, kind: .clock, ioStandard: "2.5 V", detail: "50 MHz"),
            BoardPin(label: "CLOCK4_50", pin: "PIN_K14", isInput: true, kind: .clock, ioStandard: "3.3-V LVTTL", detail: "50 MHz"),
        ]
        return all
    }()

    /// The 36 FPGA pins on the DE10-Standard GPIO header (bidirectional).
    static let gpio: [BoardPin] = {
        let pins = ["PIN_W15", "PIN_AK2", "PIN_Y16", "PIN_AK3", "PIN_AJ1", "PIN_AJ2", "PIN_AH2", "PIN_AH3",
                    "PIN_AH4", "PIN_AH5", "PIN_AG1", "PIN_AG2", "PIN_AG3", "PIN_AG5", "PIN_AG6", "PIN_AG7",
                    "PIN_AG8", "PIN_AF4", "PIN_AF5", "PIN_AF6", "PIN_AF8", "PIN_AF9", "PIN_AF10", "PIN_AE7",
                    "PIN_AE9", "PIN_AE11", "PIN_AE12", "PIN_AD7", "PIN_AD9", "PIN_AD10", "PIN_AD11", "PIN_AD12",
                    "PIN_AC9", "PIN_AC12", "PIN_AB12", "PIN_AA12"]
        return pins.enumerated().map { BoardPin(label: "GPIO[\($0.offset)]", pin: $0.element, isInput: true, kind: .gpio, ioStandard: "3.3-V LVTTL") }
    }()

    static let all: [BoardPin] = de10Standard + gpio

    static func lookup(_ pin: String?) -> BoardPin? {
        guard let pin, !pin.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let p = CycloneV.normalize(pin)
        return all.first { $0.pin == p }
    }

    static func named(_ label: String) -> BoardPin? { all.first { $0.label == label } }

    /// Board resources usable for a node of the given direction (GPIO works both ways).
    static func options(forInput input: Bool) -> [BoardPin] { de10Standard.filter { $0.isInput == input } }
}

enum Minterms {
    /// Accepts "1, 3, 5", "m(1,3,5)", "Σm(1 3 5)", ranges like "8-11".
    static func parse(_ text: String) -> Set<Int>? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        var scanner = t.replacingOccurrences(of: "–", with: "-")
        // Strip only a complete, documented wrapper. Reject all unconsumed text.
        if scanner.hasPrefix("Σm(") || scanner.hasPrefix("m(") {
            guard scanner.hasSuffix(")") else { return nil }
            scanner = String(scanner.dropFirst(scanner.hasPrefix("Σm(") ? 3 : 2).dropLast())
            if scanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        }
        let item = "[0-9]+(?:\\s*-\\s*[0-9]+)?"
        let grammar = "^\\s*" + item + "(?:(?:\\s*,\\s*|\\s+)" + item + ")*\\s*$"
        guard scanner.range(of: grammar, options: .regularExpression) != nil else { return nil }
        let regex = try! NSRegularExpression(pattern: "([0-9]+)\\s*-\\s*([0-9]+)|([0-9]+)")
        var result = Set<Int>()
        for m in regex.matches(in: scanner, range: NSRange(scanner.startIndex..., in: scanner)) {
            if let r1 = Range(m.range(at: 1), in: scanner), let r2 = Range(m.range(at: 2), in: scanner) {
                guard let a = Int(scanner[r1]), let b = Int(scanner[r2]), a <= b,
                      b - a < (1 << SimulationResult.maxInputs) else { return nil }
                result.formUnion(a...b)
            } else if let r = Range(m.range(at: 3), in: scanner), let v = Int(scanner[r]) {
                result.insert(v)
            } else { return nil }
        }
        return result
    }
}

import Foundation

/// `Quartzite --build-design spec.json out.qzproj`: builds a multi-sheet design from a small
/// JSON netlist, so scripts can generate .qzproj files without copying the Codable format.
///
///     { "name": "Top", "top": "Top",
///       "sheets": [ { "name": "HA", "symbol": true,
///                     "inputs":  [ { "name": "a", "y": 64, "loc": "SW0" } ],
///                     "outputs": [ { "name": "s", "x": 480, "y": 56, "loc": "LEDR0" } ],
///                     "parts":   [ { "id": "g1", "kind": "xor2", "x": 320, "y": 40, "name": "inst7" },
///                                  { "id": "h", "kind": "block", "of": "HA", "x": 240, "y": 40 },
///                                  { "id": "d", "kind": "macro", "of": "7447", "x": 400, "y": 72 } ],
///                     "labels":  [ [ "g1.IN1", "a" ] ],
///                     "wires":   [ [ "g1.OUT", "s" ] ],
///                     "expected": { "s": "1, 2" } } ] }
///
/// Sheets are built in order; a sheet with "symbol": true gets File > Create/Update > Create
/// Symbol Files, so later sheets can place it as a block. Inputs keep the listed order (the
/// first is the MSB). A part's optional "name" replaces its instance name (inst, inst1, ...).
/// An endpoint is "part.PORT" (IN1, OUT, cin, OA, 1 for VCC/GND, ...) or a pin name.
/// "loc" is a board name (SW0, LEDR3, HEX0[6]) or a PIN_ name.
struct DesignSpec: Decodable {
    struct Pin: Decodable { var name: String; var x: Int?; var y: Int; var loc: String? }
    struct Part: Decodable { var id: String; var kind: String; var of: String?; var x: Int; var y: Int; var name: String? }
    struct Note: Decodable { var text: String; var x: Int; var y: Int }
    struct Sheet: Decodable {
        var name: String
        var symbol: Bool?
        var inputs: [Pin]
        var outputs: [Pin]
        var parts: [Part]?
        var labels: [[String]]?
        var wires: [[String]]?
        var expected: [String: String]?
        var notes: [Note]?
    }
    var name: String
    var top: String?
    var sheets: [Sheet]

    struct Failure: Error, CustomStringConvertible { var description: String }

    func build() throws -> DesignProject {
        var db = TestDesigns.DesignBuilder(name, top: top ?? sheets.last?.name)
        for s in sheets {
            var b = db.builder(s.name)
            func location(_ l: String?) -> String? { l.map { BoardPin.named($0)?.pin ?? $0 } }
            var pins: [String: Component] = [:]
            b.p.inputOrder = s.inputs.map { p in
                let c = b.input(p.name, x: p.x ?? 32, y: p.y, loc: location(p.loc)); pins[p.name] = c; return c.id
            }
            for p in s.outputs {
                guard let x = p.x else { throw Failure(description: "\(s.name): output \(p.name) needs an x") }
                pins[p.name] = b.output(p.name, x: x, y: p.y, loc: location(p.loc))
            }
            var parts: [String: Component] = [:]
            for p in s.parts ?? [] {
                guard parts[p.id] == nil, pins[p.id] == nil else { throw Failure(description: "\(s.name): part id \(p.id) is used twice") }
                switch p.kind {
                case "block":
                    guard let e = p.of, db.symbols[e.lowercased()] != nil else {
                        throw Failure(description: "\(s.name): \(p.id) is a block of \(p.of ?? "?"), which has no symbol yet")
                    }
                    parts[p.id] = b.block(e, x: p.x, y: p.y)
                case "macro":
                    guard let m = p.of, MacroLibrary.named(m) != nil else { throw Failure(description: "\(s.name): no library macro \(p.of ?? "?")") }
                    parts[p.id] = b.macro(m, x: p.x, y: p.y)
                default:
                    guard let k = GateKind(rawValue: p.kind), GateKind.placeable.contains(k), k != .input, k != .output else {
                        throw Failure(description: "\(s.name): unknown part kind \(p.kind)")
                    }
                    parts[p.id] = b.gate(k, x: p.x, y: p.y)
                }
                if let n = p.name, let c = parts[p.id], let i = b.p.index(of: c.id) {
                    guard !b.p.components.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else {
                        throw Failure(description: "\(s.name): the name \(n) is used twice")
                    }
                    b.p.components[i].name = n
                    parts[p.id] = b.p.components[i]
                }
            }
            func end(_ e: String) throws -> PortRef {
                if let dot = e.firstIndex(of: "."), let c = parts[String(e[..<dot])] {
                    let port = String(e[e.index(after: dot)...])
                    guard let i = c.portIndex(named: port) else { throw Failure(description: "\(s.name): \(c.symbolName) has no port \(port) (\(e))") }
                    return PortRef(comp: c.id, port: i)
                }
                guard let c = pins[e] else { throw Failure(description: "\(s.name): no part or pin \(e)") }
                return PortRef(comp: c.id, port: 0)
            }
            for l in s.labels ?? [] {
                guard l.count == 2 else { throw Failure(description: "\(s.name): a label is [endpoint, name]") }
                b.label(try end(l[0]), l[1])
            }
            for w in s.wires ?? [] {
                guard w.count == 2 else { throw Failure(description: "\(s.name): a wire is [endpoint, endpoint]") }
                b.wire(try end(w[0]), try end(w[1]))
            }
            for (o, text) in s.expected ?? [:] {
                guard let c = pins[o], c.kind == .output else { throw Failure(description: "\(s.name): expected values for \(o), which is not an output") }
                guard Minterms.parse(text) != nil else { throw Failure(description: "\(s.name): expected minterms for \(o) do not parse") }
                b.p.expected[c.id.uuidString] = text
            }
            b.p.notes = s.notes.map { $0.map { TextNote(text: $0.text, x: $0.x, y: $0.y) } }
            db.sheet(b)
            if s.symbol == true { db.createSymbol(s.name) }
        }
        let errors = db.d.structuralErrors
        guard errors.isEmpty else { throw Failure(description: errors.joined(separator: "; ")) }
        return db.d
    }
}

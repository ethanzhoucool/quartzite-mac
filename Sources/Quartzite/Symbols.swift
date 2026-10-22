import Foundation

// Block symbols: the (symbol ...) of a .bsf or of a block / library macro placed in a .bdf.
//
// Quartus writes a block's symbol into its own .bsf with File > Create/Update > Create
// Symbol Files for Current File, and pastes that same (symbol ...) verbatim into every
// .bdf that instantiates the block. Only the rect (moved to the placement origin) and
// the instance name change. The rules below were read from .bsf and .bdf files written
// by Quartus Prime 18.0 Lite (ci/fixtures/quartus18/hier).

// MARK: - S-expressions

/// One node of a Quartus S-expression file (.bdf, .bsf).
indirect enum SExpr: Hashable {
    case atom(String)
    case string(String)
    case list([SExpr])

    var head: String? {
        if case .list(let items) = self, case .atom(let a)? = items.first { return a }
        return nil
    }
    var items: [SExpr] { if case .list(let items) = self { return items }; return [] }
    /// Child lists whose head is `key`.
    func children(_ key: String) -> [SExpr] { items.filter { $0.head == key } }
    func child(_ key: String) -> SExpr? { items.first { $0.head == key } }
    var stringValue: String? {
        switch self {
        case .string(let s), .atom(let s): return s
        case .list: return nil
        }
    }
    var isList: Bool { if case .list = self { return true }; return false }
}

/// Reader and writer for the S-expression layout Quartus uses. The tokenizer is a port of
/// `ci/bdf_check.py`'s: comments are dropped, strings keep their contents, everything else
/// is an atom.
enum SExprParser {
    struct ParseError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    enum Token: Equatable { case open, close, string(String), atom(String) }

    static func tokenize(_ text: String) -> [Token] {
        let s = Array(text.utf8)
        var out: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "/"), i + 1 < s.count, s[i + 1] == UInt8(ascii: "*") {
                var j = i + 2
                while j + 1 < s.count, !(s[j] == UInt8(ascii: "*") && s[j + 1] == UInt8(ascii: "/")) { j += 1 }
                i = min(s.count, j + 2)
                continue
            }
            switch c {
            case UInt8(ascii: "("): out.append(.open); i += 1
            case UInt8(ascii: ")"): out.append(.close); i += 1
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): i += 1
            case UInt8(ascii: "\""):
                var j = i + 1
                while j < s.count, s[j] != UInt8(ascii: "\"") {
                    if s[j] == UInt8(ascii: "\\") { j += 1 }
                    j += 1
                }
                out.append(.string(String(decoding: s[(i + 1)..<min(j, s.count)], as: UTF8.self)))
                i = j + 1
            default:
                var j = i
                while j < s.count {
                    let d = s[j]
                    if d == UInt8(ascii: "(") || d == UInt8(ascii: ")") || d == UInt8(ascii: "\"")
                        || d == UInt8(ascii: " ") || d == UInt8(ascii: "\t") || d == UInt8(ascii: "\n") || d == UInt8(ascii: "\r") { break }
                    j += 1
                }
                out.append(.atom(String(decoding: s[i..<j], as: UTF8.self)))
                i = j
            }
        }
        return out
    }

    /// All top-level expressions of a file.
    static func parse(_ text: String) throws -> [SExpr] {
        var stack: [[SExpr]] = []
        var cur: [SExpr] = []
        for t in tokenize(text) {
            switch t {
            case .open: stack.append(cur); cur = []
            case .close:
                guard let up = stack.popLast() else { throw ParseError(message: "unbalanced ')'") }
                let done = SExpr.list(cur)
                cur = up
                cur.append(done)
            case .string(let s): cur.append(.string(s))
            case .atom(let a): cur.append(.atom(a))
            }
        }
        guard stack.isEmpty else { throw ParseError(message: "unbalanced '('") }
        return cur
    }

    /// Lists Quartus writes over several lines, one child per line.
    static let blockHeads: Set<String> = ["symbol", "port", "drawing", "pin", "connector"]

    /// One expression on one line, spaced like Quartus: a space before atoms and before a
    /// list that follows an atom, none between consecutive lists, and `(font "Arial" )`.
    static func inline(_ e: SExpr) -> String {
        switch e {
        case .atom(let a): return a
        case .string(let s): return "\"\(s)\""
        case .list(let items):
            var out = "("
            for (k, item) in items.enumerated() {
                if k == 0 { out += inline(item); continue }
                if item.isList && items[k - 1].isList { out += inline(item) } else { out += " " + inline(item) }
            }
            if e.head == "font", let last = items.last, !last.isList { out += " " }
            return out + ")"
        }
    }

    static func lines(_ e: SExpr, indent: Int = 0) -> [String] {
        let tabs = String(repeating: "\t", count: indent)
        if let h = e.head, blockHeads.contains(h) {
            return [tabs + "(" + h] + e.items.dropFirst().flatMap { lines($0, indent: indent + 1) } + [tabs + ")"]
        }
        return [tabs + inline(e)]
    }

    /// The text of `e` with Quartus' layout, each line ended by `eol`.
    static func write(_ e: SExpr, eol: String) -> String {
        lines(e).map { $0 + eol }.joined()
    }
}

// MARK: - Symbol model

/// A (text ...) element: `(text "x" (rect 0 0 5 19)(font "Intel Clear" (font_size 8)))`.
struct SymText: Codable, Hashable {
    var text: String
    var rect: [Int]
    var font: String
    var size: Int?
    var bold = false
    var invisible = false

    var cgRect: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1]) }

    var sexpr: SExpr {
        var font: [SExpr] = [.atom("font"), .string(self.font)]
        if let size { font.append(.list([.atom("font_size"), .atom("\(size)")])) }
        if bold { font.append(.list([.atom("bold")])) }
        var items: [SExpr] = [.atom("text"), .string(text), .list([.atom("rect")] + rect.map { .atom("\($0)") }), .list(font)]
        if invisible { items.append(.list([.atom("invisible")])) }
        return .list(items)
    }

    init(text: String, rect: [Int], font: String, size: Int? = nil, bold: Bool = false, invisible: Bool = false) {
        self.text = text; self.rect = rect; self.font = font; self.size = size; self.bold = bold; self.invisible = invisible
    }

    init(_ e: SExpr) throws {
        let items = e.items
        guard e.head == "text", items.count >= 4, case .string(let t) = items[1], items[2].head == "rect",
              items[3].head == "font", case .string(let f)? = items[3].items.dropFirst().first else {
            throw SExprParser.ParseError(message: "unsupported text: \(SExprParser.inline(e))")
        }
        text = t; rect = try SymbolDef.ints(items[2], 4); font = f
        for a in items[3].items.dropFirst(2) {
            switch a.head {
            case "font_size": size = try SymbolDef.ints(a, 1)[0]
            case "bold": bold = true
            default: throw SExprParser.ParseError(message: "unsupported font attribute: \(SExprParser.inline(a))")
            }
        }
        for a in items.dropFirst(4) {
            guard a.head == "invisible" else { throw SExprParser.ParseError(message: "unsupported text attribute: \(SExprParser.inline(a))") }
            invisible = true
        }
    }
}

/// One (port ...) of a symbol, in local coordinates.
struct SymPort: Codable, Hashable {
    var name: String
    var isOutput: Bool
    var pt: [Int]
    /// The port name text Quartus keeps first (its rect is the text's own size for blocks).
    var text1: SymText
    /// The visible label.
    var text2: SymText
    /// The lead, exactly as written: (line (pt ..)(pt ..)) as x1 y1 x2 y2.
    var line: [Int]?

    var point: CGPoint { CGPoint(x: pt[0], y: pt[1]) }
}

/// One element of a symbol's (drawing ...).
enum SymShape: Codable, Hashable {
    case line([Int])
    case rectangle([Int])
    case circle([Int])
    /// p1, p2 and the ellipse rect: 8 values.
    case arc([Int])
    case text(SymText)
}

/// A block (from a sheet of the project) or library symbol (a macro, VCC or GND).
struct SymbolDef: Codable, Hashable {
    enum Source: String, Codable { case project, library }

    /// Block name: the entity / .bdf file name for project blocks ("HA"), the library name otherwise ("7447").
    var name: String
    var source: Source
    /// Folder in the Symbol dialog, e.g. ["others", "maxplus2"] (library symbols only).
    var libraryPath: [String]? = nil
    var width: Int
    var height: Int
    var nameText: SymText
    var instanceText: SymText
    /// In file order. A placed symbol's PortRef.port indexes this array.
    var ports: [SymPort]
    var drawing: [SymShape]

    static func ints(_ e: SExpr, _ n: Int) throws -> [Int] {
        let v = e.items.dropFirst().compactMap { $0.stringValue.flatMap { Int($0) } }
        guard v.count == n, e.items.count == n + 1 else { throw SExprParser.ParseError(message: "expected \(n) numbers in \(SExprParser.inline(e))") }
        return v
    }

    private static func points(_ e: SExpr) throws -> [Int] { try e.children("pt").flatMap { try ints($0, 2) } }

    init(name: String, source: Source, libraryPath: [String]? = nil, width: Int, height: Int,
         nameText: SymText, instanceText: SymText, ports: [SymPort], drawing: [SymShape]) {
        self.name = name; self.source = source; self.libraryPath = libraryPath
        self.width = width; self.height = height
        self.nameText = nameText; self.instanceText = instanceText; self.ports = ports; self.drawing = drawing
    }

    /// Reads the first (symbol ...) in `symbolText` (a .bsf, a .bdf or the bare symbol).
    init(parsing symbolText: String, source: Source = .project, libraryPath: [String]? = nil) throws {
        guard let sym = try SExprParser.parse(symbolText).first(where: { $0.head == "symbol" }) else {
            throw SExprParser.ParseError(message: "no (symbol ...) found")
        }
        try self.init(sym, source: source, libraryPath: libraryPath)
    }

    init(_ sym: SExpr, source: Source, libraryPath: [String]? = nil) throws {
        guard let rectE = sym.child("rect") else { throw SExprParser.ParseError(message: "symbol has no rect") }
        let r = try SymbolDef.ints(rectE, 4)
        let texts = try sym.children("text").map(SymText.init)
        guard texts.count == 2 else { throw SExprParser.ParseError(message: "symbol needs a name and an instance text") }
        var ports: [SymPort] = []
        for p in sym.children("port") {
            guard let ptE = p.child("pt") else { throw SExprParser.ParseError(message: "port without pt") }
            let pts = try p.children("text").map(SymText.init)
            guard pts.count == 2, p.child("input") != nil || p.child("output") != nil else {
                throw SExprParser.ParseError(message: "unsupported port: \(SExprParser.inline(p))")
            }
            let line = try p.child("line").map { l -> [Int] in
                let v = try SymbolDef.points(l)
                guard v.count == 4, l.items.count == 3 else { throw SExprParser.ParseError(message: "unsupported port line: \(SExprParser.inline(l))") }
                return v
            }
            ports.append(SymPort(name: pts[0].text, isOutput: p.child("output") != nil, pt: try SymbolDef.ints(ptE, 2),
                                 text1: pts[0], text2: pts[1], line: line))
        }
        var drawing: [SymShape] = []
        for d in sym.child("drawing")?.items.dropFirst() ?? [] {
            switch d.head {
            case "line":
                let v = try SymbolDef.points(d)
                guard v.count == 4, d.items.count == 3 else { throw SExprParser.ParseError(message: "unsupported line: \(SExprParser.inline(d))") }
                drawing.append(.line(v))
            case "rectangle", "circle":
                guard let rr = d.child("rect"), d.items.count == 2 else { throw SExprParser.ParseError(message: "unsupported \(d.head!): \(SExprParser.inline(d))") }
                let v = try SymbolDef.ints(rr, 4)
                drawing.append(d.head == "rectangle" ? .rectangle(v) : .circle(v))
            case "arc":
                guard let rr = d.child("rect"), d.items.count == 4 else { throw SExprParser.ParseError(message: "unsupported arc: \(SExprParser.inline(d))") }
                let v = try SymbolDef.points(d) + SymbolDef.ints(rr, 4)
                guard v.count == 8 else { throw SExprParser.ParseError(message: "unsupported arc: \(SExprParser.inline(d))") }
                drawing.append(.arc(v))
            case "text": drawing.append(.text(try SymText(d)))
            default: throw SExprParser.ParseError(message: "unsupported drawing element: \(SExprParser.inline(d))")
            }
        }
        self.init(name: texts[0].text, source: source, libraryPath: libraryPath, width: r[2] - r[0], height: r[3] - r[1],
                  nameText: texts[0], instanceText: texts[1], ports: ports, drawing: drawing)
    }

    var inputs: [SymPort] { ports.filter { !$0.isOutput } }
    var outputs: [SymPort] { ports.filter { $0.isOutput } }
    func portIndex(named n: String) -> Int? { ports.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } }

    /// The instance-name text for `instance`. Quartus sizes a block's text to the name (R7);
    /// library symbols keep the rect of their template.
    func instanceText(for instance: String) -> SymText {
        var t = instanceText
        t.text = instance
        if source == .project { t.rect[2] = t.rect[0] + TextMetrics.intelClear8(instance) }
        return t
    }

    /// The (symbol ...) placed at `origin` (rect origin) with the given instance name.
    func sexpr(origin: CGPoint, instance: String) -> SExpr {
        let x = Int(origin.x.rounded()), y = Int(origin.y.rounded())
        func pt(_ a: Int, _ b: Int) -> SExpr { .list([.atom("pt"), .atom("\(a)"), .atom("\(b)")]) }
        func rect(_ v: [Int]) -> SExpr { .list([.atom("rect")] + v.map { .atom("\($0)") }) }
        var items: [SExpr] = [.atom("symbol"), rect([x, y, x + width, y + height]), nameText.sexpr, instanceText(for: instance).sexpr]
        for p in ports {
            var port: [SExpr] = [.atom("port"), pt(p.pt[0], p.pt[1]), .list([.atom(p.isOutput ? "output" : "input")]), p.text1.sexpr, p.text2.sexpr]
            if let l = p.line { port.append(.list([.atom("line"), pt(l[0], l[1]), pt(l[2], l[3])])) }
            items.append(.list(port))
        }
        var draw: [SExpr] = [.atom("drawing")]
        for d in drawing {
            switch d {
            case .line(let v): draw.append(.list([.atom("line"), pt(v[0], v[1]), pt(v[2], v[3])]))
            case .rectangle(let v): draw.append(.list([.atom("rectangle"), rect(v)]))
            case .circle(let v): draw.append(.list([.atom("circle"), rect(v)]))
            case .arc(let v): draw.append(.list([.atom("arc"), pt(v[0], v[1]), pt(v[2], v[3]), rect(Array(v[4...]))]))
            case .text(let t): draw.append(t.sexpr)
            }
        }
        items.append(.list(draw))
        return .list(items)
    }

    /// The (symbol ...) text, tab-indented like Quartus, each line ended by `lineEnding`.
    func text(rect origin: CGPoint, instance: String, lineEnding: String) -> String {
        SExprParser.write(sexpr(origin: origin, instance: instance), eol: lineEnding)
    }

    /// Geometry for the canvas, the router and connectivity. A port's lead runs from its
    /// pt to the other end of its line; the body is the box around the outline's lines
    /// and rectangles.
    var primitive: Primitive {
        let ps = ports.map { p -> PortGeometry in
            let pt = p.point
            var end = pt
            if let l = p.line {
                let a = CGPoint(x: l[0], y: l[1]), b = CGPoint(x: l[2], y: l[3])
                end = a == pt ? b : a
            }
            return PortGeometry(pt: pt, lineEnd: end, isOutput: p.isOutput, name: p.name)
        }
        func r(_ v: [Int]) -> CGRect { CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) }
        var shapes: [Shape] = []
        var body: CGRect = .null
        for d in drawing {
            switch d {
            case .line(let v):
                let a = CGPoint(x: v[0], y: v[1]), b = CGPoint(x: v[2], y: v[3])
                shapes.append(.line(a, b))
                body = body.union(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            case .rectangle(let v):
                shapes.append(.rectangle(r(v)))
                body = body.union(r(v))
            case .circle(let v): shapes.append(.circle(r(v)))
            case .arc(let v): shapes.append(.arc(CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]), r(Array(v[4...]))))
            case .text: break
            }
        }
        if body.isNull { body = CGRect(x: 0, y: 0, width: width, height: height) }
        return Primitive(size: CGSize(width: width, height: height), ports: ps, drawing: shapes, body: body)
    }
}

// MARK: - Text metrics

enum TextMetrics {
    /// Widths Quartus 18.0 wrote for Intel Clear 8 pt text in the fixtures (text rect width).
    static let measured: [String: Int] = [
        "x": 5, "y": 7, "s": 5, "cout": 24, "b": 8, "z": 5, "a_long_input": 76, "result_out": 59,
        "HA": 17, "BIGBLK": 44, "inst": 16, "inst1": 22,
    ]

    // PROVISIONAL until CT-0b P2-6: per-character estimates fitted to the samples above.
    static let perCharacter: [Character: Int] = {
        var w: [Character: Int] = [:]
        let lower: [(Character, Int)] = [("a", 6), ("b", 8), ("c", 6), ("d", 8), ("e", 7), ("f", 4), ("g", 8), ("h", 7), ("i", 3),
                                         ("j", 3), ("k", 6), ("l", 3), ("m", 10), ("n", 7), ("o", 7), ("p", 8), ("q", 8), ("r", 5),
                                         ("s", 5), ("t", 4), ("u", 7), ("v", 6), ("w", 9), ("x", 5), ("y", 7), ("z", 5)]
        let upper: [(Character, Int)] = [("A", 8), ("B", 8), ("C", 8), ("D", 9), ("E", 7), ("F", 7), ("G", 9), ("H", 9), ("I", 3),
                                         ("J", 4), ("K", 8), ("L", 6), ("M", 11), ("N", 9), ("O", 9), ("P", 8), ("Q", 9), ("R", 8),
                                         ("S", 7), ("T", 7), ("U", 9), ("V", 8), ("W", 12), ("X", 8), ("Y", 7), ("Z", 7)]
        for (c, v) in lower + upper { w[c] = v }
        for d in "0123456789" { w[d] = 6 }
        w["_"] = 8
        return w
    }()

    /// Width of `s` in Intel Clear 8 pt as Quartus sizes symbol texts: exact for the
    /// measured strings, estimated per character otherwise.
    static func intelClear8(_ s: String) -> Int {
        if let m = measured[s] { return m }
        return s.reduce(0) { $0 + (perCharacter[$1] ?? 6) }
    }
}

// MARK: - Create Symbol Files for Current File

/// The symbol Quartus' File > Create/Update > Create Symbol Files for Current File makes
/// for a sheet (rules R2 to R9 in the plan, from the HA and BIGBLK fixtures).
enum SymbolGenerator {
    /// Gap between the longest input and output labels (PROVISIONAL until CT-0b P2-7; the samples bound it to 10...25).
    static let K = 10
    /// Bottom of the body for a given number of port rows (PROVISIONAL until CT-0b P1-1/P1-3; confirmed for 2 rows).
    static func bodyBottom(_ rows: Int) -> Int { 16 * rows + 48 }

    static func roundUp16(_ v: Int) -> Int { (v + 15) / 16 * 16 }

    static func font(_ s: String, _ rect: [Int], size: Int? = 8) -> SymText {
        SymText(text: s, rect: rect, font: "Intel Clear", size: size)
    }

    /// Input and output pins in symbol port order: by position on the sheet, top to bottom.
    static func portOrder(_ sheet: Project) -> (inputs: [Component], outputs: [Component]) {
        func order(_ a: Component, _ b: Component) -> Bool { (a.y, a.x, a.name) < (b.y, b.x, b.name) }
        return (sheet.components.filter { $0.kind == .input }.sorted(by: order),
                sheet.components.filter { $0.kind == .output }.sorted(by: order))
    }

    static func symbol(for sheet: Project) -> SymbolDef {
        let (ins, outs) = portOrder(sheet)
        let tw = TextMetrics.intelClear8
        let rows = max(ins.count, outs.count, 1)
        let B = bodyBottom(rows)
        let H = B + 16
        let maxIn = ins.map { tw($0.name) }.max() ?? 0
        let maxOut = outs.map { tw($0.name) }.max() ?? 0
        let W = 32 + max(64, roundUp16(maxIn + maxOut + K))
        var ports: [SymPort] = []
        for (k, p) in ins.enumerated() {
            let y = 32 + 16 * k, w = tw(p.name)
            ports.append(SymPort(name: p.name, isOutput: false, pt: [0, y], text1: font(p.name, [0, 0, w, 19]),
                                 text2: font(p.name, [21, y - 5, 21 + w, y + 14]), line: [0, y, 16, y]))
        }
        for (k, p) in outs.enumerated() {
            let y = 32 + 16 * k, w = tw(p.name)
            ports.append(SymPort(name: p.name, isOutput: true, pt: [W, y], text1: font(p.name, [0, 0, w, 19]),
                                 text2: font(p.name, [W - 21 - w, y - 5, W - 21, y + 14]), line: [W, y, W - 16, y]))
        }
        let e = sheet.entityName
        return SymbolDef(name: e, source: .project, width: W, height: H,
                         nameText: font(e, [5, 0, 5 + tw(e), 19]),
                         instanceText: font("inst", [8, B - 5, 8 + tw("inst"), B + 12], size: nil),
                         ports: ports, drawing: [.rectangle([16, 16, W - 16, B])])
    }
}

extension QuartusExport {
    /// The .bsf Quartus' Create Symbol Files writes (R1): CRLF, the warning comment, a
    /// short provenance comment (not Intel's copyright text), the header and the symbol.
    static func bsf(_ def: SymbolDef) -> String {
        let eol = "\r\n"
        let head = [
            "/*",
            "WARNING: Do NOT edit the input and output ports in this file in a text",
            "editor if you plan to continue editing the block that represents it in",
            "the Block Editor! File corruption is VERY likely to occur.",
            "*/",
            "/*",
            "Symbol for \(def.name).bdf, written by Quartzite for Mac.",
            "*/",
            "(header \"symbol\" (version \"1.2\"))",
        ]
        return head.map { $0 + eol }.joined() + def.text(rect: CGPoint(x: 16, y: 16), instance: "inst", lineEnding: eol)
    }
}

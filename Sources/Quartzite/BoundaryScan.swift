import Foundation

/// Reads the DE10-Standard's switches, push buttons, LEDs and seven-segment displays while
/// the user's design runs, with the IEEE 1149.1 SAMPLE/PRELOAD instruction. SAMPLE copies the
/// level of every I/O pad into the boundary-scan register and shifts it out; the pins stay
/// connected to the core, so the running design is not disturbed. (EXTEST, which would drive
/// the pins from the register, is never used.)
///
/// The pin-to-cell map comes from the device's BSDL file, which the user downloads from
/// Intel's BSDL page (Quartzite does not ship it). The scan itself is an SVF file played by
/// openFPGALoader against the FPGA only (the HPS is put in BYPASS by openFPGALoader).
/// openFPGALoader prints the captured bits when they differ from the expected all-zero
/// value, and exits normally when every bit is zero, so the register is known either way.

/// The subset of a BSDL file Quartzite needs.
struct BSDLFile {
    struct Cell: Equatable {
        var number: Int
        var type: String
        var port: String
        var function: String
    }

    var entity: String
    var instructionLength: Int
    var boundaryLength: Int
    /// Instruction name -> opcode bits as written ("0000000101").
    var opcodes: [String: String]
    var cells: [Cell]
    /// Port name -> package ball ("IOAB30" -> "AB30").
    var pinMap: [String: String]

    struct ParseError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { "BSDL: \(message)" }
    }

    init(text raw: String) throws {
        // Drop "--" comments (BSDL strings never contain "--").
        let text = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> Substring in
            if let r = line.range(of: "--") { return line[line.startIndex..<r.lowerBound] }
            return line
        }.joined(separator: "\n")

        func firstMatch(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
        /// The concatenated string literals of `attribute <name> ... is "..." & "...";`.
        func strings(after pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { return nil }
            var out = "", inString = false
            for ch in text[r.upperBound...] {
                if ch == "\"" { inString.toggle(); continue }
                if inString { out.append(ch) } else if ch == ";" { break }
            }
            return out
        }

        guard let e = firstMatch("\\bentity\\s+(\\w+)\\s+is") else { throw ParseError(message: "no entity declaration") }
        entity = e[1]
        guard let il = firstMatch("attribute\\s+INSTRUCTION_LENGTH\\s+of\\s+\\w+\\s*:\\s*entity\\s+is\\s+(\\d+)"), let n = Int(il[1]) else {
            throw ParseError(message: "no INSTRUCTION_LENGTH")
        }
        instructionLength = n
        guard let bl = firstMatch("attribute\\s+BOUNDARY_LENGTH\\s+of\\s+\\w+\\s*:\\s*entity\\s+is\\s+(\\d+)"), let b = Int(bl[1]) else {
            throw ParseError(message: "no BOUNDARY_LENGTH")
        }
        boundaryLength = b

        opcodes = [:]
        if let s = strings(after: "attribute\\s+INSTRUCTION_OPCODE\\s+of\\s+\\w+\\s*:\\s*entity\\s+is"),
           let re = try? NSRegularExpression(pattern: "(\\w+)\\s*\\(([01,\\s]+)\\)") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let a = Range(m.range(at: 1), in: s), let c = Range(m.range(at: 2), in: s) else { continue }
                let first = s[c].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                opcodes[s[a].uppercased()] = first
            }
        }

        cells = []
        guard let reg = strings(after: "attribute\\s+BOUNDARY_REGISTER\\s+of\\s+\\w+\\s*:\\s*entity\\s+is"),
              let re = try? NSRegularExpression(pattern: "(\\d+)\\s*\\(([^)]*)\\)") else { throw ParseError(message: "no BOUNDARY_REGISTER") }
        for m in re.matches(in: reg, range: NSRange(reg.startIndex..., in: reg)) {
            guard let a = Range(m.range(at: 1), in: reg), let c = Range(m.range(at: 2), in: reg), let num = Int(reg[a]) else { continue }
            let f = reg[c].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3 else { continue }
            cells.append(Cell(number: num, type: f[0], port: f[1], function: f[2].lowercased()))
        }
        guard !cells.isEmpty else { throw ParseError(message: "the boundary register lists no cells") }
        guard cells.allSatisfy({ $0.number >= 0 && $0.number < b }) else {
            throw ParseError(message: "a boundary cell number is outside BOUNDARY_LENGTH \(boundaryLength)")
        }

        pinMap = [:]
        if let s = strings(after: "constant\\s+\\w+\\s*:\\s*PIN_MAP_STRING\\s*:=") {
            for entry in s.split(separator: ",") {
                let kv = entry.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty, !kv[1].hasPrefix("(") { pinMap[kv[0]] = kv[1] }
            }
        }
    }

    /// The cell that captures the pad level of package ball `ball` ("AB30").
    func inputCell(ball: String) -> Int? {
        let ports = pinMap.isEmpty ? ["IO" + ball] : pinMap.filter { $0.value == ball }.map(\.key)
        return cells.first { ports.contains($0.port) && ($0.function == "input" || $0.function == "bidir" || $0.function == "observe_only") }?.number
    }
}

/// Live state of the DE10-Standard's user I/O, as a person would see it.
struct BoardState: Equatable {
    /// SW0-SW9 up (logic 1).
    var switches = [Bool](repeating: false, count: 10)
    /// KEY0-KEY3 pressed (the pin is low; the buttons are active low).
    var keysPressed = [Bool](repeating: false, count: 4)
    /// LEDR0-LEDR9 lit (the pin is high).
    var leds = [Bool](repeating: false, count: 10)
    /// HEX0-HEX5 segments a-g lit (the pin is low; the displays are active low).
    var segments = [[Bool]](repeating: [Bool](repeating: false, count: 7), count: 6)
}

/// The DE10-Standard's user I/O pins in the boundary-scan register of its 5CSXFC6D6F31.
struct BoardScanMap {
    var boundaryLength: Int
    var instructionLength: Int
    var sampleOpcode: String
    /// BoardPin label ("SW0", "HEX3[6]") -> boundary cell.
    var cells: [String: Int]

    /// The board pins whose levels the Board view shows.
    static var boardPins: [BoardPin] {
        BoardPin.de10Standard.filter { [.slideSwitch, .pushButton, .led, .sevenSegment].contains($0.kind) }
    }

    init(bsdl: BSDLFile) throws {
        guard bsdl.entity.uppercased().contains(Programmer.boardFPGA) else {
            throw BSDLFile.ParseError(message: "this BSDL file describes \(bsdl.entity); the DE10-Standard needs the one for \(Programmer.boardFPGA) (5CSXFC6D6F31.bsd)")
        }
        guard let op = bsdl.opcodes["SAMPLE"] ?? bsdl.opcodes["SAMPLE/PRELOAD"], op.count == bsdl.instructionLength,
              op.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw BSDLFile.ParseError(message: "no SAMPLE instruction of \(bsdl.instructionLength) bits")
        }
        boundaryLength = bsdl.boundaryLength
        instructionLength = bsdl.instructionLength
        sampleOpcode = op
        cells = [:]
        var missing: [String] = []
        for p in BoardScanMap.boardPins {
            let ball = p.pin.hasPrefix("PIN_") ? String(p.pin.dropFirst(4)) : p.pin
            if let c = bsdl.inputCell(ball: ball) { cells[p.label] = c } else { missing.append("\(p.label) (\(ball))") }
        }
        guard missing.isEmpty else { throw BSDLFile.ParseError(message: "no input cell for \(missing.joined(separator: ", "))") }
    }

    /// Hex digits for `bits` bits, most significant first, as SVF writes them (upper case).
    static func hex(_ bits: [Bool]) -> String {
        let digits = (bits.count + 3) / 4
        var s = ""
        for d in stride(from: digits - 1, through: 0, by: -1) {
            var v = 0
            for b in 0..<4 where d * 4 + b < bits.count && bits[d * 4 + b] { v |= 1 << b }
            s.append(String(v, radix: 16).uppercased())
        }
        return s
    }

    /// Bits of an SVF-style hex string, bit 0 (the first bit shifted out, cell 0) first.
    static func bits(hex: String, count: Int) -> [Bool]? {
        let h = hex.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out = [Bool](repeating: false, count: count)
        for (i, ch) in h.reversed().enumerated() {
            guard let v = Int(String(ch), radix: 16) else { return nil }
            for b in 0..<4 where i * 4 + b < count { out[i * 4 + b] = v & (1 << b) != 0 }
        }
        return out
    }

    /// One SAMPLE scan. TDI is all zero (PRELOAD of zeros has no effect while SAMPLE keeps the
    /// pins in user mode); TDO is compared with zero under a full mask, so openFPGALoader
    /// prints the captured register whenever any pin is high.
    func svf() -> String {
        let irHex = BoardScanMap.hex(sampleOpcode.reversed().map { $0 == "1" })
        let zero = BoardScanMap.hex([Bool](repeating: false, count: boundaryLength))
        let mask = BoardScanMap.hex([Bool](repeating: true, count: boundaryLength))
        return """
            ! Quartzite board view: boundary-scan SAMPLE of the DE10-Standard FPGA pins.
            ! SAMPLE leaves every pin under control of the running design.
            ENDIR IDLE;
            ENDDR IDLE;
            SIR \(instructionLength) TDI (\(irHex));
            SDR \(boundaryLength) TDI (\(zero)) TDO (\(zero)) MASK (\(mask));

            """
    }

    /// The captured register from openFPGALoader's output: the bits it printed, all zeros when
    /// it exited normally, nil when the scan did not happen.
    func capture(output: String, status: Int32) -> [Bool]? {
        let text = Programmer.plain(output)
        if let r = text.range(of: "TDO value ([0-9A-Fa-f]+) isn't the one expected", options: .regularExpression) {
            let hex = text[r].dropFirst("TDO value ".count).prefix { $0.isHexDigit }
            return BoardScanMap.bits(hex: String(hex), count: boundaryLength)
        }
        return status == 0 && text.contains("end of SVF file") ? [Bool](repeating: false, count: boundaryLength) : nil
    }

    func decode(_ bits: [Bool]) -> BoardState {
        func level(_ label: String) -> Bool { cells[label].map { $0 < bits.count && bits[$0] } ?? false }
        var s = BoardState()
        for i in 0..<10 { s.switches[i] = level("SW\(i)"); s.leds[i] = level("LEDR\(i)") }
        for i in 0..<4 { s.keysPressed[i] = !level("KEY\(i)") }
        for d in 0..<6 { for g in 0..<7 { s.segments[d][g] = !level("HEX\(d)[\(g)]") } }
        return s
    }
}

extension ProgrammerService {
    /// One boundary-scan SAMPLE of the FPGA at `index`, decoded into board state.
    func sampleBoard(map: BoardScanMap, index: Int, workDirectory: URL) throws -> BoardState {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let svf = workDirectory.appendingPathComponent("board_sample.svf")
        try map.svf().write(to: svf, atomically: true, encoding: .utf8)
        let args = Programmer.svfArgs(options, index: index, svf: svf)
        let r = try runner.run(options.tool, args, cancel: cancel, onLine: nil)
        if r.cancelled { throw ProgrammerError.cancelled }
        guard let bits = map.capture(output: r.output, status: r.status) else { throw Programmer.diagnose(r.output, options: options) }
        return map.decode(bits)
    }

    /// Where to download the BSDL file and what to choose.
    static let bsdlHelp = """
        The Board view needs the boundary-scan description (BSDL) of the DE10-Standard's FPGA. Download \
        the Cyclone V BSDL file for 5CSXFC6D6F31 (pre-configuration) from Intel's "BSDL Files" page \
        (search for "Cyclone V BSDL"), then choose the .bsd file in Settings > Programmer. Quartzite \
        does not include it because it belongs to Intel.
        """
}

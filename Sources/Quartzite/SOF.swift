import Foundation

// SRAM Object File (.sof) reader/writer and Cyclone V raw binary (.rbf) converter.
// The byte-level format and the evidence for each rule are in docs/SOF_FORMAT.md.

enum SOFError: Error, LocalizedError {
    case badMagic
    case truncated(String)
    case missingRecord(UInt16)
    case unsupportedDevice(String)
    case badRBF(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let s): return "invalid SOF: \(s)"
        case .badMagic: return "not an SRAM Object File (missing \"SOF\\0\" magic)"
        case .truncated(let s): return "truncated file: \(s)"
        case .missingRecord(let t): return String(format: "SOF has no record with tag 0x%04x", t)
        case .unsupportedDevice(let d): return "unsupported device \(d) (only Cyclone V parts on the sx120f die are known)"
        case .badRBF(let s): return "not a usable Cyclone V .rbf: \(s)"
        }
    }
}

// MARK: - Checksums

enum SOFChecksum {
    /// CRC-16/X-25: poly 0x1021 reflected (0x8408), init 0xFFFF, xorout 0xFFFF. Covers record tag 0x0008.
    static func crc16X25(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for b in bytes {
            c = (c >> 8) ^ x25Table[Int((c ^ UInt16(b)) & 0xFF)]
        }
        return c ^ 0xFFFF
    }

    /// The Cyclone V bitstream CRC used for option, PRAM and CRAM frames
    /// (poly 0x8005 reflected = 0xA001, init 0xFFFF, no final xor; Mistral's `crc16`).
    static func crc16Frame(_ p: UnsafePointer<UInt8>, _ count: Int) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for i in 0..<count {
            c = (c >> 8) ^ a001Table[Int((c ^ UInt16(p[i])) & 0xFF)]
        }
        return c
    }

    /// Sum of all bytes (mod 2^32). The SOF checksum (tag 0x0013, also the default JTAG usercode)
    /// is this sum over the CRAM payload plus the PRAM payload.
    static func byteSum(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { buf -> UInt32 in
            var s: UInt32 = 0
            for b in buf { s &+= UInt32(b) }
            return s
        }
    }

    private static func table(_ poly: UInt16) -> [UInt16] {
        (0..<256).map { i -> UInt16 in
            var c = UInt16(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ poly : c >> 1 }
            return c
        }
    }
    static let x25Table = table(0x8408)
    static let a001Table = table(0xA001)
}

// MARK: - Container

struct SOFFile {
    struct Record {
        var tag: UInt16
        var body: Data
    }

    /// Embedded file from record 0x0024 (design_hash.bin, the .jdi, the .sld, sopcinfo, ...).
    struct EmbeddedFile: Equatable {
        var timestamp: UInt32   // Unix time (0 for design_hash.bin)
        var flags: UInt16       // 0x0100 on IP debug files (sopcinfo/regmap/debuginfo), else 0
        var reserved: UInt16
        var name: String
        var data: Data
    }

    enum Tag {
        static let compilerVersion: UInt16 = 0x0001
        static let device: UInt16 = 0x0002
        static let designName: UInt16 = 0x0003
        static let crc: UInt16 = 0x0008
        static let cram: UInt16 = 0x0011
        static let options: UInt16 = 0x0012
        static let checksum: UInt16 = 0x0013
        static let pram: UInt16 = 0x0015
        static let files: UInt16 = 0x0024
        static let unknown33: UInt16 = 0x0033
        static let hash: UInt16 = 0x003B
    }

    /// The u32 at offset 4 (0 in every sample).
    var reserved: UInt32 = 0
    /// The u32 at offset 8 as stored (equals records.count in every sample).
    var storedCount: UInt32 = 0
    var records: [Record] = []

    init() {}

    init(data: Data) throws {
        let d = [UInt8](data)
        guard d.count >= 12, d[0] == 0x53, d[1] == 0x4F, d[2] == 0x46, d[3] == 0 else { throw SOFError.badMagic }
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
        reserved = u32(4)
        storedCount = u32(8)
        var p = 12
        while p < d.count {
            guard p + 6 <= d.count else { throw SOFError.truncated("record header at \(p)") }
            let tag = UInt16(d[p]) | UInt16(d[p + 1]) << 8
            let len = Int(u32(p + 2))
            guard p + 6 + len <= d.count else { throw SOFError.truncated(String(format: "record 0x%04x at %d", tag, p)) }
            records.append(Record(tag: tag, body: Data(d[(p + 6)..<(p + 6 + len)])))
            p += 6 + len
        }
    }

    init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    /// Serialise the records as stored. If the last record is the CRC (0x0008, 2 bytes) its value
    /// is recomputed, which reproduces the original bytes for any valid file.
    func serialize(updateCount: Bool = false) -> Data {
        var out = Data()
        out.reserveCapacity(12 + records.reduce(0) { $0 + 6 + $1.body.count })
        out.append(contentsOf: [0x53, 0x4F, 0x46, 0x00])
        appendU32(&out, reserved)
        appendU32(&out, updateCount ? UInt32(records.count) : storedCount)
        for (i, r) in records.enumerated() {
            appendU16(&out, r.tag)
            appendU32(&out, UInt32(r.body.count))
            if r.tag == Tag.crc && r.body.count == 2 && i == records.count - 1 {
                let crc = out.withUnsafeBytes { SOFChecksum.crc16X25($0) }
                appendU16(&out, crc)
            } else {
                out.append(r.body)
            }
        }
        return out
    }

    // MARK: Accessors

    func body(_ tag: UInt16) -> Data? { records.first { $0.tag == tag }?.body }

    private func string(_ tag: UInt16) -> String? {
        guard var b = body(tag) else { return nil }
        if b.last == 0 { b.removeLast() }
        return String(decoding: b, as: UTF8.self)
    }

    var compilerVersion: String? { string(Tag.compilerVersion) }
    var device: String? { string(Tag.device) }
    var designName: String? { string(Tag.designName) }

    /// Checksum stored in record 0x0013 (u32 LE at offset 12).
    var storedChecksum: UInt32? {
        guard let b = body(Tag.checksum), b.count >= 16 else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }.littleEndian
    }

    var storedCRC: UInt16? {
        guard let r = records.last, r.tag == Tag.crc, r.body.count == 2 else { return nil }
        return UInt16(r.body[r.body.startIndex]) | UInt16(r.body[r.body.startIndex + 1]) << 8
    }

    /// CRC-16/X-25 over everything before the CRC value.
    func computedCRC() -> UInt16? {
        guard storedCRC != nil else { return nil }
        let d = serialize()
        return d.withUnsafeBytes { SOFChecksum.crc16X25(UnsafeRawBufferPointer(rebasing: $0[0..<(d.count - 2)])) }
    }

    /// Payload records 0x0011 / 0x0015: 6 zero bytes, u32 bit count, u16 1, then ceil(bits/8) bytes, LSB first.
    static func payload(of body: Data) -> (bits: Int, data: Data)? {
        guard body.count >= 12 else { return nil }
        let b = [UInt8](body.prefix(12))
        let bits = Int(UInt32(b[6]) | UInt32(b[7]) << 8 | UInt32(b[8]) << 16 | UInt32(b[9]) << 24)
        let n = (bits + 7) / 8
        guard body.count == 12 + n, b.prefix(6).allSatisfy({ $0 == 0 }), b[10] == 1, b[11] == 0 else { return nil }
        if bits % 8 != 0, let last = body.last, last >> (bits % 8) != 0 { return nil }
        return (bits, body.subdata(in: (body.startIndex + 12)..<(body.startIndex + 12 + n)))
    }

    static func payloadRecord(bits: Int, data: Data) -> Data {
        var out = Data(count: 6)
        appendU32(&out, UInt32(bits))
        appendU16(&out, 1)
        out.append(data)
        return out
    }

    var cram: (bits: Int, data: Data)? { body(Tag.cram).flatMap(SOFFile.payload) }
    var pram: (bits: Int, data: Data)? { body(Tag.pram).flatMap(SOFFile.payload) }

    func computedChecksum() -> UInt32? {
        guard let c = cram, let p = pram else { return nil }
        return SOFChecksum.byteSum(c.data) &+ SOFChecksum.byteSum(p.data)
    }

    var embeddedFiles: [EmbeddedFile]? {
        guard let b = body(Tag.files) else { return nil }
        return SOFFile.parseFiles(b)
    }

    static func parseFiles(_ body: Data) -> [EmbeddedFile]? {
        let d = [UInt8](body)
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
        var p = 0
        var files: [EmbeddedFile] = []
        while p < d.count {
            guard p + 16 <= d.count else { return nil }
            let ts = u32(p), fl = u16(p + 4), nl = Int(u32(p + 6)), rs = u16(p + 10), dl = Int(u32(p + 12))
            guard p + 16 + nl + dl <= d.count else { return nil }
            var nameBytes = Array(d[(p + 16)..<(p + 16 + nl)])
            if nameBytes.last == 0 { nameBytes.removeLast() }
            files.append(EmbeddedFile(timestamp: ts, flags: fl, reserved: rs,
                                      name: String(decoding: nameBytes, as: UTF8.self),
                                      data: Data(d[(p + 16 + nl)..<(p + 16 + nl + dl)])))
            p += 16 + nl + dl
        }
        return files
    }

    static func serializeFiles(_ files: [EmbeddedFile]) -> Data {
        var out = Data()
        for f in files {
            let name = Data(f.name.utf8) + Data([0])
            appendU32(&out, f.timestamp)
            appendU16(&out, f.flags)
            appendU32(&out, UInt32(name.count))
            appendU16(&out, f.reserved)
            appendU32(&out, UInt32(f.data.count))
            out.append(name)
            out.append(f.data)
        }
        return out
    }

    /// Parsing stays lossless for inspection; conversion requires a complete, consistent container.
    func validate() throws {
        guard storedCount == records.count else { throw SOFError.invalid("record count does not match the header") }
        for tag in [Tag.device, Tag.options, Tag.checksum, Tag.cram, Tag.pram, Tag.crc] {
            guard records.filter({ $0.tag == tag }).count == 1 else {
                throw SOFError.invalid(String(format: "expected one record with tag 0x%04x", tag))
            }
        }
        // Every Quartus file seen (14.0 to 25.1) has a 110-byte option record; an empty or cut one would convert with defaults.
        let options = body(Tag.options)?.count ?? 0
        guard options == SOFFile.defaultOptions.count else {
            throw SOFError.invalid("option record (tag 0x0012) is \(options) bytes instead of \(SOFFile.defaultOptions.count)")
        }
        guard let crc = storedCRC, crc == computedCRC() else { throw SOFError.invalid("file CRC mismatch or missing final CRC") }
        guard let sum = storedChecksum, sum == computedChecksum() else { throw SOFError.invalid("payload checksum mismatch or malformed payload") }
    }

    /// Keep freshly constructed containers valid before a serialize/parse cycle.
    mutating func updateCRC() {
        if let crc = computedCRC() {
            var body = Data(); appendU16(&body, crc)
            records[records.count - 1].body = body
        }
    }

    // MARK: Info

    func info() -> [String] {
        var lines: [String] = []
        lines.append("records: \(records.count) (header count \(storedCount), reserved \(reserved))")
        for r in records {
            var s = String(format: "  tag 0x%04x  len %9d  ", r.tag, r.body.count)
            switch r.tag {
            case Tag.compilerVersion, Tag.device, Tag.designName:
                s += "\"\(string(r.tag) ?? "")\""
            case Tag.cram, Tag.pram:
                if let p = SOFFile.payload(of: r.body) {
                    s += "\(r.tag == Tag.cram ? "CRAM" : "PRAM") \(p.bits) bits, \(p.data.reduce(0) { $0 + $1.nonzeroBitCount }) set"
                }
            case Tag.checksum:
                s += String(format: "checksum 0x%08X", storedChecksum ?? 0)
            case Tag.crc:
                s += String(format: "CRC-16/X-25 0x%04X", storedCRC ?? 0)
            case Tag.files:
                s += "\(embeddedFiles?.count ?? 0) embedded files"
            default:
                s += r.body.prefix(24).map { String(format: "%02x", $0) }.joined()
                if r.body.count > 24 { s += "..." }
            }
            lines.append(s)
        }
        for f in embeddedFiles ?? [] {
            let date = f.timestamp == 0 ? "-" : ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(f.timestamp)))
            lines.append("    file \(f.name)  \(f.data.count) bytes  \(date)\(f.flags != 0 ? String(format: "  flags 0x%04x", f.flags) : "")")
        }
        if let c = computedChecksum(), let s = storedChecksum {
            lines.append(String(format: "checksum: stored 0x%08X computed 0x%08X %@", s, c, s == c ? "OK" : "MISMATCH"))
        } else {
            lines.append(storedChecksum == nil ? "checksum: missing" : "checksum: not computable (CRAM or PRAM record missing or malformed)")
        }
        if let s = storedCRC {
            let c = computedCRC()!
            lines.append(String(format: "file CRC: stored 0x%04X computed 0x%04X %@", s, c, s == c ? "OK" : "MISMATCH"))
        } else {
            lines.append("file CRC: missing")
        }
        return lines
    }
}

private func appendU16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
private func appendU32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8(v >> 24))
}

// MARK: - Cyclone V (sx120f die) bitstream

/// Geometry of the Cyclone V "sx120f" die (5CSEBA5/6, 5CSEMA5/6, 5CSXFC5/6, 5CSTFD5/6),
/// from Mistral (libmistral/cvd-sx120f.cc) and confirmed against Quartus files.
enum CycloneVSX120F {
    static let cramSX = 7605, cramSY = 7024
    static let frameSize = 227                      // 32-bit words per PRAM frame (Mistral di.frame_size)
    static let pramSizes = [5806, 7434, 9669, 8169, 4862, 2772, 7162, 9607, 3438, 7484, 5751, 1984, 9500, 6800, 9136]
    static let pramBits = 99_574
    static let maxPram = 9669
    static let pramFrameBytes = frameSize * 4 + 8   // 916
    static let oramFrameBytes = pramFrameBytes + 104  // 1020
    static let pramBlocks = (maxPram + frameSize - 1) / frameSize  // 43
    static let cramFrameBytes = 916                 // (7024 + 256 + 48) / 8
    static let cramStart = oramFrameBytes + pramFrameBytes * pramBlocks   // 40408
    static let noEDCRCZones = [318, 1121, 2099, 3059, 3491, 4174, 4940, 5862, 6530, 7605]
    static let postamble1 = 190, postamble2 = 412
    static let uncompressedSize = cramStart + cramSX * cramFrameBytes + postamble1 + 2 + 12 + postamble2  // 7,007,204
    /// First bit-column of each MLAB tile; the 30 columns at offset 9..38 are stored permuted in the .sof.
    static let mlabColumns = [183, 615, 750, 1418, 1769, 2023, 2455, 2806, 3356, 4039, 4589, 5237, 5608, 6277, 6891, 7144, 7279, 7448]
    /// .sof column (tile + 9 + q) holds .rbf column (tile + 9 + mlabPerm[q]).
    static let mlabPerm = [2, 3, 6, 7, 10, 11, 27, 26, 23, 22, 19, 18, 15, 14, 0, 1, 4, 5, 8, 9, 12, 13, 29, 28, 25, 24, 21, 20, 17, 16]

    /// Option RAM: 32 strips x 40 bits. Strips 0-7 / 12-15 as Quartus writes them for an uncompressed
    /// .rbf with the default options; jtag_id (7.8-39) and idcode (6.19-26) are filled in per file.
    static let oramTemplate: [UInt64] = [
        0x28c0e180d4, 0xa4141e3c32, 0xa0019d8eff, 0x5bffffffff, 0xfffffffe81, 0xabaacd803f, 0xfc00000eff, 0x000000006a,
        0xffffffffff, 0xffffffffff, 0xffffffffff, 0xffffffffff, 0x00000030c2, 0x3b030ecc0a, 0x0c50b98814, 0xcf82a014ce,
    ] + Array(repeating: 0xffffffffff, count: 16)

    /// Every part on the sx120f die, as `mistral-cv models` lists them (82 parts), by die prefix.
    static let parts: Set<String> = {
        let table = [
            "5CSEBA5": "U19A7 U19C6 U19C7 U19C7S U19C8 U19C8S U19I7 U19I7L U19I7S U23C7 U23C7S U23C8 U23C8S U23I7L U23I7S",
            "5CSEBA6": "U19A7 U19C6 U19C7 U19C7S U19C8 U19C8ES U19C8S U19I7 U19I7DK U19I7ES U19I7L U19I7S U23A7 U23C6 U23C7 U23C7S U23C8 U23C8S U23I7 U23I7DK U23I7L U23I7S",
            "5CSEMA5": "F31A7 F31C6 F31C7 F31C8 F31I7 U23A7 U23C7 U23C8",
            "5CSEMA6": "F31A7 F31C6 F31C7 F31C8 F31I7 U23A7 U23C6 U23C7 U23C8 U23I7",
            "5CSTFD5": "D5F31I7",
            "5CSTFD6": "D5F31I7",
            "5CSXFC5": "C6U23A7 C6U23C6 C6U23C7 C6U23C8 C6U23I7 C6U23I7L D6F31C6 D6F31C7 D6F31C8 D6F31I7",
            "5CSXFC6": "C6U23A7 C6U23C6 C6U23C7 C6U23C8 C6U23C8ES C6U23I7 C6U23I7ES C6U23I7L D6F31A7 D6F31C6 D6F31C7 D6F31C8 D6F31C8ES D6F31I7 D6F31I7ES",
        ]
        return Set(table.flatMap { die, suffixes in suffixes.split(separator: " ").map { die + $0 } })
    }()

    /// The part name as Quartus writes it (upper case), or nil if it is not a known sx120f part.
    static func part(_ device: String) -> String? {
        let d = device.trimmingCharacters(in: .whitespaces).uppercased()
        return parts.contains(d) ? d : nil
    }

    /// Low byte of the JTAG IDCODE family field as stored in ORAM bits 6.19..6.26.
    static func idcodeByte(forDevice device: String) -> UInt8? {
        guard let d = part(device) else { return nil }
        let p7 = String(d.prefix(7))
        switch p7 {
        case "5CSEBA6", "5CSEMA6", "5CSXFC6", "5CSTFD6": return 0x02
        case "5CSEBA5", "5CSEMA5", "5CSXFC5", "5CSTFD5": return 0x12
        default: return nil
        }
    }

    /// Row -> bit position inside a CRAM frame (Mistral rbf_save; padding 48, offset 16, 220 rows per bit-lane).
    static let rowPos: [Int] = (0..<cramSY).map { y in
        guard y >= 32 else { return -1 }
        let ya = (y + 16) % (frameSize - 7), yb = (y + 16) / (frameSize - 7)
        return 224 + (31 ^ yb) + 32 * ya
    }

    /// For each RBF column x, the SOF column that holds it.
    static let sofColumn: [Int] = {
        var m = Array(0..<cramSX)
        for base in mlabColumns {
            for q in 0..<30 { m[base + 9 + mlabPerm[q]] = base + 9 + q }
        }
        return m
    }()

    /// Mistral's EDCRC (crc32 with poly 0xF4ACFB13, init 1) over the frame's data bits, read lane by lane
    /// (lane 31 of all 220 words, then lane 30, ...). Reference version, one bit at a time.
    static func edcrcReference(_ d: UnsafePointer<UInt8>) -> UInt32 {
        var a: UInt32 = 1
        let blocks = frameSize - 7
        for bitid in 0..<32 {
            var pos = 224 + (31 - bitid)
            for _ in 0..<blocks {
                let bit = ((UInt32(d[pos >> 3]) >> UInt32(pos & 7)) ^ (a >> 31)) & 1
                a <<= 1
                if bit != 0 { a ^= 0xf4acfb13 }
                pos += 32
            }
        }
        return a
    }

    /// The CRC is affine in the data, so EDCRC = (CRC of an all-zero frame) xor (one constant per set bit).
    private static let edcrcTables: (zero: UInt32, contrib: [UInt32]) = {
        let n = 32 * (frameSize - 7)          // 7040 bits fed per frame
        var zero: UInt32 = 1
        for _ in 0..<n { zero = (zero << 1) ^ ((zero >> 31) != 0 ? 0xf4acfb13 : 0) }
        // seq[t]: contribution of a 1 fed at step t (t = 0 first), computed backwards.
        var seq = [UInt32](repeating: 0, count: n)
        var c: UInt32 = 0xf4acfb13
        for t in stride(from: n - 1, through: 0, by: -1) {
            seq[t] = c
            c = (c << 1) ^ ((c >> 31) != 0 ? 0xf4acfb13 : 0)
        }
        var byPos = [UInt32](repeating: 0, count: 224 + n)
        for pos in 224..<(224 + n) {
            let lane = (pos - 224) & 31, block = (pos - 224) >> 5
            byPos[pos] = seq[(31 - lane) * (frameSize - 7) + block]
        }
        return (zero, byPos)
    }()

    static func edcrc(_ d: UnsafePointer<UInt8>) -> UInt32 {
        let t = edcrcTables
        var a = t.zero
        t.contrib.withUnsafeBufferPointer { cb in
            for byte in 28..<908 where d[byte] != 0 {
                var v = d[byte], bit = 0
                while v != 0 {
                    if v & 1 != 0 { a ^= cb[byte * 8 + bit] }
                    v >>= 1; bit += 1
                }
            }
        }
        return a
    }

    /// MLAB tiles configured as LUTRAM, as (first bit-column, first row). An MLAB tile at
    /// (base, 2 + 86*ty) is RAM when its ram_dis bit (base+42, y0+44) is 0 and write_en (base+42, y0+43) is 1
    /// (Mistral mlab-mux names; tile-local offsets). Quartus leaves those tiles' rows out of the EDCRC of
    /// frames base+7 ..< base+39.
    static func lutramTiles(_ cram: UnsafeRawBufferPointer) -> [(x: Int, y: Int)] {
        func bit(_ x: Int, _ y: Int) -> Bool {
            let i = x + cramSX * y
            return (cram[i >> 3] >> UInt8(i & 7)) & 1 != 0
        }
        var out: [(x: Int, y: Int)] = []
        for base in mlabColumns {
            var ty = 0
            while 2 + 86 * ty + 86 <= cramSY {
                let y0 = 2 + 86 * ty
                if !bit(base + 42, y0 + 44) && bit(base + 42, y0 + 43) { out.append((base, y0)) }
                ty += 1
            }
        }
        return out
    }

    /// Inverse of rowPos: frame bit position -> row (or -1).
    static let posRow: [Int] = {
        var m = [Int](repeating: -1, count: cramFrameBytes * 8)
        for y in 32..<cramSY { m[rowPos[y]] = y }
        return m
    }()

    /// Inverse of sofColumn: SOF column -> RBF frame index.
    static let rbfColumn: [Int] = {
        var m = [Int](repeating: 0, count: cramSX)
        for (x, sx) in sofColumn.enumerated() { m[sx] = x }
        return m
    }()
}

/// The parts of a Cyclone V configuration that matter for conversion.
struct CycloneVConfig {
    var cram: Data        // 7605*7024 bits, bit (x + 7605*y), LSB first (identical to the .sof payload)
    var pram: Data        // 99,574 bits in .sof order
    var idcode: UInt8 = 0x02
    var jtagID: UInt32? = nil   // nil = checksum

    var checksum: UInt32 { SOFChecksum.byteSum(cram) &+ SOFChecksum.byteSum(pram) }

    struct RBFOptions {
        var compressed = false
        /// Compressed output only. Quartus 15.1 and later pad the compressed stream to a whole number of 32-bit
        /// words by writing up to 7 zero nibbles at the end of postamble 2 explicitly (docs/SOF_FORMAT.md 3.2).
        /// Quartus 14.0 does not, and ends the stream with 392 instead of 412 0xFF bytes.
        var wordAlign = true
        var trailingFF = CycloneVSX120F.postamble2
        /// Option-RAM bits (strip, bit) forced to 1 / 0 after the template is applied.
        var oramSet: [(strip: Int, bit: Int)] = []
        var oramClear: [(strip: Int, bit: Int)] = []

        /// What the given Quartus major version does (nil: assume a current one).
        static func quartus(major: Int?, compressed: Bool) -> RBFOptions {
            var o = RBFOptions()
            o.compressed = compressed
            if let m = major, m < 15 { o.wordAlign = false; o.trailingFF = 392 }
            if let m = major, m >= 25 { o.oramSet.append((4, 8)) }   // seen in one Quartus 25.1 file
            return o
        }
    }

    // MARK: Encode

    func validate() throws {
        typealias G = CycloneVSX120F
        guard cram.count == G.cramSX * G.cramSY / 8, pram.count == (G.pramBits + 7) / 8 else {
            throw SOFError.badRBF("configuration payload sizes do not match sx120f")
        }
        guard cram.prefix(G.cramSX * 32 / 8).allSatisfy({ $0 == 0 }),
              pram.last! >> (G.pramBits % 8) == 0 else {
            throw SOFError.badRBF("nonzero reserved CRAM rows or PRAM padding bits")
        }
    }

    func rbf(_ opt: RBFOptions = RBFOptions()) throws -> Data {
        try validate()
        typealias G = CycloneVSX120F
        let framedBytes = G.cramSX * G.cramFrameBytes
        var head = [UInt8](repeating: 0, count: G.cramStart)
        // PRAM
        do {
            pram.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                var k = 0
                for bit in stride(from: 31, through: 0, by: -1) {
                    let size = bit < G.pramSizes.count ? G.pramSizes[bit] : 0
                    var i = size - 1
                    while i >= 0 {
                        if (src[k >> 3] >> UInt8(k & 7)) & 1 != 0 {
                            let base = G.maxPram - i - 1
                            head[G.oramFrameBytes + 4 + (bit >> 3) + base * 4 + (base / G.frameSize) * 8] |= UInt8(1 << (bit & 7))
                        }
                        k += 1; i -= 1
                    }
                }
            }
            let last = G.oramFrameBytes + (G.pramBlocks - 1) * G.pramFrameBytes
            head[last] = 0x2a; head[last + 1] = 0xc5; head[last + 2] = 0x01
            head.withUnsafeMutableBufferPointer { h in
                var off = G.oramFrameBytes
                for _ in 0..<G.pramBlocks {
                    let c = SOFChecksum.crc16Frame(h.baseAddress! + off, G.pramFrameBytes - 2)
                    h[off + G.pramFrameBytes - 2] = UInt8(c & 0xFF); h[off + G.pramFrameBytes - 1] = UInt8(c >> 8)
                    off += G.pramFrameBytes
                }
            }
        }
        // CRAM frames
        var framed = [UInt8](repeating: 0, count: framedBytes + 204)
        framed[0] = 0x84; framed[1] = 0x3e; framed[2] = 0x01
        framed[(G.cramSX - 1) * G.cramFrameBytes] = 0x42
        framed[(G.cramSX - 1) * G.cramFrameBytes + 1] = 0x9f
        cram.withUnsafeBytes { srcRaw in
            let src = srcRaw.bindMemory(to: UInt8.self)
            framed.withUnsafeMutableBufferPointer { fb in
                // Scatter every set CRAM bit into its frame (rows 0..31 are never set in a .sof).
                let rowPos = G.rowPos, rbfColumn = G.rbfColumn
                let base = fb.baseAddress!
                for byte in 0..<src.count where src[byte] != 0 {
                    var v = src[byte], bit = 0
                    while v != 0 {
                        if v & 1 != 0 {
                            let idx = byte * 8 + bit
                            let y = idx / G.cramSX, sx = idx - y * G.cramSX
                            if y >= 32 {
                                let pos = rowPos[y]
                                base[rbfColumn[sx] * G.cramFrameBytes + (pos >> 3)] |= UInt8(1 << (pos & 7))
                            }
                        }
                        v >>= 1; bit += 1
                    }
                }
                // Frames whose EDCRC ignores LUTRAM rows: frame -> list of first rows.
                var masked: [Int: [Int]] = [:]
                for t in G.lutramTiles(UnsafeRawBufferPointer(srcRaw)) {
                    for x in (t.x + 7)..<(t.x + 39) { masked[x, default: []].append(t.y) }
                }
                var scratch = [UInt8](repeating: 0, count: G.cramFrameBytes)
                var zone = 0
                for x in 0..<G.cramSX {
                    let d = base + x * G.cramFrameBytes
                    var e: UInt32 = 0
                    if x < G.noEDCRCZones[zone] {
                        if let rows = masked[x] {
                            for i in 0..<G.cramFrameBytes { scratch[i] = d[i] }
                            for y0 in rows {
                                for y in max(y0, 32)..<(y0 + 86) { let pos = rowPos[y]; scratch[pos >> 3] &= ~UInt8(1 << (pos & 7)) }
                            }
                            e = scratch.withUnsafeBufferPointer { CycloneVSX120F.edcrc($0.baseAddress!) }
                        } else {
                            e = CycloneVSX120F.edcrc(UnsafePointer(d))
                        }
                    }
                    d[908] = UInt8(e & 0xFF); d[909] = UInt8((e >> 8) & 0xFF); d[910] = UInt8((e >> 16) & 0xFF); d[911] = UInt8(e >> 24)
                    if x == G.noEDCRCZones[zone] + 255 { zone += 1 }
                    let c = SOFChecksum.crc16Frame(UnsafePointer(d), G.cramFrameBytes - 2)
                    d[914] = UInt8(c & 0xFF); d[915] = UInt8(c >> 8)
                }
                // postambles
                let p = fb.baseAddress! + framedBytes
                p[0] = 0xec; p[1] = 0x64
                var c = SOFChecksum.crc16Frame(UnsafePointer(p), G.postamble1)
                p[190] = UInt8(c & 0xFF); p[191] = UInt8(c >> 8)
                p[192] = 0xae; p[193] = 0xfb
                c = SOFChecksum.crc16Frame(UnsafePointer(p + 192), 10)
                p[202] = UInt8(c & 0xFF); p[203] = UInt8(c >> 8)
            }
        }

        var body: [UInt8]
        if opt.compressed {
            framed.append(contentsOf: [UInt8](repeating: 0xFF, count: opt.trailingFF))
            body = CycloneVConfig.compress(framed, alignEndingAt: opt.wordAlign ? framedBytes + 204 : nil)
        } else {
            body = framed
            body.append(contentsOf: [UInt8](repeating: 0xFF, count: G.postamble2))
        }
        let total = G.cramStart + body.count

        // ORAM
        var oram = G.oramTemplate
        oram[6] = (oram[6] & ~(UInt64(0xFF) << 19)) | (UInt64(idcode) << 19)
        oram[7] = (oram[7] & 0xFF) | (UInt64(jtagID ?? checksum) << 8)
        if opt.compressed {
            oram[6] &= ~(UInt64(1) << 35)     // compression_dis = 0
            oram[4] &= ~UInt64(1)             // opt_b bit 4.0 cleared with compression
        }
        for b in opt.oramSet { oram[b.strip] |= UInt64(1) << UInt64(b.bit) }
        for b in opt.oramClear { oram[b.strip] &= ~(UInt64(1) << UInt64(b.bit)) }
        let lenConst = opt.compressed ? 357 : 305
        let field = (UInt64((total - lenConst) & 0x3F_FFFF) << 2) | 1
        oram[5] = (oram[5] & 0xFFFF) | (field << 16)
        for i in 0..<0x80 { head[i] = 0xFF }
        for i in 0x80..<0x84 { head[i] = 0x6A }
        for strip in 0..<32 {
            for bit in 0..<40 where (oram[strip] >> UInt64(bit)) & 1 != 0 {
                head[0x84 + (strip >> 3) + (bit << 2)] |= UInt8(0x80 >> (strip & 7))
            }
        }
        head.withUnsafeMutableBufferPointer { h in
            let c = SOFChecksum.crc16Frame(h.baseAddress! + 0x84, 0x126 - 0x84)
            h[0x126] = UInt8(c & 0xFF); h[0x127] = UInt8(c >> 8)
            for i in 0x128..<G.oramFrameBytes { h[i] = 0xFF }
        }
        var out = Data(capacity: total)
        out.append(contentsOf: head)
        out.append(contentsOf: body)
        return out
    }

    /// Mistral's nibble compressor: per byte pair a 4-bit mask of non-zero nibbles, then those nibbles.
    /// With `alignEndingAt` = n, zero nibbles just before byte n are written explicitly (last first) until the
    /// stream up to byte n is 2 nibbles past a 32-bit boundary, which with the 412 0xFF bytes that follow
    /// (1030 nibbles) makes the whole stream a whole number of words, as Quartus 15.1+ does.
    static func compress(_ src: [UInt8], alignEndingAt: Int? = nil) -> [UInt8] {
        let pairs = src.count / 2
        var masks = [UInt8](repeating: 0, count: pairs)
        for p in 0..<pairs {
            let a = src[2 * p], b = src[2 * p + 1]
            var m: UInt8 = 0
            if a & 0x0F != 0 { m |= 1 }
            if a & 0xF0 != 0 { m |= 2 }
            if b & 0x0F != 0 { m |= 4 }
            if b & 0xF0 != 0 { m |= 8 }
            masks[p] = m
        }
        if let end = alignEndingAt, end % 2 == 0, end <= src.count {
            var nibbles = 0
            for p in 0..<(end / 2) { nibbles += 1 + masks[p].nonzeroBitCount }
            var extra = ((2 - nibbles) % 8 + 8) % 8
            var p = end / 2 - 1
            while extra > 0 && p >= 0 {
                for bit in [UInt8(8), 4, 2, 1] where extra > 0 && masks[p] & bit == 0 {
                    masks[p] |= bit; extra -= 1
                }
                p -= 1
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(src.count / 2)
        var high = false
        func w(_ n: UInt8) {
            if high { out[out.count - 1] |= n << 4; high = false } else { out.append(n); high = true }
        }
        for p in 0..<pairs {
            let a = src[2 * p], b = src[2 * p + 1], m = masks[p]
            w(m)
            if m & 1 != 0 { w(a & 0xF) }
            if m & 2 != 0 { w(a >> 4) }
            if m & 4 != 0 { w(b & 0xF) }
            if m & 8 != 0 { w(b >> 4) }
        }
        while high { w(0xF) }
        return out
    }

    // MARK: Decode

    init(cram: Data, pram: Data, idcode: UInt8 = 0x02, jtagID: UInt32? = nil) {
        self.cram = cram; self.pram = pram; self.idcode = idcode; self.jtagID = jtagID
    }

    /// Parse a Quartus/Mistral .rbf for the sx120f die (compressed or not).
    init(rbf data: Data) throws {
        typealias G = CycloneVSX120F
        let r = [UInt8](data)
        guard r.count > G.cramStart + 1024 else { throw SOFError.badRBF("too short (\(r.count) bytes)") }
        guard r[0x80..<0x84].allSatisfy({ $0 == 0x6A }) else { throw SOFError.badRBF("no 'jjjj' sync at 0x80") }
        var oram = [UInt64](repeating: 0, count: 32)
        for strip in 0..<32 {
            for bit in 0..<40 where r[0x84 + (strip >> 3) + (bit << 2)] & UInt8(0x80 >> (strip & 7)) != 0 {
                oram[strip] |= UInt64(1) << UInt64(bit)
            }
        }
        let crcOK = r.withUnsafeBufferPointer { SOFChecksum.crc16Frame($0.baseAddress! + 0x84, 0x126 - 0x84) } == (UInt16(r[0x126]) | UInt16(r[0x127]) << 8)
        guard crcOK else { throw SOFError.badRBF("option block CRC mismatch") }
        let compressed = (oram[6] >> 35) & 1 == 0
        idcode = UInt8((oram[6] >> 19) & 0xFF)
        let jtag = UInt32((oram[7] >> 8) & 0xFFFF_FFFF)

        // Every PRAM frame has its own CRC, independently of the option/CRAM checks.
        let badPRAM = r.withUnsafeBufferPointer { b in
            (0..<G.pramBlocks).filter { i in
                let off = G.oramFrameBytes + i * G.pramFrameBytes
                let crc = UInt16(r[off + G.pramFrameBytes - 2]) | UInt16(r[off + G.pramFrameBytes - 1]) << 8
                return SOFChecksum.crc16Frame(b.baseAddress! + off, G.pramFrameBytes - 2) != crc
            }.count
        }
        guard badPRAM == 0 else { throw SOFError.badRBF("\(badPRAM) PRAM frames fail their CRC-16") }

        // PRAM
        var pramBytes = [UInt8](repeating: 0, count: (G.pramBits + 7) / 8)
        var k = 0
        for bit in stride(from: 31, through: 0, by: -1) {
            let size = bit < G.pramSizes.count ? G.pramSizes[bit] : 0
            var i = size - 1
            while i >= 0 {
                let base = G.maxPram - i - 1
                if r[G.oramFrameBytes + 4 + (bit >> 3) + base * 4 + (base / G.frameSize) * 8] & UInt8(1 << (bit & 7)) != 0 {
                    pramBytes[k >> 3] |= UInt8(1 << (k & 7))
                }
                k += 1; i -= 1
            }
        }

        // CRAM frames
        let framedBytes = G.cramSX * G.cramFrameBytes
        // Keep both postambles and at least the 392 trailing clocks of Quartus 14.
        // Mistral compresses only CRAM and leaves the postambles raw; Quartus compresses both.
        let tailBytes = 204 + 392
        var frames: [UInt8]
        if compressed {
            frames = [UInt8](repeating: 0, count: framedBytes)
            var ci = G.cramStart, high = false
            func rn() throws -> UInt8 {
                guard ci < r.count else { throw SOFError.badRBF("compressed stream ends early") }
                if high { high = false; let v = r[ci] >> 4; ci += 1; return v }
                high = true; return r[ci] & 0xF
            }
            func pair() throws -> [UInt8] {
                let key = try rn()
                var a: UInt8 = key & 1 != 0 ? try rn() : 0
                a |= key & 2 != 0 ? try rn() << 4 : 0
                var b: UInt8 = key & 4 != 0 ? try rn() : 0
                b |= key & 8 != 0 ? try rn() << 4 : 0
                return [a, b]
            }
            for o in stride(from: 0, to: framedBytes, by: 2) {
                let p = try pair(); frames[o] = p[0]; frames[o + 1] = p[1]
            }
            let rawTail = ci + (high ? 1 : 0)
            if rawTail + tailBytes <= r.count, r[rawTail] == 0xEC, r[rawTail + 1] == 0x64 {
                frames.append(contentsOf: r[rawTail..<(rawTail + tailBytes)])
            } else {
                for _ in stride(from: 0, to: tailBytes, by: 2) { frames.append(contentsOf: try pair()) }
            }
        } else {
            guard r.count >= G.cramStart + framedBytes + tailBytes else { throw SOFError.badRBF("uncompressed CRAM or postamble truncated") }
            frames = Array(r[G.cramStart..<(G.cramStart + framedBytes + tailBytes)])
        }
        let tailOK = frames.withUnsafeBufferPointer { b in
            let p = b.baseAddress! + framedBytes
            return p[0] == 0xEC && p[1] == 0x64 && p[192] == 0xAE && p[193] == 0xFB
                && SOFChecksum.crc16Frame(p, 190) == (UInt16(p[190]) | UInt16(p[191]) << 8)
                && SOFChecksum.crc16Frame(p + 192, 10) == (UInt16(p[202]) | UInt16(p[203]) << 8)
                && frames[(framedBytes + 204)...].allSatisfy({ $0 == 0xFF })
        }
        guard tailOK else { throw SOFError.badRBF("postamble CRC, markers or trailing clocks invalid") }
        var cramBytes = [UInt8](repeating: 0, count: G.cramSX * G.cramSY / 8)
        var badFrames = 0
        let posRow = G.posRow
        frames.withUnsafeBufferPointer { fb in
            for x in 0..<G.cramSX {
                let d = fb.baseAddress! + x * G.cramFrameBytes
                if SOFChecksum.crc16Frame(d, G.cramFrameBytes - 2) != (UInt16(d[914]) | UInt16(d[915]) << 8) { badFrames += 1 }
                let sx = G.sofColumn[x]
                for byte in 28..<908 where d[byte] != 0 {
                    var v = d[byte], bit = 0
                    while v != 0 {
                        if v & 1 != 0 {
                            let y = posRow[byte * 8 + bit]
                            if y >= 0 {
                                let idx = sx + G.cramSX * y
                                cramBytes[idx >> 3] |= UInt8(1 << (idx & 7))
                            }
                        }
                        v >>= 1; bit += 1
                    }
                }
            }
        }
        guard badFrames == 0 else { throw SOFError.badRBF("\(badFrames) CRAM frames fail their CRC-16") }
        cram = Data(cramBytes)
        pram = Data(pramBytes)
        let sum = SOFChecksum.byteSum(cram) &+ SOFChecksum.byteSum(pram)
        jtagID = jtag == sum ? nil : jtag
    }
}

// MARK: - SOF <-> RBF

extension SOFFile {
    static let defaultCompilerVersion = "Quartus Prime Compiler Version 18.1.0 Build 625 09/12/2018 SJ Lite Edition"

    /// The 110-byte option record (tag 0x0012) found in 8 of 10 sample files (all Quartus 17.0-23.1 defaults).
    static let defaultOptions: [UInt8] = {
        let hex = "ff0ff807fcffffffffffffffffffffffffffff1bff0f9e05a10000000080d4000000000000e083cf"
            + "000000000000000000000000000000ffff07f84700000000000000000000000000003c0064780200"
            + "0000000080e4630000000000000000000000000000000000000000000080"
        var out: [UInt8] = []
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }()

    /// Quartus major version parsed from record 0x0001 (e.g. 18 for "... Version 18.1.0 ...").
    var compilerMajorVersion: Int? {
        guard let v = compilerVersion, let r = v.range(of: "Version ") else { return nil }
        return Int(v[r.upperBound...].prefix { $0.isNumber })
    }

    func configuration() throws -> CycloneVConfig {
        try validate()
        guard let dev = device else { throw SOFError.missingRecord(Tag.device) }
        guard let idc = CycloneVSX120F.idcodeByte(forDevice: dev) else { throw SOFError.unsupportedDevice(dev) }
        guard let c = cram else { throw SOFError.missingRecord(Tag.cram) }
        guard let p = pram else { throw SOFError.missingRecord(Tag.pram) }
        guard c.bits == CycloneVSX120F.cramSX * CycloneVSX120F.cramSY, p.bits == CycloneVSX120F.pramBits else {
            throw SOFError.unsupportedDevice("\(dev) with \(c.bits) CRAM / \(p.bits) PRAM bits")
        }
        return CycloneVConfig(cram: c.data, pram: p.data, idcode: idc)
    }

    /// Convert to a raw binary file as quartus_cpf would (uncompressed by default).
    func extractRBF(compressed: Bool = false) throws -> Data {
        var opt = CycloneVConfig.RBFOptions.quartus(major: compilerMajorVersion, compressed: compressed)
        // Option record byte 0x15 bit 2 clear <-> ORAM bit 2.10 clear (one sample; byte 0x4c bit 2 is the
        // other candidate, see docs/SOF_FORMAT.md 5).
        if let o = body(Tag.options), o.count > 0x15, o[o.startIndex + 0x15] & 0x04 == 0 { opt.oramClear.append((2, 10)) }
        return try configuration().rbf(opt)
    }

    /// Optional per-file metadata. Pass `template` to copy every non-payload record from an existing .sof
    /// (then an rbf -> sof round trip reproduces that file byte for byte).
    struct WrapOptions {
        var compilerVersion = SOFFile.defaultCompilerVersion
        var designName = "Untitled"
        var projectName: String? = nil          // enables the .jdi/.sld entries
        var timestamp: UInt32 = UInt32(Date().timeIntervalSince1970)
        /// Which optional records to write, after the Quartus version that introduced them:
        /// 14 = 9 records (no 0x3B, 0x33, no .sld), 16 = adds 0x33 and the .sld (Quartus 15.1-16.1),
        /// 17 = adds the 0x3B hash (Quartus 17.0 and later; the default).
        var layout = 17
        var template: SOFFile? = nil
    }

    /// Wrap a raw Cyclone V bitstream in a .sof.
    init(wrapping rbf: Data, device: String, options: WrapOptions = WrapOptions()) throws {
        guard let idc = CycloneVSX120F.idcodeByte(forDevice: device) else { throw SOFError.unsupportedDevice(device) }
        let cfg = try CycloneVConfig(rbf: rbf)
        if cfg.idcode != idc {
            throw SOFError.badRBF(String(format: "bitstream is for idcode 0x%02x, %@ needs 0x%02x", cfg.idcode, device, idc))
        }
        try self.init(config: cfg, device: device, options: options)
    }

    init(config cfg: CycloneVConfig, device: String, options o: WrapOptions = WrapOptions()) throws {
        self.init()
        try cfg.validate()
        guard let dev = CycloneVSX120F.part(device), CycloneVSX120F.idcodeByte(forDevice: dev) == cfg.idcode else {
            throw SOFError.unsupportedDevice(device)
        }
        guard [14, 16, 17].contains(o.layout) else { throw SOFError.invalid("layout must be 14, 16 or 17") }
        let cramRec = SOFFile.payloadRecord(bits: CycloneVSX120F.cramSX * CycloneVSX120F.cramSY, data: cfg.cram)
        let pramRec = SOFFile.payloadRecord(bits: CycloneVSX120F.pramBits, data: cfg.pram)
        let sum = cfg.checksum
        var checksumRec = Data([0, 0, 0, 0, 0x20, 0, 0x20, 0, 0, 0, 1, 0])
        appendU32(&checksumRec, sum)

        if let t = o.template {
            try t.validate()
            guard t.device?.uppercased() == dev else { throw SOFError.invalid("template device does not match the requested device") }
            reserved = t.reserved
            storedCount = t.storedCount
            for r in t.records {
                switch r.tag {
                case Tag.cram: records.append(Record(tag: r.tag, body: cramRec))
                case Tag.pram: records.append(Record(tag: r.tag, body: pramRec))
                case Tag.checksum:
                    var b = r.body
                    if b.count >= 16 { b.replaceSubrange((b.startIndex + 12)..<(b.startIndex + 16), with: checksumRec.suffix(4)) }
                    records.append(Record(tag: r.tag, body: b))
                case Tag.device: records.append(Record(tag: r.tag, body: Data(dev.utf8) + Data([0])))
                default: records.append(r)
                }
            }
            updateCRC()
            return
        }

        func str(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        // A 16-byte design hash we can reproduce: MD5 is not in Foundation, so use a 128-bit FNV-style digest
        // of the payload. Quartus' own value is opaque (see docs/SOF_FORMAT.md).
        let digest = SOFFile.digest128(cfg.cram + cfg.pram)
        records.append(Record(tag: Tag.compilerVersion, body: str(o.compilerVersion)))
        records.append(Record(tag: Tag.device, body: str(dev)))
        records.append(Record(tag: Tag.designName, body: str(o.designName)))
        if o.layout >= 17 { records.append(Record(tag: Tag.hash, body: Data(digest) + Data([0]))) }
        records.append(Record(tag: Tag.options, body: Data(SOFFile.defaultOptions)))
        records.append(Record(tag: Tag.checksum, body: checksumRec))
        var files = [EmbeddedFile(timestamp: 0, flags: 0, reserved: 0, name: "design_hash.bin",
                                  data: Data([0, 0]) + Data(digest.prefix(10)) + Data(count: 4))]
        if let p = o.projectName {
            let hex = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
            func xml(_ s: String) -> String {
                s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "'", with: "&apos;")
            }
            let jdi = "<sld_project_info>\r\n  <project>\r\n    <hash md5_digest_80b=\"\(hex)\"/>\r\n  </project>\r\n"
                + "  <file_info>\r\n    <file device=\"\(dev)\" path=\"\(xml(p)).sof\" usercode=\"0xFFFFFFFF\"/>\r\n  </file_info>\r\n</sld_project_info>\r\n"
            files.append(EmbeddedFile(timestamp: o.timestamp, flags: 0, reserved: 0, name: "output_files/\(p).jdi", data: Data(jdi.utf8)))
            if o.layout >= 15 {
                files.append(EmbeddedFile(timestamp: o.timestamp, flags: 0, reserved: 0, name: "output_files/\(p).sld",
                                          data: Data("<sld_project_info/>\r\n".utf8)))
            }
        }
        records.append(Record(tag: Tag.files, body: SOFFile.serializeFiles(files)))
        records.append(Record(tag: Tag.cram, body: cramRec))
        records.append(Record(tag: Tag.pram, body: pramRec))
        if o.layout >= 15 { records.append(Record(tag: Tag.unknown33, body: Data(count: 4))) }
        records.append(Record(tag: Tag.crc, body: Data(count: 2)))
        storedCount = UInt32(records.count)
        updateCRC()
    }

    /// Deterministic 128-bit digest (two FNV-1a-64 lanes). Not MD5; only used to fill the opaque hash fields.
    static func digest128(_ d: Data) -> [UInt8] {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        d.withUnsafeBytes { buf in
            for b in buf {
                h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
                h2 = (h2 ^ UInt64(b) ^ (h1 >> 29)) &* 0x100000001b3
            }
        }
        var out: [UInt8] = []
        for h in [h1, h2] { for i in 0..<8 { out.append(UInt8((h >> UInt64(8 * i)) & 0xFF)) } }
        return out
    }
}

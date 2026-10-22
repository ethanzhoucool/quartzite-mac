import Foundation

/// Self-tests for SOF.swift. `run` uses only small synthetic data; `verifySamples` runs the
/// real-file checks (round trip, sof -> rbf against Quartus .rbf, rbf -> sof) on a local sample folder.
enum SOFSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        print("SOF container")
        check(SOFChecksum.x25Table.count == 256, "CRC tables built")
        // CRC-16/X-25 check value for "123456789" is 0x906E.
        let crc = Data("123456789".utf8).withUnsafeBytes { SOFChecksum.crc16X25($0) }
        check(crc == 0x906E, "CRC-16/X-25 check value 0x906E")
        // Mistral/Altera frame CRC (CRC-16/MODBUS parameters) check value is 0x4B37.
        let fc = Array("123456789".utf8).withUnsafeBufferPointer { SOFChecksum.crc16Frame($0.baseAddress!, 9) }
        check(fc == 0x4B37, "frame CRC-16 check value 0x4B37")

        // A tiny synthetic container round-trips and gets a valid CRC.
        var s = SOFFile()
        s.records = [
            .init(tag: 1, body: Data("Quartzite\0".utf8)),
            .init(tag: 2, body: Data("5CSXFC6D6F31C6\0".utf8)),
            .init(tag: 0x11, body: SOFFile.payloadRecord(bits: 20, data: Data([0x01, 0x80, 0x0F]))),
            .init(tag: 8, body: Data(count: 2)),
        ]
        s.storedCount = 4
        let bytes = s.serialize()
        let back = try? SOFFile(data: bytes)
        check(back?.records.count == 4 && back?.device == "5CSXFC6D6F31C6", "synthetic container parses back")
        check(back?.serialize() == bytes, "synthetic container round-trips byte for byte")
        check(back?.storedCRC == back?.computedCRC(), "CRC record is consistent")
        let full = bytes.withUnsafeBytes { SOFChecksum.crc16X25($0) }
        check(full == 0x0F47, "whole-file CRC leaves the X-25 residue (0xF0B8 ^ 0xFFFF)")
        check(back?.cram?.bits == 20 && back?.cram?.data == Data([0x01, 0x80, 0x0F]), "payload header decodes")
        let files = [SOFFile.EmbeddedFile(timestamp: 7, flags: 0x100, reserved: 0, name: "a.jdi", data: Data("x".utf8))]
        check(SOFFile.parseFiles(SOFFile.serializeFiles(files)) == files, "embedded-file record round-trips")

        print("Cyclone V bitstream")
        typealias G = CycloneVSX120F
        check(G.uncompressedSize == 7_007_204, "uncompressed sx120f .rbf size 7,007,204")
        check(Set(G.sofColumn).count == G.cramSX, "MLAB column permutation is a bijection")
        var rng = SystemRandomNumberGenerator()
        var edOK = true
        for _ in 0..<8 {
            var f = [UInt8](repeating: 0, count: G.cramFrameBytes)
            for _ in 0..<40 { f[Int.random(in: 28..<908, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            f.withUnsafeBufferPointer { b in
                if G.edcrc(b.baseAddress!) != G.edcrcReference(b.baseAddress!) { edOK = false }
            }
        }
        check(edOK, "table EDCRC equals the bit-serial reference")
        check(G.idcodeByte(forDevice: "5CSXFC6D6F31C6") == 0x02 && G.idcodeByte(forDevice: "5CSEMA5F31C6") == 0x12,
              "device idcode table")
        // Sparse synthetic configuration: a few CRAM bits (including MLAB columns) and PRAM bits.
        var cram = [UInt8](repeating: 0, count: G.cramSX * G.cramSY / 8)
        for (x, y) in [(1, 32), (630, 100), (640, 5000), (7604, 7023), (4050, 3646), (3000, 222)] {
            let i = x + G.cramSX * y
            cram[i >> 3] |= UInt8(1 << (i & 7))
        }
        var pram = [UInt8](repeating: 0, count: (G.pramBits + 7) / 8)
        for k in [0, 1, 777, 50_000, G.pramBits - 1] { pram[k >> 3] |= UInt8(1 << (k & 7)) }
        let cfg = CycloneVConfig(cram: Data(cram), pram: Data(pram), idcode: 0x02)
        // Uncompressed: full cycle config -> rbf -> config, config -> sof -> bytes -> sof -> rbf.
        guard let rbf = try? cfg.rbf() else { check(false, "configuration encodes"); return }
        check(rbf.count == G.uncompressedSize, "uncompressed rbf has the Quartus size")
        let dec = try? CycloneVConfig(rbf: rbf)
        check(dec?.cram == cfg.cram && dec?.pram == cfg.pram, "uncompressed rbf decodes back to the same CRAM/PRAM")
        check(dec?.jtagID == nil && dec?.idcode == 0x02, "rbf carries the checksum as usercode, and the idcode")
        if let sof = try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6"), let again = try? SOFFile(data: sof.serialize()) {
            check(again.storedCRC == again.computedCRC() && again.storedChecksum == again.computedChecksum(),
                  "config -> sof has valid CRC and checksum")
            check((try? again.extractRBF()) == rbf, "sof -> rbf equals the direct encoding")
        } else {
            check(false, "config wraps into a sof")
        }
        // Conversion must refuse corruption instead of repairing it into a new programming file.
        var damagedPRAM = rbf
        damagedPRAM[G.oramFrameBytes + 4] ^= 1
        check((try? CycloneVConfig(rbf: damagedPRAM)) == nil, "damaged PRAM data is rejected")
        var damagedPRAMCRC = rbf
        damagedPRAMCRC[G.cramStart - 1] ^= 1
        check((try? CycloneVConfig(rbf: damagedPRAMCRC)) == nil, "damaged final PRAM CRC is rejected")
        let frameEnd = G.cramStart + G.cramSX * G.cramFrameBytes
        check((try? CycloneVConfig(rbf: Data(rbf.prefix(frameEnd)))) == nil, "missing uncompressed postambles are rejected")
        var damagedPostamble = rbf
        damagedPostamble[frameEnd + 195] ^= 1
        check((try? CycloneVConfig(rbf: damagedPostamble)) == nil, "damaged postamble CRC is rejected")
        check((try? CycloneVConfig(rbf: Data(rbf.prefix(frameEnd + 204)))) == nil, "missing trailing configuration clocks are rejected")
        let short = CycloneVConfig(cram: Data([0]), pram: cfg.pram)
        check((try? short.rbf()) == nil && (try? SOFFile(config: short, device: "5CSXFC6D6F31C6")) == nil,
              "invalid programmatic payload sizes throw before unsafe indexing")
        if let sof = try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6") {
            check((try? sof.configuration())?.cram == cfg.cram, "fresh SOF is valid before serialization")
            var changed = cfg; changed.pram[0] ^= 1
            let rebuilt = try? SOFFile(config: changed, device: "5CSXFC6D6F31C6", options: .init(template: sof))
            check((try? rebuilt?.configuration())?.pram == changed.pram,
                  "template-based SOF updates its CRC when payloads change")
            var broken = sof
            broken.records[0].body[0] ^= 1
            check((try? broken.extractRBF()) == nil, "SOF file CRC mismatch blocks conversion")
            broken = sof; broken.storedCount += 1
            check((try? broken.extractRBF()) == nil, "SOF record count mismatch blocks conversion")
            broken = sof; broken.records.append(sof.records.first { $0.tag == SOFFile.Tag.device }!)
            check((try? broken.extractRBF()) == nil, "duplicate required SOF records block conversion")
            broken = sof; broken.records.removeAll { $0.tag == SOFFile.Tag.cram }
            check((try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6", options: .init(template: broken))) == nil,
                  "incomplete templates cannot silently omit a payload")
            broken = sof
            let ci = broken.records.firstIndex { $0.tag == SOFFile.Tag.cram }!
            broken.records[ci].body[0] = 1
            if let parsed = try? SOFFile(data: broken.serialize()) {
                check((try? parsed.extractRBF()) == nil, "invalid payload header blocks conversion even with a valid file CRC")
            } else { check(false, "malformed payload remains inspectable") }
            check((try? SOFFile(config: cfg, device: "5CSEBA6U23I7", options: .init(template: sof))) == nil,
                  "template for a different package/device is rejected")
            for size in [0, 0x15, 109] {
                broken = sof
                let oi = broken.records.firstIndex { $0.tag == SOFFile.Tag.options }!
                broken.records[oi].body = Data(SOFFile.defaultOptions.prefix(size))
                broken.updateCRC()
                check((try? broken.validate()) == nil && (try? broken.extractRBF()) == nil,
                      "a \(size)-byte option record blocks conversion even with a valid file CRC")
            }
        } else { check(false, "SOF regression fixture wraps") }
        check((try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6", options: .init(layout: 15))) == nil,
              "unsupported SOF layouts are rejected")
        if let escaped = try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6", options: .init(projectName: "a&\"<b")),
           let jdi = escaped.embeddedFiles?.first(where: { $0.name.hasSuffix(".jdi") }) {
            check(String(decoding: jdi.data, as: UTF8.self).contains("path=\"a&amp;&quot;&lt;b.sof\""),
                  "project names are escaped in embedded XML attributes")
        } else { check(false, "escaped JDI fixture wraps") }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            check(!verifySamples(dir.path), "sample verification refuses an empty folder")
            try bytes.write(to: dir.appendingPathComponent("incomplete.sof"))
            check(!verifySamples(dir.path), "sample verification requires present payload checksums")
            try FileManager.default.removeItem(at: dir.appendingPathComponent("incomplete.sof"))
            if var malformed = try? SOFFile(config: cfg, device: "5CSXFC6D6F31C6") {
                malformed.storedCount += 1
                try malformed.serialize().write(to: dir.appendingPathComponent("bad-count.sof"))
                check(!verifySamples(dir.path), "sample verification rejects wrong counts even when CRC and checksum match")
            } else { check(false, "record-count sample fixture wraps") }
        } catch { check(false, "sample-verification fixtures: \(error)") }
        // Compressed: encode and decode.
        var opt = CycloneVConfig.RBFOptions()
        opt.compressed = true
        guard let crbf = try? cfg.rbf(opt) else { check(false, "compressed configuration encodes"); return }
        check(crbf.count < rbf.count / 2, "compressed rbf is smaller")
        check((crbf.count - G.cramStart) % 4 == 0, "compressed stream is a whole number of 32-bit words")
        let cdec = try? CycloneVConfig(rbf: crbf)
        check(cdec?.cram == cfg.cram && cdec?.pram == cfg.pram, "compressed rbf decodes back to the same CRAM/PRAM")
        check((try? CycloneVConfig(rbf: Data(crbf.prefix(crbf.count - 100)))) == nil,
              "truncated compressed postambles/clocks are rejected")
        var legacy = opt; legacy.wordAlign = false; legacy.trailingFF = 392
        check((try? CycloneVConfig(rbf: cfg.rbf(legacy)))?.cram == cfg.cram,
              "Quartus 14 compressed postambles with 392 trailing bytes remain valid")
        let mistral = Data(crbf.prefix(G.cramStart))
            + Data(CycloneVConfig.compress(Array(rbf[G.cramStart..<frameEnd])))
            + Data(rbf[frameEnd...])
        check((try? CycloneVConfig(rbf: mistral))?.pram == cfg.pram,
              "Mistral compressed CRAM with raw postambles remains valid")
    }

    /// Real-file checks. Every .sof below `dir` is round-tripped; every .rbf in the same folder is compared.
    static func verifySamples(_ dir: String) -> Bool {
        var ok = true
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { print("no such folder \(dir)"); return false }
        let sofs = en.compactMap { $0 as? String }.filter { $0.lowercased().hasSuffix(".sof") }.sorted()
        guard !sofs.isEmpty else { print("no SOF samples in \(dir)"); return false }
        for rel in sofs {
            let path = (dir as NSString).appendingPathComponent(rel)
            print("== \(rel)")
            guard let data = fm.contents(atPath: path), let sof = try? SOFFile(data: data) else {
                print("  FAIL parse"); ok = false; continue
            }
            let rt = sof.serialize() == data
            print("  \(rt ? "ok  " : "FAIL") parse -> serialize byte-identical (\(data.count) bytes, \(sof.records.count) records)")
            ok = ok && rt
            do { try sof.validate() }
            catch { print("  FAIL container: \(error.localizedDescription)"); ok = false }
            let crcOK = sof.storedCRC != nil && sof.storedCRC == sof.computedCRC(), sumOK = sof.storedChecksum != nil && sof.storedChecksum == sof.computedChecksum()
            print("  \(crcOK && sumOK ? "ok  " : "FAIL") CRC-16/X-25 and byte-sum checksum")
            ok = ok && crcOK && sumOK
            let folder = (path as NSString).deletingLastPathComponent
            let rbfs = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.lowercased().hasSuffix(".rbf") }.sorted()
            for r in rbfs {
                guard let q = fm.contents(atPath: (folder as NSString).appendingPathComponent(r)),
                      let qc = try? CycloneVConfig(rbf: q) else { print("  FAIL \(r): not decodable"); ok = false; continue }
                let sum = sof.computedChecksum() ?? 0
                if qc.jtagID != nil || qc.checksum != sum {
                    print(String(format: "  skip %@: different compile (rbf checksum 0x%08X, sof 0x%08X)", r, qc.checksum, sum))
                    continue
                }
                let compressed = q.count < CycloneVSX120F.uncompressedSize
                let mine = (try? sof.extractRBF(compressed: compressed)) ?? Data()
                var diffs = 0, first = -1
                mine.withUnsafeBytes { a in
                    q.withUnsafeBytes { b in
                        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
                            if first < 0 { first = i }
                            diffs += 1
                        }
                    }
                }
                let same = mine == q
                print("  \(same ? "ok  " : "DIFF") sof -> \(compressed ? "compressed " : "")rbf vs \(r): " +
                      (same ? "byte-identical (\(q.count) bytes)" : "\(diffs) bytes differ, first at \(first), sizes \(mine.count)/\(q.count)"))
                ok = ok && same
                let cfgSame = qc.cram == sof.cram?.data && qc.pram == sof.pram?.data
                print("  \(cfgSame ? "ok  " : "FAIL") \(r) decodes to the .sof's CRAM and PRAM exactly")
                ok = ok && cfgSame
                do {
                    let back = try SOFFile(wrapping: q, device: sof.device ?? "", options: .init(template: sof))
                    let same2 = back.serialize() == data
                    print("  \(same2 ? "ok  " : "FAIL") \(r) -> sof (metadata from template) reproduces the original")
                    ok = ok && same2
                }
                catch { print("  FAIL rbf -> sof: \(error.localizedDescription)"); ok = false }
                if let fresh = try? SOFFile(wrapping: q, device: sof.device ?? "") {
                    let differing = Set(sof.records.map { $0.tag }).union(fresh.records.map { $0.tag }).sorted().filter { t in
                        sof.body(t) != fresh.body(t)
                    }
                    print("       \(r) -> sof (no template): records that differ from Quartus': " +
                          differing.map { String(format: "0x%04x", $0) }.joined(separator: " "))
                }
            }
        }
        return ok
    }
}

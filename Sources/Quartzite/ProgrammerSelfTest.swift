import Foundation

/// Self-tests for the Programmer (Programmer.swift, BoundaryScan.swift, ProgrammerCLI.swift).
/// No board is needed: openFPGALoader is replaced by `FakeProgrammerRunner`, which answers
/// with output captured from a real openFPGALoader build (ci/fixtures/openfpgaloader).
/// Set `QUARTZITE_BSDL` to a downloaded 5CSXFC6D6F31 BSDL file to also check the real pin map.
final class FakeProgrammerRunner: ProgrammerRunner {
    struct Reply { var status: Int32; var output: String }
    /// Answers by the first argument that identifies the operation.
    var replies: [String: Reply] = [:]
    private(set) var calls: [[String]] = []

    func run(_ exe: URL, _ args: [String], cancel: ProcessCancel?, onLine: ((String) -> Void)?) throws -> ToolProcess.Result {
        calls.append(args)
        let key = ["--scan-usb", "--list-cables", "--detect", "--write-sram"].first { args.contains($0) }
            ?? (args.last?.hasSuffix(".svf") == true ? "svf" : "?")
        let r = replies[key] ?? Reply(status: 1, output: "no fake reply for \(key)")
        r.output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).forEach { onLine?(String($0)) }
        return ToolProcess.Result(status: r.status, output: r.output, cancelled: false, elapsed: 0)
    }
}

enum ProgrammerSelfTest {
    typealias Check = (Bool, String) -> Void

    static func fixture(_ name: String, _ check: Check) -> String? {
        HierarchySelfTest.fixture("../openfpgaloader/" + name, check)
    }

    static func run(_ check: Check) {
        print("Programmer: command lines")
        commandLines(check)
        print("Programmer: openFPGALoader output")
        parsing(check)
        print("Programmer: programming with a fake cable")
        programming(check)
        print("Programmer: board view (boundary-scan SAMPLE)")
        boundaryScan(check)
    }

    static let tool = URL(fileURLWithPath: "/opt/tools/bin/openFPGALoader")
    static let firmware = URL(fileURLWithPath: "/Volumes/Quartus Files/linux64/blaster_6810.hex")

    static func commandLines(_ check: Check) {
        let o2 = ProgrammerOptions(tool: tool, cable: .usbBlasterII, firmware: firmware)
        check(Programmer.detectArgs(o2) == ["-c", "usb-blasterII", "--probe-firmware", firmware.path, "--detect"],
              "USB-Blaster II detect passes the firmware")
        let rbf = URL(fileURLWithPath: "/tmp/out dir/lab.rbf")
        check(Programmer.programArgs(o2, index: 1, rbf: rbf) == ["-c", "usb-blasterII", "--probe-firmware", firmware.path,
                                                                 "--index-chain", "1", "--write-sram", rbf.path],
              "USB-Blaster II program: firmware, --index-chain of the FPGA, --write-sram (SRAM, not flash), .rbf path")
        let o1 = ProgrammerOptions(tool: tool, cable: .usbBlaster, firmware: firmware)
        check(Programmer.detectArgs(o1) == ["-c", "usb-blaster", "--detect"], "USB-Blaster (FTDI) needs no firmware")
        check(Programmer.programArgs(o1, index: 0, rbf: rbf) == ["-c", "usb-blaster", "--index-chain", "0", "--write-sram", rbf.path],
              "USB-Blaster program honours the index")
        let svf = URL(fileURLWithPath: "/tmp/s.svf")
        check(Programmer.svfArgs(o2, index: 1, svf: svf).suffix(3) == ["--index-chain", "1", svf.path], "SVF playback targets the FPGA only")
        check(Programmer.listCablesArgs() == ["--list-cables"] && Programmer.scanArgs() == ["--scan-usb"], "list and scan")
        check(Programmer.shellLine(tool, Programmer.programArgs(o2, index: 1, rbf: rbf))
              == "/opt/tools/bin/openFPGALoader -c usb-blasterII --probe-firmware '/Volumes/Quartus Files/linux64/blaster_6810.hex' --index-chain 1 --write-sram '/tmp/out dir/lab.rbf'",
              "shell line quotes paths with spaces")
        check(Programmer.shellQuote("it's") == "'it'\\''s'", "single quotes are escaped")
        check(ProgrammerCable(rawValue: "usb-blasterII") == .usbBlasterII && ProgrammerCable(rawValue: "usb-blaster") == .usbBlaster
              && ProgrammerCable(rawValue: "usb-blaster2") == nil, "cable names match openFPGALoader")

        // CLI option resolution (no hardware, no installed tool needed).
        let env = ["PATH": "", "QUARTZITE_TOOLCHAIN": "/nonexistent", "HOME": "/nonexistent"]
        if let r = try? CLI.programmerOptions(["--program", "a.sof", "--cable", "usb-blaster", "--dry-run"], requireTool: false, environment: env) {
            check(r.options.cable == .usbBlaster && r.options.firmware == nil && r.options.tool.relativePath == "openFPGALoader",
                  "--cable usb-blaster; a missing tool prints as bare openFPGALoader in --dry-run")
        } else { check(false, "--dry-run options resolve without a tool") }
        if let r = try? CLI.programmerOptions(["--program", "a.sof", "--firmware", firmware.path, "--tool", "/bin/sh"], requireTool: true, environment: env) {
            check(r.options.cable == .usbBlasterII && r.options.firmware == firmware && r.options.tool.path == "/bin/sh",
                  "--firmware and --tool are used as given")
        } else { check(false, "--firmware and --tool resolve") }
        check((try? CLI.programmerOptions(["--program", "a.sof", "--cable", "jtag"], requireTool: false, environment: env)) == nil, "an unknown cable is refused")
        check((try? CLI.programmerOptions(["--detect", "--firmware"], requireTool: false, environment: env)) == nil, "--firmware without a value is refused")
        do { _ = try CLI.programmerOptions(["--detect"], requireTool: true, environment: env); check(false, "--detect without openFPGALoader is refused") }
        catch ProgrammerError.toolMissing(let m) { check(m.contains("build_toolchain.sh") && m.contains("brew install openfpgaloader"), "--detect without openFPGALoader explains how to get it") }
        catch { check(false, "--detect without openFPGALoader: \(error)") }
        let envFW = env.merging(["QUARTZITE_BLASTER_FIRMWARE": "/x/blaster_6810.hex"]) { $1 }
        check(BlasterFirmware.locate(setting: nil, environment: envFW)?.path == "/x/blaster_6810.hex"
              && BlasterFirmware.locate(setting: "/y/fw.hex", environment: envFW)?.path == "/y/fw.hex",
              "firmware: the setting wins over QUARTZITE_BLASTER_FIRMWARE")
        check(Programmer.locateTool(setting: "/bin/sh", environment: env).url?.path == "/bin/sh"
              && Programmer.locateTool(setting: nil, environment: env).url == nil,
              "openFPGALoader: setting first, nothing found in an empty environment")
        check(BlasterFirmware.missingHelp.contains("quartus/linux64/blaster_6810.hex"), "the firmware help says where Quartus keeps the file")
    }

    static func parsing(_ check: Check) {
        if let v = fixture("version.txt", check) { check(v.hasPrefix("openFPGALoader v"), "--Version fixture") }
        if let t = fixture("list_cables.txt", check) {
            let c = Programmer.parseCables(t)
            func has(_ n: String, _ v: UInt16, _ p: UInt16) -> Bool { c.contains { $0.name == n && $0.vid == v && $0.pid == p } }
            check(c.count > 40, "--list-cables parses (\(c.count) cables)")
            check(has("usb-blasterII", 0x09FB, 0x6810) && has("usb-blasterII_1", 0x09FB, 0x6010) && has("usb-blaster", 0x09FB, 0x6001),
                  "--list-cables has the USB-Blaster II (6810 before firmware, 6010 after) and USB-Blaster")
        }
        let o = ProgrammerOptions(tool: tool, cable: .usbBlasterII, firmware: firmware)
        if let t = fixture("scan_usb_none.txt", check) { check(Programmer.parseScan(t).isEmpty, "--scan-usb with nothing attached: No Hardware") }
        if let t = fixture("synthesized/scan_usb_de_soc.txt", check) {
            let p = Programmer.parseScan(t)
            check(p.count == 1 && p[0].cable == .usbBlasterII && p[0].displayName(port: 1) == "DE-SoC [USB-1]",
                  "--scan-usb row becomes \"DE-SoC [USB-1]\"")
        }
        let raw = USBProbe(bus: 1, device: 2, vid: 0x09FB, pid: 0x6810, probe: "usb-blasterII", manufacturer: "none", serial: "none", product: "none")
        check(raw.needsFirmwareLoad && raw.displayName(port: 2).hasPrefix("USB-BlasterII [USB-2]"), "a USB-Blaster II without firmware is named as such")
        if let t = fixture("detect_blasterII_no_firmware.txt", check) {
            check(Programmer.parseDetect(t).isEmpty && Programmer.diagnose(t, options: o) == .firmwareMissing(BlasterFirmware.missingHelp),
                  "missing firmware is explained")
        }
        for name in ["detect_blasterII_no_device.txt", "detect_blaster_no_device.txt"] {
            if let t = fixture(name, check) {
                if case .noHardware(let m) = Programmer.diagnose(t, options: o) { check(m.hasPrefix("No Hardware"), "\(name): No Hardware") }
                else { check(false, "\(name): No Hardware") }
            }
        }
        if let t = fixture("synthesized/detect_de10_standard.txt", check) {
            let chain = Programmer.parseDetect(t)
            check(chain.map(\.name) == ["SOCVHPS", "5CSXFC6D6F31"], "Auto Detect: SOCVHPS then 5CSXFC6D6F31")
            check(chain.map(\.idcodeText) == ["0x4BA00477", "0x02D020DD"] && chain.map(\.index) == [0, 1] && chain.map(\.irLength) == [4, 10],
                  "IDCODEs, chain indices and IR lengths")
            check(chain.map(\.isFPGA) == [false, true] && chain[1].detail == "cyclone V Soc 5CSE*A6/5CSX*6", "only the second is the FPGA")
        }
        if let t = fixture("synthesized/program_success.txt", check) {
            let p = t.split(whereSeparator: \.isNewline).compactMap { Programmer.parseProgress(String($0)) }
            check(p == [0, 0.5, 1], "SRAM progress lines parse to 0, 0.5, 1")
        }
        check(Programmer.parseProgress("\u{1B}[32mLoad SRAM: [==   ] 4.00%\u{1B}[0m") == 0.04, "colour codes are ignored")
        check(Programmer.parseProgress("Waiting reload: [====] 100.00%") == nil, "firmware reload progress is not SRAM progress")
        check(Programmer.quartusName(0x12D1_20DD) == "5CSEMA5F31" && Programmer.quartusName(0x1234_5678) == "0x12345678",
              "IDCODE names: version nibble ignored, unknown parts shown as hex")
        if case .noHardware = Programmer.diagnose("JTAG init failed with: TDO is stuck at 0", options: o) { check(true, "TDO stuck at 0: board off") }
        else { check(false, "TDO stuck at 0: board off") }
    }

    /// A tiny valid configuration wrapped in a .sof for `device`.
    static func sof(_ device: String, idcode: UInt8) -> Data? {
        typealias G = CycloneVSX120F
        var cram = [UInt8](repeating: 0, count: G.cramSX * G.cramSY / 8)
        cram[(1 + G.cramSX * 40) >> 3] = 0x02
        let cfg = CycloneVConfig(cram: Data(cram), pram: Data(count: (G.pramBits + 7) / 8), idcode: idcode)
        return (try? SOFFile(config: cfg, device: device))?.serialize()
    }

    static func programming(_ check: Check) {
        guard let detect = fixture("synthesized/detect_de10_standard.txt", check),
              let success = fixture("synthesized/program_success.txt", check),
              let noDevice = fixture("detect_blasterII_no_device.txt", check) else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quartzite-programmer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Firmware: only checked for shape; this is a two-line stand-in, not Intel's file.
            let fw = dir.appendingPathComponent("blaster_6810.hex")
            try ":0100000000FF\n:00000001FF\n".write(to: fw, atomically: true, encoding: .utf8)
            let notHex = dir.appendingPathComponent("notes.txt")
            try "hello\n".write(to: notHex, atomically: true, encoding: .utf8)
            guard let good = sof("5CSXFC6D6F31C6", idcode: 0x02), let otherDie = sof("5CSEMA5F31C6", idcode: 0x12),
                  let samedie = sof("5CSEBA6U23I7", idcode: 0x02) else { check(false, "test .sof files build"); return }
            let goodURL = dir.appendingPathComponent("lab one.sof"), dieURL = dir.appendingPathComponent("de1soc.sof")
            let nanoURL = dir.appendingPathComponent("nano.sof")
            try good.write(to: goodURL); try otherDie.write(to: dieURL); try samedie.write(to: nanoURL)
            let o = ProgrammerOptions(tool: tool, cable: .usbBlasterII, firmware: fw)

            // Success: detect, check, convert, program.
            let fake = FakeProgrammerRunner()
            fake.replies = ["--detect": .init(status: 0, output: detect), "--write-sram": .init(status: 0, output: success)]
            var log: [String] = []
            var svc = ProgrammerService(options: o, runner: fake)
            svc.log = { log.append($0) }
            var progress: [Double] = []
            try svc.program(file: goodURL, chain: nil, workDirectory: work) { progress.append($0) }
            let rbf = work.appendingPathComponent("lab one.rbf")
            check(fake.calls.count == 2 && fake.calls[0] == Programmer.detectArgs(o)
                  && fake.calls[1] == Programmer.programArgs(o, index: 1, rbf: rbf), "Start runs --detect, then --write-sram on index 1")
            check(((try? fm.attributesOfItem(atPath: rbf.path)[.size]) as? NSNumber)?.intValue == CycloneVSX120F.uncompressedSize,
                  "the .sof is converted to an uncompressed .rbf (JTAG cannot decompress)")
            check(progress.last == 1 && progress.contains(0.5), "progress reaches 100%")
            check(log.contains { $0.hasPrefix("$ ") && $0.contains("--write-sram") } && log.contains("Done"), "the log carries the commands and openFPGALoader's output")

            // A chain that is already known is not read again.
            let fake2 = FakeProgrammerRunner()
            fake2.replies = ["--write-sram": .init(status: 0, output: success)]
            try ProgrammerService(options: o, runner: fake2).program(file: goodURL, chain: Programmer.parseDetect(detect), workDirectory: work)
            check(fake2.calls.count == 1, "Start after Auto Detect only programs")

            // Device mismatch: refused before anything is sent to the board.
            for (url, what) in [(dieURL, "a .sof for another die (5CSEMA5)"), (nanoURL, "a .sof for another part on the same die (5CSEBA6U23)")] {
                let f = FakeProgrammerRunner()
                f.replies = ["--detect": .init(status: 0, output: detect), "--write-sram": .init(status: 0, output: success)]
                do {
                    try ProgrammerService(options: o, runner: f).program(file: url, chain: nil, workDirectory: work)
                    check(false, "\(what) is refused")
                } catch ProgrammerError.deviceMismatch(let m) {
                    check(m.hasPrefix("Device mismatch") && !f.calls.contains { $0.contains("--write-sram") }, "\(what) is refused, nothing programmed")
                }
            }
            let hps = Programmer.parseDetect(detect)[0]
            check(Programmer.mismatch(sofDevice: "5CSXFC6D6F31C6", target: hps) != nil, "the SOCVHPS row cannot take a .sof")

            // No hardware: detect fails, nothing is programmed.
            let f3 = FakeProgrammerRunner()
            f3.replies = ["--detect": .init(status: 1, output: noDevice), "--scan-usb": .init(status: 0, output: fixture("scan_usb_none.txt", check) ?? "")]
            let svc3 = ProgrammerService(options: o, runner: f3)
            check((try? svc3.scan())?.isEmpty == true, "Hardware Setup: No Hardware")
            do { try svc3.program(file: goodURL, chain: nil, workDirectory: work); check(false, "no hardware fails") }
            catch ProgrammerError.noHardware { check(f3.calls.filter { $0.contains("--write-sram") }.isEmpty, "no hardware: clear error, nothing programmed") }

            // Firmware missing or not a HEX file: nothing runs.
            for (bad, what) in [(nil, "no firmware chosen"), (notHex, "a file that is not Intel HEX")] {
                let f = FakeProgrammerRunner()
                var ob = o; ob.firmware = bad
                do { _ = try ProgrammerService(options: ob, runner: f).detect(); check(false, "\(what) is refused") }
                catch ProgrammerError.firmwareMissing { check(f.calls.isEmpty, "\(what): firmware error before running openFPGALoader") }
            }
            var oFTDI = o; oFTDI.cable = .usbBlaster; oFTDI.firmware = nil
            let f4 = FakeProgrammerRunner()
            f4.replies = ["--detect": .init(status: 0, output: detect)]
            check((try? ProgrammerService(options: oFTDI, runner: f4).detect())?.count == 2, "USB-Blaster detect works without firmware")

            // A failing load is reported with openFPGALoader's last lines.
            let f5 = FakeProgrammerRunner()
            f5.replies = ["--write-sram": .init(status: 1, output: "Load SRAM: [==  ] 4.00%\nFX2 write error: LIBUSB_ERROR_PIPE\n")]
            do { try ProgrammerService(options: o, runner: f5).program(file: goodURL, chain: Programmer.parseDetect(detect), workDirectory: work); check(false, "a failed load throws") }
            catch ProgrammerError.failed(let m) { check(m.contains("LIBUSB_ERROR_PIPE"), "a failed load shows openFPGALoader's error") }

            // .rbf input: uncompressed accepted, compressed refused, junk refused.
            let rbfIn = dir.appendingPathComponent("given.rbf")
            try fm.copyItem(at: rbf, to: rbfIn)
            check((try? ProgrammerService.prepare(file: rbfIn, target: Programmer.parseDetect(detect)[1], workDirectory: work)) != nil, "an uncompressed .rbf is accepted")
            if let s = try? SOFFile(data: good), let c = try? s.extractRBF(compressed: true) {
                let cURL = dir.appendingPathComponent("compressed.rbf")
                try c.write(to: cURL)
                do { _ = try ProgrammerService.prepare(file: cURL, target: nil, workDirectory: work); check(false, "compressed .rbf refused") }
                catch ProgrammerError.badFile(let m) { check(m.contains("compressed"), "a compressed .rbf is refused with the reason") }
            } else { check(false, "compressed .rbf builds") }
            var broken = good; broken[broken.count / 2] ^= 0xFF
            let brokenURL = dir.appendingPathComponent("broken.sof")
            try broken.write(to: brokenURL)
            do { _ = try ProgrammerService.prepare(file: brokenURL, target: nil, workDirectory: work); check(false, "a damaged .sof is refused") }
            catch ProgrammerError.badFile(let m) { check(m.contains("not a valid .sof"), "a damaged .sof is refused (SOF checks)") }

            // --dry-run: exact commands, no runner at all.
            let plan = try ProgrammerService.dryRun(file: goodURL, options: o, workDirectory: work)
            check(plan.commands == [Programmer.shellLine(tool, Programmer.detectArgs(o)), Programmer.shellLine(tool, Programmer.programArgs(o, index: 1, rbf: rbf))],
                  "--dry-run prints the detect and program commands")
            check(try ProgrammerService.dryRun(file: nanoURL, options: o, workDirectory: work).notes.contains { $0.hasPrefix("Warning") },
                  "--dry-run warns about a .sof for another part")
        } catch {
            check(false, "programming tests: \(error.localizedDescription)")
        }
    }

    /// A small BSDL in the format of Intel's Cyclone V files, written for this test: every board
    /// pin gets input, control and output cells at made-up positions.
    static func syntheticBSDL(entity: String = "CYCLONE_V_5CSXFC6D6F31") -> (text: String, inputCell: [String: Int]) {
        var ports: [String] = [], pinMap: [String] = [], cells: [String] = []
        var inputCell: [String: Int] = [:]
        var n = 3
        cells.append("\"0 (BC_4, *, internal, X), 1 (BC_4, *, internal, 1), 2 (BC_4, *, internal, X), \" &")
        for p in BoardScanMap.boardPins.reversed() {
            let ball = String(p.pin.dropFirst(4)), port = "IO" + ball
            ports.append(port); pinMap.append("\"\(port) : \(ball) , \" &")
            inputCell[p.label] = n
            cells.append("\"\(n) (BC_1, \(port), input, X), \(n + 1) (BC_1, *, control, 1), \(n + 2) (BC_1, \(port), output3, X, \(n + 1), 1, Z), \" &")
            n += 3
        }
        cells[cells.count - 1] = String(cells[cells.count - 1].dropLast(5)) + "\";"
        pinMap[pinMap.count - 1] = String(pinMap[pinMap.count - 1].dropLast(5)) + "\";"
        let text = """
            -- Synthetic boundary-scan description for Quartzite's self-test.
            entity \(entity) is
            generic (PHYSICAL_PIN_MAP : string := "FBGA896");
            port ( \(ports.joined(separator: ", ")) : inout bit );
            use STD_1149_1_1994.all;
            attribute PIN_MAP of \(entity) : entity is PHYSICAL_PIN_MAP;
            constant FBGA896 : PIN_MAP_STRING :=
            \(pinMap.joined(separator: "\n"))
            attribute INSTRUCTION_LENGTH of \(entity) : entity is 10;
            attribute INSTRUCTION_OPCODE of \(entity) : entity is
            "BYPASS (1111111111), "&
            "EXTEST (0000001111), "&
            "SAMPLE (0000000101), "&
            "IDCODE (0000000110)";
            attribute BOUNDARY_LENGTH of \(entity) : entity is \(n + 2);
            attribute BOUNDARY_REGISTER of \(entity) : entity is
              --BSC group 0 for untestable Family-specific pin
            \(cells.joined(separator: "\n"))
            end \(entity);
            """
        return (text, inputCell)
    }

    static func boundaryScan(_ check: Check) {
        let (text, inputCell) = syntheticBSDL()
        guard let bsdl = try? BSDLFile(text: text), let map = try? BoardScanMap(bsdl: bsdl) else {
            check(false, "synthetic BSDL parses and maps every board pin"); return
        }
        check(bsdl.instructionLength == 10 && bsdl.opcodes["SAMPLE"] == "0000000101" && bsdl.opcodes["EXTEST"] == "0000001111",
              "BSDL: instruction length and opcodes")
        check(map.cells == inputCell && map.cells.count == 66, "all 66 board pins (10 SW, 4 KEY, 10 LEDR, 42 HEX segments) map to their input cells")
        let svf = map.svf()
        check(svf.contains("SIR 10 TDI (005);") && !svf.contains("(00F)"), "the scan loads SAMPLE (0x005), never EXTEST")
        let mask = BoardScanMap.hex([Bool](repeating: true, count: map.boundaryLength))
        check(svf.contains("SDR \(map.boundaryLength) TDI (") && svf.contains("MASK (\(mask));") && mask.allSatisfy { $0 == "F" || $0 == "1" || $0 == "3" || $0 == "7" },
              "one SDR over the whole register, fully masked")
        check(BoardScanMap.hex([true, false, true, false, true]) == "15" && BoardScanMap.bits(hex: "15", count: 5) == [true, false, true, false, true],
              "SVF hex: bit 0 is the last digit's low bit")
        check(BoardScanMap.bits(hex: "1g", count: 8) == nil, "bad hex is rejected")

        // Board: SW0 and SW9 up, KEY1 pressed, LEDR0 and LEDR3 lit, HEX0 shows "1" (b, c lit).
        var bits = [Bool](repeating: false, count: map.boundaryLength)
        func set(_ label: String, _ v: Bool) { bits[inputCell[label]!] = v }
        set("SW0", true); set("SW9", true)
        for k in 0..<4 where k != 1 { set("KEY\(k)", true) }
        set("LEDR0", true); set("LEDR3", true)
        for d in 0..<6 { for g in 0..<7 { set("HEX\(d)[\(g)]", !(d == 0 && (g == 1 || g == 2))) } }
        let hex = BoardScanMap.hex(bits)
        let zero = String(repeating: "0", count: hex.count)
        let output = "Reading board_sample.svf with 7 lines\nTDO value \(hex) isn't the one expected: \(zero)\nCannot proceed because of error(s) at line 6\n"
        let fake = FakeProgrammerRunner()
        fake.replies = ["svf": .init(status: 1, output: output)]
        let o = ProgrammerOptions(tool: tool, cable: .usbBlasterII, firmware: firmware)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("quartzite-bscan-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        if let s = try? ProgrammerService(options: o, runner: fake).sampleBoard(map: map, index: 1, workDirectory: work) {
            var want = BoardState()
            want.switches[0] = true; want.switches[9] = true
            want.keysPressed[1] = true
            want.leds[0] = true; want.leds[3] = true
            want.segments[0][1] = true; want.segments[0][2] = true
            check(s == want, "SAMPLE bits decode to switches, buttons (active low), LEDs and segments (active low)")
            check(fake.calls.first == Programmer.svfArgs(o, index: 1, svf: work.appendingPathComponent("board_sample.svf")), "the scan plays an SVF on the FPGA's index")
            check(BoardScanMap.describe(s).hasPrefix("SW 9..0: 1000000001  KEY 3..0 pressed: 0010  LEDR 9..0: 0000001001"), "CLI board summary")
        } else { check(false, "a SAMPLE scan decodes") }
        let fake0 = FakeProgrammerRunner()
        fake0.replies = ["svf": .init(status: 0, output: "Reading board_sample.svf with 7 lines\nDone\nend of SVF file\n")]
        if let s = try? ProgrammerService(options: o, runner: fake0).sampleBoard(map: map, index: 1, workDirectory: work) {
            check(s.switches.allSatisfy { !$0 } && s.keysPressed.allSatisfy { $0 } && s.segments.allSatisfy { $0.allSatisfy { $0 } },
                  "an all-zero capture (no mismatch printed) means every pin is low")
        } else { check(false, "an all-zero capture decodes") }
        let fakeErr = FakeProgrammerRunner()
        fakeErr.replies = ["svf": .init(status: 1, output: "JTAG init failed with: FX2: fail to open device\n")]
        check((try? ProgrammerService(options: o, runner: fakeErr).sampleBoard(map: map, index: 1, workDirectory: work)) == nil, "a failed scan is an error, not a blank board")
        if let other = try? BSDLFile(text: syntheticBSDL(entity: "CYCLONE_V_5CSEMA5F31").text) {
            check((try? BoardScanMap(bsdl: other)) == nil, "a BSDL for another device is refused")
        } else { check(false, "second synthetic BSDL parses") }
        check((try? BSDLFile(text: "entity X is end X;")) == nil, "a file without a boundary register is refused")

        // Intel's real file, when the user points the test at it.
        if let path = ProcessInfo.processInfo.environment["QUARTZITE_BSDL"], !path.isEmpty {
            if let t = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), let real = try? BSDLFile(text: t),
               let m = try? BoardScanMap(bsdl: real) {
                check(real.boundaryLength == 1485 && m.sampleOpcode == "0000000101" && m.cells.count == 66,
                      "QUARTZITE_BSDL: 5CSXFC6D6F31 has 1485 cells, SAMPLE 0000000101, all 66 board pins mapped")
            } else { check(false, "QUARTZITE_BSDL parses and maps every board pin") }
        } else {
            print("  SKIP real 5CSXFC6D6F31 BSDL (set QUARTZITE_BSDL to check it)")
        }
    }
}

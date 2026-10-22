import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Programmer back end: drives openFPGALoader (an open-source JTAG loader) to read the
/// DE10-Standard's JTAG chain and load a .sof into the Cyclone V over the on-board
/// USB-Blaster II. Everything that touches hardware goes through a `ProgrammerRunner`, so the
/// command lines and the parsing of openFPGALoader's output are tested without a board.
///
/// Nothing from Intel is shipped: the USB-Blaster II needs FX2 firmware (`blaster_6810.hex`)
/// that the user points Quartzite at, from their own Quartus installation.

/// The JTAG cables openFPGALoader can use with a DE10-Standard.
enum ProgrammerCable: String, CaseIterable, Identifiable {
    /// The DE10-Standard's on-board USB-Blaster II (Cypress FX2, needs firmware).
    case usbBlasterII = "usb-blasterII"
    /// An original USB-Blaster (FTDI based) on the board's JTAG header.
    case usbBlaster = "usb-blaster"

    var id: String { rawValue }
    var title: String { self == .usbBlasterII ? "USB-Blaster II" : "USB-Blaster" }
    var needsFirmware: Bool { self == .usbBlasterII }
    /// USB vendor:product IDs. The USB-Blaster II enumerates as 09fb:6810 until its firmware
    /// is loaded, then as 09fb:6010.
    var usbIDs: [(vid: UInt16, pid: UInt16)] {
        switch self {
        case .usbBlasterII: return [(0x09FB, 0x6810), (0x09FB, 0x6010)]
        case .usbBlaster: return [(0x09FB, 0x6001)]
        }
    }
}

/// One device in the JTAG chain, as openFPGALoader's `--detect` reports it.
struct JTAGDevice: Equatable {
    /// openFPGALoader's `--index-chain` (0 is the device nearest TDI, the first one Quartus lists).
    var index: Int
    var idcode: UInt32
    var irLength: Int?
    /// openFPGALoader's description ("ARM cortex A9", "cyclone V Soc 5CSE*A6/5CSX*6").
    var detail: String
    /// The name Quartus Programmer shows (SOCVHPS, 5CSXFC6D6F31), or the IDCODE.
    var name: String { Programmer.quartusName(idcode) }
    var isFPGA: Bool { Programmer.isCycloneVSoCFPGA(idcode) }
    var idcodeText: String { String(format: "0x%08X", idcode) }
}

/// A JTAG probe found by `openFPGALoader --scan-usb`.
struct USBProbe: Equatable {
    var bus: Int
    var device: Int
    var vid: UInt16
    var pid: UInt16
    /// openFPGALoader's cable name ("usb-blasterII", "usb-blasterII_1", ...).
    var probe: String
    var manufacturer: String
    var serial: String
    var product: String

    var cable: ProgrammerCable? {
        ProgrammerCable.allCases.first { c in c.usbIDs.contains { $0.vid == vid && $0.pid == pid } }
    }
    /// True for a USB-Blaster II that still waits for its FX2 firmware.
    var needsFirmwareLoad: Bool { vid == 0x09FB && pid == 0x6810 }

    /// Quartus Hardware Setup style: "DE-SoC [USB-1]".
    func displayName(port: Int) -> String {
        var name = product
        if name.isEmpty || name == "none" {
            switch cable {
            case .usbBlasterII: name = needsFirmwareLoad ? "USB-BlasterII" : "DE-SoC"
            case .usbBlaster: name = "USB-Blaster"
            case nil: name = probe
            }
        }
        return "\(name) [USB-\(port)]" + (needsFirmwareLoad ? " (firmware not loaded yet)" : "")
    }
}

/// What the Programmer needs to run openFPGALoader.
struct ProgrammerOptions {
    var tool: URL
    var cable: ProgrammerCable = .usbBlasterII
    /// `blaster_6810.hex` from a Quartus installation (USB-Blaster II only).
    var firmware: URL? = nil
}

/// Runs openFPGALoader. The real one starts a process; tests inject a fake.
protocol ProgrammerRunner {
    func run(_ exe: URL, _ args: [String], cancel: ProcessCancel?, onLine: ((String) -> Void)?) throws -> ToolProcess.Result
}

enum ProgrammerError: Error, LocalizedError, Equatable {
    case toolMissing(String)
    case firmwareMissing(String)
    case noHardware(String)
    case deviceMismatch(String)
    case badFile(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolMissing(let s), .firmwareMissing(let s), .noHardware(let s), .deviceMismatch(let s),
             .badFile(let s), .failed(let s): return s
        case .cancelled: return "Stopped by the user"
        }
    }
}

enum Programmer {
    static let toolName = "openFPGALoader"
    /// The DE10-Standard's FPGA (Quartus device name without speed grade, as the chain shows it).
    static let boardFPGA = "5CSXFC6D6F31"
    /// Cyclone V SoC HPS debug access port (ARM CoreSight DAP), "SOCVHPS" in Quartus.
    static let hpsIDCode: UInt32 = 0x4BA0_0477
    /// openFPGALoader index of the FPGA on a DE10-Standard (SOCVHPS is index 0); used by
    /// `--dry-run`, which does not read the chain.
    static let defaultFPGAIndex = 1

    // MARK: Device names

    static func isHPS(_ idcode: UInt32) -> Bool { idcode & 0x0FFF_FFFF == hpsIDCode & 0x0FFF_FFFF }

    /// Cyclone V SE/SX/ST: IDCODE 0x02Dx_x0DD (manufacturer 0x6E, family 0x2D).
    static func isCycloneVSoCFPGA(_ idcode: UInt32) -> Bool { idcode & 0x0FF0_0FFF == 0x02D0_00DD }

    /// The device byte that `CycloneVSX120F.idcodeByte(forDevice:)` returns for the same die.
    static func dieByte(_ idcode: UInt32) -> UInt8 { UInt8((idcode >> 12) & 0xFF) }

    static func quartusName(_ idcode: UInt32) -> String {
        if isHPS(idcode) { return "SOCVHPS" }
        if isCycloneVSoCFPGA(idcode) {
            switch dieByte(idcode) {
            case 0x02: return boardFPGA        // 5CSEBA6 / 5CSEMA6 / 5CSXFC6 / 5CSTFD6 die; the DE10-Standard part
            case 0x12: return "5CSEMA5F31"     // DE1-SoC
            default: break
            }
        }
        return String(format: "0x%08X", idcode)
    }

    /// Why a .sof for `device` cannot go into the chain device `target`, or nil if it can.
    static func mismatch(sofDevice device: String, target: JTAGDevice) -> String? {
        guard target.isFPGA else {
            return "\(target.name) (\(target.idcodeText)) is not a Cyclone V FPGA; only the FPGA row can be programmed with a .sof"
        }
        guard let part = CycloneVSX120F.part(device), let byte = CycloneVSX120F.idcodeByte(forDevice: part) else {
            return "the file is for \(device), which Quartzite does not know (expected \(CycloneV.device))"
        }
        guard byte == dieByte(target.idcode) else {
            return "the file is for \(part), but the chain has \(target.name) (\(target.idcodeText)); they are different dies"
        }
        let name = target.name
        if name.hasPrefix("5C"), !part.hasPrefix(name) {
            return "the file is for \(part), but the chain device is \(name)"
        }
        return nil
    }

    // MARK: Command lines

    static func cableArgs(_ o: ProgrammerOptions) -> [String] {
        var a = ["-c", o.cable.rawValue]
        if o.cable.needsFirmware, let fw = o.firmware { a += ["--probe-firmware", fw.relativePath] }
        return a
    }
    static func listCablesArgs() -> [String] { ["--list-cables"] }
    static func scanArgs() -> [String] { ["--scan-usb"] }
    static func detectArgs(_ o: ProgrammerOptions) -> [String] { cableArgs(o) + ["--detect"] }
    /// Loads an uncompressed .rbf into the FPGA's configuration SRAM (not flash).
    static func programArgs(_ o: ProgrammerOptions, index: Int, rbf: URL) -> [String] {
        cableArgs(o) + ["--index-chain", String(index), "--write-sram", rbf.path]
    }
    /// Plays an SVF file against one device of the chain (used for boundary-scan SAMPLE).
    static func svfArgs(_ o: ProgrammerOptions, index: Int, svf: URL) -> [String] {
        cableArgs(o) + ["--index-chain", String(index), svf.path]
    }

    /// A command line as it would be typed in Terminal.
    static func shellLine(_ exe: URL, _ args: [String]) -> String {
        ([exe.relativePath] + args).map(shellQuote).joined(separator: " ")
    }
    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=+@,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Output parsing

    /// Removes terminal colour codes (openFPGALoader colours its output on a terminal).
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    /// `--list-cables`: "usb-blasterII            0x09fb:6810".
    static func parseCables(_ text: String) -> [(name: String, vid: UInt16, pid: UInt16)] {
        var out: [(String, UInt16, UInt16)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = plain(String(raw)).split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count == 2, f[1].hasPrefix("0x") else { continue }
            let ids = f[1].dropFirst(2).split(separator: ":")
            guard ids.count == 2, let v = UInt16(ids[0], radix: 16), let p = UInt16(ids[1].replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
            out.append((f[0], v, p))
        }
        return out
    }

    /// `--scan-usb`: "001 004    0x09fb:0x6010 usb-blasterII_1 Altera  none DE-SoC".
    static func parseScan(_ text: String) -> [USBProbe] {
        var out: [USBProbe] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = plain(String(raw)).split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 4, let bus = Int(f[0]), let dev = Int(f[1]) else { continue }
            let ids = f[2].split(separator: ":").map { $0.replacingOccurrences(of: "0x", with: "") }
            guard ids.count == 2, let v = UInt16(ids[0], radix: 16), let p = UInt16(ids[1], radix: 16) else { continue }
            out.append(USBProbe(bus: bus, device: dev, vid: v, pid: p, probe: f[3],
                                manufacturer: f.count > 4 ? f[4] : "", serial: f.count > 5 ? f[5] : "",
                                product: f.count > 6 ? f[6...].joined(separator: " ") : ""))
        }
        return out
    }

    /// `--detect`: blocks of "index N:" followed by tab-indented "key value" lines.
    static func parseDetect(_ text: String) -> [JTAGDevice] {
        var out: [JTAGDevice] = []
        var current: (index: Int, fields: [String: String])?
        func flush() {
            guard let c = current, let id = c.fields["idcode"], let code = UInt32(id.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return }
            let detail = c.fields["type"] ?? [c.fields["family"], c.fields["model"]].compactMap { $0 }.joined(separator: " ")
            out.append(JTAGDevice(index: c.index, idcode: code, irLength: c.fields["irlength"].flatMap { Int($0) }, detail: detail))
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = plain(String(raw))
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("index "), t.hasSuffix(":"), let n = Int(t.dropFirst(6).dropLast()) {
                flush()
                current = (n, [:])
            } else if current != nil, line.hasPrefix("\t") || line.hasPrefix(" ") {
                let parts = t.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                if parts.count == 2 { current!.fields[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
            } else if current != nil {
                flush()
                current = nil
            }
        }
        flush()
        return out
    }

    /// "Load SRAM: [=====      ] 45.00%" -> 0.45.
    static func parseProgress(_ line: String) -> Double? {
        let s = plain(line)
        guard s.contains("Load SRAM"), let r = s.range(of: "\\] *[0-9.]+%", options: .regularExpression) else { return nil }
        let num = s[r].dropFirst().trimmingCharacters(in: .whitespaces).dropLast()
        return Double(num).map { min(1, max(0, $0 / 100)) }
    }

    /// A readable explanation of a failed openFPGALoader run.
    static func diagnose(_ output: String, options o: ProgrammerOptions) -> ProgrammerError {
        let text = plain(output)
        if text.contains("missing FX2 firmware") {
            return .firmwareMissing(BlasterFirmware.missingHelp)
        }
        if text.contains("FX2: fail to open device") || text.contains("unable to open ftdi device")
            || text.contains("device not found") || text.contains("No USB devices found") {
            let how = o.cable == .usbBlasterII
                ? "Connect the DE10-Standard's USB-Blaster II port to this Mac with a USB cable and turn the board on (if it was already connected, unplug it and plug it back in)."
                : "Connect the USB-Blaster to this Mac and to the board's JTAG header, and turn the board on."
            return .noHardware("No Hardware: no \(o.cable.title) was found. " + how)
        }
        if text.contains("LIBUSB_ERROR_ACCESS") || text.contains("Access denied") {
            return .noHardware("The \(o.cable.title) was found but could not be opened (access denied). Quit any other program that is using it (a virtual machine running Quartus, for example) and try again.")
        }
        if text.contains("LIBUSB_ERROR_BUSY") {
            return .noHardware("The \(o.cable.title) is in use by another program. Quit it and try again.")
        }
        if text.contains("TDO is stuck at 0") {
            return .noHardware("The JTAG chain does not respond (TDO is stuck at 0). Check that the DE10-Standard is powered on.")
        }
        if text.contains("Unknown device with IDCODE") {
            let line = text.split(whereSeparator: \.isNewline).first { $0.contains("Unknown device") }.map(String.init) ?? ""
            return .failed("openFPGALoader does not know a device in the JTAG chain: \(line)")
        }
        if text.contains("no device found") { return .noHardware("The JTAG chain is empty. Check that the DE10-Standard is powered on.") }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " / ")
        return .failed("openFPGALoader failed" + (tail.isEmpty ? "" : ": \(tail)"))
    }

    // MARK: Locating openFPGALoader

    struct ToolSearch {
        var url: URL?
        var source: String
        var searched: [String]

        var summary: String {
            if let url { return "openFPGALoader: \(url.path) (found via \(source))" }
            return "openFPGALoader was not found (searched \(searched.joined(separator: ", ")))"
        }
    }

    /// Search order: the Programmer setting, `QUARTZITE_OPENFPGALOADER`, the toolchain folder
    /// (`~/.quartzite/toolchain/prefix/bin` or `$QUARTZITE_TOOLCHAIN/prefix/bin`), `PATH`, Homebrew.
    static func locateTool(setting: String? = nil, environment env: [String: String] = ProcessInfo.processInfo.environment) -> ToolSearch {
        let fm = FileManager.default
        var searched: [String] = []
        func found(_ path: String, _ source: String) -> ToolSearch? {
            searched.append(path)
            return fm.isExecutableFile(atPath: path) ? ToolSearch(url: URL(fileURLWithPath: path), source: source, searched: searched) : nil
        }
        if let s = setting, !s.isEmpty {
            // A folder (the toolchain prefix or its bin folder) or the executable itself.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: s, isDirectory: &isDir), isDir.boolValue {
                for p in [s + "/" + toolName, s + "/bin/" + toolName, s + "/prefix/bin/" + toolName] {
                    if let r = found(p, "Programmer setting") { return r }
                }
            } else if let r = found(s, "Programmer setting") { return r }
        }
        if let v = env["QUARTZITE_OPENFPGALOADER"], !v.isEmpty, let r = found(v, "QUARTZITE_OPENFPGALOADER") { return r }
        if let r = found(Toolchain.defaultPrefix(env).appendingPathComponent(toolName).path, "toolchain folder") { return r }
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for d in pathDirs where fm.isExecutableFile(atPath: d + "/" + toolName) {
            return ToolSearch(url: URL(fileURLWithPath: d + "/" + toolName), source: "PATH", searched: searched)
        }
        searched.append("PATH")
        for d in ["/opt/homebrew/bin", "/usr/local/bin"] where !pathDirs.contains(d) {
            if let r = found(d + "/" + toolName, d) { return r }
        }
        return ToolSearch(url: nil, source: "", searched: searched)
    }

    static let toolMissingHelp = """
        openFPGALoader was not found. Build it with the rest of the open-source toolchain \
        (toolchain/build_toolchain.sh in the Quartzite repository puts it in ~/.quartzite/toolchain/prefix/bin), \
        or install it with Homebrew (brew install openfpgaloader), then choose it in Settings > Programmer if \
        Quartzite still does not find it.
        """
}

// MARK: - USB-Blaster II firmware

/// The USB-Blaster II is a Cypress FX2 that loads its firmware from the host each time it is
/// plugged in. The firmware is Intel's and comes with every Quartus installation; Quartzite
/// never ships it, it only finds or asks for the user's copy.
enum BlasterFirmware {
    static let fileName = "blaster_6810.hex"

    static let missingHelp = """
        The USB-Blaster II needs its firmware file, blaster_6810.hex, which comes with Quartus Prime \
        (any edition, including the free Lite edition). Copy it from a Quartus installation: on Linux it is \
        <Quartus folder>/quartus/linux64/blaster_6810.hex (for example ~/intelFPGA_lite/18.0/quartus/linux64/). \
        Then choose it in Settings > Programmer, or pass --firmware <path> on the command line. \
        Quartzite does not include this file because it belongs to Intel.
        """

    /// Places a Quartus installation (or a copy the user made) usually puts the file.
    static func candidates(environment env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let v = env["QUARTZITE_BLASTER_FIRMWARE"], !v.isEmpty { out.append(URL(fileURLWithPath: v)) }
        let home = NSHomeDirectory()
        out.append(URL(fileURLWithPath: home + "/.quartzite/" + fileName))
        let fm = FileManager.default
        for root in [home + "/intelFPGA_lite", home + "/intelFPGA", home + "/altera_lite", home + "/altera",
                     "/opt/intelFPGA_lite", "/opt/intelFPGA", "/opt/altera"] {
            guard let versions = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for v in versions.sorted().reversed() {
                out.append(URL(fileURLWithPath: "\(root)/\(v)/quartus/linux64/\(fileName)"))
            }
        }
        return out
    }

    /// The setting when it names a file, otherwise the first candidate that exists.
    static func locate(setting: String?, environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let s = setting, !s.isEmpty { return URL(fileURLWithPath: s) }
        if let v = env["QUARTZITE_BLASTER_FIRMWARE"], !v.isEmpty { return URL(fileURLWithPath: v) }
        return candidates(environment: env).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Checks that `url` looks like the FX2 firmware (an Intel HEX file), without judging its contents further.
    static func check(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw ProgrammerError.firmwareMissing("The USB-Blaster II firmware file \(url.path) cannot be read. \(missingHelp)")
        }
        let text = String(decoding: data.prefix(1 << 20), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard data.count < 1 << 20, !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix(":") }), lines.last?.uppercased() == ":00000001FF" else {
            throw ProgrammerError.firmwareMissing("\(url.lastPathComponent) is not an Intel HEX firmware file. Choose blaster_6810.hex from <Quartus folder>/quartus/linux64/.")
        }
    }
}

// MARK: - Running openFPGALoader

/// Runs openFPGALoader for real. On macOS it gets a pseudo-terminal so its progress bar is
/// delivered while it runs (on a pipe the C library would hold the output back until exit);
/// lines are split on both carriage returns and newlines.
struct ProcessProgrammerRunner: ProgrammerRunner {
    func run(_ exe: URL, _ args: [String], cancel: ProcessCancel?, onLine: ((String) -> Void)?) throws -> ToolProcess.Result {
        #if canImport(Darwin)
        var master: Int32 = -1, slave: Int32 = -1
        if openpty(&master, &slave, nil, nil, nil) == 0 {
            return try runPTY(exe, args, master: master, slave: slave, cancel: cancel, onLine: onLine)
        }
        #endif
        var split: ((String) -> Void)? = nil
        if let onLine { split = { line in line.split(separator: "\r").forEach { onLine(String($0)) } } }
        return try ToolProcess.run(exe, args, cancel: cancel, onLine: split)
    }

    #if canImport(Darwin)
    private func runPTY(_ exe: URL, _ args: [String], master: Int32, slave: Int32, cancel: ProcessCancel?,
                        onLine: ((String) -> Void)?) throws -> ToolProcess.Result {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let start = Date()
        defer { close(master) }
        if let cancel, !cancel.attach(p) {
            close(slave)
            return ToolProcess.Result(status: -1, output: "", cancelled: true, elapsed: 0)
        }
        defer { cancel?.detach() }
        do { try p.run() } catch {
            close(slave)
            throw ToolProcess.Failure(message: "could not start \(exe.path): \(error.localizedDescription)")
        }
        close(slave)   // the child has its own copy; reading the master ends with EIO when it exits
        var collected = Data(), pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        func emit(final: Bool) {
            while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...i)
                if !line.isEmpty { onLine?(line) }
            }
            if final, !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        }
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                collected.append(contentsOf: buf[0..<n])
                pending.append(contentsOf: buf[0..<n])
                emit(final: false)
            } else if n < 0, errno == EINTR {
                continue
            } else { break }
        }
        emit(final: true)
        p.waitUntilExit()
        let text = String(decoding: collected, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return ToolProcess.Result(status: p.terminationStatus, output: text,
                                  cancelled: cancel?.isCancelled ?? false, elapsed: Date().timeIntervalSince(start))
    }
    #endif
}

/// The operations of the Programmer window and CLI, on top of an injectable runner.
struct ProgrammerService: @unchecked Sendable {
    var options: ProgrammerOptions
    var runner: ProgrammerRunner = ProcessProgrammerRunner()
    var cancel: ProcessCancel? = nil
    /// Every command and output line, for the log pane.
    var log: ((String) -> Void)? = nil

    private func exec(_ args: [String], onLine: ((String) -> Void)? = nil) throws -> ToolProcess.Result {
        log?("$ " + Programmer.shellLine(options.tool, args))
        let r = try runner.run(options.tool, args, cancel: cancel) { line in
            let l = Programmer.plain(line)
            log?(l)
            onLine?(l)
        }
        if r.cancelled { throw ProgrammerError.cancelled }
        return r
    }

    private func requireFirmware() throws {
        guard options.cable.needsFirmware else { return }
        guard let fw = options.firmware else { throw ProgrammerError.firmwareMissing(BlasterFirmware.missingHelp) }
        try BlasterFirmware.check(fw)
    }

    /// Hardware Setup: the JTAG probes on USB that openFPGALoader can drive (empty = "No Hardware").
    func scan() throws -> [USBProbe] {
        let r = try exec(Programmer.scanArgs())
        return Programmer.parseScan(r.output).filter { $0.cable != nil }
    }

    /// Auto Detect: the devices in the JTAG chain, nearest TDI first (SOCVHPS, 5CSXFC6D6F31).
    func detect() throws -> [JTAGDevice] {
        try requireFirmware()
        let r = try exec(Programmer.detectArgs(options))
        let chain = Programmer.parseDetect(r.output)
        if r.status != 0 || chain.isEmpty { throw Programmer.diagnose(r.output, options: options) }
        return chain
    }

    /// The FPGA row of a chain: the only Cyclone V SoC device, or an error.
    static func fpga(in chain: [JTAGDevice]) throws -> JTAGDevice {
        let fpgas = chain.filter(\.isFPGA)
        guard let f = fpgas.first else {
            throw ProgrammerError.deviceMismatch("No Cyclone V FPGA in the JTAG chain (found \(chain.map { "\($0.name) \($0.idcodeText)" }.joined(separator: ", "))). Is this a DE10-Standard?")
        }
        guard fpgas.count == 1 else { throw ProgrammerError.deviceMismatch("More than one Cyclone V FPGA in the JTAG chain; Quartzite expects the DE10-Standard's single FPGA") }
        return f
    }

    /// Checks a programming file and returns an uncompressed .rbf for JTAG configuration.
    /// A .sof is converted (as `--sof-to-rbf` does); a .rbf must already be uncompressed.
    /// `target` is the chain device it will go into (nil skips the device check, for `--dry-run`).
    static func prepare(file: URL, target: JTAGDevice?, workDirectory: URL) throws -> (rbf: URL, device: String, notes: [String]) {
        let ext = file.pathExtension.lowercased()
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw ProgrammerError.badFile("\(file.path) cannot be read: \(error.localizedDescription)")
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let out = workDirectory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".rbf")
        switch ext {
        case "sof":
            let sof: SOFFile
            do { sof = try SOFFile(data: data); try sof.validate() } catch {
                throw ProgrammerError.badFile("\(file.lastPathComponent) is not a valid .sof: \(error.localizedDescription)")
            }
            guard let device = sof.device else { throw ProgrammerError.badFile("\(file.lastPathComponent) does not name its device") }
            if let target, let why = mismatchError(device, target) { throw why }
            let rbf: Data
            do { rbf = try sof.extractRBF(compressed: false) } catch {
                throw ProgrammerError.badFile("\(file.lastPathComponent) cannot be converted for JTAG configuration: \(error.localizedDescription)")
            }
            try rbf.write(to: out, options: .atomic)
            return (out, device, ["\(file.lastPathComponent): device \(device), checksum \(sof.storedChecksum.map { String(format: "0x%08X", $0) } ?? "none"); converted to an uncompressed .rbf (\(rbf.count) bytes) for JTAG"])
        case "rbf":
            let cfg: CycloneVConfig
            do { cfg = try CycloneVConfig(rbf: data) } catch {
                throw ProgrammerError.badFile("\(file.lastPathComponent): \(error.localizedDescription)")
            }
            guard data.count == CycloneVSX120F.uncompressedSize else {
                throw ProgrammerError.badFile("\(file.lastPathComponent) is a compressed .rbf. The Cyclone V cannot decompress a bitstream loaded over JTAG; use the .sof instead (Quartzite converts it).")
            }
            if let target {
                guard target.isFPGA, Programmer.dieByte(target.idcode) == cfg.idcode else {
                    throw ProgrammerError.deviceMismatch(String(format: "Device mismatch: %@ is for IDCODE byte 0x%02x, but the chain device is %@ (%@)", file.lastPathComponent, cfg.idcode, target.name, target.idcodeText))
                }
            }
            if out.standardizedFileURL != file.standardizedFileURL { try data.write(to: out, options: .atomic) }
            return (out, Programmer.quartusName(0x02D0_00DD | UInt32(cfg.idcode) << 12), ["\(file.lastPathComponent): uncompressed .rbf (\(data.count) bytes)"])
        default:
            throw ProgrammerError.badFile("\(file.lastPathComponent): the Programmer accepts .sof (or uncompressed .rbf) files")
        }
    }

    private static func mismatchError(_ device: String, _ target: JTAGDevice) -> ProgrammerError? {
        Programmer.mismatch(sofDevice: device, target: target).map {
            .deviceMismatch("Device mismatch: \($0). Quartzite will not program it. Compile the project for \(CycloneV.device) (Assignments > Device).")
        }
    }

    /// Start: detects the chain if needed, checks the file against the FPGA and loads it.
    /// `progress` gets 0...1 while openFPGALoader loads the SRAM.
    func program(file: URL, chain known: [JTAGDevice]?, workDirectory: URL, progress: ((Double) -> Void)? = nil) throws {
        try requireFirmware()
        let chain = try known ?? detect()
        let target = try ProgrammerService.fpga(in: chain)
        let prepared = try ProgrammerService.prepare(file: file, target: target, workDirectory: workDirectory)
        prepared.notes.forEach { log?($0) }
        var sawDone = false
        let r = try exec(Programmer.programArgs(options, index: target.index, rbf: prepared.rbf)) { line in
            if let p = Programmer.parseProgress(line) { progress?(p) }
            if line.trimmingCharacters(in: .whitespaces) == "Done" { sawDone = true }
        }
        guard r.status == 0 else { throw Programmer.diagnose(r.output, options: options) }
        if !sawDone { log?("Note: openFPGALoader exited normally without printing Done") }
        progress?(1)
    }

    /// The commands `program` would run, without touching hardware (`--dry-run`).
    static func dryRun(file: URL, options o: ProgrammerOptions, fpgaIndex: Int = Programmer.defaultFPGAIndex,
                       workDirectory: URL) throws -> (commands: [String], notes: [String]) {
        let p = try prepare(file: file, target: nil, workDirectory: workDirectory)
        var notes = p.notes
        if Programmer.mismatch(sofDevice: p.device, target: JTAGDevice(index: fpgaIndex, idcode: 0x02D0_20DD, irLength: 10, detail: "")) != nil,
           CycloneVSX120F.part(p.device) != nil {
            notes.append("Warning: the file is for \(p.device); the DE10-Standard has \(CycloneV.device), so Start would refuse it")
        }
        return ([Programmer.shellLine(o.tool, Programmer.detectArgs(o)),
                 Programmer.shellLine(o.tool, Programmer.programArgs(o, index: fpgaIndex, rbf: p.rbf))], notes)
    }

    /// Where converted .rbf and SVF files go.
    static var workDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quartzite-programmer", isDirectory: true)
    }
}

#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// State of the Programmer window (Tools > Programmer). Long operations run openFPGALoader on
/// a background queue; every command and output line goes to the log pane.
@MainActor @Observable
final class ProgrammerModel {
    struct Row: Identifiable {
        let id = UUID()
        /// The chain device after Auto Detect; nil for a file added before detection.
        var device: JTAGDevice?
        var deviceName: String
        var file: URL?
        var checksum = ""
        var program = false

        var canProgram: Bool { file != nil && (device?.isFPGA ?? true) }
    }

    enum Keys {
        static let tool = "programmerToolPath"
        static let firmware = "programmerFirmwarePath"
        static let cable = "programmerCable"
        static let bsdl = "programmerBSDLPath"
    }

    var toolPath: String { didSet { save(toolPath, Keys.tool) } }
    var firmwarePath: String { didSet { save(firmwarePath, Keys.firmware) } }
    var bsdlPath: String { didSet { save(bsdlPath, Keys.bsdl); boardMap = nil } }
    var cable: ProgrammerCable { didSet { save(cable.rawValue, Keys.cable) } }

    var probes: [USBProbe] = []
    var rows: [Row] = []
    var chain: [JTAGDevice]?
    var log: [String] = []
    var progress: Double = 0
    var status = ""
    var statusIsError = false
    var busy = false
    var showHardwareSetup = false
    var tab = Tab.chain

    var board: BoardState?
    var boardRunning = false
    var boardMessage = ""
    var boardUpdated: Date?

    enum Tab: String, CaseIterable, Identifiable { case chain = "Programmer", board = "Board"; var id: String { rawValue } }

    @ObservationIgnored private var cancel: ProcessCancel?
    @ObservationIgnored private var boardMap: BoardScanMap?
    @ObservationIgnored private var boardGeneration = 0
    @ObservationIgnored private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let d = UserDefaults.standard
        toolPath = persist ? d.string(forKey: Keys.tool) ?? "" : ""
        firmwarePath = persist ? d.string(forKey: Keys.firmware) ?? "" : ""
        bsdlPath = persist ? d.string(forKey: Keys.bsdl) ?? "" : ""
        cable = persist ? ProgrammerCable(rawValue: d.string(forKey: Keys.cable) ?? "") ?? .usbBlasterII : .usbBlasterII
    }

    private func save(_ v: String, _ key: String) { if persist { UserDefaults.standard.set(v, forKey: key) } }

    // MARK: Setup

    var toolSearch: Programmer.ToolSearch { Programmer.locateTool(setting: toolPath) }
    var firmwareURL: URL? { cable.needsFirmware ? BlasterFirmware.locate(setting: firmwarePath) : nil }
    var hardwareName: String { probes.isEmpty ? "No Hardware" : probes[0].displayName(port: 1) }

    /// What is missing before the Programmer can run, as messages for the user.
    var setupProblems: [String] {
        var p: [String] = []
        if toolSearch.url == nil { p.append(Programmer.toolMissingHelp) }
        if cable.needsFirmware {
            if let fw = firmwareURL {
                do { try BlasterFirmware.check(fw) } catch { p.append(error.localizedDescription) }
            } else { p.append(BlasterFirmware.missingHelp) }
        }
        return p
    }

    private func options() throws -> ProgrammerOptions {
        guard let tool = toolSearch.url else { throw ProgrammerError.toolMissing(Programmer.toolMissingHelp) }
        return ProgrammerOptions(tool: tool, cable: cable, firmware: firmwareURL)
    }

    /// Runs `work` off the main thread with a service whose log feeds the log pane.
    private func run<T>(_ title: String, _ work: @escaping (ProgrammerService) throws -> T,
                        done: @escaping (Result<T, Error>) -> Void) {
        let o: ProgrammerOptions
        do { o = try options() } catch { finish(error); return }
        let c = ProcessCancel()
        cancel = c
        busy = true
        log.append("Info: \(title) (\(Date().formatted(date: .omitted, time: .standard)))")
        var svc = ProgrammerService(options: o, cancel: c)
        svc.log = { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.log.append(line) } }
        }
        let service = svc
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try work(service) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.busy = false
                    self?.cancel = nil
                    done(r)
                }
            }
        }
    }

    private func finish(_ error: Error) {
        status = error.localizedDescription
        statusIsError = true
        log.append("Error: \(error.localizedDescription)")
    }

    // MARK: Rows and files

    /// Shows the project's .sof when the window opens with no file.
    func offer(_ file: URL?) {
        guard rows.allSatisfy({ $0.file == nil }), let file else { return }
        if let i = rows.firstIndex(where: { $0.device?.isFPGA ?? true }) { setFile(file, row: i) }
        else { rows.append(row(for: file)) }
    }

    private func row(for file: URL) -> Row {
        var r = Row(device: nil, deviceName: "", file: nil)
        apply(file, to: &r)
        return r
    }

    private func apply(_ file: URL, to r: inout Row) {
        r.file = file
        r.program = true
        r.checksum = ""
        if file.pathExtension.lowercased() == "sof", let s = try? SOFFile(contentsOf: file) {
            if r.device == nil { r.deviceName = s.device ?? "?" }
            r.checksum = s.storedChecksum.map { String(format: "%08X", $0) } ?? ""
        } else if r.device == nil {
            r.deviceName = Programmer.boardFPGA
        }
    }

    private func setFile(_ file: URL, row i: Int) { apply(file, to: &rows[i]) }

    private func chooseFile(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sof", "rbf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.message = title
        if let f = rows.compactMap(\.file).first { panel.directoryURL = f.deletingLastPathComponent() }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Add File: fills the FPGA row (after Auto Detect) or adds a row.
    func addFile() {
        guard let f = chooseFile("Choose a programming file (.sof) for the DE10-Standard") else { return }
        if let i = rows.firstIndex(where: { ($0.device?.isFPGA ?? false) && $0.file == nil }) { setFile(f, row: i) }
        else { rows.append(row(for: f)) }
    }

    func changeFile(_ id: Row.ID) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].device?.isFPGA ?? true,
              let f = chooseFile("Choose the new programming file") else { return }
        setFile(f, row: i)
    }

    func delete(_ id: Row.ID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].device != nil { rows[i].file = nil; rows[i].checksum = ""; rows[i].program = false }
        else { rows.remove(at: i) }
    }

    // MARK: Operations

    func refreshHardware() {
        run("Hardware Setup: scanning USB", { try $0.scan() }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let p):
                self.probes = p
                self.log.append("Info: Hardware: \(self.hardwareName)")
            case .failure(let e): self.probes = []; self.finish(e)
            }
        }
    }

    func autoDetect() {
        status = ""; statusIsError = false
        run("Auto Detect", { try $0.detect() }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let chain):
                self.chain = chain
                let fpgaFile = self.rows.first { $0.device?.isFPGA ?? true }?.file
                self.rows = chain.map { Row(device: $0, deviceName: $0.name, file: nil) }
                if let f = fpgaFile, let i = self.rows.firstIndex(where: { $0.device?.isFPGA == true }) { self.setFile(f, row: i) }
                self.status = "Detected \(chain.map(\.name).joined(separator: ", "))"
                if self.probes.isEmpty { self.refreshHardware() }
            case .failure(let e): self.finish(e)
            }
        }
    }

    /// Start: programs every checked row (the FPGA; the HPS takes no file).
    func start() {
        guard let row = rows.first(where: { $0.program && $0.canProgram }), let file = row.file else {
            finish(ProgrammerError.badFile("Nothing to program: add a .sof with Add File and tick Program/Configure"))
            return
        }
        progress = 0
        status = "Programming \(file.lastPathComponent)"
        statusIsError = false
        let known = chain
        run("Start: \(file.path)", { [weak self] svc in
            try svc.program(file: file, chain: known, workDirectory: ProgrammerService.workDirectory) { p in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress = p } }
            }
        }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success:
                self.progress = 1
                self.status = "100% (Successful)"
                self.log.append("Info: Configuration succeeded: \(file.lastPathComponent) is running on the FPGA")
            case .failure(let e):
                self.finish(e)
                self.status = "Failed: " + e.localizedDescription
            }
        }
    }

    func stop() {
        cancel?.cancel()
        stopBoard()
    }

    // MARK: Board view

    func loadBoardMap() throws -> BoardScanMap {
        if let m = boardMap { return m }
        guard !bsdlPath.isEmpty else { throw ProgrammerError.badFile(ProgrammerService.bsdlHelp) }
        let text: String
        do { text = try String(contentsOf: URL(fileURLWithPath: bsdlPath), encoding: .utf8) } catch {
            throw ProgrammerError.badFile("Cannot read \(bsdlPath): \(error.localizedDescription)")
        }
        let m = try BoardScanMap(bsdl: BSDLFile(text: text))
        boardMap = m
        return m
    }

    /// Reads the board a few times per second until stopped or a scan fails.
    func startBoard() {
        guard !boardRunning else { return }
        let map: BoardScanMap, o: ProgrammerOptions
        do { map = try loadBoardMap(); o = try options() } catch { boardMessage = error.localizedDescription; return }
        boardGeneration += 1
        let generation = boardGeneration
        boardRunning = true
        boardMessage = "Reading the board..."
        let known = chain
        let c = ProcessCancel()
        cancel = c
        let svc = ProgrammerService(options: o, cancel: c)
        // A let box, not [weak self]: Swift 5.10 rejects a captured weak var in the nested
        // main-queue closures below.
        let ref = WeakModel(self)
        DispatchQueue.global(qos: .userInitiated).async {
            var index: Int?
            do {
                index = try ProgrammerService.fpga(in: known ?? svc.detect()).index
            } catch {
                let e = error
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.boardStopped(generation, e) } }
                return
            }
            while true {
                let keepGoing = DispatchQueue.main.sync { MainActor.assumeIsolated { ref.value?.boardGeneration == generation && ref.value?.boardRunning == true } }
                guard keepGoing, let i = index else { return }
                do {
                    let s = try svc.sampleBoard(map: map, index: i, workDirectory: ProgrammerService.workDirectory)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let model = ref.value, model.boardGeneration == generation else { return }
                            model.board = s
                            model.boardUpdated = Date()
                            model.boardMessage = "Live (boundary-scan SAMPLE; the design keeps running)"
                        }
                    }
                } catch {
                    let e = error
                    DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.boardStopped(generation, e) } }
                    index = nil
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func boardStopped(_ generation: Int, _ error: Error) {
        guard generation == boardGeneration else { return }
        boardRunning = false
        boardMessage = (error as? ProgrammerError) == .cancelled ? "Stopped" : error.localizedDescription
        if (error as? ProgrammerError) != .cancelled { log.append("Error: Board view: \(error.localizedDescription)") }
    }

    func stopBoard() {
        guard boardRunning else { return }
        boardGeneration += 1
        boardRunning = false
        boardMessage = "Stopped"
    }
}

/// Weak reference that a background loop can capture as a constant.
private final class WeakModel: @unchecked Sendable {
    weak var value: ProgrammerModel?
    init(_ value: ProgrammerModel) { self.value = value }
}

// MARK: - Programmer window

/// Quartus Programmer: Hardware Setup and Mode on top, Start / Stop / Auto Detect / Delete /
/// Add File / Change File on the left, the device chain in the middle, and the log below.
@MainActor
struct ProgrammerView: View {
    @Bindable var model: ProgrammerModel
    var defaultFile: () -> URL?
    @State private var selection: ProgrammerModel.Row.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.setupProblems.isEmpty { setupBanner; Divider() }
            Picker("", selection: $model.tab) {
                ForEach(ProgrammerModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 6)
            switch model.tab {
            case .chain: chainPane
            case .board: BoardPanel(model: model)
            }
            Divider()
            logPane
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.offer(defaultFile()) }
        .sheet(isPresented: $model.showHardwareSetup) { HardwareSetupSheet(model: model) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button("Hardware Setup...") { model.showHardwareSetup = true; model.refreshHardware() }
                .disabled(model.busy)
            Text(model.hardwareName)
                .font(.callout.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Text("Mode:")
            Picker("Mode", selection: .constant("JTAG")) { Text("JTAG").tag("JTAG") }
                .labelsHidden().frame(width: 90)
                .help("The DE10-Standard is configured over JTAG (SRAM); the design is lost when the board is turned off")
            Spacer()
            Text("Progress:")
            ProgressView(value: model.progress)
                .frame(width: 180)
                .tint(model.statusIsError ? Theme.error : (model.progress >= 1 ? Theme.ok : Theme.accent))
            Text(model.statusIsError ? "Failed" : (model.progress >= 1 ? "100% (Successful)" : (model.busy && model.progress > 0 ? "\(Int(model.progress * 100))%" : "")))
                .font(.callout.monospacedDigit())
                .foregroundStyle(model.statusIsError ? Theme.error : .primary)
                .frame(width: 130, alignment: .leading)
        }
        .padding(8)
        .background(.bar)
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.setupProblems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            SettingsLink { Text("Open Settings...") }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var chainPane: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 6) {
                sideButton("Start", "play.fill", enabled: !model.busy && model.rows.contains { $0.program && $0.canProgram }) { model.start() }
                sideButton("Stop", "stop.fill", enabled: model.busy) { model.stop() }
                sideButton("Auto Detect", "dot.radiowaves.left.and.right", enabled: !model.busy) { model.autoDetect() }
                sideButton("Delete", "minus.circle", enabled: !model.busy && selection != nil) { if let s = selection { model.delete(s) } }
                sideButton("Add File...", "doc.badge.plus", enabled: !model.busy) { model.addFile() }
                sideButton("Change File...", "doc.badge.arrow.up", enabled: !model.busy && selection != nil) { if let s = selection { model.changeFile(s) } }
                Spacer()
            }
            .frame(width: 130)
            VStack(alignment: .leading, spacing: 4) {
                Table(model.rows, selection: $selection) {
                    TableColumn("File") { r in
                        Text(r.file?.lastPathComponent ?? "<none>").help(r.file?.path ?? "No file")
                    }
                    TableColumn("Device") { r in Text(r.deviceName).font(.body.monospaced()) }
                    TableColumn("Checksum") { r in Text(r.checksum).font(.body.monospaced()) }
                    TableColumn("IDCODE") { r in Text(r.device?.idcodeText ?? "").font(.body.monospaced()) }
                    TableColumn("Program/Configure") { r in
                        Toggle("", isOn: Binding(
                            get: { model.rows.first { $0.id == r.id }?.program ?? false },
                            set: { v in if let i = model.rows.firstIndex(where: { $0.id == r.id }) { model.rows[i].program = v } }))
                        .labelsHidden()
                        .disabled(!r.canProgram || model.busy)
                    }
                    .width(120)
                }
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(model.statusIsError ? Theme.error : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                ChainDiagram(rows: model.rows)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
    }

    private func sideButton(_ title: String, _ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!enabled)
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.hasPrefix("Error") ? Theme.error : (line.hasPrefix("$ ") ? Theme.accent : .primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .textSelection(.enabled)
                .padding(6)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }
}

/// The JTAG chain as Quartus draws it under the table: TDI, one box per device, TDO.
private struct ChainDiagram: View {
    var rows: [ProgrammerModel.Row]
    var body: some View {
        HStack(spacing: 0) {
            Text("TDI").font(.caption2).foregroundStyle(.secondary)
            ForEach(rows) { r in
                Rectangle().fill(.secondary).frame(width: 24, height: 1)
                VStack(spacing: 2) {
                    Text(r.device?.isFPGA == false ? "Intel" : "Cyclone V").font(.caption2).foregroundStyle(.secondary)
                    Text(r.deviceName).font(.caption.monospaced())
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).stroke(r.program ? Theme.accent : Color.secondary))
            }
            Rectangle().fill(.secondary).frame(width: 24, height: 1)
            Text("TDO").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

// MARK: - Hardware Setup

private struct HardwareSetupSheet: View {
    @Bindable var model: ProgrammerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hardware Setup").font(.title3.bold())
            HStack {
                Text("Currently selected hardware:")
                Text(model.hardwareName).font(.body.monospaced())
            }
            GroupBox("Available hardware items") {
                if model.probes.isEmpty {
                    Text(model.busy ? "Scanning..." : "No Hardware. Connect the DE10-Standard's USB-Blaster II port to this Mac and turn the board on, then click Refresh.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                } else {
                    ForEach(Array(model.probes.enumerated()), id: \.offset) { i, p in
                        HStack {
                            Text(p.displayName(port: i + 1)).font(.body.monospaced())
                            Spacer()
                            Text(String(format: "%04x:%04x  bus %d device %d", p.vid, p.pid, p.bus, p.device)).foregroundStyle(.secondary)
                        }
                        .padding(2)
                    }
                }
            }
            Picker("Cable:", selection: $model.cable) {
                ForEach(ProgrammerCable.allCases) { Text("\($0.title) (\($0.rawValue))").tag($0) }
            }
            .frame(width: 360)
            Text("Mode: JTAG. Quartzite uses openFPGALoader; \(model.toolSearch.summary).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh") { model.refreshHardware() }.disabled(model.busy)
                SettingsLink { Text("Settings...") }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

// MARK: - Board view

/// Live view of the DE10-Standard's switches, buttons, LEDs and seven-segment displays.
private struct BoardPanel: View {
    @Bindable var model: ProgrammerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(model.boardRunning ? "Stop Monitoring" : "Start Monitoring") {
                    model.boardRunning ? model.stopBoard() : model.startBoard()
                }
                .disabled(model.busy)
                Text(model.boardMessage).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
            }
            if model.bsdlPath.isEmpty {
                Text(ProgrammerService.bsdlHelp).font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            let s = model.board ?? BoardState()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ForEach((0..<6).reversed(), id: \.self) { d in
                        VStack(spacing: 2) {
                            SevenSegment(lit: s.segments[d]).frame(width: 40, height: 64)
                            Text("HEX\(d)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach((0..<10).reversed(), id: \.self) { i in
                        VStack(spacing: 2) {
                            Circle().fill(s.leds[i] ? Color.red : Color.red.opacity(0.15)).frame(width: 14, height: 14)
                                .shadow(color: s.leds[i] ? .red : .clear, radius: 4)
                            Text("LEDR\(i)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach((0..<10).reversed(), id: \.self) { i in
                        VStack(spacing: 2) {
                            SlideSwitch(on: s.switches[i])
                            Text("SW\(i)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer().frame(width: 24)
                    ForEach((0..<4).reversed(), id: \.self) { i in
                        VStack(spacing: 2) {
                            Circle().fill(s.keysPressed[i] ? Color.gray : Color.gray.opacity(0.25)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.secondary))
                            Text("KEY\(i)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(red: 0.08, green: 0.25, blue: 0.16)))
            .environment(\.colorScheme, .dark)
            .opacity(model.board == nil ? 0.5 : 1)
            Text("Read-only: the pin levels are sampled over JTAG while the design runs. Quartzite cannot move the switches or press the buttons.")
                .font(.caption).foregroundStyle(.secondary)
            if let t = model.boardUpdated {
                Text("Last read \(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Segments a-g of a DE10-Standard display (a top, then clockwise, g middle).
struct SevenSegment: View {
    var lit: [Bool]
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, t = max(3, w * 0.14), g = t * 0.25
            let horiz: [(Int, CGFloat)] = [(0, 0), (6, h / 2 - t / 2), (3, h - t)]
            let vert: [(Int, CGFloat, CGFloat)] = [(5, 0, 0), (1, w - t, 0), (4, 0, h / 2), (2, w - t, h / 2)]
            func fill(_ r: CGRect, _ on: Bool) {
                ctx.fill(Path(roundedRect: r, cornerRadius: t / 2), with: .color(on ? .red : .red.opacity(0.12)))
            }
            for (i, y) in horiz { fill(CGRect(x: t / 2 + g, y: y, width: w - t - 2 * g, height: t), lit.indices.contains(i) && lit[i]) }
            for (i, x, y) in vert { fill(CGRect(x: x, y: y + t / 2 + g, width: t, height: h / 2 - t - g), lit.indices.contains(i) && lit[i]) }
        }
    }
}

private struct SlideSwitch: View {
    var on: Bool
    var body: some View {
        ZStack(alignment: on ? .top : .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)).frame(width: 14, height: 30)
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: 12, height: 13).padding(1)
        }
    }
}

// MARK: - Settings

/// Settings > Programmer: openFPGALoader, the USB-Blaster II firmware and the BSDL file.
@MainActor
struct ProgrammerSettingsView: View {
    @Bindable var model: ProgrammerModel

    var body: some View {
        Form {
            Section("openFPGALoader") {
                pathRow("Program or toolchain folder:", $model.toolPath, placeholder: "Search automatically", folders: true)
                status(model.toolSearch.url != nil, model.toolSearch.url != nil ? model.toolSearch.summary : Programmer.toolMissingHelp)
            }
            Section("USB-Blaster II firmware") {
                Picker("Cable:", selection: $model.cable) {
                    ForEach(ProgrammerCable.allCases) { Text("\($0.title) (\($0.rawValue))").tag($0) }
                }
                pathRow("blaster_6810.hex:", $model.firmwarePath, placeholder: "Search Quartus installations", folders: false)
                if model.cable.needsFirmware {
                    let fw = model.firmwareURL
                    let problem = firmwareProblem(fw)
                    status(problem == nil, problem ?? "Using \(fw?.path ?? "")")
                } else {
                    status(true, "The USB-Blaster (FTDI) needs no firmware")
                }
            }
            Section("Board view (optional)") {
                pathRow("5CSXFC6D6F31 BSDL file:", $model.bsdlPath, placeholder: "Not set", folders: false)
                let problem = bsdlProblem()
                status(problem == nil, problem ?? "All 66 board pins found in the boundary-scan register")
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
    }

    private func pathRow(_ title: String, _ path: Binding<String>, placeholder: String, folders: Bool) -> some View {
        HStack {
            TextField(title, text: path, prompt: Text(placeholder))
            Button("Choose...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = folders
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let u = panel.url { path.wrappedValue = u.path }
            }
            if !path.wrappedValue.isEmpty { Button("Clear") { path.wrappedValue = "" } }
        }
    }

    private func firmwareProblem(_ fw: URL?) -> String? {
        guard let fw else { return BlasterFirmware.missingHelp }
        do { try BlasterFirmware.check(fw); return nil } catch { return error.localizedDescription }
    }

    private func bsdlProblem() -> String? {
        if model.bsdlPath.isEmpty { return ProgrammerService.bsdlHelp }
        do { _ = try model.loadBoardMap(); return nil } catch { return error.localizedDescription }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(ok ? Theme.ok : Theme.warning)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

import Foundation

/// The Quartzite compile flow, modelled on Quartus Prime's Compile Design task:
/// Analysis & Synthesis (including Analysis & Elaboration), Fitter, Assembler, Timing
/// Analysis (a logic-depth estimate) and the EDA Netlist Writer. Without the optional
/// open-source toolchain the Fitter is Quartzite's logical fitter and the Assembler is
/// skipped; with it (`FlowState.hardware`), the Fitter runs yosys + nextpnr-mistral and the
/// Assembler writes and verifies an experimental .sof (HardwareFlow.swift). Every stage is a pure function of the project and the earlier stages'
/// results, so the app can run them one at a time off the main thread and the CLI and
/// CI can run them synchronously.
enum FlowStage: String, CaseIterable, Identifiable, Codable {
    case analysisElaboration, analysisSynthesis, fitter, assembler, timing, eda

    var id: String { rawValue }

    /// Name used in "Running Quartzite ..." lines and the report.
    var toolName: String {
        switch self {
        case .analysisElaboration: return "Analysis & Elaboration"
        case .analysisSynthesis: return "Analysis & Synthesis"
        case .fitter: return "Fitter"
        case .assembler: return "Assembler"
        case .timing: return "Timing Analyzer"
        case .eda: return "EDA Netlist Writer"
        }
    }

    /// Name in the Tasks pane, as Quartus labels the flow.
    var taskName: String {
        switch self {
        case .analysisElaboration: return "Analysis & Elaboration"
        case .analysisSynthesis: return "Analysis & Synthesis"
        case .fitter: return "Fitter (Place & Route)"
        case .assembler: return "Assembler (Generate programming files)"
        case .timing: return "Timing Analysis"
        case .eda: return "EDA Netlist Writer"
        }
    }

    /// Stages that must have run (and succeeded) first.
    var prerequisites: [FlowStage] {
        switch self {
        case .analysisElaboration, .analysisSynthesis: return []
        case .fitter: return [.analysisSynthesis]
        case .assembler, .timing, .eda: return [.analysisSynthesis, .fitter]
        }
    }

    static let fullCompilation: [FlowStage] = [.analysisSynthesis, .fitter, .assembler, .timing, .eda]
}

enum StageStatus: Equatable {
    case notRun, running, succeeded, warnings, failed, skipped
}

struct StageRun {
    var stage: FlowStage
    var status: StageStatus
    var messages: [Message]
    var started: Date
    var elapsed: TimeInterval
    var errors: Int
    var warnings: Int
}

struct FlowState {
    /// The design being compiled.
    var design: DesignProject
    /// The top sheet until elaboration, then the flattened design (the same sheet if it has no blocks).
    var project: Project
    var flat: FlatDesign?
    var mainTask: String
    var started = Date()
    var finished: Date?
    var circuit: CompiledCircuit?
    var synthesis: SynthesisResult?
    var fit: FitResult?
    var timing: TimingEstimate?
    var netlist: String?
    /// Set to run the experimental hardware flow (real place and route, .sof). nil = logical stages only.
    var hardware: HardwareConfig?
    /// Why `hardware` is nil, shown by the skipped Assembler (nil in tests and CI).
    var toolchainNote: String?
    var pnr: PnRResult?
    var assembly: AssemblyResult?
    var runs: [StageRun] = []
    /// "Quartzite Full Compilation was successful" line (full compilations only).
    var summary: Message?

    init(design: DesignProject, mainTask: String, hardware: HardwareConfig? = nil) {
        self.design = design
        var top = design.top ?? design.sheets[0]
        top.device = design.device
        self.project = top
        self.mainTask = mainTask
        self.hardware = hardware
    }

    init(project: Project, mainTask: String, hardware: HardwareConfig? = nil) {
        self.init(design: DesignProject(single: project), mainTask: mainTask, hardware: hardware)
    }

    func run(_ s: FlowStage) -> StageRun? { runs.last { $0.stage == s } }
    var failed: Bool { runs.contains { $0.status == .failed } }
    var messages: [Message] { runs.flatMap { $0.messages } + (summary.map { [$0] } ?? []) }
    var errors: Int { runs.reduce(0) { $0 + $1.errors } }
    var warnings: Int { runs.reduce(0) { $0 + $1.warnings } }
}

enum CompileFlow {
    static let version = "1.0"
    static let product = "Quartzite"

    // MARK: - Formatting

    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        return f.string(from: d)
    }

    static func shortDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f.string(from: d)
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func thousands(_ v: Int) -> String {
        let s = String(abs(v))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (v < 0 ? "-" : "") + String(out.reversed())
    }

    /// "( < 1 % )" style percentage, as Quartus prints it.
    static func percent(_ used: Int, _ total: Int) -> String {
        guard total > 0 else { return "" }
        if used == 0 { return "0 %" }
        let p = Double(used) * 100 / Double(total)
        return p < 1 ? "< 1 %" : "\(Int(p.rounded())) %"
    }

    static func usage(_ used: Int, _ total: Int) -> String { "\(thousands(used)) / \(thousands(total)) ( \(percent(used, total)) )" }

    static func count(_ ms: [Message], _ levels: Set<Message.Level>) -> Int {
        ms.reduce(0) { $0 + (levels.contains($1.level) ? 1 : 0) + count($1.children, levels) }
    }

    // MARK: - Messages

    static func header(_ stage: FlowStage, at date: Date) -> [Message] {
        [Message(level: .info, text: "*******************************************************************", stage: stage.rawValue),
         Message(level: .info, text: "Running \(product) \(stage.toolName)",
                 children: [Message(level: .info, text: "Version \(version) (\(product) for Mac)"),
                            Message(level: .info, text: "Processing started: \(dateTime(date))")],
                 stage: stage.rawValue)]
    }

    private static func footer(_ stage: FlowStage, body: [Message], status: StageStatus, started: Date, ended: Date) -> Message {
        let e = count(body, [.error]), w = count(body, [.warning, .criticalWarning])
        let tail = [Message(level: .info, text: "Processing ended: \(dateTime(ended))"),
                    Message(level: .info, text: "Elapsed time: \(elapsed(ended.timeIntervalSince(started)))")]
        let text: String
        switch status {
        case .failed: text = "\(product) \(stage.toolName) was unsuccessful. \(plural(e, "error")), \(plural(w, "warning"))"
        case .skipped: text = "\(product) \(stage.toolName) was skipped. No programming file was generated"
        default: text = "\(product) \(stage.toolName) was successful. \(plural(e, "error")), \(plural(w, "warning"))"
        }
        return Message(level: status == .failed ? .error : .info, text: text, children: tail, stage: stage.rawValue)
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    // MARK: - Running

    /// Runs one stage (without its header lines; see `header`). Prerequisites must be in `state`.
    static func execute(_ stage: FlowStage, state: inout FlowState, started: Date = Date()) -> StageRun {
        var body: [Message] = []
        var status: StageStatus = .succeeded
        switch stage {
        case .analysisElaboration:
            let (c, ms, flat) = elaborate(state.design)
            body = ms
            state.circuit = c
            state.flat = flat
            if let flat { state.project = flat.project }
            if c == nil { status = .failed }
        case .analysisSynthesis:
            let (c, ms, flat) = elaborate(state.design)
            body = ms
            state.circuit = c
            state.flat = flat
            if let flat { state.project = flat.project }
            if let c {
                do {
                    let s = try Synthesizer.run(c, project: state.project)
                    state.synthesis = s
                    let sm = synthesisMessages(s, project: state.project)
                    body += flat.map { Flattener.remap(sm, $0) } ?? sm
                } catch {
                    body.append(Message(level: .error, text: "\(error)"))
                    status = .failed
                }
            } else {
                status = .failed
            }
        case .fitter:
            state.pnr = nil
            state.assembly = nil
            if let c = state.circuit, let s = state.synthesis {
                let fit = Fitter.run(project: state.project, circuit: c, synthesis: s)
                state.fit = fit
                body.append(Message(level: .info, text: "Selected device \(state.project.device) for design \"\(state.project.entityName)\""))
                body.append(Message(level: .info, text: "Low junction temperature is 0 degrees C"))
                body.append(Message(level: .info, text: "High junction temperature is 85 degrees C"))
                body.append(Message(level: .info, text: "Starting Fitter periphery placement operations"))
                body += fit.messages
                body.append(Message(level: .info, text: "Fitter periphery placement operations ending: elapsed time is \(elapsed(Date().timeIntervalSince(started)))"))
                if fit.errors > 0 {
                    status = .failed
                } else if let hw = state.hardware {
                    // Real synthesis, place and route with the open-source toolchain.
                    hw.onMessage.map { f in body.forEach(f) }
                    let emit = HardwareFlow.Emitter(hw.onMessage)
                    do {
                        let r = try HardwareFlow.placeAndRoute(project: state.project, circuit: c, synthesis: s, fit: fit, config: hw, emit: emit)
                        state.pnr = r
                        body += emit.messages
                        body.append(Message(level: .info, text: "Fitter placement and routing was successful: \(plural(r.almsUsed, "ALM")) in \(plural(r.labsUsed, "LAB")) configured in the bitstream (nextpnr-mistral)"))
                    } catch {
                        body += emit.messages
                        body.append(Message(level: .error, text: "Place and route with the open-source toolchain failed: \(error.localizedDescription)"))
                        status = .failed
                    }
                } else {
                    body.append(Message(level: .info, text: "Fitter placement operations beginning"))
                    body.append(Message(level: .info, text: "Placed \(plural(s.network.luts.count, "LUT")) in \(plural(fit.alms, "ALM")) across \(plural(fit.labs, "LAB")) (Quartzite logical placement, ten ALMs per LAB)"))
                    body.append(Message(level: .info, text: "Fitter placement was successful"))
                    body.append(Message(level: .info, text: "Fitter placement operations ending: elapsed time is \(elapsed(Date().timeIntervalSince(started)))"))
                    body.append(Message(level: .info, text: "Routing was not performed: Quartzite does not model Cyclone V interconnect. Quartus routes the design when you compile it at the lab."))
                }
            } else {
                body.append(Message(level: .error, text: "Can't run Fitter: Analysis & Synthesis did not complete successfully"))
                status = .failed
            }
        case .assembler:
            state.assembly = nil
            if let hw = state.hardware, let pnr = state.pnr, let c = state.circuit, let fit = state.fit {
                let emit = HardwareFlow.Emitter(hw.onMessage)
                do {
                    let a = try HardwareFlow.assemble(project: state.project, circuit: c, synthesis: state.synthesis, fit: fit, pnr: pnr, config: hw, emit: emit)
                    state.assembly = a
                    body = emit.messages
                    if !a.passed {
                        body.append(Message(level: .error, text: "The programming file failed verification: \(a.failure ?? "unknown reason")"))
                        status = .failed
                    }
                } catch {
                    body = emit.messages
                    body.append(Message(level: .error, text: "Assembler failed: \(error.localizedDescription)"))
                    status = .failed
                }
            } else {
                status = .skipped
                body.append(Message(level: .info, text: "No programming file was generated. Quartzite writes an experimental .sof only with the open-source toolchain (yosys, nextpnr-mistral, mistral-cv); without it, programming files come from Quartus."))
                body.append(Message(level: .info, text: "To program the DE10-Standard: export the project (File > Export Quartus Project), open \(state.project.entityName).qpf in Quartus Prime at the lab, run Start Compilation, then open Tools > Programmer and add output_files/\(state.project.entityName).sof."))
                if state.hardware != nil {
                    body.append(Message(level: .info, text: "No bitstream is available from the Fitter, so the experimental .sof was not generated. Run the Fitter (or Start Compilation) again."))
                } else if let note = state.toolchainNote {
                    body.append(Message(level: .info, text: note))
                }
            }
        case .timing:
            if let s = state.synthesis {
                let t = TimingEstimate.run(s)
                state.timing = t
                body.append(Message(level: .info, text: "Quartzite has no Cyclone V delay models. This stage reports combinational logic depth (LUT levels from each input pin to each output pin) as an estimate; it is not a Quartus timing analysis and gives no delays or slack."))
                if let p = t.paths.first, p.levels > 0 {
                    body.append(Message(level: .info, text: "Deepest path: \(p.from) to \(p.to) through \(plural(p.levels, "LUT level"))"))
                } else {
                    body.append(Message(level: .info, text: "Every output is driven directly by an input pin or a constant"))
                }
                body.append(Message(level: .info, text: "The design has no clocks or registers, so there are no clock domains to analyze"))
            } else {
                body.append(Message(level: .error, text: "Can't run Timing Analyzer: Analysis & Synthesis did not complete successfully"))
                status = .failed
            }
        case .eda:
            if let s = state.synthesis {
                let text = NetlistWriter.verilog(s, fit: state.fit, project: state.project, date: started)
                state.netlist = text
                body.append(Message(level: .info, text: "Generated file \(NetlistWriter.fileName(state.project.entityName)) for EDA simulation tool (any Verilog simulator). It is written to \(NetlistWriter.folder)/ when you export the Quartus project."))
                body.append(Message(level: .info, text: "The netlist is a functional (zero-delay) LUT-level model generated by Quartzite, not a Quartus .vo file"))
            } else {
                body.append(Message(level: .error, text: "Can't run EDA Netlist Writer: Analysis & Synthesis did not complete successfully"))
                status = .failed
            }
        }
        if count(body, [.error]) > 0 { status = .failed }
        if status == .succeeded && count(body, [.warning, .criticalWarning]) > 0 { status = .warnings }
        let ended = Date()
        let tagged = body.map { m -> Message in var m = m; m.stage = stage.rawValue; return m }
        let run = StageRun(stage: stage, status: status,
                           messages: tagged + [footer(stage, body: body, status: status, started: started, ended: ended)],
                           started: started, elapsed: ended.timeIntervalSince(started),
                           errors: count(body, [.error]), warnings: count(body, [.warning, .criticalWarning]))
        return run
    }

    /// Final "Full Compilation" line.
    static func fullSummary(_ state: FlowState) -> Message {
        let e = state.errors, w = state.warnings
        let ok = !state.failed
        return Message(level: ok ? .info : .error,
                       text: "\(product) Full Compilation was \(ok ? "successful" : "unsuccessful"). \(plural(e, "error")), \(plural(w, "warning"))")
    }

    /// Runs stages in order, stopping at the first failure (CLI, tests).
    static func run(_ project: Project, stages: [FlowStage] = FlowStage.fullCompilation, mainTask: String = "Compilation",
                    hardware: HardwareConfig? = nil, toolchainNote: String? = nil) -> FlowState {
        run(DesignProject(single: project), stages: stages, mainTask: mainTask, hardware: hardware, toolchainNote: toolchainNote)
    }

    static func run(_ design: DesignProject, stages: [FlowStage] = FlowStage.fullCompilation, mainTask: String = "Compilation",
                    hardware: HardwareConfig? = nil, toolchainNote: String? = nil) -> FlowState {
        var state = FlowState(design: design, mainTask: mainTask, hardware: hardware)
        state.toolchainNote = toolchainNote
        for stage in stages {
            let t = Date()
            var run = execute(stage, state: &state, started: t)
            run.messages = header(stage, at: t) + run.messages
            state.runs.append(run)
            if run.status == .failed { break }
        }
        if stages == FlowStage.fullCompilation { state.summary = fullSummary(state) }
        state.finished = Date()
        return state
    }

    // MARK: - Stage bodies

    static func elaborate(_ p: Project) -> (CompiledCircuit?, [Message]) {
        let (c, ms, _) = elaborate(DesignProject(single: p))
        return (c, ms)
    }

    /// Analysis & Elaboration of every sheet used under the top, then of the flattened design.
    static func elaborate(_ d: DesignProject) -> (CompiledCircuit?, [Message], FlatDesign?) {
        var ms: [Message] = []
        let top = d.top?.entityName ?? d.topLevelEntity
        let used = d.usedSheets()
        for e in used {
            ms.append(Message(level: .info, text: "Found 1 design units, including 1 entities, in source file \(e).bdf",
                              children: [Message(level: .info, text: "Found entity 1: \(e)")]))
        }
        ms.append(Message(level: .info, text: "Elaborating entity \"\(top)\" for the top level hierarchy"))
        var seen: Set<String> = [top.lowercased()]
        d.instanceTree().walk { n, path in
            guard !path.isEmpty, !n.missing, !n.recursive, seen.insert(n.entity.lowercased()).inserted else { return }
            let hierarchy = (path.dropFirst().map(\.label) + [n.label]).joined(separator: "|")
            ms.append(Message(level: .info, text: "Elaborating entity \"\(n.entity)\" for hierarchy \"\(hierarchy)\""))
        }
        let (c, check, flat) = Compiler.compile(d, checkLocations: false)
        // The design check's own summary lines are replaced by the flow's messages.
        ms += check.filter { $0.level != .info }.filter { !$0.text.hasPrefix("Design check failed") }
        for e in used {
            guard let s = d.sheet(named: e) else { continue }
            let routing = Routing(project: s, conn: Connectivity(s))
            let sheet = e == top ? nil : e
            ms += routing.warnings.map { Message(level: .warning, text: used.count > 1 ? "\(e).bdf: \($0)" : $0, sheet: sheet) }
            if !routing.labeledWires.isEmpty {
                ms.append(Message(level: .info, text: "\(routing.labeledWires.count) wire(s) will be exported to \(e).bdf as matching net labels, so they don't touch other wires"))
            }
        }
        return (c, ms, flat)
    }

    static func synthesisMessages(_ s: SynthesisResult, project: Project) -> [Message] {
        var ms: [Message] = []
        if !s.removed.isEmpty {
            ms.append(Message(level: .info, text: "Removed \(plural(s.removed.count, "redundant gate")) during synthesis",
                              component: s.removed.first?.id,
                              children: s.removed.map { Message(level: .info, text: "Gate \"\($0.name)\" (\($0.kind.bdfName)) \($0.explanation)", component: $0.id) }))
        }
        let stuck = s.outputs.filter { $0.constant != nil }
        if !stuck.isEmpty {
            ms.append(Message(level: .warning, text: "Output pins are stuck at VCC or GND", component: stuck.first?.id,
                              children: stuck.map { Message(level: .warning, text: "Pin \"\($0.name)\" is stuck at \($0.constant! ? "VCC" : "GND")", component: $0.id) }))
        }
        if !s.unusedInputs.isEmpty {
            let ids = Dictionary(project.inputPins.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            ms.append(Message(level: .warning, text: "Design contains \(s.unusedInputs.count) input pin(s) that do not drive logic",
                              component: ids[s.unusedInputs[0]],
                              children: s.unusedInputs.map { Message(level: .warning, text: "No output dependent on input pin \"\($0)\"", component: ids[$0]) }))
        }
        for o in s.outputs where o.constant == nil {
            var kids = [Message(level: .info, text: "Method: \(o.method)\(o.primeCount > 0 ? ", \(plural(o.primeCount, "prime implicant"))" : "")")]
            if o.minimized {
                kids.append(Message(level: .info, text: "Minimal POS: \(o.name) = \(o.posEquation)"))
            }
            if o.minimized && !o.exact {
                kids.append(Message(level: .info, text: "The search limit was reached; this cover is the best found and may not be minimal"))
            }
            ms.append(Message(level: .info, text: "Minimized logic for output pin \"\(o.name)\": \(o.name) = \(o.sopEquation)", component: o.id, children: kids))
        }
        if !s.sharedTerms.isEmpty {
            ms.append(Message(level: .info, text: "\(plural(s.sharedTerms.count, "product term")) shared by more than one output",
                              children: s.sharedTerms.map { Message(level: .info, text: "\($0.term) is used by \($0.outputs.joined(separator: ", "))") }))
        }
        let r = s.resources
        ms.append(Message(level: .info, text: "Implemented \(r.deviceResources) device resources after synthesis - the final resource count might be different",
                          children: [Message(level: .info, text: "Implemented \(r.inputPins) input pins"),
                                     Message(level: .info, text: "Implemented \(r.outputPins) output pins"),
                                     Message(level: .info, text: "Implemented \(r.luts) logic cells")]))
        return ms
    }

    // MARK: - Report

    static func report(_ state: FlowState) -> [ReportNode] {
        let p = state.project
        let ok = !state.failed
        let when = dateTime(state.finished ?? state.started)
        let s = state.synthesis, fit = state.fit
        let pins = p.inputPins.count + p.outputPins.count
        var nodes: [ReportNode] = []

        let ranFitter = state.run(.fitter).map { $0.status != .failed } ?? false
        nodes.append(ReportNode(id: "flow.summary", title: "Flow Summary", icon: .table, tables: [ReportTableData(title: "Flow Summary", rows: [
            ["Flow Status", "\(ok ? "Successful" : "Failed") - \(when)"],
            ["Quartzite Version", "\(version) (Quartzite for Mac; not Intel Quartus Prime)"],
            ["Revision Name", state.design.projectName],
            ["Top-level Entity Name", p.entityName],
            ["Family", CycloneV.family],
            ["Device", p.device],
            ["Timing Models", "Not modeled (Quartzite reports logic depth only)"],
            ["Logic utilization (in ALMs)", ranFitter ? usage(fit?.alms ?? 0, CycloneV.totalALMs) : (s.map { "\($0.resources.alms) (estimate after synthesis)" } ?? "N/A")],
            ["Total registers", "0"],
            ["Total pins", usage(pins, CycloneV.totalPins)],
            ["Total virtual pins", "0"],
            ["Total block memory bits", usage(0, CycloneV.totalBlockMemoryBits)],
            ["Total DSP Blocks", usage(0, CycloneV.totalDSPBlocks)],
            ["Total HSSI RX PCSs", usage(0, CycloneV.totalHSSI)],
            ["Total HSSI PMA RX Deserializers", usage(0, CycloneV.totalHSSI)],
            ["Total HSSI TX PCSs", usage(0, CycloneV.totalHSSI)],
            ["Total HSSI PMA TX Serializers", usage(0, CycloneV.totalHSSI)],
            ["Total PLLs", usage(0, CycloneV.totalPLLs)],
            ["Total DLLs", usage(0, CycloneV.totalDLLs)],
        ], note: "Device totals come from Intel's Cyclone V Device Overview and from Quartus' own Fitter report for \(CycloneV.device).")]))
        nodes.append(ReportNode(id: "flow.settings", title: "Flow Settings", icon: .table, tables: [ReportTableData(title: "Flow Settings", header: ["Option", "Setting"], rows: [
            ["Start date & time", shortDateTime(state.started)],
            ["Main task", state.mainTask],
            ["Revision Name", state.design.projectName],
        ])]))
        nodes.append(ReportNode(id: "flow.elapsed", title: "Flow Elapsed Time", icon: .table, tables: [ReportTableData(title: "Flow Elapsed Time", header: ["Module Name", "Elapsed Time"],
            rows: state.runs.map { [$0.stage.toolName, elapsed($0.elapsed)] } + [["Total", elapsed(state.runs.reduce(0) { $0 + $1.elapsed })]])]))
        let info = ProcessInfo.processInfo
        #if arch(arm64)
        let cpu = "arm64"
        #else
        let cpu = "x86_64"
        #endif
        nodes.append(ReportNode(id: "flow.os", title: "Flow OS Summary", icon: .table, tables: [ReportTableData(title: "Flow OS Summary",
            header: ["Module Name", "Machine Hostname", "OS Name", "OS Version", "Processor type"],
            rows: state.runs.map { [$0.stage.toolName, info.hostName, osName, osVersion(info), cpu] })]))

        for run in state.runs {
            nodes.append(stageReport(run, state: state))
        }
        let all = state.messages
        nodes.append(ReportNode(id: "flow.messages", title: "Flow Messages", icon: .messages, messages: all))
        nodes.append(ReportNode(id: "flow.suppressed", title: "Flow Suppressed Messages", icon: .messages, messages: []))
        return nodes
    }

    private static var osName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }

    private static func osVersion(_ info: ProcessInfo) -> String {
        let v = info.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func statusLine(_ run: StageRun, _ when: String) -> String {
        switch run.status {
        case .failed: return "Failed - \(when)"
        case .skipped: return "Skipped - no programming file was generated"
        default: return "Successful - \(when)"
        }
    }

    /// One row per entity instance, as Quartus lists the hierarchy. LUTs are mapped after
    /// flattening, so only the top row has ALUTs; schematic gates are "total (own)".
    static func entityTable(_ f: FlatDesign, resources r: SynthesisResult.Resources) -> ReportTableData {
        var rows: [[String]] = []
        f.hierarchy.walk { n, path in
            let full = "|" + (path.map(\.label) + [n.label]).joined(separator: "|")
            let node = path.isEmpty ? "|\(n.entity)" : String(repeating: " ", count: 3 * path.count) + "|\(n.label)|"
            rows.append([node, path.isEmpty ? "\(r.luts) (\(r.luts))" : "--", "\(n.totalGates) (\(n.ownGates))", "0 (0)", "0", "0",
                         path.isEmpty ? "\(r.inputPins + r.outputPins)" : "0", full, n.entity, n.isMacro ? "maxplus2" : "work"])
        }
        return ReportTableData(title: "Analysis & Synthesis Resource Utilization by Entity",
                               header: ["Compilation Hierarchy Node", "Combinational ALUTs", "Schematic Gates", "Dedicated Logic Registers", "Block Memory Bits",
                                        "DSP Blocks", "Pins", "Full Hierarchy Name", "Entity Name", "Library Name"],
                               rows: rows,
                               note: "LUTs are mapped after the hierarchy is flattened, so Combinational ALUTs are given for the top-level entity only. Schematic Gates counts the gates drawn in each entity and everything below it (total (own)); library macros count the gates Quartzite models them with.")
    }

    static func stageReport(_ run: StageRun, state: FlowState) -> ReportNode {
        let p = state.project
        let when = dateTime(run.started.addingTimeInterval(run.elapsed))
        let id = "stage.\(run.stage.rawValue)"
        var kids: [ReportNode] = []
        let msgs = ReportNode(id: id + ".messages", title: "Messages", icon: .messages, messages: run.messages)
        switch run.stage {
        case .analysisElaboration, .analysisSynthesis:
            let s = run.stage == .analysisSynthesis ? state.synthesis : nil
            let name = run.stage.toolName
            kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "\(name) Summary", rows: [
                ["\(name) Status", statusLine(run, when)],
                ["Quartzite Version", version],
                ["Revision Name", state.design.projectName],
                ["Top-level Entity Name", p.entityName],
                ["Family", CycloneV.family],
                ["Logic utilization (in ALMs)", "N/A"],
                ["Total registers", "0"],
                ["Total pins", "\(p.inputPins.count + p.outputPins.count)"],
                ["Total virtual pins", "0"],
                ["Total block memory bits", "0"],
                ["Total DSP Blocks", "0"],
                ["Total PLLs", "0"],
                ["Total DLLs", "0"],
            ])]))
            kids.append(ReportNode(id: id + ".settings", title: "Settings", icon: .table, tables: [ReportTableData(title: "\(name) Settings", header: ["Option", "Setting"], rows: [
                ["Device", p.device],
                ["Top-level entity name", p.entityName],
                ["Family name", CycloneV.family],
                ["Two-level minimization", "Quine-McCluskey, Petrick's method (exact up to \(Synthesizer.minimizeLimit) inputs per output)"],
                ["Technology mapping", "6-input LUTs; Shannon decomposition above 6 inputs"],
            ])]))
            let sheets = state.flat?.sheetsUsed ?? [p.entityName]
            let macros = state.flat?.macrosUsed ?? []
            let fileRows = sheets.map { ["\($0).bdf", "yes", "User Block Diagram/Schematic File"] }
                + macros.map { m in ["\(m) (\((MacroLibrary.named(m)?.library ?? []).joined(separator: "/")))", "yes", "Library macro (modelled by Quartzite)"] }
            kids.append(ReportNode(id: id + ".files", title: "Source Files Read", icon: .table, tables: [ReportTableData(title: "\(name) Source Files Read",
                header: ["File Name with User-Entered Path", "Used in Netlist", "File Type"], rows: fileRows)]))
            if let s {
                let r = s.resources
                kids.append(ReportNode(id: id + ".resources", title: "Resource Usage Summary", icon: .table, tables: [ReportTableData(title: "Analysis & Synthesis Resource Usage Summary", header: ["Resource", "Usage"], rows: [
                    ["Estimate of Logic utilization (ALMs needed)", "\(r.alms)"],
                    ["", ""],
                    ["Combinational ALUT usage for logic", "\(r.luts)"],
                    ["    -- 7 input functions", "0"],
                    ["    -- 6 input functions", "\(r.lutsByInputs[6] ?? 0)"],
                    ["    -- 5 input functions", "\(r.lutsByInputs[5] ?? 0)"],
                    ["    -- 4 input functions", "\(r.lutsByInputs[4] ?? 0)"],
                    ["    -- <=3 input functions", "\(r.lutsByInputs[3] ?? 0)"],
                    ["", ""],
                    ["Dedicated logic registers", "0"],
                    ["", ""],
                    ["I/O pins", "\(r.inputPins + r.outputPins)"],
                    ["", ""],
                    ["Total DSP Blocks", "0"],
                    ["", ""],
                    ["Maximum fan-out node", r.maxFanoutNode.isEmpty ? "--" : r.maxFanoutNode],
                    ["Maximum fan-out", "\(r.maxFanout)"],
                    ["Total fan-out", "\(r.totalFanout)"],
                    ["Average fan-out", String(format: "%.2f", r.averageFanout)],
                ], note: "ALMs are estimated by packing LUT pairs under the Cyclone V normal-mode rules; Quartus' Fitter may pack differently.")]))
                if let f = state.flat, !f.identity {
                    kids.append(ReportNode(id: id + ".entity", title: "Resource Utilization by Entity", icon: .table, tables: [entityTable(f, resources: r)]))
                } else {
                    kids.append(ReportNode(id: id + ".entity", title: "Resource Utilization by Entity", icon: .table, tables: [ReportTableData(title: "Analysis & Synthesis Resource Utilization by Entity",
                        header: ["Compilation Hierarchy Node", "Combinational ALUTs", "Dedicated Logic Registers", "Block Memory Bits", "DSP Blocks", "Pins", "Entity Name"],
                        rows: [["|\(p.entityName)", "\(r.luts) (\(r.luts))", "0 (0)", "0", "0", "\(r.inputPins + r.outputPins)", p.entityName]])]))
                }
                kids.append(ReportNode(id: id + ".equations", title: "Equations (LUT masks)", icon: .table, tables: [ReportTableData(title: "Synthesized LUTs (Quartzite)",
                    header: ["Node", "Inputs", "LUT mask", "Equation", "Level"],
                    rows: s.network.luts.indices.map { i -> [String] in
                        let l = s.network.luts[i]
                        let ins = l.inputs.enumerated().map { "\(LUTNetwork.LUT.ports[$0.offset])=\(s.network.name(of: $0.element))" }.joined(separator: " ")
                        return [l.name, ins, LUTMask.hex(l.mask), "\(l.name) = \(s.network.equation(i))", "\(l.level)"]
                    }, note: "lut_mask uses the Quartus encoding: bit index = dataf*32 + datae*16 + datad*8 + datac*4 + datab*2 + dataa. Quartus may choose different input ports or inversions, which changes the mask but not the function."),
                    ReportTableData(title: "Output Drivers", header: ["Output Pin", "Driven by"], rows: s.outputs.map { [$0.name, s.network.name(of: $0.driver)] })]))
                kids.append(ReportNode(id: id + ".logic", title: "Minimized Logic", icon: .table, tables: [ReportTableData(title: "Minimized Logic (Quartzite)",
                    header: ["Output", "Minimal SOP", "Minimal POS", "SOP cost", "POS cost", "Method"],
                    rows: s.outputs.map { o in
                        [o.name, o.minimized ? "\(o.name) = \(o.textbookSOP)" : "--", o.minimized ? "\(o.name) = \(o.textbookPOS)" : "--",
                         o.minimized ? "\(o.sopCost.gates) gates, \(o.sopCost.inputs) inputs" : "--",
                         o.minimized ? "\(o.posCost.gates) gates, \(o.posCost.inputs) inputs" : "--",
                         o.method + (o.minimized && !o.exact ? " (not proven minimal)" : "")]
                    }, note: "Cost counts gates and gate inputs, with one NOT gate per complemented variable. Your schematic: \(plural(s.schematicGates, "gate")), \(s.schematicGateInputs) gate inputs."),
                    ReportTableData(title: "Equations (Quartus notation)", header: ["Output", "Equation"], rows: s.outputs.map { [$0.name, "\($0.name) = \($0.sopEquation)"] })]))
                var removedRows = s.removed.map { [$0.name, $0.kind.bdfName, $0.explanation] }
                if removedRows.isEmpty { removedRows = [["--", "--", "No redundant gates found"]] }
                kids.append(ReportNode(id: id + ".removed", title: "Gates Removed During Synthesis", icon: .table, tables: [ReportTableData(title: "Gates Removed During Synthesis (Quartzite)",
                    header: ["Gate", "Type", "Reason"], rows: removedRows,
                    note: "All gates are replaced by LUTs during technology mapping; this table lists gates that are logically redundant in the schematic.")]))
            }
        case .fitter:
            if let fit = state.fit, let s = state.synthesis {
                kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "Fitter Summary", rows: [
                    ["Fitter Status", statusLine(run, when)],
                    ["Quartzite Version", version],
                    ["Revision Name", state.design.projectName],
                    ["Top-level Entity Name", p.entityName],
                    ["Family", CycloneV.family],
                    ["Device", p.device],
                    ["Timing Models", "Not modeled"],
                    ["Place and route", state.pnr == nil ? "Not performed (Quartzite logical fitter)" : "nextpnr-mistral, open-source (experimental)"],
                    ["Logic utilization (in ALMs)", usage(fit.alms, CycloneV.totalALMs)],
                    ["Total registers", "0"],
                    ["Total pins", usage(p.inputPins.count + p.outputPins.count, CycloneV.totalPins)],
                    ["Total virtual pins", "0"],
                    ["Total block memory bits", usage(0, CycloneV.totalBlockMemoryBits)],
                    ["Total RAM Blocks", usage(0, CycloneV.totalRAMBlocks)],
                    ["Total DSP Blocks", usage(0, CycloneV.totalDSPBlocks)],
                    ["Total PLLs", usage(0, CycloneV.totalPLLs)],
                    ["Total DLLs", usage(0, CycloneV.totalDLLs)],
                ])]))
                kids.append(ReportNode(id: id + ".settings", title: "Settings", icon: .table, tables: [ReportTableData(title: "Fitter Settings", header: ["Option", "Setting"], rows: [
                    ["Device", p.device],
                    ["Package", CycloneV.package],
                    ["Board", "Terasic DE10-Standard"],
                ] + (state.pnr == nil ? [
                    ["Logic placement", "Quartzite logical LABs (ten ALMs each); not Quartus coordinates"],
                    ["Routing", "Not performed"],
                ] : [
                    ["Synthesis for place and route", "yosys synth_intel_alm -family cyclonev"],
                    ["Logic placement", "nextpnr-mistral: HeAP analytic placer, then simulated annealing"],
                    ["Routing", "nextpnr-mistral router2"],
                    ["Placement seed", "\(state.hardware?.seed ?? 1)"],
                    ["I/O standard", "Fixed 3.3-V drive on outputs (nextpnr-mistral ignores IO_STANDARD)"],
                ]))]))
                kids.append(ReportNode(id: id + ".pinout", title: "Pin-Out File", icon: .table, tables: [ReportTableData(title: "Pin-Out File",
                    header: ["Pin Name/Usage", "Location", "Dir.", "I/O Bank", "User Assignment", "Board Resource"],
                    rows: fit.io.map { [$0.name, $0.location.replacingOccurrences(of: "PIN_", with: ""), $0.isInput ? "input" : "output", $0.bank ?? "--", $0.assignedByUser ? "Y" : "N", $0.board?.longLabel ?? ""] },
                    note: "Only the design's pins are listed. Unused device pins are left to Quartus.")]))
                let r = s.resources
                kids.append(ReportNode(id: id + ".resources", title: "Resource Section", icon: .folder, children: [
                    ReportNode(id: id + ".resources.usage", title: "Fitter Resource Usage Summary", icon: .table, tables: [ReportTableData(title: "Fitter Resource Usage Summary", header: ["Resource", "Usage", "%"], rows: [
                        ["Logic utilization (ALMs needed / total ALMs on device)", "\(thousands(fit.alms)) / \(thousands(CycloneV.totalALMs))", percent(fit.alms, CycloneV.totalALMs)],
                        ["ALMs needed", "\(fit.alms)", ""],
                        ["", "", ""],
                        ["Total LABs:  partially or completely used", "\(thousands(fit.labs)) / \(thousands(CycloneV.totalLABs))", percent(fit.labs, CycloneV.totalLABs)],
                        ["    -- Logic LABs", "\(fit.labs)", ""],
                        ["", "", ""],
                        ["Combinational ALUT usage for logic", "\(r.luts)", ""],
                        ["    -- 7 input functions", "0", ""],
                        ["    -- 6 input functions", "\(r.lutsByInputs[6] ?? 0)", ""],
                        ["    -- 5 input functions", "\(r.lutsByInputs[5] ?? 0)", ""],
                        ["    -- 4 input functions", "\(r.lutsByInputs[4] ?? 0)", ""],
                        ["    -- <=3 input functions", "\(r.lutsByInputs[3] ?? 0)", ""],
                        ["", "", ""],
                        ["Dedicated logic registers", "0", ""],
                        ["", "", ""],
                        ["I/O pins", "\(r.inputPins + r.outputPins) / \(CycloneV.totalPins)", percent(r.inputPins + r.outputPins, CycloneV.totalPins)],
                    ])]),
                    ReportNode(id: id + ".resources.input", title: "Input Pins", icon: .table, tables: [ReportTableData(title: "Input Pins",
                        header: ["Name", "Pin #", "I/O Bank", "Combinational Fan-Out", "Location assigned by", "Board Resource"],
                        rows: fit.io.filter { $0.isInput }.map { [$0.name, $0.location.replacingOccurrences(of: "PIN_", with: ""), $0.bank ?? "--", "\($0.fanout)", $0.assignedByUser ? "User" : "Fitter", $0.board?.longLabel ?? ""] })]),
                    ReportNode(id: id + ".resources.output", title: "Output Pins", icon: .table, tables: [ReportTableData(title: "Output Pins",
                        header: ["Name", "Pin #", "I/O Bank", "Location assigned by", "Board Resource"],
                        rows: fit.io.filter { !$0.isInput }.map { [$0.name, $0.location.replacingOccurrences(of: "PIN_", with: ""), $0.bank ?? "--", $0.assignedByUser ? "User" : "Fitter", $0.board?.longLabel ?? ""] })]),
                    ReportNode(id: id + ".resources.banks", title: "I/O Bank Usage", icon: .table, tables: [ReportTableData(title: "I/O Bank Usage", header: ["I/O Bank", "Usage"],
                        rows: FitResult.bankCapacity.keys.sorted().map { b in [b, usage(fit.io.filter { $0.bank == b }.count, FitResult.bankCapacity[b]!)] },
                        note: "Counts are the package's user I/O pins per bank. VCCIO depends on the board and is not shown.")]),
                ] + (state.pnr == nil ? [
                    ReportNode(id: id + ".resources.placement", title: "Logic Placement", icon: .table, tables: [ReportTableData(title: "Logic Placement (Quartzite)",
                        header: ["Node", "Location"], rows: fit.logic.map { [$0.name, $0.location] },
                        note: "Quartzite's own deterministic LAB numbering. Quartus places logic itself; these are not Quartus LABCELL coordinates.")]),
                ] : [])))
                if let pnr = state.pnr { kids.append(pnrReport(pnr, id: id + ".pnr")) }
            }
        case .assembler:
            var rows = [
                ["Assembler Status", statusLine(run, when)],
                ["Revision Name", state.design.projectName],
                ["Top-level Entity Name", p.entityName],
                ["Family", CycloneV.family],
                ["Device", p.device],
            ]
            let quartus = "Compile the exported project in Quartus Prime to get output_files/\(p.entityName).sof"
            if let a = state.assembly {
                rows += [
                    ["Programming file", a.passed ? a.sofURL.path : "None: the .sof failed verification (unverified file kept at \(a.sofURL.path))"],
                    ["Checksum", a.checksumText],
                    ["File CRC-16", String(format: "0x%04X", a.crc)],
                    ["File size", "\(thousands(a.bytes)) bytes"],
                    ["Records", "\(a.records) (layout of Quartus \(a.layout == 17 ? "17.0 and later, including 18.1" : a.layout == 16 ? "15.1 to 16.1" : "\(a.layout)"))"],
                    ["Compiler version record", a.compilerVersionRecord],
                    ["Verification", a.check.summary + (a.roundTripIdentical ? "; every configuration bit re-extracted from the .sof" : "; the re-extracted bitstream differs")],
                    ["Generated by", "Quartzite with yosys, nextpnr-mistral and Mistral (not Intel Quartus)"],
                ]
                kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "Assembler Summary", rows: rows,
                    note: HardwareFlow.experimentalNotice)]))
                var files = [["Programming file (.sof)", a.sofURL.path]]
                if a.passed { files.append(["Quartzite marker", HardwareFlow.markerURL(a.sofURL).path]) }
                files += [["Bitstream re-extracted from the .sof", a.extractedRBF.path], ["Decoded bitstream (mistral-cv)", a.btURL.path]]
                if let pnr = state.pnr { files.append(["Work folder", pnr.workDirectory.path]) }
                kids.append(ReportNode(id: id + ".files", title: "Generated Files", icon: .table, tables: [ReportTableData(title: "Assembler Generated Files", header: ["File", "Path"], rows: files)]))
                kids.append(ReportNode(id: id + ".check", title: "Bitstream Check", icon: .table, tables: bitstreamTables(a.check, title: "Programming File Bitstream Check")))
            } else {
                rows.append(["Programming file", state.hardware == nil
                             ? "None. \(state.toolchainNote.map { $0 + " " } ?? "")\(quartus)"
                             : "None. The Fitter produced no bitstream; run Start Compilation again"])
                kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "Assembler Summary", rows: rows)]))
            }
        case .timing:
            if let t = state.timing {
                kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "Timing Analyzer Summary (estimate)", rows: [
                    ["Status", statusLine(run, when)],
                    ["Analysis", "Combinational logic depth only (Quartzite estimate)"],
                    ["Delay models", "None. This is not a Quartus timing analysis"],
                    ["Clocks", "None"],
                    ["Deepest input-to-output path", "\(plural(t.maxLevels, "LUT level"))"],
                ])]))
                kids.append(ReportNode(id: id + ".depth", title: "Logic Depth", icon: .table, tables: [ReportTableData(title: "Input to Output Logic Depth (estimate)",
                    header: ["From", "To", "LUT levels"], rows: t.paths.map { [$0.from, $0.to, "\($0.levels)"] },
                    note: "Path depth counts the LUTs between an input pin and an output pin. It says nothing about delay in nanoseconds.")]))
            }
        case .eda:
            kids.append(ReportNode(id: id + ".summary", title: "Summary", icon: .table, tables: [ReportTableData(title: "EDA Netlist Writer Summary", rows: [
                ["EDA Netlist Writer Status", statusLine(run, when)],
                ["Revision Name", state.design.projectName],
                ["Top-level Entity Name", p.entityName],
                ["Family", CycloneV.family],
                ["Simulation Files Creation", run.status == .failed ? "Failed" : "Successful"],
                ["Netlist", "\(NetlistWriter.path(p.entityName)) (Quartzite LUT-level Verilog, written on export)"],
            ])]))
            if let text = state.netlist {
                kids.append(ReportNode(id: id + ".netlist", title: "Netlist", icon: .text, text: text))
            }
        }
        kids.append(msgs)
        return ReportNode(id: id, title: run.stage.toolName + (run.stage == .timing ? " (estimate)" : ""), icon: .folder,
                          children: kids, failed: run.status == .failed)
    }

    /// Fitter > Place and Route: what yosys and nextpnr-mistral did, and the decoded bitstream.
    static func pnrReport(_ r: PnRResult, id: String) -> ReportNode {
        let seconds = { (t: TimeInterval) in String(format: "%.1f s", t) }
        return ReportNode(id: id, title: "Place and Route (nextpnr-mistral)", icon: .folder, children: [
            ReportNode(id: id + ".toolchain", title: "Toolchain", icon: .table, tables: [
                ReportTableData(title: "Open-Source Toolchain", header: ["Tool", "Version"], rows: [
                    ["yosys", r.yosysVersion], ["nextpnr-mistral", r.nextpnrVersion], ["mistral-cv", r.mistralVersion]],
                    note: "None of these tools come from Intel. The flow is experimental and has not been tested on a DE10-Standard."),
                ReportTableData(title: "Elapsed Time", header: ["Step", "Elapsed"], rows: r.times.map { [$0.step, seconds($0.seconds)] }),
                ReportTableData(title: "Files", header: ["File", "Path"], rows: [
                    ["Verilog netlist", r.verilogURL.path], ["Pin locations (.qsf)", r.qsfURL.path], ["yosys netlist", r.netlistURL.path],
                    ["Bitstream (.rbf)", r.rbfURL.path], ["Decoded bitstream", r.btURL.path], ["yosys log", r.yosysLog.path], ["nextpnr log", r.nextpnrLog.path]]),
            ]),
            ReportNode(id: id + ".cells", title: "Synthesized Cells (yosys)", icon: .table, tables: [ReportTableData(title: "yosys Cell Usage",
                header: ["Cell type", "Count"], rows: r.yosysCells.map { [$0.type, "\($0.count)"] })]),
            ReportNode(id: id + ".utilization", title: "Device Utilization (nextpnr)", icon: .table, tables: [ReportTableData(title: "nextpnr-mistral Device Utilization",
                header: ["Resource", "Used", "Available", "%"], rows: r.utilization.filter { $0.used > 0 }.map { [$0.type, thousands($0.used), thousands($0.available), percent($0.used, $0.available)] },
                note: "Resources with no cells used are omitted.")]),
            ReportNode(id: id + ".placement", title: "Placement", icon: .table, tables: [ReportTableData(title: "Cell Placement (nextpnr-mistral)",
                header: ["Cell", "Type", "Location", "nextpnr BEL"], rows: r.cells.map { [$0.name, $0.type, HardwareFlow.belLabel($0.bel), $0.bel] }),
                ReportTableData(title: "I/O Placement", header: ["Pin Name", "Location", "nextpnr I/O cell"], rows: r.ioCells.map { [$0.name, $0.pin, $0.bel] })]),
            ReportNode(id: id + ".bitstream", title: "Bitstream", icon: .table, tables: [ReportTableData(title: "nextpnr-mistral Bitstream", rows: [
                ["File", r.rbfURL.lastPathComponent],
                ["Size", "\(thousands(r.rbfBytes)) bytes (raw, uncompressed)"],
                ["Routed links", thousands(r.check.routedLinks)],
                ["Non-default settings", thousands(r.check.settingsCount)],
                ["ALMs configured", "\(r.almsUsed) in \(plural(r.labsUsed, "LAB")) (including nextpnr's constant drivers)"],
            ], note: "Decoded with mistral-cv, independently of nextpnr.")] + bitstreamTables(r.check, title: "Fitter Bitstream Check")),
        ])
    }

    /// Pin and truth-table results of a decoded bitstream.
    static func bitstreamTables(_ c: BitstreamCheck, title: String) -> [ReportTableData] {
        var t = [ReportTableData(title: title, header: ["Pin Name", "Dir.", "Location", "Routing node", "Check"],
                                 rows: c.pins.map { [$0.name, $0.isInput ? "input" : "output", "PIN_\($0.pin)", $0.node, ($0.ok ? "OK: " : "FAIL: ") + $0.note] },
                                 note: c.summary)]
        if c.evaluationError == nil && !c.outputNames.isEmpty {
            t.append(ReportTableData(title: "Truth Table of the Decoded Bitstream", header: ["Output", "Rows matching the schematic simulation"],
                                     rows: c.outputNames.enumerated().map { [$0.element, "\(c.outputRowsCorrect[$0.offset]) / \(c.rows)"] }))
        }
        return t
    }
}

/// A table in the Compilation Report. An empty `header` means a two-column key/value table.
struct ReportTableData: Hashable {
    var title: String
    var header: [String] = []
    var rows: [[String]]
    var note: String? = nil
}

struct ReportNode: Identifiable {
    enum Icon { case table, folder, messages, text }
    var id: String
    var title: String
    var icon: Icon
    var tables: [ReportTableData] = []
    var text: String? = nil
    var messages: [Message]? = nil
    var children: [ReportNode] = []
    var failed = false

    var optionalChildren: [ReportNode]? { children.isEmpty ? nil : children }

    func find(_ id: String) -> ReportNode? {
        if self.id == id { return self }
        for c in children { if let f = c.find(id) { return f } }
        return nil
    }
}

/// Plain-text rendering in the layout of Quartus .rpt files.
enum ReportText {
    static func table(_ t: ReportTableData) -> String {
        let cols = max(t.header.count, t.rows.map { $0.count }.max() ?? 0, 1)
        var widths = [Int](repeating: 0, count: cols)
        for row in [t.header] + t.rows { for (i, c) in row.enumerated() { widths[i] = max(widths[i], c.count) } }
        var rowLen = 4 + widths.reduce(0, +) + 3 * (cols - 1)
        if t.title.count + 4 > rowLen { widths[cols - 1] += t.title.count + 4 - rowLen; rowLen = t.title.count + 4 }
        func line(_ cells: [String]) -> String {
            "; " + (0..<cols).map { i in let c = i < cells.count ? cells[i] : ""; return c + String(repeating: " ", count: widths[i] - c.count) }.joined(separator: " ; ") + " ;"
        }
        let sep = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        var out = ["+" + String(repeating: "-", count: rowLen - 2) + "+",
                   "; " + t.title + String(repeating: " ", count: rowLen - 4 - t.title.count) + " ;",
                   sep]
        if !t.header.isEmpty { out += [line(t.header), sep] }
        out += t.rows.map(line)
        out.append(sep)
        if let n = t.note { out.append(n) }
        return out.joined(separator: "\n")
    }

    static func render(_ nodes: [ReportNode]) -> String {
        var out: [String] = []
        func walk(_ n: ReportNode) {
            for t in n.tables { out.append(table(t)); out.append("\n") }
            if let m = n.messages, n.id != "flow.messages" {
                out.append("+" + String(repeating: "-", count: n.title.count + 2) + "+\n; \(n.title) ;\n+" + String(repeating: "-", count: n.title.count + 2) + "+")
                out += m.flatMap { $0.reportLines() }
                out.append("\n")
            }
            if let t = n.text { out.append(t) }
            n.children.forEach(walk)
        }
        nodes.forEach(walk)
        return out.joined(separator: "\n")
    }
}

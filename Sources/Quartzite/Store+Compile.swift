#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Processing menu / Tasks pane commands: runs the compile flow one stage at a time off
/// the main thread, streaming each stage's messages into the Messages pane.
extension Store {
    var isProcessing: Bool { flowTask != nil }

    /// Processing > Start Compilation (Cmd-L).
    func startCompilation() { runFlow(FlowStage.fullCompilation, mainTask: "Compilation") }

    /// Processing > Start > Start <stage>. Earlier stages are reused when their results are
    /// still current, and run first when they are not.
    func start(_ stage: FlowStage) {
        switch stage {
        case .analysisElaboration, .analysisSynthesis:
            runFlow([stage], mainTask: stage.toolName)
        default:
            // The Assembler needs a bitstream; a Fitter run without one is redone.
            if let f = flow, !compileIsStale,
               stage.prerequisites.allSatisfy({ s in f.run(s).map { $0.status != .failed } ?? false }),
               !(stage == .assembler && f.pnr == nil && hardwareAvailable) {
                runFlow([stage], mainTask: stage.toolName, reusing: f)
            } else {
                runFlow(stage.prerequisites + [stage], mainTask: stage.toolName)
            }
        }
    }

    /// Processing > Stop Processing: terminates a running external tool, otherwise
    /// finishes the running stage, then stops.
    func stopProcessing() {
        flowTask?.cancel()
        hardwareCancel?.cancel()
    }

    // MARK: - Open-source Fitter and Assembler

    /// True when a compilation would run real place and route and write a .sof.
    var hardwareAvailable: Bool { useHardwareFlow && toolchainSearch.toolchain != nil }

    /// One line for the Tasks pane and tooltips.
    var toolchainStatus: String {
        if toolchainSearch.toolchain == nil { return "Toolchain: not found" }
        return useHardwareFlow ? "Toolchain: on" : "Toolchain: off"
    }

    /// Quartus writes output_files/ next to the project; an unsaved project uses Application Support.
    static func outputDirectory(project: Project, fileURL: URL?) -> URL {
        if let f = fileURL { return f.deletingLastPathComponent().appendingPathComponent("output_files", isDirectory: true) }
        return supportDirectory.appendingPathComponent("output_files", isDirectory: true)
            .appendingPathComponent(project.entityName, isDirectory: true)
    }

    /// Settings for real place and route and the experimental .sof, or why there are none.
    /// Searches for the toolchain again, so a toolchain built while Quartzite runs is found.
    func hardwareConfig() -> (config: HardwareConfig?, note: String?) {
        guard useHardwareFlow else {
            return (nil, "The experimental open-source Fitter and Assembler are turned off (Processing > Use Open-Source Fitter and Assembler).")
        }
        toolchainSearch = Toolchain.locate()
        guard let tc = toolchainSearch.toolchain else {
            return (nil, "\(toolchainSearch.summary). Build it with toolchain/build_toolchain.sh (docs/TOOLCHAIN_NOTES.md) to generate the experimental .sof.")
        }
        var c = HardwareConfig(toolchain: tc, outputDirectory: Store.outputDirectory(project: topProject, fileURL: fileURL))
        let cancel = ProcessCancel()
        c.cancel = cancel
        hardwareCancel = cancel
        return (c, nil)
    }

    /// Tasks pane: where the toolchain was looked for and what was found.
    func showToolchainStatus() {
        toolchainSearch = Toolchain.locate()
        var lines = [toolchainSearch.summary + "."]
        if let tc = toolchainSearch.toolchain {
            lines.append("")
            lines += tc.tools.map { "\($0.name): \($0.url.path) (found via \($0.source))" }
            lines.append("")
            lines.append(useHardwareFlow
                ? "Start Compilation runs yosys and nextpnr-mistral in the Fitter, and the Assembler writes an experimental .sof to \(Store.outputDirectory(project: topProject, fileURL: fileURL).path)."
                : "Turn on Processing > Use Open-Source Fitter and Assembler to generate the experimental .sof.")
        } else {
            for m in toolchainSearch.missing { lines.append("\(m.name): searched \(m.searched.joined(separator: ", "))") }
            lines.append("")
            lines.append("Build it with toolchain/build_toolchain.sh from the Quartzite repository (docs/TOOLCHAIN_NOTES.md). Everything else in Quartzite works without it.")
        }
        alert("Open-Source Cyclone V Toolchain", lines.joined(separator: "\n"))
    }

    /// Shows the last generated .sof in Finder.
    func revealProgrammingFile() {
        guard let a = flow?.assembly, a.passed else { return }
        NSWorkspace.shared.activateFileViewerSelecting([a.sofURL])
    }

    func resetFlow() {
        flowTask?.cancel()
        hardwareCancel?.cancel()
        hardwareCancel = nil
        liveStage = nil
        flowTask = nil
        flowGeneration = UUID()
        processingStage = nil
        flow = nil
        stageStatus = [:]
        stageElapsed = [:]
        processingProgress = 0
        processingStarted = nil
        processingEnded = nil
        messages = []
    }

    func status(_ s: FlowStage) -> StageStatus {
        if processingStage == s { return .running }
        return stageStatus[s] ?? .notRun
    }

    /// Status of the Compile Design row: running, failed, warnings or done.
    var compileDesignStatus: StageStatus {
        if isProcessing && FlowStage.fullCompilation.contains(where: { processingStage == $0 }) { return .running }
        let ran = FlowStage.fullCompilation.compactMap { stageStatus[$0] }
        if ran.isEmpty { return .notRun }
        if ran.contains(.failed) { return .failed }
        if ran.count < FlowStage.fullCompilation.count { return .notRun }
        return ran.contains(.warnings) ? .warnings : .succeeded
    }

    func runFlow(_ stages: [FlowStage], mainTask: String, reusing: FlowState? = nil) {
        guard flowTask == nil else { return }
        let version = projectVersion
        let generation = UUID()
        flowGeneration = generation
        var state = reusing ?? FlowState(project: topProject, mainTask: mainTask)
        state.mainTask = mainTask
        if stages.contains(.fitter) || stages.contains(.assembler) {
            var (hw, note) = hardwareConfig()
            // Tool output appears in the Messages pane while the tool runs.
            hw?.onMessage = { [weak self] m in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.liveStage == generation else { return }
                        self.messages.append(m)
                    }
                }
            }
            state.hardware = hw
            state.toolchainNote = note
        }
        if reusing == nil {
            stageStatus = [:]
            stageElapsed = [:]
        } else {
            for s in stages { stageStatus[s] = nil; stageElapsed[s] = nil }
            state.runs.removeAll { stages.contains($0.stage) }
            state.summary = nil
        }
        messages = []
        processingStarted = Date()
        processingEnded = nil
        processingProgress = 0
        let total = stages.count
        flowTask = Task { @MainActor [weak self] in
            guard let self, self.flowGeneration == generation, self.projectVersion == version else { return }
            var stopped = false
            for (i, stage) in stages.enumerated() {
                if Task.isCancelled { stopped = true; break }
                let started = Date()
                let header = CompileFlow.header(stage, at: started)
                self.messages += header
                self.processingStage = stage
                self.liveStart = self.messages.count
                self.liveStage = generation
                let input = state
                let (next, run) = await Task.detached(priority: .userInitiated) { () -> (FlowState, StageRun) in
                    var st = input
                    let r = CompileFlow.execute(stage, state: &st, started: started)
                    return (st, r)
                }.value
                // Keep each stage's spinner visible briefly; the reported time is the real one.
                try? await Task.sleep(nanoseconds: 120_000_000)
                // A reset/new document must never receive results from this old task.
                guard self.flowGeneration == generation, self.projectVersion == version else { return }
                // The stage's final messages replace what was streamed while it ran.
                self.liveStage = nil
                if self.messages.count > self.liveStart { self.messages.removeSubrange(self.liveStart...) }
                state = next
                var withHeader = run
                withHeader.messages = header + run.messages
                state.runs.append(withHeader)
                self.messages += run.messages
                self.stageStatus[stage] = run.status
                self.stageElapsed[stage] = run.elapsed
                self.processingProgress = Double(i + 1) / Double(total)
                if Task.isCancelled { stopped = true; break }
                if run.status == .failed { break }
            }
            if stopped {
                self.messages.append(Message(level: .error, text: "Processing was stopped by the user. Stages that had not started were not run."))
            }
            if stages == FlowStage.fullCompilation || (stages.count > 1 && stages.last == .eda) {
                var summary = CompileFlow.fullSummary(state)
                if stopped { summary = Message(level: .error, text: "Quartzite Full Compilation was unsuccessful. Processing was stopped by the user") }
                state.summary = summary
                self.messages.append(summary)
            }
            state.finished = Date()
            self.flow = state
            if self.projectVersion == version {
                self.compiled = state.circuit
                self.compileIsStale = false
            }
            self.lastCompile = Date()
            self.processingStage = nil
            self.processingEnded = Date()
            self.hardwareCancel = nil
            self.flowTask = nil
            if !state.failed && !stopped && stages.contains(.analysisSynthesis) && stages.count > 1 {
                // Quartus opens the Compilation Report when a compilation finishes.
                self.reportSelection = "flow.summary"
                self.tab = .report
            }
        }
    }

    /// Synchronous Analysis & Elaboration (the design check), used before simulation.
    @discardableResult
    func compile() -> Bool {
        if isProcessing { resetFlow() }
        let state = CompileFlow.run(topProject, stages: [.analysisElaboration], mainTask: "Analysis & Elaboration")
        messages = state.messages
        flow = state
        stageStatus = [.analysisElaboration: state.runs.first?.status ?? .failed]
        stageElapsed = [.analysisElaboration: state.runs.first?.elapsed ?? 0]
        compiled = state.circuit
        compileIsStale = false
        lastCompile = Date()
        processingEnded = Date()
        return state.circuit != nil
    }

    /// Simulation Waveform Editor: Run Functional Simulation.
    func simulate() {
        if compiled == nil || compileIsStale { compile() }
        guard let c = compiled else {
            tab = .bdf
            return
        }
        guard c.inputs.count <= SimulationResult.maxInputs else {
            messages.append(Message(level: .error, text: "Simulation is limited to 10 inputs (\(c.inputs.count) found)"))
            return
        }
        guard let r = try? SimulationResult.run(c, project: topProject) else { return }
        simulation = r
        var kids: [Message] = []
        for (i, name) in r.outputNames.enumerated() {
            if let ok = r.matches(output: i) {
                kids.append(Message(level: ok ? .info : .error,
                                    text: ok ? "Output \(name) matches the expected minterms"
                                             : "Output \(name) does not match the expected minterms (see the red cells)"))
            }
        }
        messages.append(Message(level: kids.contains { $0.level == .error } ? .error : .info,
                                text: "Functional simulation: \(r.rows.count) input combinations evaluated", children: kids))
        tab = .waveform
    }

    /// Tools > Programmer: explains why programming happens in Quartus, and offers the
    /// experimental .sof when this compilation produced one.
    func openProgrammer() {
        let quartus = "Export the project (Shift-Command-E), open \(topProject.entityName).qpf in Quartus Prime, run Start Compilation, then use Tools > Programmer with output_files/\(topProject.entityName).sof."
        if let a = flow?.assembly, a.passed, FileManager.default.fileExists(atPath: a.sofURL.path) {
            let al = NSAlert()
            al.messageText = "Programmer runs in Quartus"
            al.informativeText = "A Mac cannot drive the DE10-Standard's USB-Blaster II. Copy \(a.sofURL.lastPathComponent) (checksum \(a.checksumText)) to a computer with Quartus Prime, open Tools > Programmer, click Add File, select it and click Start.\n\n\(HardwareFlow.experimentalNotice)\n\nFor graded work: \(quartus)"
            al.addButton(withTitle: "Show in Finder")
            al.addButton(withTitle: "OK")
            if al.runModal() == .alertFirstButtonReturn { revealProgrammingFile() }
            return
        }
        let why = toolchainSearch.toolchain == nil
            ? "Quartzite writes an experimental .sof only when the open-source toolchain (yosys, nextpnr-mistral, mistral-cv) is installed."
            : (useHardwareFlow ? "Run Start Compilation to generate the experimental .sof first."
                               : "Turn on Processing > Use Open-Source Fitter and Assembler and run Start Compilation to generate an experimental .sof.")
        alert("Programmer runs in Quartus at the lab", "A Mac cannot drive the DE10-Standard's USB-Blaster II. \(why) \(quartus)")
    }

    /// Saves the current Quartzite netlist (EDA Netlist Writer output).
    func saveNetlist() {
        guard let text = flow?.netlist else { return }
        exportText(NetlistWriter.fileName(topProject.entityName), text)
    }

    /// Saves the whole Compilation Report as text in the .rpt layout.
    func saveReport() {
        guard let f = flow else { return }
        exportText("\(topProject.entityName)_quartzite.rpt", ReportText.render(CompileFlow.report(f)))
    }
}
#endif

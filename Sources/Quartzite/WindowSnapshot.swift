#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// `Quartzite --snapshot-window <file.qzproj> <dir>`: renders the main window offscreen
/// (after a full compilation) for each document tab, for visual checks without screen
/// recording permission.
enum WindowSnapshot {
    @MainActor
    static func run(_ p: Project, to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print("Could not create snapshot directory: \(error.localizedDescription)"); return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = Store(persist: false)
        store.project = p
        let state = CompileFlow.run(p)
        store.flow = state
        store.messages = state.messages
        store.compiled = state.circuit
        store.compileIsStale = false
        store.lastCompile = Date()
        store.processingStarted = state.started
        store.processingEnded = state.finished
        store.processingProgress = 1
        for run in state.runs { store.stageStatus[run.stage] = run.status; store.stageElapsed[run.stage] = run.elapsed }
        var ok = true
        // Live run through the asynchronous pipeline: capture the window while a stage runs.
        let live = Store(persist: false)
        live.project = p
        live.startCompilation()
        var sawRunning = false
        let deadline = Date().addingTimeInterval(20)
        while live.isProcessing && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if live.processingStage != nil && !sawRunning {
                sawRunning = true
                ok = render(ContentView(store: live), "window_running", dir) && ok
            }
        }
        if live.isProcessing { live.stopProcessing(); ok = false }
        let statuses = FlowStage.fullCompilation.map { "\($0.toolName)=\(live.stageStatus[$0].map { "\($0)" } ?? "nil")" }
        print("live run: sawRunning=\(sawRunning) finished=\(!live.isProcessing) tab=\(live.tab) \(statuses.joined(separator: ", "))")
        print("live run last message: \(live.messages.last?.text ?? "")")
        let shots: [(String, DocTab, String?)] = [
            ("window_bdf", .bdf, nil), ("window_report_summary", .report, "flow.summary"),
            ("window_report_equations", .report, "stage.analysisSynthesis.equations"),
            ("window_report_pinout", .report, "stage.fitter.pinout"), ("window_report_netlist", .report, "stage.eda.netlist"),
            ("window_pins", .pins, nil), ("window_assignments", .assignments, nil), ("window_waveform", .waveform, nil),
        ]
        for (name, tab, sel) in shots {
            store.tab = tab
            if let sel { store.reportSelection = sel }
            if tab == .waveform { store.simulate() }
            let host = NSHostingView(rootView: ContentView(store: store).frame(width: 1440, height: 900))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { ok = false; continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                do {
                    try data.write(to: dir.appendingPathComponent("\(name).png"))
                    print("rendered \(name).png")
                } catch { print("Could not write snapshot: \(error.localizedDescription)"); ok = false }
            } else { ok = false }
            window.close()
        }
        return ok
    }

    /// `--snapshot-window <file> <dir> --hardware`: a compilation through the open-source
    /// Fitter and Assembler (needs the toolchain), captured while nextpnr runs and afterwards.
    @MainActor
    static func runHardware(_ p: Project, to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print("Could not create snapshot directory: \(error.localizedDescription)"); return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = Store(persist: false)
        store.project = p
        store.toolchainSearch = Toolchain.locate()
        guard store.toolchainSearch.toolchain != nil else { print(store.toolchainSearch.summary); return false }
        store.fileURL = dir.appendingPathComponent("project/\(p.entityName).qzproj")
        store.useHardwareFlow = true
        store.startCompilation()
        var ok = true, sawFitter = false
        let deadline = Date().addingTimeInterval(180)
        while store.isProcessing && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !sawFitter && store.messages.contains(where: { $0.text.hasPrefix("Running nextpnr-mistral") }) {
                sawFitter = true
                ok = render(ContentView(store: store), "hw_running_fitter", dir) && ok
            }
        }
        print("hardware run: finished=\(!store.isProcessing) sof=\(store.flow?.assembly?.sofURL.path ?? "none") passed=\(store.flow?.assembly?.passed == true)")
        for (name, tab, sel) in [("hw_tasks_bdf", DocTab.bdf, nil as String?), ("hw_report_assembler", .report, "stage.assembler.summary"),
                                 ("hw_report_check", .report, "stage.assembler.check"), ("hw_report_pnr_placement", .report, "stage.fitter.pnr.placement"),
                                 ("hw_report_fitter_settings", .report, "stage.fitter.settings")] {
            store.tab = tab
            if let sel { store.reportSelection = sel }
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            ok = render(ContentView(store: store), name, dir) && ok
        }
        return ok && store.flow?.assembly?.passed == true
    }

    @MainActor
    private static func render(_ view: some View, _ name: String, _ dir: URL) -> Bool {
        let host = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: dir.appendingPathComponent("\(name).png")) }
        catch { print("Could not write snapshot: \(error.localizedDescription)"); return false }
        print("rendered \(name).png")
        return true
    }
}
#endif

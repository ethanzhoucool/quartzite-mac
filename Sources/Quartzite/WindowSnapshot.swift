#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// `Quartzite --snapshot-window <file.qzproj> <dir>`: renders the main window offscreen
/// (after a full compilation) for each document tab, for visual checks without screen
/// recording permission.
enum WindowSnapshot {
    @MainActor
    static func run(_ d: DesignProject, to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print("Could not create snapshot directory: \(error.localizedDescription)"); return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = Store(persist: false)
        store.loadDesign(d, from: nil, dirty: true)
        let state = CompileFlow.run(d)
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
        live.loadDesign(d, from: nil, dirty: true)
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
        var shots: [(String, DocTab, String?)] = [
            ("window_bdf", .bdf, nil), ("window_report_summary", .report, "flow.summary"),
            ("window_report_equations", .report, "stage.analysisSynthesis.equations"),
            ("window_report_pinout", .report, "stage.fitter.pinout"), ("window_report_netlist", .report, "stage.eda.netlist"),
            ("window_pins", .pins, nil), ("window_assignments", .assignments, nil), ("window_waveform", .waveform, nil),
        ]
        // Multi-file designs: a selected block and macro on the top sheet, then the block's own sheet.
        let top = d.top?.components ?? []
        let block = top.first { $0.kind == .block }, macro = top.first { $0.kind == .macro }
        if macro != nil { shots.append(("window_bdf_macro", .bdf, "macro")) }
        if block != nil { shots += [("window_bdf_block", .bdf, "block"), ("window_bdf_child", .bdf, "child")] }
        for (name, tab, sel) in shots {
            store.tab = tab
            switch (tab, sel) {
            case (.bdf, "macro"?): store.selection = [.comp(macro!.id)]
            case (.bdf, "block"?): store.selection = [.comp(block!.id)]
            case (.bdf, "child"?): store.openBlock(block!.id)
            default: if let sel { store.reportSelection = sel }
            }
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
        if (store.simulation?.rows.count ?? 0) > 64 { measureScrolling(store) }
        measureEditing(store)
        // Dialogs of multi-file designs: Insert Symbol on the block's sheet, the macro's function table.
        if block != nil {
            ok = render(PropertySheetView(store: store, sheet: .symbolLibrary(at: .zero)).background(.background), "dialog_symbol", dir) && ok
        }
        if let macro, let top = d.top?.id {
            store.openSheet(top)
            ok = render(PropertySheetView(store: store, sheet: .macroInfo(macro.id)).background(.background), "dialog_macro", dir) && ok
        }
        return ok
    }

    /// `--snapshot-window <file> <dir> --hardware`: a compilation through the open-source
    /// Fitter and Assembler (needs the toolchain), captured while nextpnr runs and afterwards.
    @MainActor
    static func runHardware(_ d: DesignProject, to dir: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print("Could not create snapshot directory: \(error.localizedDescription)"); return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = Store(persist: false)
        store.loadDesign(d, from: nil, dirty: true)
        store.toolchainSearch = Toolchain.locate()
        guard store.toolchainSearch.toolchain != nil else { print(store.toolchainSearch.summary); return false }
        store.fileURL = dir.appendingPathComponent("project/\(d.projectName).qzproj")
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

    /// Scrolls each scroll view of the Waveform tab offscreen, one 60-point step at a time, and
    /// prints the time per step (scrolling, SwiftUI layout and drawing), to check that a big
    /// truth table scrolls smoothly.
    @MainActor
    static func measureScrolling(_ store: Store) {
        store.tab = .waveform
        let host = NSHostingView(rootView: ContentView(store: store).frame(width: 1440, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        func scrollViews(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        let sim = store.simulation
        print("scroll timing, \(sim?.rows.count ?? 0) rows x \((sim?.inputNames.count ?? 0) + (sim?.outputNames.count ?? 0)) columns:")
        for sv in scrollViews(host) {
            guard let doc = sv.documentView else { continue }
            let clip = sv.contentView
            let maxY = doc.frame.height - clip.bounds.height
            guard maxY > 100 else { continue }
            var times: [Double] = []
            var y = clip.bounds.minY
            while y < maxY && times.count < 300 {
                y = min(maxY, y + 60)
                let t0 = CFAbsoluteTimeGetCurrent()
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                sv.reflectScrolledClipView(clip)
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.display()
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let sorted = times.sorted()
            print(String(format: "  scroll view %.0f x %.0f in %.0f x %.0f: %d steps, mean %.1f ms, median %.1f ms, max %.1f ms",
                         doc.frame.width, doc.frame.height, clip.bounds.width, clip.bounds.height, times.count,
                         times.reduce(0, +) / Double(max(1, times.count)), sorted[sorted.count / 2], sorted.last ?? 0))
        }
        window.close()
    }

    /// Times one drag step on the top sheet: the connectivity and routing alone, a live move
    /// of a component that reroutes at once and one that defers the routing, and the autosave
    /// written after each edit.
    @MainActor
    static func measureEditing(_ store: Store) {
        guard let top = store.design.top?.id else { return }
        store.openSheet(top)
        guard let c = store.project.components.first(where: { !$0.kind.isPin }) ?? store.project.components.first else { return }
        func time(_ body: (Int) -> Void) -> String {
            var times: [Double] = []
            for n in 0..<40 {
                let t0 = CFAbsoluteTimeGetCurrent()
                body(n)
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let sorted = times.sorted()
            return String(format: "mean %.1f ms, median %.1f ms, max %.1f ms",
                          times.reduce(0, +) / Double(times.count), sorted[sorted.count / 2], sorted.last ?? 0)
        }
        let p = store.project
        print("edit timing, \(p.components.count) components and \(p.wires.count) wires on \(p.entityName).bdf:")
        print("  connectivity: " + time { _ in _ = Connectivity(p) })
        print("  connectivity and routing: " + time { _ in store.refreshRouting() })
        func move(_ n: Int) {
            store.liveMutate { p in
                if let i = p.index(of: c.id) { p.components[i].x = c.x + Int(Routing.grid) * (n % 4 + 1) }
            }
        }
        let budget = store.liveRoutingBudget
        store.checkpoint()
        store.liveRoutingBudget = .infinity
        print("  drag step, rerouting at once: " + time(move))
        store.liveRoutingBudget = budget
        store.refreshRouting()
        print(String(format: "  drag step with the default budget (%.0f ms): ", budget * 1000) + time(move)
              + (store.routingIsBehind ? ", routing deferred" : ""))
        store.finishLiveEdit()
        store.undo()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quartzite-autosave-timing-\(UUID().uuidString).json")
        print("  autosave: " + time { _ in try? JSONEncoder().encode(store.design).write(to: file, options: .atomic) })
        try? FileManager.default.removeItem(at: file)
    }

    /// The Programmer window with a DE10-Standard chain as Auto Detect would show it, the Board
    /// tab with a sample state, and Settings > Programmer. No hardware is used.
    @MainActor
    static func runProgrammer(_ store: Store, to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = ProgrammerModel(persist: false)
        let chain = [JTAGDevice(index: 0, idcode: Programmer.hpsIDCode, irLength: 4, detail: "ARM cortex A9"),
                     JTAGDevice(index: 1, idcode: 0x02D0_20DD, irLength: 10, detail: "cyclone V Soc 5CSE*A6/5CSX*6")]
        m.chain = chain
        m.rows = chain.map { ProgrammerModel.Row(device: $0, deviceName: $0.name, file: nil) }
        m.rows[1].file = URL(fileURLWithPath: "/project/output_files/\(store.topProject.entityName).sof")
        m.rows[1].checksum = "00AF52DB"
        m.rows[1].program = true
        m.probes = [USBProbe(bus: 1, device: 4, vid: 0x09FB, pid: 0x6010, probe: "usb-blasterII_1", manufacturer: "Altera", serial: "none", product: "DE-SoC")]
        m.progress = 1
        m.status = "100% (Successful)"
        m.log = ["$ openFPGALoader -c usb-blasterII --probe-firmware blaster_6810.hex --index-chain 1 --write-sram lab.rbf",
                 "Load SRAM: [==================================================] 100.00%", "Done"]
        var ok = render(ProgrammerView(model: m, defaultFile: { nil }), "programmer_chain", dir)
        var b = BoardState()
        b.switches = [true, false, true, true, false, false, false, false, false, true]
        b.leds = [true, false, true, true, false, false, false, false, false, false]
        b.keysPressed[0] = true
        let digits: [[Bool]] = [[true, true, true, true, true, true, false], [false, true, true, false, false, false, false]]
        b.segments[0] = digits[1]; b.segments[1] = digits[0]
        m.board = b
        m.tab = .board
        m.boardMessage = "Live (boundary-scan SAMPLE; the design keeps running)"
        ok = render(ProgrammerView(model: m, defaultFile: { nil }), "programmer_board", dir) && ok
        ok = render(ProgrammerSettingsView(model: m), "programmer_settings", dir) && ok
        return ok
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

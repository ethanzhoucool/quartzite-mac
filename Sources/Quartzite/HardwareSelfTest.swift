import Foundation

/// Self-tests for the experimental hardware flow (Toolchain, BitstreamVerifier, HardwareFlow).
/// The verifier tests use an embedded decoded bitstream and run everywhere (including Linux CI).
/// The full-flow tests need the open-source toolchain and are skipped, with a message, without it.
enum HardwareSelfTest {
    /// `mistral-cv decomp` output for toolchain/examples/demo4 (f = Σm(2,3,6,7,9,13,14) on
    /// w,x,y,z = AC30,AB28,Y27,AB30 -> AA24), trimmed to the lines the design uses plus two
    /// HMC-area inverters. CMUXHR and the other HMC lines are omitted.
    static let demoBT = """
        m 5CSXFC6D6F31C6
        r V2.087.011.0018 H6.088.011.0001
        r H6.088.011.0001 TD.089.011.0023
        r V2.087.017.0018 V2.087.015.0018
        r LAB.088.021.0:FFT1 V2.087.019.0018
        r H6.086.025.0033 V2.087.023.0012
        r V4.087.021.0009 H6.088.021.0016
        r H6.088.021.0016 TD.088.021.0015
        r V2.087.023.0012 V2.087.021.0012
        r V2.087.021.0012 H6.088.021.0010
        r TD.088.021.0009 LAB.088.021.0:C
        r H3.086.021.0012 TD.088.021.0009
        r TD.088.021.0015 LAB.088.021.0:F0
        r V2.087.015.0018 V2.087.013.0018
        r GPIO.089.025.3:DATAIN.0 H6.086.025.0033 ; AC30
        r V2.087.019.0018 V2.087.017.0018
        r H6.086.025.0039 V4.087.021.0009
        r GPIO.089.025.1:DATAIN.0 H6.086.025.0039 ; Y27
        r GPIO.089.021.0:DATAIN.0 TD.088.021.0044 ; AB30
        r TD.089.011.0023 GPIO.089.011.0:DATAOUT.0 ; AA24
        r GPIO.089.021.2:DATAIN.0 H3.086.021.0012 ; AB28
        r TD.088.021.0001 LAB.088.021.0:E0
        r V2.087.013.0018 V2.087.011.0018
        r TD.088.021.0044 LAB.088.021.0:B
        r H6.088.021.0010 TD.088.021.0001
        s LAB.088.021:ACLR0_SEL ACLR0
        s LAB.088.021:BMODE.0 E_1
        s LAB.088.021:LUT_MASK.0 ffffffff.ffcc00f3
        s LAB.088.021:TDFF1.0 NLUT
        s LAB.088.021:TMODE.0 E_0
        s MLAB.021.049:ACLR0_SEL ACLR0
        s MLAB.021.049:BMODE.3 E_1
        s MLAB.021.049:LUT_MASK.3 ffffffff.ffffffff
        s MLAB.021.049:TMODE.3 E_0
        s MLAB.072.017:ACLR0_SEL ACLR0
        s MLAB.072.017:BMODE.7 E_1
        s MLAB.072.017:LUT_MASK.7 00000000.ffffffff
        s MLAB.072.017:TMODE.7 E_0
        s GPIO.089.011:DRIVE_STRENGTH.0 V3P3_LVTTL_16MA_LVCMOS_2MA ; AA24
        s GPIO.089.011:IOCSR_STD.0 DIS ; AA24
        s GPIO.089.011:USE_WEAK_PULLUP.0 0 ; AA24
        s GPIO.089.021:USE_WEAK_PULLUP.0 0 ; AB30
        s GPIO.089.021:USE_WEAK_PULLUP.2 0 ; AB28
        s GPIO.089.025:USE_WEAK_PULLUP.1 0 ; Y27
        s GPIO.089.025:USE_WEAK_PULLUP.3 0 ; AC30
        s DQS16.089.015:INPUT_REG4_SEL.0 SEL_LOCKED_DPA ; AA24
        s DQS16.089.015:RB_T9_SEL_EREG_CFF_DELAY.0 1f ; AA24
        i HMC.025.000:IOINTDQOE.4 0 ; AG16 ; HMC.025.000:PHYDDIODQOE.4 GPIO.050.000.2:OEIN.0
        i HMC.025.000:IOINTDQOE.0 0 ; AF18 ; HMC.025.000:PHYDDIODQOE.0 GPIO.050.000.1:OEIN.0
        i GPIO.089.011.0:OEIN.0 1 ; AA24
        i GPIO.089.011.0:OEIN.1 0 ; AA24
        """

    static func demoSpec(_ minterms: Set<Int> = [2, 3, 6, 7, 9, 13, 14]) -> BitstreamVerifier.Spec {
        BitstreamVerifier.Spec(inputs: [("w", "PIN_AC30"), ("x", "PIN_AB28"), ("y", "PIN_Y27"), ("z", "PIN_AB30")],
                               outputs: [("f", "PIN_AA24")], expected: { [minterms.contains($0)] })
    }

    static func run(_ check: (Bool, String) -> Void) {
        print("Bitstream verifier (embedded example bitstream)")
        verifierTests(check)
        print("Toolchain locator")
        let off = Toolchain.locate(environment: ["QUARTZITE_NO_TOOLCHAIN": "1"])
        check(off.toolchain == nil && off.disabled, "QUARTZITE_NO_TOOLCHAIN hides the toolchain")
        let none = Toolchain.locate(environment: ["QUARTZITE_YOSYS": "/nonexistent/yosys", "QUARTZITE_NEXTPNR": "/nonexistent/np",
                                                  "QUARTZITE_MISTRAL_CV": "/nonexistent/mcv", "PATH": "/nonexistent",
                                                  "QUARTZITE_TOOLCHAIN": "/nonexistent"])
        // The Homebrew fallback folders may still hold yosys, so only nextpnr/mistral-cv are certain to be missing.
        check(none.toolchain == nil && none.missing.contains { $0.name == "nextpnr-mistral" }, "missing tools are reported (\(none.summary))")
        print("Assembler without the toolchain")
        let logical = CompileFlow.run(TestDesigns.exampleSOP())
        check(logical.run(.assembler)?.status == .skipped && logical.assembly == nil, "no toolchain: Assembler skipped, no .sof")
        let stopped = HardwareConfig(toolchain: Toolchain(yosys: .init(name: "yosys", url: URL(fileURLWithPath: "/nonexistent"), source: "test"),
                                                          nextpnr: .init(name: "nextpnr-mistral", url: URL(fileURLWithPath: "/nonexistent"), source: "test"),
                                                          mistralCV: .init(name: "mistral-cv", url: URL(fileURLWithPath: "/nonexistent"), source: "test")),
                                     outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("qz-stop-\(UUID().uuidString)"))
        stopped.cancel.cancel()
        let st = CompileFlow.run(TestDesigns.exampleSOP(), hardware: stopped)
        check(st.run(.fitter)?.status == .failed && st.messages.contains { $0.text.contains("stopped by the user") }, "Stop Processing before place and route fails the Fitter cleanly")
        try? FileManager.default.removeItem(at: stopped.outputDirectory)
        let skippedReport = ReportText.render(CompileFlow.report(CompileFlow.run(TestDesigns.exampleSOP(), toolchainNote: "NOTE-FOR-TEST")))
        check(skippedReport.contains("Programming file") && skippedReport.contains("None. NOTE-FOR-TEST"),
              "no toolchain: the Assembler report says why there is no programming file")
        #if canImport(SwiftUI)
        MainActor.assumeIsolated { storeWithoutToolchain(check) }
        #endif

        print("Full hardware flow (yosys + nextpnr-mistral + .sof + mistral-cv)")
        let search = Toolchain.locate()
        guard let tc = search.toolchain else {
            print("  skip \(search.summary); the full-flow tests need it (see docs/ASSEMBLER_NOTES.md)")
            return
        }
        if let v = ProcessInfo.processInfo.environment["QUARTZITE_SKIP_HW_SELFTEST"], !v.isEmpty, v != "0" {
            print("  skip QUARTZITE_SKIP_HW_SELFTEST is set")
            return
        }
        for (tool, version) in tc.versions() { print("    \(tool): \(version)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quartzite-hw-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let designs = TestDesigns.all
        var lastState: FlowState?
        for (name, p) in designs {
            let t0 = Date()
            let cfg = HardwareConfig(toolchain: tc, outputDirectory: root.appendingPathComponent(name, isDirectory: true))
            let state = CompileFlow.run(p, hardware: cfg)
            let a = state.assembly
            let n = state.circuit?.inputs.count ?? 0
            check(state.run(.fitter)?.status != .failed && state.pnr != nil,
                  "\(name): Fitter ran place and route" + (state.pnr == nil ? " (\(state.messages.filter { $0.level == .error }.map { $0.text }.joined(separator: "; ")))" : ""))
            guard let a else { check(false, "\(name): Assembler produced a .sof"); continue }
            check(a.passed, "\(name): Assembler verification passed (\(a.check.summary)\(a.failure.map { "; \($0)" } ?? ""))")
            check(a.check.rows == 1 << n && a.check.rowsMatching == a.check.rows,
                  "\(name): decoded truth table equals the schematic simulation on all \(1 << n) rows")
            check(a.check.pins.count == p.inputPins.count + p.outputPins.count && a.check.pins.allSatisfy { $0.ok }, "\(name): all \(a.check.pins.count) pins check out")
            check(a.roundTripIdentical, "\(name): .sof -> .rbf re-extraction keeps every configuration bit")
            if let sof = try? SOFFile(contentsOf: a.sofURL) {
                check(sof.records.count == 11 && sof.storedChecksum == sof.computedChecksum() && sof.storedCRC == sof.computedCRC(),
                      "\(name): .sof has 11 records, checksum \(a.checksumText) and CRC are consistent")
            } else { check(false, "\(name): .sof readable") }
            check(state.run(.assembler)?.status == .warnings && state.summary?.text.hasPrefix("Quartzite Full Compilation was successful") == true,
                  "\(name): Assembler successful (with the experimental-file warning), full compilation successful")
            let report = ReportText.render(CompileFlow.report(state))
            check(report.contains(a.checksumText) && report.contains("EXPERIMENTAL"), "\(name): report shows the checksum and the experimental notice")
            print("    \(name): \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            lastState = state
        }

        print("Assembler edge cases")
        if var st = lastState, var hw = st.hardware {
            let e = st.project.entityName
            // A .sof Quartzite did not write is never overwritten.
            let dir = root.appendingPathComponent("foreign", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let foreign = dir.appendingPathComponent("\(e).sof")
            try? Data("not ours".utf8).write(to: foreign)
            hw.sofURL = foreign
            st.hardware = hw
            let run = CompileFlow.execute(.assembler, state: &st)
            check(run.status == .failed && (try? Data(contentsOf: foreign)) == Data("not ours".utf8),
                  "an existing non-Quartzite .sof is left untouched and the Assembler fails with the reason")
            // --layout 16 (10 records, as Quartus 15.1-16.1 wrote).
            hw.sofURL = dir.appendingPathComponent("layout16.sof")
            hw.sofLayout = 16
            st.hardware = hw
            let r16 = CompileFlow.execute(.assembler, state: &st)
            let s16 = try? SOFFile(contentsOf: dir.appendingPathComponent("layout16.sof"))
            check(r16.status != .failed && s16?.records.count == 10 && st.assembly?.passed == true, "layout 16 writes 10 records and verifies")
            let report = CompileFlow.report(st)
            check(report.contains { $0.find("stage.fitter.pnr.placement") != nil } && report.contains { $0.find("stage.assembler.check") != nil },
                  "report has the nextpnr placement and the Assembler's bitstream check")
        }
        #if canImport(SwiftUI)
        print("App compilation with the open-source Fitter and Assembler")
        MainActor.assumeIsolated { storeWithToolchain(check, root: root) }
        #endif
    }

    #if canImport(SwiftUI)
    /// Waits for the Store's compilation task, servicing the main run loop like the app does.
    @MainActor
    static func wait(_ store: Store, timeout: TimeInterval = 180, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    @MainActor
    static func storeWithoutToolchain(_ check: (Bool, String) -> Void) {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        check(!store.useHardwareFlow && !store.hardwareAvailable, "test stores never run the external tools")
        let (cfg, note) = store.hardwareConfig()
        check(cfg == nil && note?.contains("turned off") == true, "turned off: no hardware config, and the reason is given")
        check(Store.outputDirectory(project: store.project, fileURL: URL(fileURLWithPath: "/tmp/qz/Lab1.qzproj")).path == "/tmp/qz/output_files",
              "a saved project's .sof goes to output_files next to it")
        check(Store.outputDirectory(project: store.project, fileURL: nil).path.hasSuffix("Quartzite/output_files/\(store.project.entityName)")
              || ProcessInfo.processInfo.environment["QUARTZITE_SUPPORT_DIR"] != nil,
              "an unsaved project's .sof goes to Application Support")
        store.startCompilation()
        check(wait(store, timeout: 30) { !store.isProcessing }, "logical compilation finishes")
        check(store.flow?.run(.assembler)?.status == .skipped && store.flow?.toolchainNote?.contains("turned off") == true,
              "turned off: the Assembler is skipped with the reason")
    }

    @MainActor
    static func storeWithToolchain(_ check: (Bool, String) -> Void, root: URL) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("app project", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        store.fileURL = dir.appendingPathComponent("\(store.project.entityName).qzproj")
        store.useHardwareFlow = true
        store.startCompilation()
        check(store.hardwareCancel != nil, "Start Compilation sets up the open-source Fitter and Assembler")
        var streamed = false
        let finished = wait(store) {
            if store.processingStage == .fitter && store.messages.contains(where: { $0.text.hasPrefix("Running nextpnr-mistral") }) { streamed = true }
            return !store.isProcessing
        }
        check(finished, "app compilation finishes")
        check(streamed, "nextpnr progress appears in the Messages pane while the Fitter runs")
        let sof = dir.appendingPathComponent("output_files/\(store.project.entityName).sof")
        check(store.flow?.assembly?.passed == true && store.flow?.assembly?.sofURL.path == sof.path && fm.fileExists(atPath: sof.path),
              "the app writes a verified .sof to output_files next to the project")
        check(store.messages.filter { $0.text.hasPrefix("Running nextpnr-mistral") }.count == 1,
              "streamed messages are replaced, not duplicated, when the stage ends")
        check(store.flow?.summary?.text.hasPrefix("Quartzite Full Compilation was successful") == true && store.tab == .report,
              "full compilation successful; the Compilation Report opens")
        let summary = CompileFlow.report(store.flow!).first { $0.id == "stage.assembler" }?.find("stage.assembler.summary")
        check(summary?.tables.first?.rows.contains { $0 == ["Programming file", sof.path] } == true, "Assembler report names the .sof")
        check(store.toolchainStatus.hasSuffix("on"), "Tasks pane shows the toolchain as on")

        // Stop Processing during place and route terminates nextpnr and keeps the earlier .sof.
        let before = try? Data(contentsOf: sof)
        store.startCompilation()
        let reachedPnR = wait(store, timeout: 60) { store.messages.contains { $0.text.hasPrefix("Running nextpnr-mistral") } || !store.isProcessing }
        let t0 = Date()
        store.stopProcessing()
        let stopped = wait(store, timeout: 30) { !store.isProcessing }
        check(reachedPnR && stopped && Date().timeIntervalSince(t0) < 3, "Stop Processing ends a running nextpnr promptly")
        check(store.flow?.run(.fitter)?.status == .failed && store.flow?.assembly == nil
              && store.messages.contains { $0.text.contains("stopped by the user") },
              "a stopped Fitter fails cleanly and no new .sof is reported")
        check((try? Data(contentsOf: sof)) == before, "the previous .sof is left as it was")
    }
    #endif

    static func verifierTests(_ check: (Bool, String) -> Void) {
        guard let bt = try? DecodedBitstream(text: demoBT) else { check(false, "embedded bitstream parses"); return }
        check(bt.device == "5CSXFC6D6F31C6" && bt.routes.count == 24, "parses the decoded bitstream (\(bt.routes.count) routes)")
        let ok = BitstreamVerifier.check(bt, spec: demoSpec())
        check(ok.passed && ok.rowsMatching == 16 && ok.pins.count == 5, "example bitstream: \(ok.summary)")
        check(ok.almHalves.count == 1 && ok.almHalves[0].block == "LAB.088.021" && !ok.almHalves[0].sixInput, "one top-half 5-LUT in LAB (88,21) ALM 0")
        check(ok.configuredALMs == 3 && ok.configuredLABs == 3, "3 ALMs configured (logic + nextpnr's two constant drivers)")
        let wrong = BitstreamVerifier.check(bt, spec: demoSpec([2, 3, 6, 7, 9, 13]))
        check(!wrong.passed && wrong.rowsMatching == 15, "a different expected function is caught (15/16 rows)")
        func mutated(_ f: (String) -> String) -> BitstreamCheck? {
            (try? DecodedBitstream(text: f(demoBT))).map { BitstreamVerifier.check($0, spec: demoSpec()) }
        }
        let flip = mutated { $0.replacingOccurrences(of: "ffffffff.ffcc00f3", with: "ffffffff.ffcc00f0") }
        check(flip.map { !$0.passed && $0.rowsMatching == 15 } == true, "one flipped LUT entry gives 15/16 rows")
        let half = mutated { $0.replacingOccurrences(of: "ffffffff.ffcc00f3", with: "ffffffff.ffcc00f2") }
        check(half.map { !$0.passed && $0.evaluationError?.contains("unrouted input") == true } == true, "a LUT that depends on an unrouted input is refused")
        let cut = mutated { $0.replacingOccurrences(of: "r TD.088.021.0044 LAB.088.021.0:B\n", with: "") }
        check(cut.map { !$0.passed } == true, "a deleted route is caught")
        let oe = mutated { $0 + "\ni GPIO.089.025.3:OEIN.0 1 ; AC30" }
        check(oe.map { !$0.passed && $0.pins.contains { $0.name == "w" && !$0.ok } } == true, "an output driver on an input pin is caught")
        let stray = mutated { $0 + "\ni GPIO.050.000.2:OEIN.0 1 ; AG16" }
        check(stray.map { !$0.passed && $0.strayDrivenPins == ["AG16"] } == true, "an output driver on a pin outside the design is caught")
        let reg = mutated { $0.replacingOccurrences(of: "TDFF1.0 NLUT", with: "TDFF1.0 FF") }
        check(reg.map { !$0.passed && $0.evaluationError?.contains("register") == true } == true, "a register output is refused (not modelled)")
        check(HardwareFlow.parseConstrain("Info: Constraining IO 'z_MISTRAL_IB_PAD' to pin PIN_AB30 (bel MISTRAL_IO.89.21.0)").map { $0.pin == "PIN_AB30" && $0.bel == "MISTRAL_IO.89.21.0" } == true,
              "parses nextpnr's IO constraint lines")
        check(HardwareFlow.parseUtilLine("Info: \t        MISTRAL_COMB:       3/  83820     0%").map { $0.0 == "MISTRAL_COMB" && $0.1 == 3 && $0.2 == 83820 } == true,
              "parses nextpnr's utilisation lines")
        check(HardwareFlow.yosysStat("4. Printing statistics.\n\n=== demo4 ===\n        6 cells\n        1   MISTRAL_ALUT4\n        4   MISTRAL_IB\n        1   MISTRAL_OB\n").map { "\($0.count) \($0.type)" } == ["1 MISTRAL_ALUT4", "4 MISTRAL_IB", "1 MISTRAL_OB"],
              "parses yosys stat")
        check(HardwareFlow.hex32(0x00AF5432) == "0x00AF5432", "checksum shown in Quartus' format")
    }
}

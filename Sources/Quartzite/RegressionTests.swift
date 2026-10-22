import Foundation

enum RegressionTests {
    static var failures = 0

    static func run() -> Bool {
        failures = 0
        print("Regression checks")
        testMintermSyntaxMustBeFullyValid()
        testExpectedMintermsOutsideTruthTableCannotMatch()
        testInputOrderDoesNotDuplicatePins()
        do { try testDecodedProjectsRejectBrokenReferencesAndDuplicateIDs() }
        catch { check(false, "Project round trip: \(error)") }
        testEntityNamesAndPinWhitespaceAreValidForExport()
        testGeneratedNetNamesAvoidInstancesAndOtherNets()
        testRoutingPreservesBacktrackingForReversalCheck()
        testInputLimitAndUnsafeRoutes()
        testInvalidExpectedIsNotAMatch()
        testMalformedAssignmentsAreRejected()
        testNetlistNamesAndFitterFailures()
        testLabSupportFixes()
        return failures == 0
    }
    static func testMintermSyntaxMustBeFullyValid() {
        assertEqual(Minterms.parse("Σm(1, 3 5, 8–11)"), [1, 3, 5, 8, 9, 10, 11])
        for invalid in ["junk", "1oops2", "-1", "8-2", "1,", "1.5", "m(1", "0-999999999999999999999"] {
            assertNil(Minterms.parse(invalid), invalid)
        }
        assertEqual(Minterms.parse("m()"), [])
    }

    static func testExpectedMintermsOutsideTruthTableCannotMatch() {
        let p = TestDesigns.exampleSOP()
        let c = Compiler.compile(p).0!
        var sim = try! SimulationResult.run(c, project: p)
        sim.expected[0]?.insert(16)
        assertEqual(sim.matches(output: 0), false)
    }

    static func testInputOrderDoesNotDuplicatePins() {
        var p = TestDesigns.exampleSOP()
        let id = p.inputPins[0].id
        p.inputOrder = [id, id, UUID()]
        assertEqual(p.inputPins.count, 4)
        assertEqual(Set(p.inputPins.map(\.id)).count, 4)
    }

    static func testDecodedProjectsRejectBrokenReferencesAndDuplicateIDs() throws {
        let p = TestDesigns.exampleSOP()
        var cases = [Project]()
        var bad = p
        bad.components.append(p.components[0]); cases.append(bad)
        bad = p; bad.wires[0].a.port = -1; cases.append(bad)
        bad = p; bad.wires[0].b.comp = UUID(); cases.append(bad)
        bad = p; bad.wires.append(p.wires[0]); cases.append(bad)
        bad = p; bad.labels[PortRef(comp: p.components[0].id, port: 99).key] = "a"; cases.append(bad)
        for project in cases {
            let data = try JSONEncoder().encode(project)
            assertThrows(try JSONDecoder().decode(Project.self, from: data))
        }
        assertNoThrow(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)))
    }

    static func testEntityNamesAndPinWhitespaceAreValidForExport() {
        var p = TestDesigns.exampleSOP()
        for name in ["module", "and", "123", "é雪", ""] {
            p.name = name
            assertTrue(Compiler.isValidName(p.entityName), p.entityName)
            assertFalse(Compiler.reserved.contains(p.entityName.lowercased()), p.entityName)
        }
        p.components[0].name = " w "
        assertNil(Compiler.compile(p).0)
    }

    static func testGeneratedNetNamesAvoidInstancesAndOtherNets() {
        var p = TestDesigns.exampleSOP()
        let conn = Connectivity(p)
        let internalNet = conn.nets.first { $0.names.isEmpty && $0.ports.allSatisfy { p.component($0.comp)?.kind.isPin == false } }!
        let reservedName = "qz_net\(internalNet.id)"
        p.components[0].name = reservedName
        let renamed = Connectivity(p)
        assertNotEqual(renamed.netName(internalNet.id, project: p), reservedName)
        p.components[0].name = "w"
        let index = p.components.firstIndex { !$0.kind.isPin }!
        p.components[index].name = reservedName
        assertNotEqual(Connectivity(p).netName(internalNet.id, project: p), reservedName)
    }

    static func testRoutingPreservesBacktrackingForReversalCheck() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 16, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 8)]
        assertTrue(Routing.reversesOnItself(Routing.dedupe(path)))
    }

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ok   \(message)" : "  FAIL \(message)")
        if !condition { failures += 1 }
    }
    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = #function) { check(a == b, message) }
    static func assertNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = #function) { check(a != b, message) }
    static func assertNil<T>(_ value: T?, _ message: String = #function) { check(value == nil, message) }
    static func assertNotNil<T>(_ value: T?, _ message: String = #function) { check(value != nil, message) }
    static func assertTrue(_ value: Bool, _ message: String = #function) { check(value, message) }
    static func assertFalse(_ value: Bool, _ message: String = #function) { check(!value, message) }
    static func assertThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = #function) {
        do { _ = try expression(); check(false, message) } catch { check(true, message) }
    }
    static func assertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = #function) {
        do { _ = try expression(); check(true, message) } catch { check(false, message) }
    }

    static func testNetlistNamesAndFitterFailures() {
        var p = TestDesigns.exampleSOP()
        p.name = "qz_lcell_comb"
        p.components[0].name = "qz_cell_0"
        let circuit = Compiler.compile(p).0!
        var synthesis = try! Synthesizer.run(circuit, project: p)
        let text = NetlistWriter.verilog(synthesis, fit: nil, project: p)
        assertTrue(text.contains("module qz_lcell_comb ("), "Top-level keeps its valid project name")
        assertTrue(text.contains("module qz_lcell_comb_model ("), "Behavioral model has a distinct module name")
        assertTrue(text.contains("qz_cell_0_ ("), "Generated LUT instance does not collide with the input port")
        for row in try! SimulationResult.run(circuit, project: p).rows {
            let values = Dictionary(uniqueKeysWithValues: zip(synthesis.inputNames, row.inputs))
            assertEqual(NetlistWriter.simulate(text, inputs: values)?["f"], row.outputs[0], "Renamed netlist still evaluates correctly")
        }
        p.device = "5CEFA7F31C6"
        assertTrue(Fitter.run(project: p, circuit: circuit, synthesis: synthesis).errors > 0,
                   "Fitter rejects a device whose package database is not available")
        p.device = CycloneV.device
        synthesis.resources.alms = CycloneV.totalALMs + 1
        assertTrue(Fitter.run(project: p, circuit: circuit, synthesis: synthesis).errors > 0,
                   "Fitter reports ALM capacity overflow")
        synthesis.resources.alms = 1
        // More unassigned outputs than free non-board balls; no expensive logic is needed.
        var overloaded = circuit
        overloaded.outputs = (0..<CycloneV.pins.count).map { Component(kind: .output, name: "o\($0)", x: 600, y: $0 * 24) }
        assertTrue(Fitter.run(project: p, circuit: overloaded, synthesis: synthesis).errors > 0,
                   "Fitter reports exhausted I/O placement rather than dropping pins")
    }

    static func testMalformedAssignmentsAreRejected() {
        var p = TestDesigns.exampleSOP()
        p.device = ""
        assertNil(Compiler.compile(p).0, "Empty device cannot generate a valid QSF")
        p.device = "5CSXFC6D6F31C6; bad_command"
        assertNil(Compiler.compile(p).0, "Device must be a single Cyclone V part identifier")
        p.device = "5CSXFC6D6F31C6"
        p.components[0].location = "PIN_AC30 -to another_pin"
        assertNil(Compiler.compile(p).0, "Malformed locations are errors instead of export warnings")
    }

    static func testInvalidExpectedIsNotAMatch() {
        var b = TestDesigns.Builder("ConstantZero")
        let input = b.input("a", y: 64)
        let gate = b.gate(.xor2, x: 360, y: 64)
        b.wire(input, to: gate, 0); b.wire(input, to: gate, 1)
        let output = b.output("f", x: 600, y: 80)
        b.wire(gate, to: output, 0)
        b.p.expected[output.id.uuidString] = "junk"
        let sim = try! SimulationResult.run(Compiler.compile(b.p).0!, project: b.p)
        assertEqual(sim.matches(output: 0), false, "Invalid expected minterms cannot report success for an all-zero function")
    }

    static func testInputLimitAndUnsafeRoutes() {
        var b = TestDesigns.Builder("Large")
        for i in 0..<64 { b.input("a\(i)", y: 32 * i) }
        let out = b.output("f", x: 800, y: 0)
        b.wire(b.p.components[0], to: out, 0)
        let circuit = Compiler.compile(b.p).0!
        assertThrows(try SimulationResult.run(circuit, project: b.p), "64-input simulation is rejected before a shift or allocation")
        assertThrows(try QuartusExport.vwf(b.p), "64-input waveform export is rejected")
        assertThrows(try QuartusExport.makeBundle(b.p, conn: circuit.conn), "64-input bundle is rejected")

        b = TestDesigns.Builder("Unsafe")
        b.input("a", y: 64) // Port at (200,72), immediately left of the NOT's input.
        b.input("b", y: 160)
        let gate = b.gate(.not, x: 208, y: 56)
        b.label(b.pin(gate, 0), "b")
        let output = b.output("f", x: 400, y: 64)
        b.wire(gate, to: output, 0)
        assertNotNil(Compiler.compile(b.p).0, "Logical netlist is valid before physical routing")
        assertThrows(try QuartusExport.makeBundle(b.p, conn: Connectivity(b.p)), "Export refuses a forced label stub that shorts a different input")
    }
}

#if canImport(SwiftUI)

extension RegressionTests {
    @MainActor
    static func runEditor() -> Bool {
        failures = 0
        print("Editor regression checks")
        testTextClipboardAndMixedSelection()
        testCutDoesNotDeleteItemsThatCannotBeCopied()
        testNewProjectResetsDocumentState()
        testPinAssignmentTreatsLocationsCaseInsensitively()
        testAutosaveAndFailedSave()
        testCompileCancellationAcrossDocuments()
        return failures == 0
    }
    @MainActor
    static func testTextClipboardAndMixedSelection() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        let id = store.addNote(at: CGPoint(x: 100, y: 200))
        store.setNoteText(id, "Keep this note")
        store.selection = [.text(id)]
        let fragment = store.copySelection()
        assertNotNil(fragment)
        if let fragment { store.paste(fragment) }
        assertEqual(store.project.notes?.count, 2)
        assertEqual(store.project.notes?.last?.text, "Keep this note")
        assertNotEqual(store.project.notes?.last?.id, id)
        let comp = store.project.components[0]
        store.selection = [.comp(comp.id), .text(id)]
        store.nudgeSelected(dx: 8, dy: 8)
        assertEqual(store.project.component(comp.id)?.x, comp.x + 8)
        assertEqual(store.project.notes?.first?.x, 112, "Mixed selection nudges text from its snapped x=104 position")
        store.deleteSelected()
        assertNil(store.project.component(comp.id))
        assertFalse(store.project.notes!.contains { $0.id == id })
        store.undo()
        assertNotNil(store.project.component(comp.id))
        assertTrue(store.project.notes!.contains { $0.id == id })
    }

    @MainActor
    static func testCutDoesNotDeleteItemsThatCannotBeCopied() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        let wire = store.project.wires[0]
        store.selection = [.wire(wire.id)]
        assertNil(store.cutSelection())
        assertTrue(store.project.wires.contains { $0.id == wire.id })
    }

    @MainActor
    static func testNewProjectResetsDocumentState() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        store.fileURL = URL(fileURLWithPath: "/old/project.qzproj")
        store.simulate()
        assertNotNil(store.lastCompile)
        store.newProject(name: "New", device: "5CSXFC6D6F31C6", starterPins: false)
        assertNil(store.fileURL)
        assertNil(store.lastCompile)
        assertNil(store.simulation)
        assertTrue(store.dirty)
    }

    @MainActor
    static func testPinAssignmentTreatsLocationsCaseInsensitively() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        let first = store.project.inputPins[0], second = store.project.inputPins[1]
        store.assign(second.id, to: " pin_ac30 ")
        assertNil(store.project.component(first.id)?.location)
        assertEqual(store.project.component(second.id)?.location, "PIN_AC30")
    }

    @MainActor
    static func testAutosaveAndFailedSave() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quartzite-regression-\(UUID().uuidString)", isDirectory: true)
        let oldSupport = ProcessInfo.processInfo.environment["QUARTZITE_SUPPORT_DIR"]
        setenv("QUARTZITE_SUPPORT_DIR", dir.path, 1)
        defer {
            if let oldSupport { setenv("QUARTZITE_SUPPORT_DIR", oldSupport, 1) }
            else { unsetenv("QUARTZITE_SUPPORT_DIR") }
            try? fm.removeItem(at: dir)
        }
        let store = Store()
        store.project = TestDesigns.exampleSOP()
        let savedURL = dir.appendingPathComponent("saved.qzproj")
        assertNoThrow(try store.saveProject(to: savedURL), "Successful save commits the file URL")
        assertFalse(Store().dirty, "Saved autosave restores as clean")
        store.mutate { $0.name = "Edited" }
        let restored = Store()
        assertTrue(restored.dirty, "Unsaved edits restore as dirty")
        assertEqual(restored.fileURL, savedURL, "Restored edits retain the correct document URL")
        let impossible = dir.appendingPathComponent("missing/subdir/file.qzproj")
        assertThrows(try store.saveProject(to: impossible), "Failed Save As reports an error")
        assertEqual(store.fileURL, savedURL, "Failed Save As retains the previous document URL")
        assertTrue(store.dirty, "Failed Save As retains unsaved state")
        store.newProject(name: "Empty", device: "5CSXFC6D6F31C6", starterPins: false)
        var emptyRestored = Store()
        assertEqual(emptyRestored.project.name, "Empty", "Empty projects restore instead of resurrecting the old document")
        assertNil(emptyRestored.fileURL, "New project autosave is not associated with the previous file")
        let note = store.addNote(at: CGPoint(x: 3000, y: 2000))
        store.setNoteText(note, "Only text")
        emptyRestored = Store()
        assertEqual(emptyRestored.project.notes?.first?.text, "Only text", "Text-only projects survive session restore")
        assertTrue(emptyRestored.canvasSize.width > 3000, "Canvas includes notes outside the symbol bounds")
    }


    @MainActor
    static func testCompileCancellationAcrossDocuments() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        store.startCompilation()
        let oldTask = store.flowTask!
        store.newProject(name: "Replacement", device: CycloneV.device, starterPins: false)
        assertTrue(oldTask.isCancelled, "Replacing a document cancels its compilation")
        assertFalse(store.isProcessing, "Document replacement releases the active task immediately")
        store.project = TestDesigns.tricky()
        store.compile()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        assertEqual(store.flow?.project.entityName, "Tricky", "An obsolete compilation cannot overwrite the replacement document's results")
        assertEqual(store.tab, .bdf, "An obsolete task cannot switch the new document to its report")
    }

}
#endif

extension RegressionTests {
    static func testLabSupportFixes() {
        testExportWritesIOStandards()
        testCompileLayoutIsCheckedUpFront()
    }

    /// A bad --layout used to surface only after place and route, or not at all.
    static func testCompileLayoutIsCheckedUpFront() {
        for bad in ["abc", "99", "15", "--seed", ""] {
            assertThrows(try CLI.layoutOption(["Quartzite", "--compile", "a.qzproj", "--sof", "a.sof", "--layout"] + (bad.isEmpty ? [] : [bad])),
                         "--compile --layout \(bad.isEmpty ? "(missing)" : bad) is refused before any work")
        }
        for good in [14, 16, 17] {
            assertEqual(try? CLI.layoutOption(["--compile", "a.qzproj", "--layout", "\(good)"]), good, "--compile --layout \(good) is accepted")
        }
        do { assertNil(try CLI.layoutOption(["--compile", "a.qzproj"]), "no --layout keeps the default") }
        catch { check(false, "no --layout keeps the default") }
    }

    /// Quartus compiles a pin without IO_STANDARD as 2.5 V; the LEDs and HEX displays are 3.3-V LVTTL.
    static func testExportWritesIOStandards() {
        var p = TestDesigns.exampleSOP()
        let unplaced = Component(kind: .output, name: "unplaced", x: 800, y: 400)
        p.components.append(unplaced)
        p.wires.append(Wire(a: PortRef(comp: p.inputPins[0].id, port: 0), b: PortRef(comp: unplaced.id, port: 0)))
        guard let bundle = try? QuartusExport.makeBundle(p, conn: Connectivity(p)) else { check(false, "IO_STANDARD fixture exports"); return }
        for file in ["\(p.entityName).qsf", "\(p.entityName)_pins.qsf"] {
            guard let text = bundle.files.first(where: { $0.name == file })?.contents else { check(false, "\(file) exported"); continue }
            let lines = text.split(separator: "\n").map(String.init)
            for pin in p.inputPins + p.outputPins {
                guard let board = BoardPin.lookup(pin.location) else {
                    assertFalse(lines.contains { $0.hasPrefix("set_instance_assignment -name IO_STANDARD") && $0.hasSuffix(" -to \(pin.name)") },
                                "\(file): no IO_STANDARD for unassigned pin \(pin.name)")
                    continue
                }
                assertTrue(lines.contains("set_instance_assignment -name IO_STANDARD \"\(board.ioStandard)\" -to \(pin.name)"),
                           "\(file): \(pin.name) on \(board.label) gets IO_STANDARD \"\(board.ioStandard)\"")
            }
            assertTrue(lines.contains("set_instance_assignment -name IO_STANDARD \"3.3-V LVTTL\" -to f"), "\(file): LEDR0 output is 3.3-V LVTTL")
            let lastLocation = lines.lastIndex { $0.hasPrefix("set_location_assignment") } ?? -1
            let firstStandard = lines.firstIndex { $0.contains("-name IO_STANDARD") } ?? -1
            assertTrue(firstStandard > lastLocation, "\(file): IO_STANDARD lines follow the locations, as Quartus saves them")
        }
    }
}

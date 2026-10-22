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
        testMultiSheetStore()
        testLegacyAutosaveRestores()
        testSheetTabsAndFileCommands()
        testInsertSymbolRefusesRecursion()
        testMessagesLocateTheirSheet()
        testPinPlannerAssignsFromCleanStart()
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

    @MainActor
    static func testMultiSheetStore() {
        let store = Store(persist: false)
        store.project = TestDesigns.exampleSOP()
        assertEqual(store.design.topLevelEntity, "Example", "Setting the only sheet sets the top-level entity")
        assertEqual(store.design.name, "Example", "Setting the only sheet sets the project name")
        let d = HierarchySelfTest.haFA()
        store.loadDesign(d, from: nil, dirty: false)
        assertEqual(store.project.entityName, "FA", "A loaded design opens its top-level sheet")
        assertEqual(store.topProject.entityName, "FA")
        store.activeSheetID = store.design.sheet(named: "HA")!.id!
        assertEqual(store.project.entityName, "HA", "The Block Editor shows the active sheet")
        assertEqual(store.topProject.entityName, "FA", "The top sheet does not follow the active sheet")
        let before = store.project.components.count
        store.mutate { $0.components.append(Component(kind: .input, name: "extra", x: 32, y: 400)) }
        assertEqual(store.project.components.count, before + 1, "mutate edits the active sheet")
        assertEqual(store.design.sheet(named: "FA")?.components.count, d.sheet(named: "FA")?.components.count, "mutate leaves other sheets alone")
        store.mutate { $0.name = "HALF" }
        assertEqual(store.design.sheet(named: "HALF")?.id, d.sheet(named: "HA")?.id, "Renaming the active sheet keeps its id")
        assertTrue(store.design.sheet(named: "FA")!.components.filter { $0.kind == .block }.allSatisfy { $0.symbol?.name == "HALF" },
                   "Renaming the active sheet renames its block instances")
        assertEqual(store.design.topLevelEntity, "FA", "Renaming another sheet keeps the top-level entity")
        let x = store.topProject.inputPins[0]
        store.assign(x.id, to: "pin_ab30")
        assertEqual(store.design.sheet(named: "FA")?.component(x.id)?.location, "PIN_AB30", "Pin assignments go to the top sheet")
        store.undo()
        assertNil(store.design.sheet(named: "FA")?.component(x.id)?.location, "Undo reverts a top-sheet assignment")
        store.undo()
        assertEqual(store.project.entityName, "HA", "Undo reverts the rename")
        store.activeSheetID = store.design.sheet(named: "FA")!.id!
        store.undo()
        assertEqual(store.project.entityName, "HA", "Undo returns to the sheet that was edited")
        assertEqual(store.project.components.count, before, "Undo reverts the edit on that sheet")
        store.redo()
        assertEqual(store.design.sheet(named: "HA")?.components.count, before + 1, "Redo repeats it")
        store.mutateDesign { _ = try? $0.addSheet(named: "Spare") }
        assertEqual(store.design.sheets.count, 3, "mutateDesign adds a sheet")
        store.undo()
        assertEqual(store.design.sheets.count, 2, "Undo removes it again")
    }

    /// Document tabs, Hierarchy Up and the File / Edit / Project commands for sheets (plan 6.1-6.2).
    @MainActor
    static func testSheetTabsAndFileCommands() {
        let store = Store(persist: false)
        store.loadDesign(HierarchySelfTest.haFA(), from: nil, dirty: false)
        let fa = store.design.sheet(named: "FA")!.id!, ha = store.design.sheet(named: "HA")!.id!
        assertEqual(store.openSheetIDs, [fa], "A loaded design opens one tab, its top-level file")
        let blocks = store.project.components.filter { $0.kind == .block }
        assertTrue(store.openBlock(blocks[1].id), "Double-clicking a block opens its file")
        assertEqual(store.activeSheetID, ha, "The block's sheet is shown")
        assertEqual(store.openSheetIDs, [fa, ha], "in a new tab")
        assertEqual(store.hierarchyTrail.map(\.instance), [blocks[1].id], "and the instance is remembered")
        assertTrue(store.hierarchyUp(), "Hierarchy Up goes back")
        assertEqual(store.activeSheetID, fa, "to the parent file")
        assertEqual(store.selection, [.comp(blocks[1].id)], "with the same instance selected")
        assertTrue(store.hierarchyTrail.isEmpty, "and the trail is used up")
        store.openSheet(ha)
        assertTrue(store.hierarchyTrail.isEmpty, "Opening a file from its tab has no trail")
        assertTrue(store.hierarchyUp(), "Hierarchy Up without a trail")
        assertEqual(store.selection, [.comp(blocks[0].id)], "selects the first instance that uses the file")
        store.closeSheet(ha)
        assertEqual(store.openSheetIDs, [fa], "Closing a tab")
        store.closeSheet(fa)
        assertEqual(store.openSheetIDs, [fa], "The last tab can't be closed")

        store.openSheet(ha)
        store.mutate { $0.notes = [TextNote(text: "half", x: 40, y: 400)] }
        assertEqual(store.dirtySheets, [ha], "Only the edited file gets an asterisk")
        assertThrows(try store.newSheet(named: "ha"), "File > New refuses a name in use (any case)")
        assertThrows(try store.newSheet(named: "7447"), "File > New refuses an invalid name")
        assertNoThrow(try store.newSheet(named: "Spare"), "File > New > Block Diagram/Schematic File")
        let spare = store.design.sheet(named: "Spare")?.id
        assertEqual(store.activeSheetID, spare, "opens the new file")
        assertEqual(store.openSheetIDs.count, 3, "in its own tab")
        store.mutate {
            $0.components.append(Component(kind: .input, name: "a", x: 32, y: 64))
            $0.components.append(Component(kind: .output, name: "y", x: 400, y: 64))
        }
        let report = store.createSymbolFiles()
        assertEqual(report.summary, "Created Spare.bsf; updated 0 instances", "Create Symbol Files for Current File")
        assertEqual(EditorState.shared.status, report.summary, "reports in the status bar")
        assertEqual(store.design.sheet(named: "Spare")?.symbol?.ports.map(\.name), ["a", "y"], "and makes the symbol")
        store.setTopLevel("Spare")
        assertEqual(store.design.topLevelEntity, "Spare", "Set as Top-Level Entity")
        assertEqual(store.topProject.entityName, "Spare", "changes the design's pins")
        store.undo()
        assertEqual(store.design.topLevelEntity, "FA", "and can be undone")
        assertThrows(try store.removeSheet(ha), "A file used as a block can't be removed")
        assertThrows(try store.removeSheet(fa), "The top-level file can't be removed")
        assertNoThrow(try store.removeSheet(spare!), "Remove File from Project")
        assertFalse(store.openSheetIDs.contains(spare!), "closes its tab")
        assertNoThrow(try store.renameSheet(ha, to: "HALF"), "Rename...")
        assertTrue(store.design.sheet(named: "FA")!.components.filter { $0.kind == .block }.allSatisfy { $0.symbol?.name == "HALF" },
                   "renames its block instances")

        // Edit > Update Symbol or Block: give HALF a new pin and a new symbol without updating FA.
        store.openSheet(ha)
        store.mutate { $0.components.append(Component(kind: .input, name: "en", x: 32, y: 400)) }
        store.mutateDesign { d in
            let i = d.sheetIndex(id: ha)!
            d.sheets[i].symbol = SymbolGenerator.symbol(for: d.sheets[i])
        }
        assertEqual(store.design.staleInstances().count, 2, "Both FA blocks are out of date")
        store.openSheet(fa)
        store.selection = [.comp(blocks[0].id)]
        let one = store.updateSymbols(.selected)
        assertEqual(store.design.staleInstances().map(\.component.id), [blocks[1].id], "Updating the selected block updates only it (\(one))")
        store.selection = []
        store.updateSymbols(.all)
        assertTrue(store.design.staleInstances().isEmpty, "Updating all blocks in the file updates the other one")
        assertTrue(store.project.components.filter { $0.kind == .block }.allSatisfy { $0.portIndex(named: "en") != nil },
                   "and both have the new port")
    }

    /// Insert Symbol and paste refuse blocks that would make a sheet contain itself (plan 6.3).
    @MainActor
    static func testInsertSymbolRefusesRecursion() {
        let store = Store(persist: false)
        var d = HierarchySelfTest.haFA()
        assertNoThrow(try d.addSheet(named: "Top"), "a third sheet")
        let top = d.sheet(named: "Top")!.id!
        assertNoThrow(try d.placeBlock("FA", inSheet: top, x: 200, y: 100), "Top uses FA")
        store.loadDesign(d, from: nil, dirty: false)
        let fa = d.sheet(named: "FA")!.id!, ha = d.sheet(named: "HA")!.id!

        store.openSheet(ha)
        assertNotNil(store.placementProblem(.block("HA")), "Insert Symbol: HA can't go into HA")
        assertNotNil(store.placementProblem(.block("FA")), "Insert Symbol: FA can't go into HA, which FA contains")
        assertFalse(store.place(.block("FA"), at: CGPoint(x: 400, y: 400)), "placing FA in HA is refused")
        assertTrue(EditorState.shared.status?.contains("contain itself") == true, "with the reason in the status bar")
        assertEqual(store.project.components.count, d.sheet(named: "HA")!.components.count, "and nothing is added")
        assertTrue(store.place(.macro("7447"), at: CGPoint(x: 600, y: 300)), "a library macro can be placed")
        assertEqual(store.project.components.last?.symbolName, "7447", "as a 7447")
        assertTrue(store.place(.primitive(.vcc), at: CGPoint(x: 600, y: 100)), "VCC can be placed")

        store.openSheet(top)
        store.repeatInsert = true
        store.tool = .place(.block("HA"))
        let before = store.project.components.count
        assertTrue(store.place(.block("HA"), at: CGPoint(x: 500, y: 400)), "a project block can be placed")
        assertTrue(store.place(.block("HA"), at: CGPoint(x: 500, y: 600)), "twice with repeat-insert")
        assertEqual(store.tool, .place(.block("HA")), "and the tool stays on HA")
        let placed = store.project.components.suffix(2)
        assertEqual(store.project.components.count, before + 2, "two HA blocks were added")
        assertTrue(placed.allSatisfy { $0.kind == .block && $0.symbol == store.design.sheet(named: "HA")?.symbol }, "with HA's symbol")
        assertEqual(Set(placed.map(\.name)).count, 2, "and different instance names")
        store.repeatInsert = false
        store.selection = [.comp(placed.first!.id)]
        assertFalse(store.canApply(.rotate90) || store.canApply(.flipy), "blocks can't be rotated or flipped")
        assertTrue(store.selectionHasFixedOrientation, "and say why")

        // Copy the FA block from Top and paste it into HA and into FA.
        let faBlock = store.project.components.first { $0.symbolName == "FA" }!
        store.selection = [.comp(faBlock.id)]
        let fragment = store.copySelection()!
        store.openSheet(ha)
        let haCount = store.project.components.count
        store.paste(fragment)
        assertEqual(store.project.components.count, haCount, "pasting FA into HA leaves it out")
        assertTrue(EditorState.shared.status?.contains("contain itself") == true, "and says why")
        store.openSheet(fa)
        let faCount = store.project.components.count
        store.paste(fragment)
        assertEqual(store.project.components.count, faCount, "pasting FA into FA leaves it out")
        // A fragment with an allowed block and a gate keeps both; only the recursive block is dropped.
        let haBlock = store.project.components.first { $0.kind == .block }!
        let gate = store.project.components.first { $0.kind.isGate }!
        store.selection = [.comp(haBlock.id), .comp(gate.id)]
        let mixed = store.copySelection()!
        store.openSheet(top)
        let topCount = store.project.components.count
        store.paste(mixed)
        assertEqual(store.project.components.count, topCount + 2, "pasting HA and a gate into Top keeps both")
        store.openSheet(ha)
        store.paste(mixed)
        assertEqual(store.project.components.count, haCount + 1, "pasting them into HA keeps only the gate")
    }

    /// Double-clicking a message opens the sheet its component is on (plan 6.5).
    @MainActor
    static func testMessagesLocateTheirSheet() {
        let store = Store(persist: false)
        let d = HierarchySelfTest.haFA()
        store.loadDesign(d, from: nil, dirty: false)
        let ha = d.sheet(named: "HA")!, gate = ha.components.first { $0.kind.isGate }!
        let m = Message(level: .warning, text: "test", component: gate.id, sheet: "HA")
        assertEqual(store.sheetID(for: m), ha.id, "A message names the sheet its component is on")
        assertTrue(store.locate(m), "Double-clicking it")
        assertEqual(store.activeSheetID, ha.id, "opens that sheet")
        assertEqual(store.selection, [.comp(gate.id)], "and selects the component")
        let topPin = d.top!.inputPins[0]
        assertTrue(store.locate(Message(level: .info, text: "pin", component: topPin.id)), "A message without a sheet")
        assertEqual(store.activeSheetID, d.top!.id, "is about the top-level sheet")
        assertFalse(store.locate(Message(level: .info, text: "none")), "A message without a component locates nothing")
    }

    /// Clears the top-level pin locations of `d` and assigns them again with the Pin Planner's
    /// actions only: Assign Switches, Assign 7-Segment Digit and board clicks (each click
    /// assigns the selected node and selects the next unassigned one). Nothing is typed.
    @MainActor
    static func replayPinAssignments(_ d: DesignProject) -> (actions: Int, pins: Int, wrong: [String]) {
        let store = Store(persist: false)
        store.loadDesign(d, from: nil, dirty: false)
        let pins = store.pinPlannerPins
        let original = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0.location.flatMap(BoardPin.lookup)) })
        store.mutateTop { p in for i in p.components.indices where p.components[i].kind.isPin { p.components[i].location = nil } }
        var actions = 0
        func number(_ label: String, after prefix: String) -> Int? {
            label.hasPrefix(prefix) ? Int(label.dropFirst(prefix.count).prefix { $0.isNumber }) : nil
        }
        // Outputs whose segments all sat on one display, segment k on HEXd[k].
        for g in store.sevenSegmentGroups {
            let places = g.segments.map { k, id -> (Int, Int)? in
                guard let b = original[id] ?? nil, b.kind == .sevenSegment, let dd = number(b.label, after: "HEX"),
                      b.label.hasSuffix("[\(k)]") else { return nil }
                return (dd, k)
            }
            let digits = Set(places.compactMap { $0?.0 })
            if digits.count == 1, !places.contains(where: { $0 == nil }) {
                store.assignSevenSegment(prefix: g.prefix, digit: digits.first!)
                actions += 1
            }
        }
        // Runs of inputs (MSB first) that sat on consecutive switches going down.
        var run: [UUID] = [], runStart = 0
        func flush() {
            if !run.isEmpty, store.assignSwitches(run, from: runStart) { actions += 1 }
            run = []
        }
        for p in store.topProject.inputPins {
            guard let b = original[p.id] ?? nil, b.kind == .slideSwitch, let n = number(b.label, after: "SW") else { flush(); continue }
            if run.isEmpty || n != runStart - run.count { flush(); runStart = n }
            run.append(p.id)
        }
        flush()
        // Board clicks for the rest, starting at the first unassigned node in Node Name order.
        let order = store.pinPlannerPins.map(\.id)
        var selected = order.first { (store.topProject.component($0)?.location ?? "").isEmpty }
        var seen = Set<UUID>()
        while let sel = selected, seen.insert(sel).inserted {
            if let b = original[sel] ?? nil {
                store.assign(sel, to: b.pin)
                actions += 1
            }
            selected = store.nextUnassignedPin(after: sel, in: order)
        }
        let wrong = store.pinPlannerPins.filter { $0.location != (original[$0.id] ?? nil)?.pin }.map(\.name)
        return (actions, pins.count, wrong)
    }

    /// Pin Planner actions for designs with many pins (plan 6.6).
    @MainActor
    static func testPinPlannerAssignsFromCleanStart() {
        assertEqual(Store.segment(of: "hex5_3")?.prefix, "hex5_", "hex5_3 is a segment of hex5_")
        assertEqual(Store.segment(of: "hex5_3")?.segment, 3, "segment 3")
        assertEqual(Store.segment(of: "seg_c")?.segment, 2, "seg_c is segment 2")
        assertNil(Store.segment(of: "z10"), "z10 is not a segment")
        assertNil(Store.segment(of: "neg"), "neg is not a segment")
        assertNil(Store.segment(of: "h7"), "7 is not a segment")

        let d = TestDesigns.addSub4Display()
        let store = Store(persist: false)
        store.loadDesign(d, from: nil, dirty: false)
        let names = store.pinPlannerPins.map(\.name)
        assertTrue(names.firstIndex(of: "hex0_1")! < names.firstIndex(of: "hex4_0")!, "Node Name sorts naturally (hex0_1 before hex4_0)")
        let groups = store.sevenSegmentGroups.map(\.prefix)
        assertTrue(["hex0_", "hex4_", "hex5_"].allSatisfy(groups.contains), "the three displays are offered (\(groups))")
        store.mutateTop { p in for i in p.components.indices where p.components[i].kind.isPin { p.components[i].location = nil } }
        assertEqual(store.assignSevenSegment(prefix: "hex4_", digit: 2), 7, "Assign 7-Segment Digit assigns seven pins")
        let hex4 = store.topProject.outputPins.filter { $0.name.hasPrefix("hex4_") }
        assertTrue(hex4.allSatisfy { BoardPin.lookup($0.location)?.label == "HEX2[\($0.name.last!)]" }, "segment k goes to HEX2[k]")
        store.undo()
        assertTrue(store.topProject.outputPins.allSatisfy { $0.location == nil }, "in one undo step")
        let ins = store.topProject.inputPins.map(\.id)
        assertFalse(store.assignSwitches(ins, from: 5), "Assign Switches refuses inputs that don't fit below the start")
        assertTrue(store.assignSwitches(Array(ins.prefix(3)), from: 9), "Assign Switches")
        assertEqual(ins.prefix(3).map { BoardPin.lookup(store.topProject.component($0)?.location)?.label ?? "" }, ["SW9", "SW8", "SW7"],
                    "puts the inputs on SW9, SW8, SW7")
        assertTrue(store.assignSwitches([ins[3]], from: 9), "Assigning another input to SW9")
        assertNil(store.topProject.component(ins[0])?.location, "takes SW9 from the first")
        let order = store.pinPlannerPins.map(\.id)
        assertEqual(store.nextUnassignedPin(after: ins[3], in: order).flatMap { store.topProject.component($0)?.location }, nil,
                    "the next unassigned node has no location")

        let replay = replayPinAssignments(d)
        assertTrue(replay.wrong.isEmpty, "addsub4_display: all \(replay.pins) pins assigned from a clean start with \(replay.actions) Pin Planner actions (wrong: \(replay.wrong))")
        // Designs from QUARTZITE_EXTRA_DESIGNS get the same check.
        if let dir = ProcessInfo.processInfo.environment["QUARTZITE_EXTRA_DESIGNS"], !dir.isEmpty,
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files.sorted() where f.hasSuffix(".qzproj") {
                guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(f)),
                      let x = try? DesignProject.load(data) else { check(false, "\(f) loads"); continue }
                let r = replayPinAssignments(x)
                assertTrue(r.wrong.isEmpty, "\(f): all \(r.pins) pins assigned from a clean start with \(r.actions) Pin Planner actions (wrong: \(r.wrong))")
            }
        }
    }

    @MainActor
    static func testLegacyAutosaveRestores() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quartzite-autosave-\(UUID().uuidString)", isDirectory: true)
        let oldSupport = ProcessInfo.processInfo.environment["QUARTZITE_SUPPORT_DIR"]
        setenv("QUARTZITE_SUPPORT_DIR", dir.path, 1)
        defer {
            if let oldSupport { setenv("QUARTZITE_SUPPORT_DIR", oldSupport, 1) }
            else { unsetenv("QUARTZITE_SUPPORT_DIR") }
            try? fm.removeItem(at: dir)
        }
        struct LegacyAutosave: Codable { var project: Project; var url: URL?; var dirty: Bool? }
        let url = URL(fileURLWithPath: "/tmp/legacy/Example.qzproj")
        let legacy = LegacyAutosave(project: TestDesigns.exampleSOP(), url: url, dirty: false)
        assertNoThrow(try JSONEncoder().encode(legacy).write(to: Store.supportDirectory.appendingPathComponent("autosave.json")),
                      "Legacy autosave written")
        let store = Store()
        assertEqual(store.project.entityName, "Example", "A pre-hierarchy autosave restores its project")
        assertEqual(store.project.components.count, legacy.project.components.count, "with all of its components")
        assertEqual(store.design.sheets.count, 1, "as a one-sheet design")
        assertEqual(store.fileURL, url, "with its file URL")
        assertFalse(store.dirty, "and its saved state")
        store.loadDesign(HierarchySelfTest.haFA(), from: nil, dirty: true)
        store.activeSheetID = store.design.sheet(named: "HA")!.id!
        store.mutate { $0.notes = [TextNote(text: "half", x: 40, y: 400)] }
        let again = Store()
        assertEqual(again.design.sheets.count, 2, "A multi-sheet autosave restores every sheet")
        assertEqual(again.project.entityName, "HA", "and the active sheet")
        assertEqual(again.design.topLevelEntity, "FA", "and the top-level entity")
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

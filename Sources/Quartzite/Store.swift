#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Block Editor selection and tools (editor branch; see Store+Editor.swift)
/// A selected symbol/pin, wire, named node stub (a net label on a port) or free text.
enum Selection: Hashable { case comp(UUID), wire(UUID), node(PortRef), text(UUID) }
/// Block Editor tools, named like the Quartus toolbar buttons.
enum Tool: Equatable { case select, zoom, hand, text, node, place(GateKind) }

/// Document tabs, named like the windows they mirror in Quartus.
enum DocTab: String, CaseIterable, Identifiable {
    case bdf, pins, assignments, waveform, report
    var id: String { rawValue }
    func title(_ p: Project) -> String {
        switch self {
        case .bdf: return "\(p.entityName).bdf"
        case .pins: return "Pin Planner"
        case .assignments: return "Assignment Editor"
        case .waveform: return "Waveform.vwf"
        case .report: return "Compilation Report"
        }
    }
    var icon: String {
        switch self {
        case .bdf: return "square.grid.3x3.square"
        case .pins: return "cpu"
        case .assignments: return "list.bullet.rectangle"
        case .waveform: return "waveform.path"
        case .report: return "doc.text.magnifyingglass"
        }
    }
}

enum TaskState { case notRun, running, ok, warning, failed }

/// Modal property dialogs (Quartus opens these on double-click).
enum PropertySheet: Identifiable {
    case symbolLibrary(at: CGPoint)
    case pin(UUID)
    case symbol(UUID)
    case node(PortRef)
    case newProject
    case device
    var id: String {
        switch self {
        case .symbolLibrary: return "lib"
        case .pin(let u): return "pin\(u)"
        case .symbol(let u): return "sym\(u)"
        case .node(let r): return "node\(r.key)"
        case .newProject: return "new"
        case .device: return "device"
        }
    }
}

@MainActor @Observable
final class Store {
    /// The whole project: every .bdf sheet, the top-level entity and the device.
    var design = DesignProject(single: Project()) { didSet { designChanged() } }
    /// The sheet shown in the Block Editor.
    var activeSheetID = UUID() { didSet { if activeSheetID != oldValue { refreshRouting() } } }
    /// Sheets with an open .bdf tab, in tab order.
    var openSheetIDs: [UUID] = []
    /// Blocks the user descended into (Hierarchy Up returns along it).
    var hierarchyTrail: [(sheet: UUID, instance: UUID)] = []
    var fileURL: URL?
    var dirty = false
    var selection: Set<Selection> = []
    var tool: Tool = .select
    var repeatInsert = false
    var tab: DocTab = .bdf
    var zoom: CGFloat = 1.0
    var messages: [Message] = []
    var compiled: CompiledCircuit?
    var simulation: SimulationResult?
    var compileIsStale = true
    var lastCompile: Date?
    var exportedTo: URL?
    var sheet: PropertySheet?
    // MARK: Block Editor state (editor branch)
    /// Text typed on a selected node before its Node Properties dialog opened (Quartus: select a node and type).
    var editorPendingName: String? = nil
    /// Switch positions in the board preview, keyed by input pin id.
    var boardInputs: [UUID: Bool] = [:]
    // MARK: Compile flow state (compiler branch; see Store+Compile.swift)
    /// Results of the last compilation task (feeds the Compilation Report and Pin Planner).
    var flow: FlowState?
    var stageStatus: [FlowStage: StageStatus] = [:]
    var stageElapsed: [FlowStage: TimeInterval] = [:]
    var processingStage: FlowStage?
    var processingStarted: Date?
    var processingEnded: Date?
    var processingProgress: Double = 0
    /// Messages pane "System" tab (file operations); `messages` is the "Processing" tab.
    var systemMessages: [Message] = []
    var reportSelection: String? = "flow.summary"
    var projectVersion = 0
    var flowTask: Task<Void, Never>?
    var flowGeneration = UUID()
    /// Processing > Use Open-Source Fitter and Assembler. Remembered between launches; always
    /// off for test stores, so self-tests never start the external tools.
    var useHardwareFlow = false {
        didSet { if persist { UserDefaults.standard.set(useHardwareFlow, forKey: Store.hardwareFlowKey) } }
    }
    static let hardwareFlowKey = "useOpenSourceFitterAssembler"
    /// The last toolchain search (refreshed at the start of every compilation).
    var toolchainSearch = Toolchain.Search(toolchain: nil, missing: [])
    /// Lets Stop Processing terminate the external tool that is running.
    var hardwareCancel: ProcessCancel?
    /// Identifies the stage whose tool output is being streamed into `messages` from `liveStart` on.
    var liveStage: UUID?
    var liveStart = 0
    private(set) var routing: Routing
    private var undoStack: [(design: DesignProject, sheet: UUID)] = []
    private var redoStack: [(design: DesignProject, sheet: UUID)] = []
    private var suppressChange = false
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let p = Project()
        routing = Routing(project: p, conn: Connectivity(p))
        activeSheetID = design.sheets[0].id!
        openSheetIDs = [activeSheetID]
        if persist {
            toolchainSearch = Toolchain.shared
            useHardwareFlow = UserDefaults.standard.object(forKey: Store.hardwareFlowKey) as? Bool ?? true
        }
        if persist, let restored = Store.loadAutosave() {
            suppressChange = true
            design = restored.design
            activeSheetID = restored.activeSheet
            openSheetIDs = [activeSheetID]
            fileURL = restored.url
            dirty = restored.dirty ?? true
            suppressChange = false
            refreshRouting()
            systemMessages = [Message(level: .info, text: "Restored your last session")]
        } else {
            systemMessages = [Message(level: .info, text: "Double-click the canvas to insert a symbol, or use the Starter Pins button to start.")]
        }
    }

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? design.name }

    // MARK: - Sheets

    private var activeIndex: Int { design.sheetIndex(id: activeSheetID) ?? design.topIndex ?? 0 }
    private var topIndex: Int { design.topIndex ?? activeIndex }

    /// The sheet open in the Block Editor. Setting a sheet with another entity name renames
    /// it (with its symbol and block instances); a one-sheet design also takes the sheet's
    /// name as its project name, top-level entity and device.
    var project: Project {
        get { design.sheets[activeIndex] }
        set { design = Store.replacingSheet(activeIndex, with: newValue, in: design) }
    }

    /// The top-level entity's sheet: its pins are the design's pins.
    var topProject: Project { design.top ?? project }

    static func replacingSheet(_ i: Int, with p: Project, in design: DesignProject) -> DesignProject {
        var d = design
        let old = d.sheets[i]
        var p = p
        p.id = old.id
        d.sheets[i] = p
        if p.entityName != old.entityName { d.renameReferences(from: old.entityName, sheet: i) }
        if d.sheets.count == 1 {
            d.name = p.name
            d.topLevelEntity = p.entityName
            d.device = p.device
        }
        return d
    }

    var canvasSize: CGSize {
        let frames = project.components.map { $0.frame } + (project.notes ?? []).map { $0.frame }
        let maxX = frames.map { $0.maxX }.max() ?? 0
        let maxY = frames.map { $0.maxY }.max() ?? 0
        return CGSize(width: max(2000, maxX + 600), height: max(1400, maxY + 500))
    }

    // MARK: - Task flow (Quartus "Tasks" pane)

    var analysisState: TaskState {
        guard !compileIsStale else { return .notRun }
        if compiled == nil { return .failed }
        return messages.contains { $0.level == .warning } ? .warning : .ok
    }

    var pinState: TaskState {
        let pins = topProject.inputPins + topProject.outputPins
        if pins.isEmpty { return .notRun }
        return pins.allSatisfy { !($0.location ?? "").isEmpty } ? .ok : .warning
    }

    var simulationState: TaskState {
        guard let s = simulation else { return .notRun }
        let checks = s.outputNames.indices.compactMap { s.matches(output: $0) }
        if checks.contains(false) { return .failed }
        return .ok
    }

    var exportState: TaskState { exportedTo == nil ? .notRun : .ok }

    // MARK: - Mutation & undo

    private func designChanged() {
        guard !suppressChange else { return }
        dirty = true
        if isProcessing { resetFlow() }
        projectVersion += 1
        compileIsStale = true
        simulation = nil
        compiled = nil
        exportedTo = nil
        refreshRouting()
        autosave()
    }

    func refreshRouting() { routing = Routing(project: project, conn: Connectivity(project)) }

    func checkpoint() {
        undoStack.append((design, activeSheetID))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func mutate(_ change: (inout Project) -> Void) {
        checkpoint()
        var p = project
        change(&p)
        project = p
    }

    /// An undoable change to the whole design (sheets, top-level entity, device).
    func mutateDesign(_ change: (inout DesignProject) -> Void) {
        checkpoint()
        var d = design
        change(&d)
        if d.sheetIndex(id: activeSheetID) == nil, let id = (d.top ?? d.sheets.first)?.id { activeSheetID = id }
        openSheetIDs = openSheetIDs.filter { d.sheetIndex(id: $0) != nil }
        if !openSheetIDs.contains(activeSheetID) { openSheetIDs.append(activeSheetID) }
        design = d
    }

    /// An undoable change to the top-level sheet (pin locations, input order).
    func mutateTop(_ change: (inout Project) -> Void) {
        let i = topIndex
        mutateDesign { change(&$0.sheets[i]) }
    }

    /// Live edits during a drag; call `checkpoint()` once before the drag starts.
    func liveMutate(_ change: (inout Project) -> Void) {
        var p = project
        change(&p)
        project = p
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append((design, activeSheetID))
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((design, activeSheetID))
        restore(next)
    }

    private func restore(_ state: (design: DesignProject, sheet: UUID)) {
        activeSheetID = state.design.sheetIndex(id: state.sheet) != nil ? state.sheet : (state.design.top?.id ?? state.design.sheets[0].id!)
        openSheetIDs = openSheetIDs.filter { state.design.sheetIndex(id: $0) != nil }
        if !openSheetIDs.contains(activeSheetID) { openSheetIDs.append(activeSheetID) }
        design = state.design
        pruneSelection()
    }

    func pruneSelection() {
        selection = selection.filter {
            switch $0 {
            case .comp(let id): return project.component(id) != nil
            case .wire(let id): return project.wires.contains { $0.id == id }
            case .node(let ref): return project.label(ref) != nil
            case .text(let id): return project.notes?.contains { $0.id == id } ?? false
            }
        }
    }

    // MARK: - Editing

    func place(_ kind: GateKind, at p: CGPoint) {
        let size = kind.size
        let x = Int(Routing.snap(p.x - size.width / 2)), y = Int(Routing.snap(p.y - size.height / 2))
        var comp = Component(kind: kind, name: "", x: max(0, x), y: max(0, y))
        comp.name = kind.isPin ? project.nextPinName(for: kind) : project.nextInstanceName()
        mutate { $0.components.append(comp) }
        selection = [.comp(comp.id)]
        if !repeatInsert { tool = .select }
    }

    func connect(_ a: PortRef, _ b: PortRef) {
        guard a != b else { return }
        if project.wires.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }) { return }
        // Store the driver first so routing starts at outputs.
        let aOut = project.component(a.comp)?.isOutputPort(a.port) ?? false
        let wire = aOut ? Wire(a: a, b: b) : Wire(a: b, b: a)
        mutate { $0.wires.append(wire) }
    }

    func deleteSelection() { deleteSelected() }

    func selectAll() {
        selection = Set(project.components.map { Selection.comp($0.id) } + project.wires.map { Selection.wire($0.id) }
                        + (project.notes ?? []).map { Selection.text($0.id) }
                        + project.labels.keys.compactMap { PortRef(key: $0).map { Selection.node($0) } })
    }

    func nudge(dx: Int, dy: Int) { nudgeSelected(dx: dx, dy: dy) }

    func updateComponent(_ id: UUID, _ change: (inout Component) -> Void) {
        guard let i = project.index(of: id) else { return }
        mutate { change(&$0.components[i]) }
    }

    func setLabel(_ ref: PortRef, _ text: String) {
        mutate { p in
            let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
            if t.isEmpty { p.labels.removeValue(forKey: ref.key) } else { p.labels[ref.key] = t }
        }
    }

    func moveInput(_ id: UUID, by delta: Int) {
        var order = topProject.inputPins.map { $0.id }
        guard let i = order.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        mutateTop { $0.inputOrder = order }
    }

    /// Lab defaults: inputs MSB to LSB on SW(n-1)...SW0, outputs on LEDR0, LEDR1...
    func autoAssignPins() {
        let ins = topProject.inputPins, outs = topProject.outputPins
        mutateTop { p in
            for (k, pin) in ins.enumerated() {
                let sw = ins.count - 1 - k
                if sw < 10, let i = p.index(of: pin.id) { p.components[i].location = BoardPin.de10Standard[sw].pin }
            }
            let leds = BoardPin.de10Standard.filter { $0.kind == .led }
            for (k, pin) in outs.enumerated() where k < leds.count {
                if let i = p.index(of: pin.id) { p.components[i].location = leds[k].pin }
            }
        }
    }

    func assign(_ pinID: UUID, to location: String?) {
        guard topProject.component(pinID)?.kind.isPin == true else { return }
        let normalized = location?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let loc = normalized?.isEmpty == false ? normalized : nil
        mutateTop { p in
            // A board resource can only belong to one node, regardless of spelling.
            if let loc {
                for i in p.components.indices where p.components[i].location?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == loc
                    && p.components[i].id != pinID {
                    p.components[i].location = nil
                }
            }
            if let i = p.index(of: pinID) { p.components[i].location = loc }
        }
    }

    /// Four switch inputs w, x, y, z (SW3 to SW0) and output f (LEDR0) on the DE10-Standard.
    func insertStarterPins() {
        mutate { p in
            let names = ["w", "x", "y", "z"]
            let locs = ["PIN_AC30", "PIN_AB28", "PIN_Y27", "PIN_AB30"]
            var y = 64
            for (n, l) in zip(names, locs) where !p.components.contains(where: { $0.name == n }) {
                p.components.append(Component(kind: .input, name: n, x: 32, y: y, location: l))
                y += 64
            }
            if !p.components.contains(where: { $0.name == "f" }) {
                p.components.append(Component(kind: .output, name: "f", x: 880, y: 184, location: "PIN_AA24"))
            }
        }
    }

    // MARK: - Clipboard

    private struct Fragment: Codable {
        var components: [Component]
        var wires: [Wire]
        var labels: [String: String]
        var notes: [TextNote]? = nil
    }

    static let fragmentPrefix = "quartzite-fragment:"

    func copySelection() -> String? {
        let ids = Set(selection.compactMap { if case .comp(let id) = $0 { return id } else { return nil } })
        let notes = selectedNoteIDs
        guard !ids.isEmpty || !notes.isEmpty else { return nil }
        let frag = Fragment(components: project.components.filter { ids.contains($0.id) },
                            wires: project.wires.filter { ids.contains($0.a.comp) && ids.contains($0.b.comp) },
                            labels: project.labels.filter { key, _ in ids.contains { key.hasPrefix($0.uuidString) } },
                            notes: project.notes?.filter { notes.contains($0.id) })
        guard let data = try? JSONEncoder().encode(frag) else { return nil }
        return Store.fragmentPrefix + data.base64EncodedString()
    }

    func paste(_ text: String, offset: Int = 32) {
        guard text.hasPrefix(Store.fragmentPrefix),
              let data = Data(base64Encoded: String(text.dropFirst(Store.fragmentPrefix.count))),
              let frag = try? JSONDecoder().decode(Fragment.self, from: data) else { return }
        var fragmentProject = Project()
        fragmentProject.components = frag.components
        fragmentProject.wires = frag.wires
        fragmentProject.labels = frag.labels
        fragmentProject.notes = frag.notes
        guard fragmentProject.structuralErrors.isEmpty else { return }
        var map: [UUID: UUID] = [:]
        var newSelection: Set<Selection> = []
        mutate { p in
            for var c in frag.components {
                let old = c.id
                c.id = UUID()
                map[old] = c.id
                c.x += offset; c.y += offset
                if c.kind.isPin {
                    if p.components.contains(where: { $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) {
                        c.name = p.nextPinName(for: c.kind)
                    }
                    c.location = nil
                } else {
                    c.name = p.nextInstanceName()
                }
                p.components.append(c)
                newSelection.insert(.comp(c.id))
            }
            for var note in frag.notes ?? [] {
                note.id = UUID()
                note.x = max(0, note.x + offset); note.y = max(0, note.y + offset)
                p.notes = (p.notes ?? []) + [note]
                newSelection.insert(.text(note.id))
            }
            for w in frag.wires {
                guard let a = map[w.a.comp], let b = map[w.b.comp] else { continue }
                p.wires.append(Wire(a: PortRef(comp: a, port: w.a.port), b: PortRef(comp: b, port: w.b.port)))
            }
            for (key, value) in frag.labels {
                let parts = key.split(separator: "#")
                guard parts.count == 2, let u = UUID(uuidString: String(parts[0])), let n = map[u] else { continue }
                p.labels["\(n.uuidString)#\(parts[1])"] = value
            }
        }
        selection = newSelection
    }

    /// Cut only items actually encoded in the clipboard. Standalone wires and
    /// labels on unselected components cannot be pasted as independent objects.
    func cutSelection() -> String? {
        guard let fragment = copySelection() else { return nil }
        let ids = Set(selectedComponentIDs)
        selection = selection.filter {
            switch $0 {
            case .comp, .text: return true
            case .wire(let id):
                return project.wires.contains { $0.id == id && ids.contains($0.a.comp) && ids.contains($0.b.comp) }
            case .node(let ref): return ids.contains(ref.comp)
            }
        }
        deleteSelected()
        return fragment
    }

    func duplicate() {
        if let s = copySelection() { paste(s, offset: 32) }
    }

    // MARK: - Compile & simulate

    func setExpected(_ output: UUID, _ text: String) {
        suppressChange = true
        design.sheets[topIndex].expected[output.uuidString] = text
        suppressChange = false
        dirty = true
        if let s = simulation, let i = s.outputIDs.firstIndex(of: output) {
            simulation?.expected[i] = Minterms.parse(text)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Minterms.parse(text) == nil {
                simulation?.invalidExpected.insert(output)
            } else { simulation?.invalidExpected.remove(output) }
        }
        autosave()
    }

    /// Output values for the board preview's current switch positions.
    func boardOutputs() -> [UUID: Bool]? {
        // Pure read: never mutates state, so it is safe to call while views render.
        guard let c = (compileIsStale ? nil : compiled) ?? Compiler.compile(design).0 else { return nil }
        // Push buttons are active low: they read 0 while pressed.
        let bits = c.inputs.map { pin -> Bool in
            let v = boardInputs[pin.id] ?? false
            return BoardPin.lookup(pin.location)?.activeLow == true ? !v : v
        }
        let outs = c.evaluate(bits).outputs
        return Dictionary(uniqueKeysWithValues: zip(c.outputs.map { $0.id }, outs))
    }

    // MARK: - Files

    static let projectType = UTType(exportedAs: "com.quartzite.project", conformingTo: .json)

    /// Replace a document without autosaving a new project under the previous URL.
    func loadDesign(_ d: DesignProject, from url: URL?, dirty: Bool, activeSheet: UUID? = nil) {
        resetFlow()
        projectVersion += 1
        suppressChange = true
        var d = d
        for i in d.sheets.indices where d.sheets[i].id == nil { d.sheets[i].id = UUID() }
        if d.sheets.isEmpty { d = DesignProject(single: Project()) }
        design = d
        activeSheetID = activeSheet.flatMap { d.sheetIndex(id: $0) != nil ? $0 : nil } ?? (d.top ?? d.sheets[0]).id!
        openSheetIDs = [activeSheetID]
        hierarchyTrail = []
        fileURL = url
        self.dirty = dirty
        suppressChange = false
        undoStack.removeAll(); redoStack.removeAll()
        selection = []
        boardInputs = [:]
        tool = .select
        compiled = nil
        simulation = nil
        lastCompile = nil
        exportedTo = nil
        compileIsStale = true
        EditorState.shared.editingNote = nil
        EditorState.shared.status = nil
        EditorState.shared.cursor = nil
        refreshRouting()
        autosave()
    }

    /// A one-sheet project (a version 1 file).
    func loadProject(_ p: Project, from url: URL?, dirty: Bool) {
        loadDesign(DesignProject(single: p), from: url, dirty: dirty)
    }

    func newProject(name: String, device: String, starterPins: Bool) {
        var p = Project()
        p.name = name
        p.device = device
        loadProject(p, from: nil, dirty: true)
        systemMessages.append(Message(level: .info, text: "Created project \(p.entityName) for \(device)"))
        if starterPins { insertStarterPins() }
        tab = .bdf
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Store.projectType, .json]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            loadDesign(try DesignProject.load(data), from: url, dirty: false)
            systemMessages.append(Message(level: .info, text: "Opened \(url.lastPathComponent)"))
            autosave()
        } catch {
            alert("Could not open project", error.localizedDescription)
        }
    }

    func save() {
        if let url = fileURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Store.projectType]
        panel.nameFieldStringValue = design.projectName + ".qzproj"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    /// Commit document state only after the file was successfully written.
    func saveProject(to url: URL) throws {
        try design.encoded().write(to: url, options: .atomic)
        fileURL = url
        dirty = false
        autosave()
    }

    private func write(to url: URL) {
        do { try saveProject(to: url) } catch {
            alert("Could not save", error.localizedDescription)
        }
    }

    func exportQuartusProject() {
        let project = topProject
        guard Compiler.compile(design, checkLocations: false).0 != nil else {
            compile()
            tab = .bdf
            alert("Fix the errors first", "The design check found errors (see Messages). Quartus would refuse to compile it, so nothing was exported.")
            return
        }
        let unassigned = (project.inputPins + project.outputPins).filter { ($0.location ?? "").isEmpty }
        if !unassigned.isEmpty {
            let a = NSAlert()
            a.messageText = "Some pins have no location"
            a.informativeText = "\(unassigned.map { $0.name }.joined(separator: ", ")) would be placed on random FPGA pins, so the switches and LEDs won't work. Assign them in the Pin Planner first, or export anyway."
            a.addButton(withTitle: "Open Pin Planner")
            a.addButton(withTitle: "Export Anyway")
            if a.runModal() == .alertFirstButtonReturn { tab = .pins; return }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to create the \(design.projectName)_quartus folder"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        exportBundle(into: parent.appendingPathComponent("\(design.projectName)_quartus", isDirectory: true), reveal: true)
    }

    /// Writes the Quartus project folder. Used by the menu command and by tests.
    @discardableResult
    func exportBundle(into folder: URL, reveal: Bool) -> Bool {
        do {
            let bundle = try QuartusExport.makeBundle(design)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files = bundle.files
            if let vo = NetlistWriter.bundleFile(design) { files.append(vo) }
            for f in files {
                let url = folder.appendingPathComponent(f.name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.contents.write(to: url, atomically: true, encoding: .utf8)
            }
            systemMessages.append(Message(level: .info, text: "Exported \(files.count) files to \(folder.path)",
                                          children: bundle.notes.map { Message(level: .info, text: $0) }))
            exportedTo = folder
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            return true
        } catch {
            alert("Export failed", error.localizedDescription)
            return false
        }
    }

    func importAssignments() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a .qsf file with set_location_assignment lines"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let regex = try! NSRegularExpression(pattern: "set_location_assignment\\s+(PIN_\\w+)\\s+-to\\s+\"?([A-Za-z_][\\w\\[\\]]*)\"?")
        var count = 0
        mutateTop { p in
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let lr = Range(m.range(at: 1), in: text), let nr = Range(m.range(at: 2), in: text) else { continue }
                let loc = String(text[lr]).uppercased(), name = String(text[nr])
                if let i = p.components.firstIndex(where: { $0.kind.isPin && $0.name == name }) {
                    p.components[i].location = loc
                    count += 1
                }
            }
        }
        systemMessages.append(Message(level: .info, text: "Imported \(count) pin assignment(s) from \(url.lastPathComponent)"))
    }

    func exportText(_ name: String, _ contents: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try contents.write(to: url, atomically: true, encoding: .utf8) } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    func exportPNG(_ name: String, _ view: some View) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let a = NSAlert()
        a.messageText = "Replace the current project?"
        a.informativeText = "Unsaved changes to \(design.projectName) will be lost. Save first with File > Save if you want to keep them."
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Autosave

    /// ~/Library/Application Support/Quartzite (autosave, and output_files of unsaved projects).
    static var supportDirectory: URL {
        // QUARTZITE_SUPPORT_DIR lets UI tests run without touching the real session.
        let dir = ProcessInfo.processInfo.environment["QUARTZITE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quartzite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var autosaveURL: URL { supportDirectory.appendingPathComponent("autosave.json") }

    /// Sessions saved before multi-sheet designs have `project` instead of `design`.
    private struct Autosave: Codable {
        var design: DesignProject?
        var project: Project?
        var url: URL?
        var dirty: Bool? = nil
        var activeSheet: UUID?
    }

    private func autosave() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(Autosave(design: design, url: fileURL, dirty: dirty, activeSheet: activeSheetID)) {
            try? data.write(to: Store.autosaveURL, options: .atomic)
        }
    }

    private static func loadAutosave() -> (design: DesignProject, activeSheet: UUID, url: URL?, dirty: Bool?)? {
        guard let data = try? Data(contentsOf: autosaveURL),
              let a = try? JSONDecoder().decode(Autosave.self, from: data),
              var d = a.design ?? a.project.map({ DesignProject(single: $0) }), !d.sheets.isEmpty else { return nil }
        for i in d.sheets.indices where d.sheets[i].id == nil { d.sheets[i].id = UUID() }
        guard d.structuralErrors.isEmpty || a.design == nil else { return nil }
        let active = a.activeSheet.flatMap { d.sheetIndex(id: $0) != nil ? $0 : nil } ?? (d.top ?? d.sheets[0]).id!
        return (d, active, a.url, a.dirty)
    }
}

#endif

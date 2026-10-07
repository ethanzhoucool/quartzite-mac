#if canImport(SwiftUI)
import SwiftUI
import AppKit

@main
@MainActor
struct QuartziteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: Store

    init() {
        if CLI.wants(CommandLine.arguments) {
            exit(CLI.run(CommandLine.arguments))
        }
        _store = State(initialValue: Store())
    }

    var body: some Scene {
        Window("Quartzite", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1180, minHeight: 720)
                .navigationTitle(windowTitle)
        }
        .commands { QuartusCommands(store: store) }
    }

    /// Quartus: "Quartus Prime Lite Edition - C:/path/project - entity".
    private var windowTitle: String {
        if let url = store.fileURL {
            let dir = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return "Quartzite - \(dir)/\(store.title) - \(store.project.entityName)"
        }
        return "Quartzite - \(store.project.entityName)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Window layout flags (View > Utility Windows).
enum PaneVisibility {
    static let navigator = "showProjectNavigator"
    static let tasks = "showTasks"
    static let messages = "showMessages"
}

// MARK: - Menus

/// Menu bar in Quartus Prime order: File, Edit, View, Project, Assignments, Processing,
/// Tools, Window, Help. Quartus' Ctrl shortcuts map to Command.
@MainActor
struct QuartusCommands: Commands {
    @Bindable var store: Store
    @AppStorage(PaneVisibility.navigator) private var showNavigator = true
    @AppStorage(PaneVisibility.tasks) private var showTasks = true
    @AppStorage(PaneVisibility.messages) private var showMessages = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New...") { store.sheet = .newProject }.keyboardShortcut("n")
            Button("Open...") { store.open() }.keyboardShortcut("o")
            Divider()
            Button("New Project Wizard...") { store.sheet = .newProject }
            Button("Open Project...") { store.open() }.keyboardShortcut("j")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store.save() }.keyboardShortcut("s")
            Button("Save As...") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export Quartus Project...") { store.exportQuartusProject() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Schematic Image...") {
                store.exportPNG("\(store.project.entityName)_schematic.png", SchematicSnapshot(store: store))
            }
            Button("Save Compilation Report as Text...") { store.saveReport() }.disabled(store.flow == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
            Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { store.duplicate() }.keyboardShortcut("d")
            Divider()
            Button("Insert Symbol...") { store.tab = .bdf; store.sheet = .symbolLibrary(at: .zero) }
            Menu("Insert Pin") {
                Button("Input") { store.tab = .bdf; store.tool = .place(.input) }
                Button("Output") { store.tab = .bdf; store.tool = .place(.output) }
            }
        }
        CommandGroup(after: .toolbar) {
            Menu("Utility Windows") {
                Toggle("Project Navigator", isOn: $showNavigator).keyboardShortcut("0", modifiers: .option)
                Toggle("Tasks", isOn: $showTasks).keyboardShortcut("4", modifiers: .option)
                Toggle("Messages", isOn: $showMessages).keyboardShortcut("3", modifiers: .option)
            }
            Divider()
            Button("Zoom In") { store.zoom = min(3, store.zoom + 0.25) }.keyboardShortcut("=")
            Button("Zoom Out") { store.zoom = max(0.5, store.zoom - 0.25) }.keyboardShortcut("-")
            Button("Actual Size") { store.zoom = 1 }.keyboardShortcut("0")
            Divider()
            ForEach(Array(DocTab.allCases.enumerated()), id: \.element) { i, t in
                Button(t.title(store.project)) { store.tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
        }
        CommandMenu("Project") {
            Button("Add Starter Pins (w, x, y, z, f)") { store.tab = .bdf; store.insertStarterPins() }
            Button("Export Quartus Project...") { store.exportQuartusProject() }
            Divider()
            Button("Add/Remove Files in Project...") {}
                .disabled(true)
                .help("A Quartzite project has exactly one schematic, \(store.project.entityName).bdf")
            Button("Revisions...") {}
                .disabled(true)
                .help("Quartzite projects have a single revision")
        }
        CommandMenu("Assignments") {
            Button("Device...") { store.sheet = .device }
            Divider()
            Button("Assignment Editor") { store.tab = .assignments }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Pin Planner") { store.tab = .pins }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Auto-Assign Lab Pins (SW / LEDR)") { store.autoAssignPins() }
            Button("Import Assignments...") { store.importAssignments() }
            Button("Export Assignments...") {
                store.exportText("\(store.project.entityName)_pins.qsf", QuartusExport.pinAssignments(store.project))
            }
        }
        CommandMenu("Processing") {
            Button("Stop Processing") { store.stopProcessing() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!store.isProcessing)
            Divider()
            Button("Start Compilation") { store.startCompilation() }
                .keyboardShortcut("l")
                .disabled(store.isProcessing)
            Menu("Start") {
                Button("Start Analysis & Elaboration") { store.start(.analysisElaboration) }
                Button("Start Analysis & Synthesis") { store.start(.analysisSynthesis) }.keyboardShortcut("k")
                Button("Start Fitter") { store.start(.fitter) }
                Button("Start Assembler (experimental .sof)") { store.start(.assembler) }
                    .disabled(!store.hardwareAvailable)
                    .help(store.hardwareAvailable ? "Write an experimental .sof from the open-source place and route"
                                                  : "Needs the open-source toolchain and Use Open-Source Fitter and Assembler")
                Button("Start Timing Analyzer (logic-depth estimate)") { store.start(.timing) }
                Button("Start EDA Netlist Writer") { store.start(.eda) }
            }
            .disabled(store.isProcessing)
            Toggle("Use Open-Source Fitter and Assembler (Experimental)", isOn: Binding(
                get: { store.useHardwareFlow }, set: { store.useHardwareFlow = $0 }))
                .disabled(store.isProcessing)
            Button("Open-Source Toolchain Status...") { store.showToolchainStatus() }
            Divider()
            Button("Compilation Report") { store.tab = .report }.keyboardShortcut("r")
            Divider()
            Button("Run Functional Simulation") { store.simulate() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Quartus Compatibility and Trademarks") {
                store.alert("Quartzite is not affiliated with Intel or Altera",
                            "Quartzite is an independent, open-source project (MIT license). It is not made, endorsed or supported by Intel Corporation or Altera Corporation. Quartus, Quartus Prime, Cyclone and Intel are trademarks of their owners and are used only to describe compatibility. DE10-Standard is a product of Terasic.\n\nFiles Quartzite exports follow the Quartus formats, but keep compiling in Quartus for graded work. Experimental .sof files come from the open-source Mistral/nextpnr flow and have not been tested in Quartus Programmer or on hardware.")
            }
        }
        CommandMenu("Tools") {
            Button("Programmer") { store.openProgrammer() }
            Button("Pin Planner") { store.tab = .pins }
            Button("Simulation Waveform Editor") { store.tab = .waveform }
            Button("Timing Analyzer (logic-depth estimate)") {
                store.reportSelection = "stage.timing.depth"
                store.tab = .report
            }
            .disabled(store.flow?.timing == nil)
            Divider()
            Button("Netlist Viewers") {}
                .disabled(true)
                .help("RTL and Technology Map viewers are not implemented in Quartzite")
        }
    }
}

// MARK: - Main window

@MainActor
struct ContentView: View {
    @Bindable var store: Store
    @AppStorage("messagesHeight") private var messagesHeight: Double = 170
    @AppStorage(PaneVisibility.navigator) private var showNavigator = true
    @AppStorage(PaneVisibility.tasks) private var showTasks = true
    @AppStorage(PaneVisibility.messages) private var showMessages = true

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar(store: store)
            Divider()
            HSplitView {
                if showNavigator || showTasks {
                    VSplitView {
                        if showNavigator {
                            ProjectNavigatorPane(store: store)
                                .frame(minHeight: 110, idealHeight: 200)
                        }
                        if showTasks {
                            TasksPane(store: store)
                                .frame(minHeight: 180, idealHeight: 330)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 480)
                }
                VStack(spacing: 0) {
                    DocumentTabBar(store: store)
                    Divider()
                    Group {
                        switch store.tab {
                        case .bdf: SchematicView(store: store)
                        case .pins: PinPlannerView(store: store)
                        case .assignments: AssignmentEditorView(store: store)
                        case .waveform: SimulationView(store: store)
                        case .report: ReportView(store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: 600)
                .layoutPriority(1)
            }
            .frame(minHeight: 360, maxHeight: .infinity)
            if showMessages {
                PaneResizer(height: $messagesHeight)
                MessagesPane(store: store)
                    .frame(height: messagesHeight)
            }
            Divider()
            StatusBar(store: store)
        }
        .sheet(item: $store.sheet) { s in PropertySheetView(store: store, sheet: s) }
    }
}

// MARK: - Main toolbar

/// The Quartus main toolbar, in Quartus order: New, Open, Save | Cut, Copy, Paste |
/// Undo, Redo | top-level entity | Assignment Editor, Pin Planner | Stop Processing,
/// Start Compilation, Start Analysis & Elaboration, Start Analysis & Synthesis, Start
/// Fitter, Start Assembler, Start Timing Analyzer | Compilation Report | Programmer.
@MainActor
struct MainToolbar: View {
    @Bindable var store: Store

    var body: some View {
        HStack(spacing: 2) {
            ToolButton("doc.badge.plus", "New (Command-N)") { store.sheet = .newProject }
            ToolButton("folder", "Open Project (Command-O)") { store.open() }
            ToolButton("square.and.arrow.down", "Save (Command-S)") { store.save() }
            separator
            ToolButton("scissors", "Cut (Command-X)") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
            ToolButton("doc.on.doc", "Copy (Command-C)") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            ToolButton("doc.on.clipboard", "Paste (Command-V)") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            separator
            ToolButton("arrow.uturn.backward", "Undo (Command-Z)", enabled: store.canUndo) { store.undo() }
            ToolButton("arrow.uturn.forward", "Redo (Shift-Command-Z)", enabled: store.canRedo) { store.redo() }
            separator
            EntityField(store: store)
            separator
            ToolButton("list.bullet.rectangle", "Assignment Editor (Shift-Command-A)") { store.tab = .assignments }
            ToolButton("cpu", "Pin Planner (Shift-Command-N)") { store.tab = .pins }
            separator
            ToolButton("stop.circle", "Stop Processing (Shift-Command-C)", enabled: store.isProcessing,
                       tint: store.isProcessing ? Theme.error : nil) { store.stopProcessing() }
            ToolButton("play.fill", "Start Compilation (Command-L)", enabled: !store.isProcessing, tint: Theme.accent) { store.startCompilation() }
            ToolButton("checkmark.seal", "Start Analysis & Elaboration", enabled: !store.isProcessing) { store.start(.analysisElaboration) }
            ToolButton("function", "Start Analysis & Synthesis (Command-K)", enabled: !store.isProcessing) { store.start(.analysisSynthesis) }
            ToolButton("square.grid.3x3.topleft.filled", "Start Fitter", enabled: !store.isProcessing) { store.start(.fitter) }
            ToolButton("shippingbox", store.hardwareAvailable
                       ? "Start Assembler (writes an experimental .sof from the open-source place and route)"
                       : "Start Assembler needs the open-source toolchain and Processing > Use Open-Source Fitter and Assembler. Without them, compile the exported project in Quartus Prime at the lab.",
                       enabled: !store.isProcessing && store.hardwareAvailable) { store.start(.assembler) }
            ToolButton("clock", "Start Timing Analyzer (logic-depth estimate only; Quartzite has no Cyclone V delay models)",
                       enabled: !store.isProcessing) { store.start(.timing) }
            separator
            ToolButton("doc.text.magnifyingglass", "Compilation Report (Command-R)") { store.tab = .report }
            separator
            ToolButton("cable.connector", "Programmer (runs in Quartus)") { store.openProgrammer() }
            Spacer(minLength: 12)
            ToolButton("waveform.path", "Run Functional Simulation (Option-Command-R)") { store.simulate() }
            Button { store.exportQuartusProject() } label: {
                Label("Export Quartus Project", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .help("Write .qpf, .qsf, .bdf, .vwf and the Quartzite netlist for the lab computers (Shift-Command-E)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }
}

/// Square icon button for the main toolbar.
@MainActor
struct ToolButton: View {
    var symbol: String
    var help: String
    var enabled = true
    var tint: Color? = nil
    var action: () -> Void
    @State private var hover = false

    init(_ symbol: String, _ help: String, enabled: Bool = true, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.enabled = enabled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(enabled ? (tint ?? Color.primary) : Color.secondary.opacity(0.45))
                .frame(width: 28, height: 24)
                .background(hover && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(true)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The top-level entity box between Redo and the assignment tools.
@MainActor
struct EntityField: View {
    @Bindable var store: Store

    var body: some View {
        Menu {
            Button { } label: { Label(store.project.entityName, systemImage: "checkmark") }
            Divider()
            Text("Quartzite projects have one entity, named after the project")
        } label: {
            Text(store.project.entityName).font(.callout)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 170)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color(nsColor: .separatorColor)))
        .help("Top-level entity")
    }
}

// MARK: - Panes

/// Title strip of a utility window (Project Navigator, Tasks, Messages).
@MainActor
struct PaneHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            trailing()
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

@MainActor
struct ProjectNavigatorPane: View {
    @Bindable var store: Store
    @AppStorage("navigatorView") private var view = "Hierarchy"

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Project Navigator") {
                Picker("", selection: $view) {
                    Text("Hierarchy").tag("Hierarchy")
                    Text("Files").tag("Files")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            List {
                if view == "Hierarchy" {
                    Label("Cyclone V: \(store.project.device)", systemImage: "cpu")
                    row(store.project.entityName, icon: "square.stack.3d.up", indent: 14) { store.tab = .bdf }
                } else {
                    row("\(store.project.entityName).bdf", icon: DocTab.bdf.icon) { store.tab = .bdf }
                    row("Waveform.vwf", icon: DocTab.waveform.icon) { store.tab = .waveform }
                    row("\(store.project.entityName).qsf", icon: "doc.plaintext") { store.tab = .assignments }
                    if store.flow?.netlist != nil {
                        row(NetlistWriter.path(store.project.entityName), icon: "doc.text") {
                            store.reportSelection = "stage.eda.netlist"
                            store.tab = .report
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 22)
            .font(.callout)
        }
    }

    private func row(_ title: String, icon: String, indent: CGFloat = 0, open: @escaping () -> Void) -> some View {
        Label(title, systemImage: icon)
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .help("Double-click to open")
    }
}

/// Status glyph for a flow stage: blank (not run), spinner, green check, warning, red X,
/// or a grey dash for the skipped Assembler.
@MainActor
struct StageStatusIcon: View {
    var status: StageStatus
    var body: some View {
        switch status {
        case .notRun: Color.clear
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Theme.ok)
        case .warnings: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .failed: Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(Theme.error)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// Tasks window with the Quartus "Compilation" flow.
@MainActor
struct TasksPane: View {
    @Bindable var store: Store
    @AppStorage("tasksFlow") private var flowName = "Compilation"
    @State private var collapsed: Set<String> = []
    @State private var selected: String?

    private struct Row: Identifiable {
        var id: String
        var title: String
        var depth: Int
        var status: StageStatus? = nil
        var time: String = ""
        var expandable = false
        var runnable = true
        var icon: String? = "play.fill"
        var help: String = ""
        var action: () -> Void = {}
        var failed = false
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Tasks") {
                Picker("", selection: $flowName) {
                    Text("Compilation").tag("Compilation")
                    Text("Lab Flow (Quartzite)").tag("Lab")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            HStack(spacing: 0) {
                Text("").frame(width: 22)
                Text("Task").frame(maxWidth: .infinity, alignment: .leading)
                Text("Time").frame(width: 64, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(visibleRows) { r in rowView(r) }
                }
            }
        }
    }

    private func time(_ s: FlowStage) -> String { store.stageElapsed[s].map(CompileFlow.elapsed) ?? "" }

    private func report(_ id: String) -> () -> Void {
        { store.reportSelection = id; store.tab = .report }
    }

    private var rows: [Row] {
        if flowName == "Lab" { return labRows }
        let total = FlowStage.fullCompilation.compactMap { store.stageElapsed[$0] }
        let noSettings = "Quartzite has no settings for this stage"
        var r: [Row] = [
            Row(id: "compile", title: "Compile Design", depth: 0, status: store.compileDesignStatus,
                time: total.isEmpty ? "" : CompileFlow.elapsed(total.reduce(0, +)), expandable: true,
                help: "Start Compilation (Command-L)", action: { store.startCompilation() }),
            Row(id: "map", title: FlowStage.analysisSynthesis.taskName, depth: 1, status: store.status(.analysisSynthesis),
                time: time(.analysisSynthesis), expandable: true, help: "Start Analysis & Synthesis (Command-K)",
                action: { store.start(.analysisSynthesis) }),
            Row(id: "map.settings", title: "Edit Settings", depth: 2, runnable: false, icon: "slider.horizontal.3", help: noSettings),
            Row(id: "map.report", title: "View Report", depth: 2, icon: "tablecells", help: "Open the Analysis & Synthesis report",
                action: report("stage.analysisSynthesis.summary")),
            Row(id: "map.elab", title: FlowStage.analysisElaboration.taskName, depth: 2, status: store.status(.analysisElaboration),
                time: time(.analysisElaboration), help: "Start Analysis & Elaboration (design check only)",
                action: { store.start(.analysisElaboration) }),
            Row(id: "fit", title: FlowStage.fitter.taskName, depth: 1, status: store.status(.fitter), time: time(.fitter),
                expandable: true, help: "Start Fitter", action: { store.start(.fitter) }),
            Row(id: "fit.settings", title: "Edit Settings", depth: 2, runnable: false, icon: "slider.horizontal.3", help: noSettings),
            Row(id: "fit.report", title: "View Report", depth: 2, icon: "tablecells", help: "Open the Fitter report", action: report("stage.fitter.summary")),
            Row(id: "fit.toolchain", title: store.toolchainStatus, depth: 2, icon: "wrench.and.screwdriver",
                help: "Open-source toolchain (yosys, nextpnr-mistral, mistral-cv): where Quartzite looked and what it found", action: { store.showToolchainStatus() }),
            Row(id: "asm", title: FlowStage.assembler.taskName, depth: 1, status: store.status(.assembler), time: time(.assembler),
                expandable: true, runnable: store.hardwareAvailable,
                help: store.hardwareAvailable ? "Start Assembler (writes an experimental .sof)"
                    : "Needs the open-source toolchain and Processing > Use Open-Source Fitter and Assembler. Without them, compile the exported project in Quartus Prime at the lab.",
                action: { store.start(.assembler) }),
            Row(id: "asm.report", title: "View Report", depth: 2, icon: "tablecells", help: "Open the Assembler report", action: report("stage.assembler.summary")),
            Row(id: "asm.sof", title: sofTitle, depth: 2, runnable: store.flow?.assembly?.passed == true, icon: "folder",
                help: store.flow?.assembly.flatMap { $0.passed ? "Show the experimental .sof in Finder (checksum \($0.checksumText))" : nil }
                    ?? "Run the Assembler with the open-source toolchain first",
                action: { store.revealProgrammingFile() }),
            Row(id: "sta", title: FlowStage.timing.taskName, depth: 1, status: store.status(.timing), time: time(.timing),
                expandable: true, help: "Start Timing Analyzer (logic-depth estimate, not Quartus timing)", action: { store.start(.timing) }),
            Row(id: "sta.report", title: "View Report", depth: 2, icon: "tablecells", help: "Open the logic-depth report", action: report("stage.timing.summary")),
            Row(id: "eda", title: FlowStage.eda.taskName, depth: 1, status: store.status(.eda), time: time(.eda),
                expandable: true, help: "Start EDA Netlist Writer", action: { store.start(.eda) }),
            Row(id: "eda.report", title: "View Report", depth: 2, icon: "tablecells", help: "Open the EDA Netlist Writer report", action: report("stage.eda.summary")),
            Row(id: "program", title: "Program Device (Open Programmer)", depth: 0, icon: "cable.connector",
                help: "Programming the board happens in Quartus Programmer", action: { store.openProgrammer() }),
        ]
        // A report row only works once its stage has run.
        for i in r.indices where r[i].id.hasSuffix(".report") {
            let stage: FlowStage? = ["map": .analysisSynthesis, "fit": .fitter, "asm": .assembler, "sta": .timing, "eda": .eda][String(r[i].id.prefix { $0 != "." })]
            if let stage, store.flow?.run(stage) == nil { r[i].runnable = false; r[i].help = "Run \(stage.toolName) first" }
        }
        return r
    }

    private var sofTitle: String {
        guard let a = store.flow?.assembly, a.passed else { return "Show .sof" }
        return "Show \(a.sofURL.lastPathComponent)"
    }

    private var labRows: [Row] {
        let pins = store.pinState
        let sim = store.simulationState
        return [
            Row(id: "lab.pins", title: "Pin Assignments", depth: 0, status: pins == .notRun ? .notRun : (pins == .ok ? .succeeded : .warnings),
                icon: "cpu", help: "Open the Pin Planner", action: { store.tab = .pins }),
            Row(id: "lab.compile", title: "Compile Design", depth: 0, status: store.compileDesignStatus, help: "Start Compilation (Command-L)",
                action: { store.startCompilation() }),
            Row(id: "lab.sim", title: "Functional Simulation", depth: 0,
                status: sim == .notRun ? .notRun : (sim == .failed ? .failed : .succeeded), icon: "waveform.path",
                help: "Run Functional Simulation", action: { store.simulate() }),
            Row(id: "lab.export", title: "Export Quartus Project", depth: 0, status: store.exportedTo == nil ? .notRun : .succeeded,
                icon: "square.and.arrow.up", help: "Write the project for the lab computers", action: { store.exportQuartusProject() }),
            Row(id: "lab.program", title: "Program Device (in Quartus at the lab)", depth: 0, icon: "cable.connector",
                help: "Programming the board happens in Quartus at the lab", action: { store.openProgrammer() }),
        ]
    }

    private var visibleRows: [Row] {
        var out: [Row] = []
        var hiddenBelow: Int? = nil
        for r in rows {
            if let d = hiddenBelow, r.depth > d { continue }
            hiddenBelow = nil
            out.append(r)
            if r.expandable && collapsed.contains(r.id) { hiddenBelow = r.depth }
        }
        return out
    }

    private func rowView(_ r: Row) -> some View {
        let isSelected = selected == r.id
        let failed = r.status == .failed
        return HStack(spacing: 0) {
            StageStatusIcon(status: r.status ?? .notRun).frame(width: 22)
            HStack(spacing: 4) {
                Group {
                    if r.expandable {
                        Button {
                            if collapsed.contains(r.id) { collapsed.remove(r.id) } else { collapsed.insert(r.id) }
                        } label: {
                            Image(systemName: collapsed.contains(r.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 12)
                    }
                }
                if let icon = r.icon {
                    Image(systemName: icon)
                        .font(.system(size: icon == "play.fill" ? 9 : 11))
                        .foregroundStyle(r.runnable ? (icon == "play.fill" ? Theme.accent : Color.secondary) : Color.secondary.opacity(0.4))
                        .frame(width: 14)
                }
                Text(r.title)
                    .foregroundStyle(!r.runnable ? Color.secondary : (failed ? Theme.error : Color.primary))
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(r.depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if r.runnable && !store.isProcessing || (r.runnable && r.status == nil) { r.action() } }
        .simultaneousGesture(TapGesture().onEnded { selected = r.id })
        .contextMenu {
            Button(r.status == nil ? "Open" : "Start") { r.action() }.disabled(!r.runnable)
        }
        .help(r.help)
    }
}

/// Draggable divider above the Messages pane.
@MainActor
struct PaneResizer: View {
    @Binding var height: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if start == nil { start = height }
                    height = min(520, max(80, (start ?? height) - v.translation.height))
                }
                .onEnded { _ in start = nil })
    }
}

// MARK: - Document tabs

@MainActor
struct DocumentTabBar: View {
    @Bindable var store: Store

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DocTab.allCases) { t in
                let selected = store.tab == t
                Button { store.tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.caption)
                        Text(t == .report ? "Compilation Report - \(store.project.entityName)" : t.title(store.project)).font(.callout)
                        if t == .bdf && store.dirty { Text("*").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .overlay(alignment: .top) { if selected { Rectangle().fill(Theme.accent).frame(height: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
                Divider().frame(height: 30)
            }
            Spacer()
        }
        .background(.bar)
    }
}

// MARK: - Messages

@MainActor
struct MessageIcon: View {
    var level: Message.Level
    var body: some View {
        switch level {
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .criticalWarning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.purple)
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
        }
    }
}

extension Message {
    var childrenOrNil: [Message]? { children.isEmpty ? nil : children }

    /// Quartus colours message text by type: green Info, blue Warning, purple Critical
    /// Warning, red Error.
    var textColor: Color {
        switch level {
        case .info: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.45, green: 0.82, blue: 0.45, alpha: 1)
                : NSColor(red: 0.0, green: 0.48, blue: 0.12, alpha: 1)
        })
        case .warning: return Color(nsColor: .systemBlue)
        case .criticalWarning: return Color(nsColor: .systemPurple)
        case .error: return Color(nsColor: .systemRed)
        }
    }

    func matches(_ q: String) -> Bool {
        text.localizedCaseInsensitiveContains(q) || children.contains { $0.matches(q) }
    }
}

/// Quartus Messages window: type filters with counts, a filter field, Find / Find Next,
/// Type | ID | Message columns with expandable sub-messages, and System / Processing tabs.
@MainActor
struct MessagesPane: View {
    @Bindable var store: Store
    @State private var hidden: Set<Message.Level> = []
    @State private var filter = ""
    @State private var source: Source = .processing
    @State private var selection: Message.ID?
    @State private var findText = ""
    @State private var showFind = false

    enum Source { case system, processing }

    private var all: [Message] { source == .processing ? store.messages : store.systemMessages }

    private func count(_ level: Message.Level, _ ms: [Message]) -> Int {
        ms.reduce(0) { $0 + ($1.level == level ? 1 : 0) + count(level, $1.children) }
    }

    private var shown: [Message] {
        all.filter { !hidden.contains($0.level) }.filter { filter.isEmpty || $0.matches(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Messages").font(.callout.weight(.semibold)).padding(.trailing, 4)
                filterButton(nil, "All", count: nil)
                filterButton(.error, "Error", count: count(.error, all))
                filterButton(.criticalWarning, "Critical Warning", count: count(.criticalWarning, all))
                filterButton(.warning, "Warning", count: count(.warning, all))
                filterButton(.info, "Info", count: count(.info, all))
                Button { } label: { badge(icon: AnyView(Image(systemName: "eye.slash").foregroundStyle(.secondary)), count: 0) }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .help("Suppressed (0): Quartzite does not suppress messages")
                TextField("<<Filter>>", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 200)
                Spacer()
                if store.compileIsStale && store.lastCompile != nil {
                    Text("Design changed since the last compilation").font(.caption).foregroundStyle(.secondary)
                }
                Button { showFind.toggle() } label: { Label("Find...", systemImage: "binoculars") }
                    .controlSize(.small)
                    .popover(isPresented: $showFind, arrowEdge: .bottom) {
                        HStack {
                            TextField("Find what", text: $findText).frame(width: 220).onSubmit(findNext)
                            Button("Find Next", action: findNext).keyboardShortcut(.defaultAction)
                        }
                        .padding(10)
                    }
                Button(action: findNext) { Label("Find Next", systemImage: "binoculars.fill") }
                    .controlSize(.small)
                    .disabled(findText.isEmpty)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(.bar)
            Divider()
            HStack(spacing: 0) {
                Text("Type").frame(width: 46, alignment: .leading)
                Text("ID").frame(width: 44, alignment: .leading)
                Text("Message")
                Spacer()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
            .frame(height: 18)
            Divider()
            if shown.isEmpty {
                Text(all.isEmpty ? "No messages." : "No messages match the current filters.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(shown, children: \.childrenOrNil, selection: $selection) { m in
                        row(m).id(m.id)
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 18)
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                    .onChange(of: store.messages.count) { _, _ in
                        if source == .processing, let last = store.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 0) {
                tabButton(.system, store.systemMessages.isEmpty ? "System" : "System (\(Message.Level.allCases.reduce(0) { $0 + count($1, store.systemMessages) }))")
                tabButton(.processing, "Processing (\(Message.Level.allCases.reduce(0) { $0 + count($1, store.messages) }))")
                Spacer()
            }
            .frame(height: 24)
            .background(.bar)
        }
    }

    private func row(_ m: Message) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            MessageIcon(level: m.level).font(.system(size: 11)).frame(width: 46, alignment: .leading)
            Text("").frame(width: 44, alignment: .leading)
            Text(m.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(m.textColor)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let id = m.component, store.project.component(id) != nil {
                store.tab = .bdf
                store.selection = [.comp(id)]
            }
        })
        .help(m.component != nil ? "Double-click to locate in \(store.project.entityName).bdf" : "")
    }

    private func badge(icon: AnyView, count: Int?) -> some View {
        HStack(spacing: 3) {
            icon
            if let count { Text("\(count)").font(.caption.monospacedDigit()) }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }

    private func filterButton(_ level: Message.Level?, _ title: String, count: Int?) -> some View {
        let on = level.map { !hidden.contains($0) } ?? hidden.isEmpty
        return Button {
            if let level {
                if hidden.contains(level) { hidden.remove(level) } else { hidden.insert(level) }
            } else {
                hidden = []
            }
        } label: {
            Group {
                if let level {
                    badge(icon: AnyView(MessageIcon(level: level).font(.system(size: 12))), count: count)
                } else {
                    Text("All").font(.callout).padding(.horizontal, 8).frame(height: 22)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(on ? Theme.accent.opacity(0.45) : Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(level.map { "\(on ? "Hide" : "Show") \($0.title) messages (\(count ?? 0))" } ?? "Show all message types")
    }

    private func tabButton(_ s: Source, _ title: String) -> some View {
        Button { source = s; selection = nil } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(source == s ? Color(nsColor: .controlBackgroundColor) : .clear)
                .overlay(alignment: .bottom) { if source == s { Rectangle().fill(Theme.accent).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(source == s ? .primary : .secondary)
    }

    /// Selects the next message (in display order, including sub-messages) containing the find text.
    private func findNext() {
        guard !findText.isEmpty else { return }
        func flat(_ ms: [Message]) -> [Message] { ms.flatMap { [$0] + flat($0.children) } }
        let list = flat(shown)
        let start = selection.flatMap { id in list.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let order = Array(list[start...]) + Array(list[..<start])
        if let hit = order.first(where: { $0.text.localizedCaseInsensitiveContains(findText) }) { selection = hit.id }
        else { NSSound.beep() }
    }
}

// MARK: - Status bar

/// Bottom-right progress and elapsed time, as in Quartus' status bar.
@MainActor
struct StatusBar: View {
    @Bindable var store: Store

    var body: some View {
        HStack(spacing: 14) {
            if let s = store.processingStage {
                ProgressView().controlSize(.mini)
                Text("Running \(s.toolName)...").font(.caption)
            } else {
                Text(store.flow == nil ? "Ready" : "Last task: \(store.flow!.mainTask)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int((store.processingProgress * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
            Divider().frame(height: 12)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsedText(now: ctx.date)).font(.caption.monospacedDigit())
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }

    private func elapsedText(now: Date) -> String {
        guard let start = store.processingStarted else { return "00:00:00" }
        return CompileFlow.elapsed((store.processingEnded ?? now).timeIntervalSince(start))
    }
}

/// Light render of the whole diagram, cropped to its contents.
/// Drawing lives in SheetRenderer.swift so rotated symbols and text match the editor.
@MainActor
struct SchematicSnapshot: View {
    var store: Store
    var body: some View { SchematicImage(project: store.project, routing: store.routing) }
}

#endif

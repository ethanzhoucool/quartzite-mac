#if canImport(SwiftUI)
import SwiftUI

/// Routes `store.sheet` to the matching dialog.
@MainActor
struct PropertySheetView: View {
    @Bindable var store: Store
    var sheet: PropertySheet

    var body: some View {
        switch sheet {
        case .symbolLibrary(let at): SymbolLibrarySheet(store: store, insertAt: at == .zero ? nil : at)
        case .pin(let id): PinPropertiesSheet(store: store, id: id)
        case .symbol(let id): SymbolPropertiesSheet(store: store, id: id)
        case .node(let ref): NodePropertiesSheet(store: store, ref: ref)
        case .newProject: NewProjectWizard(store: store)
        case .device: DeviceSheet(store: store)
        }
    }
}

@MainActor
private struct SheetFrame<Content: View>: View {
    var title: String
    var okTitle = "OK"
    var okDisabled = false
    var onOK: () -> Void
    var onCancel: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(okTitle, action: onOK).keyboardShortcut(.defaultAction).disabled(okDisabled)
            }
        }
        .padding(20)
    }
}

// MARK: - Symbol library (Quartus: Edit > Insert Symbol)

/// Quartus' "Symbol" window: a Libraries tree, the Name field, Repeat-insert mode,
/// and a preview on a dotted sheet.
@MainActor
struct SymbolLibrarySheet: View {
    @Bindable var store: Store
    var insertAt: CGPoint?
    @State private var name = ""
    @State private var selected: GateKind? = .and2
    @State private var logicOpen = true
    @State private var pinOpen = true
    @FocusState private var nameFocused: Bool

    private var logic: [GateKind] { GateKind.gates.sorted { $0.bdfName.lowercased() < $1.bdfName.lowercased() } }

    var body: some View {
        SheetFrame(title: "Symbol", okDisabled: resolved == nil, onOK: insert, onCancel: { store.sheet = nil }) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libraries:")
                    List(selection: $selected) {
                        DisclosureGroup(isExpanded: .constant(true)) {
                            DisclosureGroup(isExpanded: .constant(true)) {
                                DisclosureGroup(isExpanded: $logicOpen) {
                                    ForEach(logic) { k in
                                        Label(k.bdfName.lowercased(), systemImage: "square.on.square.dashed").tag(k)
                                    }
                                } label: { Label("logic", systemImage: "folder") }
                                DisclosureGroup(isExpanded: $pinOpen) {
                                    Label("bidir", systemImage: "square.on.square.dashed")
                                        .foregroundStyle(.tertiary)
                                        .help("Bidirectional pins are not supported yet")
                                    Label("input", systemImage: "square.on.square.dashed").tag(GateKind.input)
                                    Label("output", systemImage: "square.on.square.dashed").tag(GateKind.output)
                                } label: { Label("pin", systemImage: "folder") }
                            } label: { Label("primitives", systemImage: "folder") }
                        } label: { Label("libraries/", systemImage: "folder") }
                    }
                    .frame(width: 220, height: 280)
                    .onChange(of: selected) { _, k in if let k { name = symbolName(k) } }
                    Text("Name:")
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { if resolved != nil { insert() } }
                        .onChange(of: name) { _, v in if let k = lookup(v) { selected = k } }
                    Toggle("Repeat-insert mode", isOn: $store.repeatInsert).toggleStyle(.checkbox)
                    Toggle("Insert symbol as block", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        .help("Blocks are not supported yet")
                }
                ZStack {
                    Rectangle().fill(Theme.paper)
                    Canvas { ctx, size in
                        SheetRenderer.drawGrid(&ctx, size: size, zoom: 1.5)
                        guard let k = resolved else { return }
                        let s = k.size
                        let z: CGFloat = min(2, (size.width - 40) / s.width)
                        let c = Component(kind: k, name: k.isPin ? (k == .input ? "pin_name" : "pin_name") : "inst",
                                          x: 0, y: 0)
                        ctx.translateBy(x: Routing.snap((size.width - s.width * z) / 2), y: Routing.snap((size.height - s.height * z) / 2))
                        ctx.scaleBy(x: z, y: z)
                        var o = SheetRenderer.Options()
                        o.zoom = z
                        o.showOpenPorts = false
                        SheetRenderer(project: Project(), routing: Routing(project: Project(), conn: Connectivity(Project())), options: o)
                            .drawSymbol(&ctx, c, selected: false, conn: nil)
                    }
                    if resolved == nil {
                        Text("No symbol named \(name)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .overlay(Rectangle().strokeBorder(.separator))
                .frame(width: 320, height: 380)
                .environment(\.colorScheme, .light)
            }
        }
        .frame(width: 600)
        .onAppear {
            name = symbolName(selected ?? .and2)
            nameFocused = true
        }
    }

    private func symbolName(_ k: GateKind) -> String { k.isPin ? k.rawValue : k.bdfName.lowercased() }

    private func lookup(_ s: String) -> GateKind? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "input" { return .input }
        if t == "output" { return .output }
        return GateKind.gates.first { $0.bdfName.lowercased() == t || $0.rawValue == t }
    }

    private var resolved: GateKind? { lookup(name) }

    private func insert() {
        guard let k = resolved else { return }
        store.sheet = nil
        if let p = insertAt {
            store.place(k, at: p)
            if store.repeatInsert { store.tool = .place(k) }
        } else {
            store.tool = .place(k)
        }
        store.tab = .bdf
    }
}

/// Quartus-style dialog body: a tab strip over a bordered pane.
@MainActor
private struct DialogTabs<Content: View>: View {
    var tabs: [String]
    @Binding var current: String
    var minHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $current) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(.background.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(.separator))
        }
    }
}

// MARK: - Pin Properties

/// Quartus "Pin Properties", General tab: Pin name(s) and Default value.
@MainActor
struct PinPropertiesSheet: View {
    @Bindable var store: Store
    var id: UUID
    @State private var name = ""
    @State private var location = ""
    @State private var defaultValue = "VCC"
    @State private var tab = "General"
    @FocusState private var nameFocused: Bool

    var body: some View {
        let pin = store.project.component(id)
        SheetFrame(title: "Pin Properties", okDisabled: !Compiler.isValidName(name), onOK: apply, onCancel: { store.sheet = nil }) {
            DialogTabs(tabs: ["General"], current: $tab) {
                Text("Enter one pin name. Bus names such as name[3..0] and comma-separated lists are not supported yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Pin name(s):")
                        TextField("", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                            .onSubmit { if Compiler.isValidName(name) { apply() } }
                    }
                    if pin?.kind == .input {
                        GridRow {
                            Text("Default value:")
                            Picker("", selection: $defaultValue) {
                                Text("VCC").tag("VCC")
                                Text("GND").tag("GND")
                            }
                            .labelsHidden()
                            .help("The value Quartus uses when this pin is left unconnected in a higher-level design")
                        }
                    }
                    GridRow {
                        Text("Location:")
                        Picker("", selection: $location) {
                            Text("Not assigned").tag("")
                            ForEach(BoardPin.de10Standard.filter { $0.isInput == (pin?.kind == .input) }) {
                                Text("\($0.label)  (\($0.pin))").tag($0.pin)
                            }
                            if !location.isEmpty && BoardPin.lookup(location) == nil { Text(location).tag(location) }
                        }
                        .labelsHidden()
                        .help("Same as the Location column in the Pin Planner")
                    }
                }
                if !name.isEmpty && !Compiler.isValidName(name) {
                    Text("Names start with a letter and use only letters, digits and _.").font(.caption).foregroundStyle(Theme.error)
                }
            }
        }
        .frame(width: 460)
        .onAppear {
            name = pin?.name ?? ""
            location = pin?.location ?? ""
            defaultValue = pin?.defaultValue ?? "VCC"
            nameFocused = true
        }
    }

    private func apply() {
        let dv = defaultValue
        store.updateComponent(id) { c in
            c.name = name
            if c.kind == .input { c.defaultValue = dv == "VCC" ? nil : dv }
        }
        store.assign(id, to: location.isEmpty ? nil : location)
        store.sheet = nil
    }
}

// MARK: - Symbol Properties

/// Quartus "Symbol Properties": General (instance name) and Ports.
@MainActor
struct SymbolPropertiesSheet: View {
    @Bindable var store: Store
    var id: UUID
    @State private var name = ""
    @State private var portNames: [String] = []
    @State private var tab = "General"
    @FocusState private var nameFocused: Bool

    var body: some View {
        let c = store.project.component(id)
        SheetFrame(title: "Symbol Properties", okDisabled: !Compiler.isValidName(name), onOK: apply, onCancel: { store.sheet = nil }) {
            DialogTabs(tabs: ["General", "Ports"], current: $tab, minHeight: 190) {
                if tab == "General" {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            Text("Symbol name:")
                            Text(c?.symbolName.lowercased() ?? "").monospaced()
                        }
                        GridRow {
                            Text("Instance name:")
                            TextField("", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                                .onSubmit { if Compiler.isValidName(name) { apply() } }
                        }
                        GridRow {
                            Text("Orientation:")
                            Text(c?.orient.title ?? "")
                        }
                    }
                } else if let c {
                    Text("Name a port's node to connect it to every pin and node with the same name.")
                        .font(.callout).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Port").font(.caption).foregroundStyle(.secondary)
                            Text("Type").font(.caption).foregroundStyle(.secondary)
                            Text("Node name").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(c.portIndices, id: \.self) { i in
                            GridRow {
                                Text(c.portName(i)).monospaced()
                                Text(c.isOutputPort(i) ? "output" : "input")
                                TextField("unnamed", text: binding(i)).textFieldStyle(.roundedBorder).monospaced()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 440)
        .onAppear {
            name = c?.name ?? ""
            if let c { portNames = c.portIndices.map { store.project.labels[PortRef(comp: id, port: $0).key] ?? "" } }
            nameFocused = true
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { i < portNames.count ? portNames[i] : "" }, set: { if i < portNames.count { portNames[i] = $0 } })
    }

    private func apply() {
        store.mutate { p in
            guard let idx = p.index(of: id) else { return }
            p.components[idx].name = name
            for (i, raw) in portNames.enumerated() {
                let key = PortRef(comp: id, port: i).key
                let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
                if t.isEmpty { p.labels.removeValue(forKey: key) } else { p.labels[key] = t }
            }
        }
        store.sheet = nil
    }
}

// MARK: - Node Properties (naming a node)

/// Quartus "Node Properties", General tab: Name.
@MainActor
struct NodePropertiesSheet: View {
    @Bindable var store: Store
    var ref: PortRef
    @State private var name = ""
    @State private var tab = "General"
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Node Properties", okDisabled: !(name.isEmpty || Compiler.isValidName(name)), onOK: apply,
                   onCancel: { store.sheet = nil }) {
            DialogTabs(tabs: ["General"], current: $tab) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Name:")
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(apply)
                    }
                }
                Text("The node on \(store.describe(ref)) connects to every pin and node with the same name. Leave the name empty to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let pins = store.project.inputPins.map { $0.name }
                if !pins.isEmpty {
                    HStack(spacing: 6) {
                        Text("Input pins:").font(.caption).foregroundStyle(.secondary)
                        ForEach(pins, id: \.self) { n in
                            Button(n) { name = n }.controlSize(.small)
                        }
                    }
                }
                if !name.isEmpty && !Compiler.isValidName(name) {
                    Text("Names start with a letter and use only letters, digits and _.").font(.caption).foregroundStyle(Theme.error)
                }
            }
        }
        .frame(width: 420)
        .onAppear {
            let typed = store.editorPendingName
            store.editorPendingName = nil
            name = typed ?? store.project.labels[ref.key] ?? ""
            focused = true
            if typed != nil {
                // Keep typing after the first letter: put the caret after it instead of selecting it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private func apply() {
        guard name.isEmpty || Compiler.isValidName(name) else { return }
        store.setLabel(ref, name)
        store.selection = name.isEmpty ? [] : [.node(ref)]
        store.sheet = nil
    }
}

/// Changing a device is a project edit, not document replacement.
@MainActor
struct DeviceSheet: View {
    @Bindable var store: Store
    @State private var device = ""

    var body: some View {
        SheetFrame(title: "Device", okDisabled: device.trimmingCharacters(in: .whitespaces).isEmpty,
                   onOK: {
                       let value = device.trimmingCharacters(in: .whitespaces).uppercased()
                       store.mutate { $0.device = value }
                       store.sheet = nil
                   }, onCancel: { store.sheet = nil }) {
            TextField("Cyclone V device", text: $device).textFieldStyle(.roundedBorder)
        }
        .frame(width: 420)
        .onAppear { device = store.project.device }
    }
}

// MARK: - New Project Wizard

@MainActor
struct NewProjectWizard: View {
    @Bindable var store: Store
    @State private var name = "Lab1"
    @State private var device = "5CSXFC6D6F31C6"
    @State private var starterPins = true

    var body: some View {
        SheetFrame(title: "New Project Wizard", okTitle: "Finish", okDisabled: !Compiler.isValidName(name),
                   onOK: finish, onCancel: { store.sheet = nil }) {
            Form {
                Section("Directory, Name, Top-Level Entity") {
                    LabeledContent("Name of the project:") { TextField("", text: $name).monospaced().labelsHidden() }
                    LabeledContent("Top-level design entity:", value: name)
                }
                Section("Family, Device & Board Settings") {
                    LabeledContent("Family:", value: "Cyclone V (E/GX/GT/SX/SE/ST)")
                    LabeledContent("Device:") { TextField("", text: $device).monospaced().labelsHidden() }
                    LabeledContent("Board:", value: device == "5CSXFC6D6F31C6" ? "DE10-Standard" : "Custom")
                }
                Section("Starter Pins") {
                    Toggle("Add inputs w, x, y, z (SW3 to SW0) and output f (LEDR0)", isOn: $starterPins)
                }
            }
            .formStyle(.grouped)
            if store.dirty && !store.project.components.isEmpty {
                Text("This replaces the open project. Save it first if you want to keep it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 520)
    }

    private func finish() {
        guard store.confirmDiscard() else { return }
        store.sheet = nil
        store.newProject(name: name, device: device.trimmingCharacters(in: .whitespaces).uppercased(), starterPins: starterPins)
    }
}
#endif

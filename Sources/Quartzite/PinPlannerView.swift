#if canImport(SwiftUI)
import SwiftUI

@MainActor
struct PinPlannerView: View {
    @Bindable var store: Store
    @State private var selectedPin: UUID?

    var body: some View {
        let pins = store.project.inputPins + store.project.outputPins
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pin Planner").font(.title3.weight(.semibold))
                    Text("\(store.project.device), DE10-Standard. Select a node, then click a switch, push button, LED or 7-segment display segment.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Auto-Assign (SW / LEDR)") { store.autoAssignPins() }
                    .help("Inputs in order (MSB first) go to SW(n-1) to SW0, outputs to LEDR0, LEDR1, ...")
                Button("Import Assignments...") { store.importAssignments() }
                Button("Export Assignments...") {
                    store.exportText("\(store.project.entityName)_pins.qsf", QuartusExport.pinAssignments(store.project))
                }
            }
            .padding(16)
            BoardView(store: store, mode: .assign, selectedPin: $selectedPin)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            if pins.isEmpty {
                ContentUnavailableView {
                    Label("No pins yet", systemImage: "pin.slash")
                } description: {
                    Text("Insert input and output pins in \(store.project.entityName).bdf, or add the starter pins.")
                } actions: {
                    Button("Add Starter Pins") { store.insertStarterPins() }
                }
            } else {
                HStack {
                    Text("All Pins").font(.callout.weight(.semibold))
                    Spacer()
                    if store.flow?.fit == nil {
                        Text("Fitter Location fills in after Start Compilation").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.bar)
                Table(pins, selection: $selectedPin) {
                    TableColumn("Node Name") { p in
                        Label(p.name, systemImage: p.kind == .input ? "arrow.right.to.line" : "arrow.right.circle")
                            .fontWeight(.medium)
                    }
                    TableColumn("Direction") { p in Text(p.kind == .input ? "Input" : "Output") }
                        .width(64)
                    TableColumn("Location") { p in LocationField(store: store, pin: p) }
                        .width(min: 120, ideal: 140)
                    TableColumn("I/O Bank") { p in
                        Text(CycloneV.pin(p.location)?.bank ?? "").monospaced()
                    }
                    .width(60)
                    TableColumn("Fitter Location") { p in
                        Text(fitterLocation(p)).monospaced().foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 110)
                    TableColumn("Board I/O Standard") { p in
                        Text(BoardPin.lookup(p.location)?.ioStandard ?? "").foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn("Board Resource") { p in
                        Text(boardText(p))
                            .foregroundStyle(p.location == nil ? Theme.warning : .secondary)
                    }
                }
            }
        }
        .onAppear { if selectedPin == nil { selectedPin = pins.first { $0.location == nil }?.id ?? pins.first?.id } }
    }

    /// Where the last Fitter run put the pin (same as Location unless it had none).
    private func fitterLocation(_ p: Component) -> String {
        guard !store.compileIsStale, let io = store.flow?.fit?.io.first(where: { $0.component == p.id }) else { return "" }
        return io.location
    }

    private func boardText(_ p: Component) -> String {
        guard let loc = p.location, !loc.isEmpty else { return "Not assigned" }
        if let b = BoardPin.lookup(loc) { return b.longLabel }
        guard let pkg = CycloneV.pin(loc) else { return "Not a pin of \(CycloneV.device)" }
        return pkg.isUserIO ? "I/O pin not wired to a board resource" : (pkg.function ?? "Not an I/O pin")
    }
}

/// Quartus Assignment Editor, showing the project's Location assignments.
@MainActor
struct AssignmentEditorView: View {
    @Bindable var store: Store
    @State private var filter = "*"
    @State private var filterOn = true

    private var pins: [Component] {
        let all = store.project.inputPins + store.project.outputPins
        guard filterOn, !filter.isEmpty, filter != "*" else { return all }
        let pattern = filter.lowercased()
        return all.filter { p in
            let n = p.name.lowercased()
            if pattern.contains("*") {
                let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                var idx = n.startIndex
                for (i, part) in parts.enumerated() where !part.isEmpty {
                    guard let r = n.range(of: part, range: idx..<n.endIndex) else { return false }
                    if i == 0 && r.lowerBound != n.startIndex { return false }
                    idx = r.upperBound
                }
                if let last = parts.last, !last.isEmpty { return n.hasSuffix(last) }
                return true
            }
            return n.contains(pattern)
        }
    }

    var body: some View {
        let assigned = pins.filter { !($0.location ?? "").isEmpty }
        let open = pins.filter { ($0.location ?? "").isEmpty }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Filter on node names:", isOn: $filterOn).toggleStyle(.checkbox)
                TextField("*", text: $filter).textFieldStyle(.roundedBorder).frame(width: 240).disabled(!filterOn)
                Spacer()
                Text("Location assignments are written to \(store.project.entityName).qsf on export").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.bar)
            Divider()
            Table(assigned) {
                TableColumn("Status") { p in statusIcon(p) }.width(44)
                TableColumn("From") { _ in Text("") }.width(70)
                TableColumn("To") { p in
                    Label(p.name, systemImage: p.kind == .input ? "arrow.right.to.line" : "arrow.right.circle")
                }
                TableColumn("Assignment Name") { _ in Text("Location") }
                TableColumn("Value") { p in LocationField(store: store, pin: p) }.width(min: 120, ideal: 140)
                TableColumn("Enabled") { _ in Text("Yes") }.width(60)
                TableColumn("Comment") { p in Text(BoardPin.lookup(p.location)?.longLabel ?? "").foregroundStyle(.secondary) }
            }
            if !open.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Text("<<new>>").foregroundStyle(Theme.ok).monospaced()
                    Text("Nodes without a Location:").foregroundStyle(.secondary)
                    ForEach(open) { p in
                        Menu(p.name) {
                            ForEach(BoardPin.options(forInput: p.kind == .input)) { o in
                                Button("\(o.longLabel)  (\(o.pin))") { store.assign(p.id, to: o.pin) }
                            }
                        }
                        .fixedSize()
                    }
                    Spacer()
                }
                .font(.callout)
                .padding(8)
            }
        }
    }

    @ViewBuilder private func statusIcon(_ p: Component) -> some View {
        if let pkg = CycloneV.pin(p.location), pkg.isUserIO {
            Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Theme.ok).help("\(pkg.location) is a user I/O pin in bank \(pkg.bank ?? "")")
        } else {
            Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(Theme.error).help("Not a user I/O pin of \(CycloneV.device); the Fitter will report an error")
        }
    }
}

/// Editable location cell: type AC30 or PIN_AC30, or pick from the menu.
@MainActor
private struct LocationField: View {
    @Bindable var store: Store
    var pin: Component
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("PIN_...", text: $text)
                .textFieldStyle(.plain)
                .monospaced()
                .onSubmit(commit)
            Menu {
                Button("Not assigned") { store.assign(pin.id, to: nil) }
                Divider()
                ForEach(BoardPin.options(forInput: pin.kind == .input)) { o in
                    Button("\(o.longLabel)  (\(o.pin))") { store.assign(pin.id, to: o.pin) }
                }
            } label: { EmptyView() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .onAppear { text = pin.location ?? "" }
        .onChange(of: pin.location) { _, v in text = v ?? "" }
    }

    private func commit() {
        var t = text.trimmingCharacters(in: .whitespaces).uppercased()
        if t.isEmpty { store.assign(pin.id, to: nil); return }
        if !t.hasPrefix("PIN_") { t = "PIN_" + t }
        store.assign(pin.id, to: t)
    }
}

// MARK: - Board

/// A drawing of the DE10-Standard's switches, push buttons and red LEDs.
/// In `.assign` mode clicking a resource assigns the selected node; in `.play`
/// mode the switches drive the simulated circuit and the LEDs show its outputs.
@MainActor
struct BoardView: View {
    enum Mode { case assign, play }
    @Bindable var store: Store
    var mode: Mode
    var selectedPin: Binding<UUID?> = .constant(nil)

    private var pins: [Component] { store.project.inputPins + store.project.outputPins }

    var body: some View {
        let outputs = mode == .play ? store.boardOutputs() : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DE10-Standard").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                if mode == .play {
                    Text(outputs == nil ? "Fix the design errors to try it on the board" : "Click the switches to try your circuit")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(alignment: .bottom, spacing: 22) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach((0..<10).reversed(), id: \.self) { i in led(i, outputs: outputs) }
                    }
                    HStack(spacing: 6) {
                        ForEach((0..<10).reversed(), id: \.self) { i in slide(i) }
                    }
                }
                VStack(alignment: .trailing, spacing: 14) {
                    HStack(spacing: 10) {
                        ForEach((0..<6).reversed(), id: \.self) { d in hexDigit(d, outputs: outputs) }
                    }
                    HStack(spacing: 8) {
                        ForEach((0..<4).reversed(), id: \.self) { i in key(i) }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 2).fill(Color(red: 0.11, green: 0.13, blue: 0.16)))
    }

    private func owner(_ pin: String) -> Component? { pins.first { $0.location?.uppercased() == pin } }

    private func resource(_ prefix: String, _ i: Int) -> BoardPin {
        BoardPin.named("\(prefix)\(i)")!
    }

    private func tapped(_ r: BoardPin) {
        switch mode {
        case .assign:
            if let sel = selectedPin.wrappedValue, let pin = store.project.component(sel), (pin.kind == .input) == r.isInput {
                store.assign(sel, to: owner(r.pin)?.id == sel ? nil : r.pin)
            } else if let o = owner(r.pin) {
                selectedPin.wrappedValue = o.id
            }
        case .play:
            if let o = owner(r.pin), o.kind == .input { store.boardInputs[o.id] = !(store.boardInputs[o.id] ?? false) }
        }
    }

    private func tag(_ r: BoardPin) -> some View {
        let o = owner(r.pin)
        let selected = o != nil && o?.id == selectedPin.wrappedValue && mode == .assign
        return Text(o?.name ?? " ")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(selected ? Color.white : Theme.accent)
            .padding(.horizontal, 4)
            .frame(minWidth: 26, minHeight: 15)
            .background(o == nil ? Color.clear : (selected ? Theme.accent : Color.white.opacity(0.92)),
                        in: RoundedRectangle(cornerRadius: 3))
    }

    private func led(_ i: Int, outputs: [UUID: Bool]?) -> some View {
        let r = resource("LEDR", i)
        let o = owner(r.pin)
        let on = o.flatMap { outputs?[$0.id] } ?? false
        return Button { tapped(r) } label: {
            VStack(spacing: 4) {
                tag(r)
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? Color.red : Color(red: 0.35, green: 0.12, blue: 0.12))
                    .frame(width: 12, height: 7)
                    .shadow(color: on ? .red.opacity(0.9) : .clear, radius: 5)
                Text("LEDR\(i)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(r.label) (\(r.pin))")
    }

    private func slide(_ i: Int) -> some View {
        let r = resource("SW", i)
        let o = owner(r.pin)
        let up = mode == .play && (o.map { store.boardInputs[$0.id] ?? false } ?? false)
        return Button { tapped(r) } label: {
            VStack(spacing: 4) {
                ZStack(alignment: up ? .top : .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.55)).frame(width: 14, height: 30)
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.85)).frame(width: 12, height: 13).padding(1)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: up)
                Text("SW\(i)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
                tag(r)
            }
            .frame(width: 40)
            .opacity(mode == .play && o == nil ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .play ? (o.map { "\($0.name) = \(up ? 1 : 0)" } ?? "\(r.label) is not used") : "\(r.label) (\(r.pin))")
    }

    /// One seven-segment display; each segment is a pin (active low: it lights at 0).
    private func hexDigit(_ d: Int, outputs: [UUID: Bool]?) -> some View {
        // Segment rectangles in a 30 x 50 digit, in HEXd[0]...HEXd[6] order (a...g).
        let rects: [CGRect] = [
            CGRect(x: 6, y: 0, width: 18, height: 4), CGRect(x: 25, y: 4, width: 4, height: 19),
            CGRect(x: 25, y: 27, width: 4, height: 19), CGRect(x: 6, y: 46, width: 18, height: 4),
            CGRect(x: 1, y: 27, width: 4, height: 19), CGRect(x: 1, y: 4, width: 4, height: 19),
            CGRect(x: 6, y: 23, width: 18, height: 4),
        ]
        return VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { k in
                    let r = BoardPin.named("HEX\(d)[\(k)]")!
                    let o = owner(r.pin)
                    let lit = o.flatMap { outputs?[$0.id] }.map { !$0 } ?? false
                    let selected = mode == .assign && o != nil && o?.id == selectedPin.wrappedValue
                    Button { tapped(r) } label: {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(lit ? Color.red : (selected ? Color.white : (o != nil && mode == .assign ? Theme.accent : Color(red: 0.32, green: 0.12, blue: 0.12))))
                            .shadow(color: lit ? .red.opacity(0.8) : .clear, radius: 4)
                            .frame(width: rects[k].width, height: rects[k].height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: rects[k].minX, y: rects[k].minY)
                    .help("\(r.longLabel) (\(r.pin))" + (o.map { ": \($0.name)" } ?? ""))
                }
            }
            .frame(width: 30, height: 50, alignment: .topLeading)
            Text("HEX\(d)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private func key(_ i: Int) -> some View {
        let r = resource("KEY", i)
        let o = owner(r.pin)
        let pressed = mode == .play && (o.map { store.boardInputs[$0.id] ?? false } ?? false)
        return Button { tapped(r) } label: {
            VStack(spacing: 4) {
                Circle().fill(pressed ? Color(white: 0.55) : Color(white: 0.8)).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4)))
                Text("KEY\(i)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
                tag(r)
            }
            .frame(width: 40)
            .opacity(mode == .play && o == nil ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(r.label) (\(r.pin)). Push buttons read 0 while pressed.")
    }
}
#endif

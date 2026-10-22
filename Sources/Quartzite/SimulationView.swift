#if canImport(SwiftUI)
import SwiftUI

@MainActor
struct SimulationView: View {
    @Bindable var store: Store
    @State private var kmapOutput = 0
    @AppStorage("groupInputs") private var groupInputs = true
    @AppStorage("busRadix") private var radix = WaveformView.Radix.hex
    /// Height of the input-order and expected-minterm fields; the row scrolls past `expectedLimit`.
    @State private var expectedHeight: CGFloat = 60
    private let expectedLimit: CGFloat = 150
    /// Whether the expected-minterm fields are shown (nil: open for up to 8 outputs).
    @State private var expectedOpen: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolStrip
            Divider()
            expectedRow
            Divider()
            if let sim = store.simulation {
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 20) {
                        ScrollView(.horizontal) {
                            WaveformView(sim: sim, groupInputs: groupInputs, radix: radix).padding(.vertical, 4)
                        }
                        // A wide truth table (many outputs) scrolls instead of widening the window.
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 28) {
                                TruthTableView(sim: sim)
                                VStack(alignment: .leading, spacing: 20) {
                                    if (2...4).contains(sim.inputCount), !sim.outputNames.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if sim.outputNames.count > 1 {
                                                Picker("K-map of", selection: $kmapOutput) {
                                                    ForEach(sim.outputNames.indices, id: \.self) { Text(sim.outputNames[$0]).tag($0) }
                                                }
                                                .frame(width: 180)
                                            }
                                            KMapView(sim: sim, output: min(kmapOutput, sim.outputNames.count - 1))
                                        }
                                    }
                                    BoardView(store: store, mode: .play).fixedSize()
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("Not simulated yet", systemImage: "waveform.path")
                } description: {
                    Text("Run Functional Simulation to evaluate every input combination. Inputs count up from 0 with the first input as the MSB.")
                } actions: {
                    Button("Run Functional Simulation") { store.simulate() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Mirrors the Simulation Waveform Editor toolbar.
    private var toolStrip: some View {
        HStack(spacing: 10) {
            Button { store.simulate() } label: {
                Label("Run Functional Simulation", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Simulation > Run Functional Simulation (⌥⌘R)")
            Divider().frame(height: 18)
            Toggle("Group inputs", isOn: $groupInputs)
                .toggleStyle(.checkbox)
                .help("Edit > Grouping > Group: show the inputs as one bus")
            Picker("Radix", selection: $radix) {
                ForEach(WaveformView.Radix.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .disabled(!groupInputs)
            Divider().frame(height: 18)
            if store.topProject.inputPins.count <= SimulationResult.maxInputs {
                Text("End time: \(QuartusExport.fmt(QuartusExport.vwfTiming(store.topProject.inputPins.count).end)) ns")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Each input combination lasts \(QuartusExport.fmt(QuartusExport.vwfTiming(store.topProject.inputPins.count).step)) ns, the same vectors as the exported Waveform.vwf (Count Value)")
            } else {
                Text("Waveforms support up to \(SimulationResult.maxInputs) inputs").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let sim = store.simulation {
                Button("Save Image...") {
                    store.exportPNG("\(store.topProject.entityName)_waveform.png",
                                    WaveformSnapshot(sim: sim, project: store.topProject.entityName, groupInputs: groupInputs, radix: radix))
                }
            }
            Button("Export .vwf...") {
                do { store.exportText("Waveform.vwf", try QuartusExport.vwf(store.topProject)) }
                catch { store.alert("Waveform export failed", error.localizedDescription) }
            }
                .help("Test vectors for Quartus. Open in the lab and run Simulation > Run Functional Simulation.")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    /// Wraps to the pane's width and scrolls once it is taller than `expectedLimit`, so a design
    /// with many outputs (Lab 3 has about 30) never pushes the window wider than the screen.
    private var expectedRow: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input order (MSB to LSB)").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(store.topProject.inputPins.enumerated()), id: \.element.id) { idx, pin in
                            HStack(spacing: 2) {
                                Button { store.moveInput(pin.id, by: -1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(idx == 0)
                                Text(pin.name).fontWeight(.semibold).monospaced().padding(.horizontal, 3)
                                Button { store.moveInput(pin.id, by: 1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(idx == store.topProject.inputPins.count - 1)
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radius))
                        }
                    }
                }
                let outputs = store.topProject.outputPins
                if !outputs.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { expectedOpen ?? (outputs.count <= 8) }, set: { expectedOpen = $0 })) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(outputs) { expectedField($0) }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Expected minterms (optional)").font(.caption).foregroundStyle(.secondary)
                            Text(expectedSummary(outputs)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { expectedHeight = $0 }
        }
        .frame(height: min(expectedHeight, expectedLimit))
    }

    /// "3 of 26 outputs have expected minterms, 1 mismatch".
    private func expectedSummary(_ outputs: [Component]) -> String {
        let set = outputs.filter { !(store.topProject.expected[$0.id.uuidString] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        var s = "\(set) of \(outputs.count) output\(outputs.count == 1 ? "" : "s") set"
        if let sim = store.simulation {
            let bad = sim.outputIDs.indices.filter { sim.matches(output: $0) == false }.count
            if bad > 0 { s += ", \(bad) mismatch\(bad == 1 ? "" : "es")" }
        }
        return s
    }

    private func expectedField(_ out: Component) -> some View {
        HStack(spacing: 6) {
            Text("\(out.name) = Σm(").monospaced()
            TextField("e.g. 0, 4, 9", text: Binding(
                get: { store.topProject.expected[out.id.uuidString] ?? "" },
                set: { store.setExpected(out.id, $0) }))
                .textFieldStyle(.roundedBorder)
                .monospaced()
                .frame(minWidth: 110, maxWidth: 220)
            Text(")").monospaced()
            if let sim = store.simulation, let i = sim.outputIDs.firstIndex(of: out.id), let ok = sim.matches(output: i) {
                Label(ok ? "Matches" : "Mismatch", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Theme.ok : Theme.error)
            }
        }
        .help("Expected minterms for \(out.name) (optional)")
    }
}

/// Left to right, wrapping onto a new line when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, arrange(width: bounds.width, subviews).origins) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, used: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            origins.append(CGPoint(x: x, y: y))
            used = max(used, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (origins, CGSize(width: used, height: y + line))
    }
}

// MARK: - Waveform

@MainActor
struct WaveformView: View {
    enum Radix: String, CaseIterable, Identifiable {
        case hex, unsigned, binary
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hex: return "Hexadecimal"
            case .unsigned: return "Unsigned Decimal"
            case .binary: return "Binary"
            }
        }
        func format(_ v: Int, bits: Int) -> String {
            switch self {
            case .hex: return String(v, radix: 16).uppercased()
            case .unsigned: return String(v)
            case .binary:
                let s = String(v, radix: 2)
                return String(repeating: "0", count: max(0, bits - s.count)) + s
            }
        }
    }

    var sim: SimulationResult
    var groupInputs = true
    var radix: Radix = .hex
    var nameWidth: CGFloat = 120
    var rowHeight: CGFloat = 30

    private enum Row { case bus, input(Int), output(Int), expected(Int) }

    private var rows: [Row] {
        var r: [Row] = groupInputs ? [.bus] : []
        r += sim.inputNames.indices.map { .input($0) }
        for o in sim.outputNames.indices {
            r.append(.output(o))
            if sim.expected[o] != nil { r.append(.expected(o)) }
        }
        return r
    }

    /// 1,024 rows at 12 points would make a canvas wider than a Retina layer can be (16,384 pixels).
    private var stepWidth: CGFloat { sim.rows.count <= 16 ? 46 : (sim.rows.count <= 64 ? 24 : (sim.rows.count <= 512 ? 12 : 6)) }
    private var timeStep: Double { QuartusExport.vwfTiming(sim.inputCount).step }

    var body: some View {
        let rows = rows
        let width = nameWidth + stepWidth * CGFloat(sim.rows.count) + 20
        let height = 26 + rowHeight * CGFloat(rows.count)
        Canvas { ctx, _ in
            let n = sim.rows.count
            let x0 = nameWidth
            // time axis
            let every = max(1, Int((60 / stepWidth).rounded(.up)))
            for i in stride(from: 0, through: n, by: every) {
                let x = x0 + CGFloat(i) * stepWidth
                ctx.draw(Text(QuartusExport.fmt(Double(i) * timeStep) + " ns").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: 10), anchor: .center)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 18)); tick.addLine(to: CGPoint(x: x, y: height))
                ctx.stroke(tick, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            }
            for (ri, row) in rows.enumerated() {
                let top = 26 + CGFloat(ri) * rowHeight
                let hi = top + 6, lo = top + rowHeight - 6, mid = top + rowHeight / 2
                if ri % 2 == 0 {
                    ctx.fill(Path(CGRect(x: 0, y: top, width: width, height: rowHeight)), with: .color(.secondary.opacity(0.05)))
                }
                switch row {
                case .bus:
                    ctx.draw(Text("Inputs").font(.system(size: 11, weight: .semibold)), at: CGPoint(x: 8, y: mid), anchor: .leading)
                    for i in 0..<n {
                        let a = x0 + CGFloat(i) * stepWidth, b = a + stepWidth
                        var hex = Path()
                        hex.move(to: CGPoint(x: a, y: mid))
                        hex.addLine(to: CGPoint(x: a + 3, y: hi)); hex.addLine(to: CGPoint(x: b - 3, y: hi))
                        hex.addLine(to: CGPoint(x: b, y: mid))
                        hex.addLine(to: CGPoint(x: b - 3, y: lo)); hex.addLine(to: CGPoint(x: a + 3, y: lo))
                        hex.closeSubpath()
                        ctx.stroke(hex, with: .color(.blue), lineWidth: 1)
                        // Only labels that fit their step (monospaced digits are 0.6 em wide); with 128+ rows they would overlap.
                        let label = radix.format(i, bits: sim.inputCount), size: CGFloat = radix == .binary ? 8 : 10
                        if CGFloat(label.count) * size * 0.6 <= stepWidth - 4 {
                            ctx.draw(Text(label).font(.system(size: size, design: .monospaced)), at: CGPoint(x: (a + b) / 2, y: mid))
                        }
                    }
                case .input(let k):
                    ctx.draw(Text(sim.inputNames[k]).font(.system(size: 11)), at: CGPoint(x: 20, y: mid), anchor: .leading)
                    trace(&ctx, values: sim.rows.map { $0.inputs[k] }, x0: x0, hi: hi, lo: lo, color: .blue)
                case .output(let o):
                    ctx.draw(Text(sim.outputNames[o]).font(.system(size: 11, weight: .semibold)), at: CGPoint(x: 8, y: mid), anchor: .leading)
                    if let exp = sim.expected[o] {
                        for i in 0..<n where sim.rows[i].outputs[o] != exp.contains(i) {
                            ctx.fill(Path(CGRect(x: x0 + CGFloat(i) * stepWidth, y: top + 2, width: stepWidth, height: rowHeight - 4)),
                                     with: .color(.red.opacity(0.22)))
                        }
                    }
                    trace(&ctx, values: sim.rows.map { $0.outputs[o] }, x0: x0, hi: hi, lo: lo, color: .green)
                case .expected(let o):
                    ctx.draw(Text("expected").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: 20, y: mid), anchor: .leading)
                    let exp = sim.expected[o] ?? []
                    trace(&ctx, values: (0..<n).map { exp.contains($0) }, x0: x0, hi: hi, lo: lo, color: .gray, dashed: true)
                }
            }
            var sep = Path()
            sep.move(to: CGPoint(x: x0 - 4, y: 18)); sep.addLine(to: CGPoint(x: x0 - 4, y: height))
            ctx.stroke(sep, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }

    private func trace(_ ctx: inout GraphicsContext, values: [Bool], x0: CGFloat, hi: CGFloat, lo: CGFloat,
                       color: Color, dashed: Bool = false) {
        var p = Path()
        for (i, v) in values.enumerated() {
            let a = x0 + CGFloat(i) * stepWidth, b = a + stepWidth
            let y = v ? hi : lo
            if i == 0 { p.move(to: CGPoint(x: a, y: y)) } else { p.addLine(to: CGPoint(x: a, y: y)) }
            p.addLine(to: CGPoint(x: b, y: y))
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, dash: dashed ? [4, 3] : []))
    }
}

/// Self-contained, light-mode image for printing or showing a TA.
@MainActor
struct WaveformSnapshot: View {
    var sim: SimulationResult
    var project: String
    var groupInputs = true
    var radix: WaveformView.Radix = .hex
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(project): functional simulation").font(.headline)
            Text("Simulated in Quartzite for Mac (not Quartus). \(sim.rows.count) input combinations, \(sim.inputNames.joined(separator: ", ")) (MSB to LSB).")
                .font(.caption).foregroundStyle(.secondary)
            WaveformView(sim: sim, groupInputs: groupInputs, radix: radix)
        }
        .padding(20)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Truth table

@MainActor
struct TruthTableView: View {
    var sim: SimulationResult

    /// Past 64 rows, or 2000 cells, the table scrolls on its own with the header pinned.
    var scrolls: Bool {
        let columns = sim.inputNames.count + sim.outputNames.count + sim.expected.compactMap { $0 }.count
        return sim.rows.count > 64 || sim.rows.count * columns > 2000
    }

    /// One monospaced attributed string per row, not a view per cell: 512 rows of 9 inputs and 30
    /// outputs would otherwise be ~36,000 views, rebuilt on every keystroke in an expected field.
    /// A scrolling table builds only the rows on screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if scrolls {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(sim.rows.indices, id: \.self) { Text(row($0)) }
                        } header: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(header)
                                Divider()
                            }
                            .background {
                                ZStack {
                                    Color(nsColor: .windowBackgroundColor)
                                    Rectangle().fill(.quaternary.opacity(0.4))
                                }
                            }
                        }
                    }
                }
                .frame(height: 420)
            } else {
                Text(header)
                Divider()
                ForEach(sim.rows.indices, id: \.self) { Text(row($0)) }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .fixedSize()
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private static let gap = "  "

    /// `s` centred in a column `width` characters wide.
    private func cell(_ s: String, _ width: Int) -> String {
        let pad = max(0, width - s.count)
        return String(repeating: " ", count: pad / 2) + s + String(repeating: " ", count: pad - pad / 2)
    }

    private func run(_ s: String, _ color: Color? = nil, bold: Bool = false) -> AttributedString {
        var a = AttributedString(s)
        if let color { a.foregroundColor = color }
        if bold { a.font = .system(.callout, design: .monospaced).bold() }
        return a
    }

    private var indexWidth: Int { String(max(0, sim.rows.count - 1)).count }

    private var header: AttributedString {
        var s = run(cell("m", indexWidth), .secondary)
        for name in sim.inputNames { s += run(Self.gap + name) }
        for o in sim.outputNames.indices {
            s += run(Self.gap + sim.outputNames[o], bold: true)
            if sim.expected[o] != nil { s += run(Self.gap + "exp", .secondary) }
        }
        return s
    }

    private func row(_ i: Int) -> AttributedString {
        let r = sim.rows[i]
        var line = run(cell("\(i)", indexWidth), .secondary)
        line += run(zip(sim.inputNames, r.inputs).map { Self.gap + cell($1 ? "1" : "0", $0.count) }.joined())
        for o in sim.outputNames.indices {
            let v = r.outputs[o]
            line += run(Self.gap + cell(v ? "1" : "0", sim.outputNames[o].count),
                        mismatch(i, o) ? .red : (v ? .primary : .secondary), bold: true)
            if let exp = sim.expected[o] { line += run(Self.gap + cell(exp.contains(i) ? "1" : "0", 3), .secondary) }
        }
        if mismatch(i, nil) { line.backgroundColor = Color.red.opacity(0.12) }
        return line
    }

    private func mismatch(_ i: Int, _ o: Int?) -> Bool {
        let outs = o.map { [$0] } ?? Array(sim.outputNames.indices)
        return outs.contains { o in
            guard let exp = sim.expected[o] else { return false }
            return sim.rows[i].outputs[o] != exp.contains(i)
        }
    }
}

// MARK: - K-map

@MainActor
struct KMapView: View {
    var sim: SimulationResult
    var output: Int

    private let gray = [0, 1, 3, 2]

    var body: some View {
        let n = sim.inputCount
        let rowBits = n / 2, colBits = n - rowBits
        let rowCodes = rowBits == 1 ? [0, 1] : gray
        let colCodes = colBits == 1 ? [0, 1] : gray
        let names = sim.inputNames
        let rowLabel = names.prefix(rowBits).joined()
        let colLabel = names.suffix(colBits).joined()
        VStack(alignment: .leading, spacing: 6) {
            Text("K-map of \(sim.outputNames[output])").font(.headline)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("\(rowLabel) \\ \(colLabel)").font(.caption).foregroundStyle(.secondary).frame(width: 64, height: 26)
                    ForEach(colCodes, id: \.self) { c in
                        Text(code(c, colBits)).font(.system(.callout, design: .monospaced)).frame(width: 46, height: 26)
                    }
                }
                ForEach(rowCodes, id: \.self) { r in
                    GridRow {
                        Text(code(r, rowBits)).font(.system(.callout, design: .monospaced)).frame(width: 64, height: 46)
                        ForEach(colCodes, id: \.self) { c in
                            let m = (r << colBits) | c
                            let v = sim.rows[m].outputs[output]
                            let bad = sim.expected[output].map { $0.contains(m) != v } ?? false
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(bad ? Color.red.opacity(0.25) : (v ? Color.accentColor.opacity(0.18) : Color.clear))
                                Rectangle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                                Text("\(m)").font(.system(size: 8)).foregroundStyle(.secondary).padding(3)
                                Text(v ? "1" : "0").font(.system(.title3, design: .monospaced).weight(v ? .bold : .regular))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(width: 46, height: 46)
                        }
                    }
                }
            }
            Text("Grey-code order, cell number = minterm index.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func code(_ v: Int, _ bits: Int) -> String {
        String((0..<bits).reversed().map { (v >> $0) & 1 == 1 ? "1" : "0" })
    }
}

#endif

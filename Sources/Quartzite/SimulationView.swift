#if canImport(SwiftUI)
import SwiftUI

@MainActor
struct SimulationView: View {
    @Bindable var store: Store
    @State private var kmapOutput = 0
    @AppStorage("groupInputs") private var groupInputs = true
    @AppStorage("busRadix") private var radix = WaveformView.Radix.hex

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
                            Spacer(minLength: 0)
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
            if store.project.inputPins.count <= SimulationResult.maxInputs {
                Text("End time: \(QuartusExport.fmt(QuartusExport.vwfTiming(store.project.inputPins.count).end)) ns")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Each input combination lasts \(QuartusExport.fmt(QuartusExport.vwfTiming(store.project.inputPins.count).step)) ns, the same vectors as the exported Waveform.vwf (Count Value)")
            } else {
                Text("Waveforms support up to \(SimulationResult.maxInputs) inputs").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let sim = store.simulation {
                Button("Save Image...") {
                    store.exportPNG("\(store.project.entityName)_waveform.png",
                                    WaveformSnapshot(sim: sim, project: store.project.entityName, groupInputs: groupInputs, radix: radix))
                }
            }
            Button("Export .vwf...") {
                do { store.exportText("Waveform.vwf", try QuartusExport.vwf(store.project)) }
                catch { store.alert("Waveform export failed", error.localizedDescription) }
            }
                .help("Test vectors for Quartus. Open in the lab and run Simulation > Run Functional Simulation.")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var expectedRow: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Input order (MSB to LSB)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(store.project.inputPins.enumerated()), id: \.element.id) { idx, pin in
                        HStack(spacing: 2) {
                            Button { store.moveInput(pin.id, by: -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(idx == 0)
                            Text(pin.name).fontWeight(.semibold).monospaced().padding(.horizontal, 3)
                            Button { store.moveInput(pin.id, by: 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(idx == store.project.inputPins.count - 1)
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radius))
                    }
                }
            }
            ForEach(store.project.outputPins) { out in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expected minterms for \(out.name) (optional)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(out.name) = Σm(").monospaced()
                        TextField("e.g. 0, 4, 9", text: Binding(
                            get: { store.project.expected[out.id.uuidString] ?? "" },
                            set: { store.setExpected(out.id, $0) }))
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .frame(width: 200)
                        Text(")").monospaced()
                        if let sim = store.simulation, let i = sim.outputIDs.firstIndex(of: out.id), let ok = sim.matches(output: i) {
                            Label(ok ? "Matches" : "Mismatch", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? Theme.ok : Theme.error)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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

    private var stepWidth: CGFloat { sim.rows.count <= 16 ? 46 : (sim.rows.count <= 64 ? 24 : 12) }
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
                        if stepWidth >= 20 || radix == .hex {
                            ctx.draw(Text(radix.format(i, bits: sim.inputCount)).font(.system(size: radix == .binary ? 8 : 10, design: .monospaced)),
                                     at: CGPoint(x: (a + b) / 2, y: mid))
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

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("m").foregroundStyle(.secondary)
                ForEach(sim.inputNames, id: \.self) { Text($0) }
                ForEach(sim.outputNames.indices, id: \.self) { o in
                    Text(sim.outputNames[o]).fontWeight(.bold)
                    if sim.expected[o] != nil { Text("exp").foregroundStyle(.secondary).fixedSize() }
                }
            }
            .font(.system(.callout, design: .monospaced))
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(sim.rows.indices, id: \.self) { i in
                GridRow {
                    Text("\(i)").foregroundStyle(.secondary)
                    ForEach(sim.rows[i].inputs.indices, id: \.self) { Text(sim.rows[i].inputs[$0] ? "1" : "0") }
                    ForEach(sim.outputNames.indices, id: \.self) { o in
                        let v = sim.rows[i].outputs[o]
                        Text(v ? "1" : "0").fontWeight(.bold)
                            .foregroundStyle(mismatch(i, o) ? Color.red : (v ? Color.primary : Color.secondary))
                        if let exp = sim.expected[o] {
                            Text(exp.contains(i) ? "1" : "0").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .background(mismatch(i, nil) ? Color.red.opacity(0.12) : .clear)
            }
        }
        .fixedSize()
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radius))
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

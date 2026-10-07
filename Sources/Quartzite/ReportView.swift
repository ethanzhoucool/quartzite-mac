#if canImport(SwiftUI)
import SwiftUI

/// Compilation Report, laid out like Quartus: a Table of Contents tree on the left and
/// the selected section's tables on the right.
@MainActor
struct ReportView: View {
    @Bindable var store: Store
    @State private var filter = ""

    var body: some View {
        if let flow = store.flow {
            let nodes = CompileFlow.report(flow)
            HSplitView {
                VStack(spacing: 0) {
                    PaneHeader(title: "Table of Contents") {}
                    List(nodes, children: \.optionalChildren, selection: $store.reportSelection) { n in
                        Label {
                            Text(n.title).foregroundStyle(n.failed ? Theme.error : Color.primary)
                        } icon: {
                            Image(systemName: icon(n)).foregroundStyle(n.icon == .folder ? Theme.warning : Theme.accent)
                        }
                        .tag(n.id)
                    }
                    .listStyle(.sidebar)
                    .font(.callout)
                }
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                detail(selected(nodes))
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No report yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Start Compilation to run Analysis & Synthesis, the Fitter, the Timing Analyzer estimate and the EDA Netlist Writer.")
            } actions: {
                Button("Start Compilation") { store.startCompilation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isProcessing)
            }
        }
    }

    private func icon(_ n: ReportNode) -> String {
        switch n.icon {
        case .table: return "tablecells"
        case .folder: return "folder.fill"
        case .messages: return "info.circle"
        case .text: return "doc.plaintext"
        }
    }

    /// The selected node, or the first leaf of a selected folder.
    private func selected(_ nodes: [ReportNode]) -> ReportNode {
        let id = store.reportSelection ?? "flow.summary"
        var node = nodes.lazy.compactMap { $0.find(id) }.first ?? nodes[0]
        while node.tables.isEmpty && node.text == nil && node.messages == nil, let first = node.children.first { node = first }
        return node
    }

    @ViewBuilder private func detail(_ node: ReportNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(node.tables.first?.title ?? node.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if node.text != nil {
                    Button("Save Netlist...") { store.saveNetlist() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.accent)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("<<Filter>>", text: $filter).textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .overlay(alignment: .bottom) { Divider() }
            if store.compileIsStale {
                Label("The design changed after this report was generated. Start Compilation again to refresh it.", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let text = node.text {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let ms = node.messages {
                ReportMessages(messages: filter.isEmpty ? ms : ms.filter { $0.matches(filter) })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(node.tables.enumerated()), id: \.offset) { i, t in
                            VStack(alignment: .leading, spacing: 6) {
                                if i > 0 { Text(t.title).font(.callout.weight(.semibold)) }
                                ReportTableView(table: t, filter: filter)
                                if let note = t.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A Quartus report table: header row (when present), then rows with alternating shading.
/// Two-column tables without a header read as Quartus' key/value summaries.
@MainActor
struct ReportTableView: View {
    var table: ReportTableData
    var filter = ""

    var body: some View {
        let rows = filter.isEmpty ? table.rows : table.rows.filter { r in r.contains { $0.localizedCaseInsensitiveContains(filter) } }
        let cols = max(table.header.count, table.rows.map { $0.count }.max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !table.header.isEmpty {
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        Text(c < table.header.count ? table.header[c] : "")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                            .overlay(alignment: .trailing) { Divider() }
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        let v = c < row.count ? row[c] : ""
                        Text(v)
                            .foregroundStyle(table.header.isEmpty && c == 0 ? Color.secondary : Color.primary)
                            .font(c > 0 && looksCode(v) ? .system(size: 12, design: .monospaced) : .callout)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                    }
                }
            }
        }
        .font(.callout)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .frame(maxWidth: cols <= 2 ? 760 : .infinity, alignment: .leading)
    }

    private func looksCode(_ s: String) -> Bool { s.hasPrefix("64'h") || s.contains(" # ") || s.contains(" & ") }
}

/// Messages page of a report section.
@MainActor
struct ReportMessages: View {
    var messages: [Message]

    var body: some View {
        if messages.isEmpty {
            Text("No messages.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(messages, children: \.childrenOrNil) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MessageIcon(level: m.level).font(.system(size: 11))
                    Text(m.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(m.textColor)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
        }
    }
}
#endif

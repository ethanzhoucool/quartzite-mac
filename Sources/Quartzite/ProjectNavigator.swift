#if canImport(SwiftUI)
import SwiftUI

/// Quartus' Project Navigator. Hierarchy: the device, then the entity instances under the
/// top-level entity ("FA:inst2"). Files: every .bdf of the project (the top in bold, a .bsf
/// badge once it has a symbol), Waveform.vwf and the .qsf.
@MainActor
struct ProjectNavigatorPane: View {
    @Bindable var store: Store
    @AppStorage(PaneVisibility.navigatorView) private var view = "Hierarchy"

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
                    Label("Cyclone V: \(store.design.device)", systemImage: "cpu")
                    HierarchyRow(store: store, node: store.design.instanceTree(), trail: [], parentSheet: nil)
                } else {
                    ForEach(store.design.sheets, id: \.id) { s in fileRow(s) }
                    row("Waveform.vwf", icon: DocTab.waveform.icon) { store.tab = .waveform }
                    row("\(store.design.projectName).qsf", icon: "doc.plaintext") { store.tab = .assignments }
                    if store.flow?.netlist != nil {
                        row(NetlistWriter.path(store.topProject.entityName), icon: "doc.text") {
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

    private func row(_ title: String, icon: String, open: @escaping () -> Void) -> some View {
        Label(title, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .help("Double-click to open")
    }

    private func fileRow(_ s: Project) -> some View {
        let id = s.id ?? UUID()
        let isTop = s.entityName.caseInsensitiveCompare(store.design.topLevelEntity) == .orderedSame
        return HStack(spacing: 6) {
            Label("\(s.entityName).bdf", systemImage: DocTab.bdf.icon)
                .fontWeight(isTop ? .bold : .regular)
            if s.symbol != nil {
                Text(".bsf")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.15)))
                    .help("\(s.entityName).bsf: the block symbol, so \(s.entityName) can be placed in other files")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openSheet(id) }
        .help(isTop ? "\(s.entityName).bdf is the top-level entity. Double-click to open." : "Double-click to open")
        .contextMenu {
            Button("Open") { store.openSheet(id) }
            Button("Set as Top-Level Entity") { store.setTopLevel(s.entityName) }.disabled(isTop)
            Button("Create Symbol Files for Current File") {
                store.openSheet(id)
                store.createSymbolFiles(for: id)
            }
            Button("Rename...") { store.sheet = .renameSheet(id) }
            Divider()
            Button("Remove File from Project") {
                do { try store.removeSheet(id) } catch { store.alert("Could not remove \(s.entityName).bdf", error.localizedDescription) }
            }
            .disabled(isTop || store.design.sheets.count == 1)
        }
    }
}

/// One entity instance in the Hierarchy view, with its sub-instances below it.
@MainActor
private struct HierarchyRow: View {
    var store: Store
    var node: HierarchyNode
    /// Block instances (parent sheet, instance) from the top down to this node.
    var trail: [(sheet: UUID, instance: UUID)]
    var parentSheet: UUID?
    @State private var expanded = true

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children.indices, id: \.self) { i in
                    let child = node.children[i]
                    HierarchyRow(store: store, node: child, trail: childTrail(child), parentSheet: sheetID)
                }
            } label: { label }
        }
    }

    /// The sheet this node stands for (nil for macros and missing or recursive blocks).
    private var sheetID: UUID? {
        node.isMacro || node.missing || node.recursive ? nil : store.design.sheet(named: node.entity)?.id
    }

    private func childTrail(_ child: HierarchyNode) -> [(sheet: UUID, instance: UUID)] {
        guard let s = sheetID, let i = child.instanceID else { return trail }
        return trail + [(s, i)]
    }

    /// The sheet open in the Block Editor is this instance.
    private var isOpen: Bool {
        guard let s = sheetID, s == store.activeSheetID, store.tab == .bdf else { return false }
        return trail.map(\.instance) == store.hierarchyTrail.map(\.instance) || (parentSheet == nil && store.hierarchyTrail.isEmpty)
    }

    private var icon: String {
        if node.missing || node.recursive { return "exclamationmark.triangle" }
        if node.isMacro { return "memorychip" }
        return parentSheet == nil ? "square.stack.3d.up" : "square.on.square"
    }

    private var help: String {
        if node.missing { return node.isMacro ? "\(node.entity) is not in the symbol library" : "The project has no file named \(node.entity).bdf" }
        if node.recursive { return "\(node.entity) contains itself, so the hierarchy stops here" }
        if node.isMacro { return "Library macro (others > maxplus2 > \(node.entity)). Double-click to show the instance." }
        return "Double-click to open \(node.entity).bdf"
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(node.missing || node.recursive ? Theme.warning : Color.secondary)
                .frame(width: 16)
            Text(node.label).fontWeight(parentSheet == nil ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(isOpen ? Theme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .help(help)
        .contextMenu {
            Button(node.isMacro ? "Locate Instance" : "Open") { open() }
            if let s = sheetID, parentSheet != nil {
                Button("Set as Top-Level Entity") { store.setTopLevel(node.entity) }
                    .disabled(store.design.sheetIndex(id: s) == store.design.topIndex)
            }
        }
    }

    private func open() {
        if let s = sheetID {
            store.openSheet(s, trail: trail)
        } else if let p = parentSheet, let inst = node.instanceID {
            store.openSheet(p, trail: Array(trail.dropLast()))
            store.selection = [.comp(inst)]
        }
    }
}
#endif

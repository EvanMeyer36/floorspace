import AppKit
import SwiftUI

/// WizTree-style disk explorer: folder tree sorted by size, file types, and a treemap.
struct ExplorerView: View {
    @EnvironmentObject var explorer: ExplorerModel
    @EnvironmentObject var model: AppModel

    @State private var pendingTrash: [DiskNode]?
    @State private var trashFailures: [(name: String, message: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let progress = explorer.progress {
                ScanProgressPanel(progress: progress) { explorer.cancelScan() }
            } else if let root = explorer.root {
                results(root)
            } else {
                emptyState
            }
        }
        .navigationTitle("Disk Explorer")
        .onChange(of: explorer.treeVersion) { model.refreshDisk() }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { nodes in
            Button("Move to Trash", role: .destructive) {
                trashFailures = explorer.moveToTrash(nodes).failures
                model.refreshDisk()
            }
            Button("Cancel", role: .cancel) {}
        } message: { nodes in
            Text(trashMessage(nodes))
        }
        .alert("Some items weren't moved to the Trash", isPresented: Binding(get: { !trashFailures.isEmpty }, set: { if !$0 { trashFailures = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trashFailures.prefix(6).map { "\u{2022} \($0.name): \($0.message)" }.joined(separator: "\n"))
        }
    }

    private var trashTitle: String {
        guard let nodes = pendingTrash else { return "" }
        let plan = explorer.trashPlan(for: nodes)
        let size = Format.bytes(plan.reduce(0) { $0 + $1.size })
        if plan.count == 1, let node = plan.first { return "Move \u{201C}\(node.name)\u{201D} (\(size)) to the Trash?" }
        return "Move \(Format.count(plan.count)) items (\(size)) to the Trash?"
    }

    private func trashMessage(_ nodes: [DiskNode]) -> String {
        let plan = explorer.trashPlan(for: nodes)
        var lines: [String] = []
        if plan.count > 1 {
            let names = plan.prefix(5).map { "\u{2022} \($0.name)" }
            lines.append((names + (plan.count > 5 ? ["\u{2022} \u{2026}and \(plan.count - 5) more"] : [])).joined(separator: "\n"))
        }
        let skipped = nodes.filter { !explorer.canTrash($0) }.count
        if skipped > 0 {
            lines.append("\(skipped) selected item\(skipped == 1 ? " is" : "s are") part of an app or library (like Photos) or outside your home folder and Applications, and will be left alone.")
        }
        lines.append("You can restore items from the Trash until you empty it. The space is freed when the Trash is emptied.")
        return lines.joined(separator: "\n\n")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("Scan", selection: targetBinding) {
                Text(ExplorerModel.Target.startupDisk.title).tag(ExplorerModel.Target.startupDisk)
                Text("Home folder").tag(ExplorerModel.Target.home)
                if case .folder(let url) = explorer.target {
                    Text(Format.tildePath(url)).tag(ExplorerModel.Target.folder(url))
                }
                Divider()
                Text("Choose Folder\u{2026}").tag(ExplorerModel.Target.folder(URL(fileURLWithPath: "/choose")))
            }
            .fixedSize()
            .disabled(explorer.isScanning)

            if explorer.isScanning {
                Button("Stop") { explorer.cancelScan() }
            } else {
                Button {
                    explorer.scan()
                } label: {
                    Label(explorer.root == nil ? "Scan" : "Scan Again", systemImage: "arrow.clockwise")
                }
            }

            Spacer()

            if let summary = explorer.summary, !explorer.isScanning {
                Text("\(Format.count(summary.files)) files \u{2022} \(Format.count(summary.folders)) folders \u{2022} \(String(format: "%.1f", summary.duration)) s")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !summary.otherVolumes.isEmpty {
                    Label("\(summary.otherVolumes.count) other volume\(summary.otherVolumes.count == 1 ? "" : "s") skipped", systemImage: "externaldrive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("These are separate drives or disk images mounted inside this folder, so they aren't counted:\n\n" + summary.otherVolumes.prefix(8).joined(separator: "\n"))
                }
                if summary.unreadableCount > 0 {
                    Button {
                        model.openSettings(.fullDiskAccess)
                    } label: {
                        Label("\(Format.count(summary.unreadableCount)) folders locked", systemImage: "lock")
                    }
                    .help("macOS didn't let Mac Cleaner read these folders, so their space shows up as \u{201C}System data\u{201D}. Click to grant Full Disk Access, then scan again.\n\n" + summary.unreadableExamples.prefix(8).joined(separator: "\n"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var targetBinding: Binding<ExplorerModel.Target> {
        Binding(get: { explorer.target }, set: { newValue in
            if case .folder(let url) = newValue, url.path == "/choose" {
                chooseFolder()
            } else {
                explorer.target = newValue
            }
        })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            explorer.target = .folder(url)
            explorer.scan()
        }
    }

    // MARK: Results

    private func results(_ root: DiskNode) -> some View {
        VStack(spacing: 0) {
            ExplorerStorageBar(root: root)
            Divider()
            splitViews(root)
        }
    }

    private func splitViews(_ root: DiskNode) -> some View {
        VSplitView {
            HSplitView {
                FolderTreeTable(root: root, onTrash: { pendingTrash = $0 })
                    .frame(minWidth: 380, idealWidth: 600)
                SidePanel(onTrash: { pendingTrash = $0 })
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 640)
            }
            .frame(minHeight: 170, idealHeight: 280)

            VStack(spacing: 0) {
                TreemapHeader()
                Divider()
                TreemapView(onTrash: { pendingTrash = $0 })
                if !explorer.selectedIDs.isEmpty {
                    Divider()
                    SelectionBar(onTrash: { pendingTrash = $0 })
                }
            }
            .frame(minHeight: 220, idealHeight: 380)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.3x3")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("See exactly where your space went").font(.title2.bold())
            Text("Scans every folder and shows them biggest-first, plus a map where each block's size is the space it takes. Nothing is changed by scanning.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button {
                explorer.scan()
            } label: {
                Text("Scan \(explorer.target.title)").frame(minWidth: 160)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("Some folders are private to macOS. For a complete picture, grant Full Disk Access first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Full Disk Access Settings\u{2026}") { model.openSettings(.fullDiskAccess) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Storage bar

/// Where the scanned folder sits on the disk, and how much the current selection would free.
private struct ExplorerStorageBar: View {
    @EnvironmentObject var explorer: ExplorerModel
    @EnvironmentObject var model: AppModel
    let root: DiskNode

    var body: some View {
        let disk = model.disk
        let selected = min(explorer.selectedSize, disk.used)
        let isWholeDisk = explorer.target == .startupDisk
        let scanned = isWholeDisk ? disk.used : min(root.size, disk.used)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ExplorerModel.Target.startupDisk.title).font(.headline)
                Spacer()
                Text("\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            StorageBar(segments: [
                StorageSegment(label: isWholeDisk ? "Used" : root.name, value: scanned - selected, color: ChartColors.used),
                StorageSegment(label: "Selected", value: selected, color: ChartColors.reclaimable),
                StorageSegment(label: "Rest of disk", value: isWholeDisk ? 0 : disk.used - scanned, color: ChartColors.used.opacity(0.35)),
                StorageSegment(label: "Free", value: disk.free, color: ChartColors.track),
            ], total: disk.total)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared item actions

/// Context-menu items for one or several selected items.
struct DiskNodeActions: View {
    @EnvironmentObject var explorer: ExplorerModel
    let nodes: [DiskNode]
    let onTrash: ([DiskNode]) -> Void

    var body: some View {
        let onDisk = nodes.filter(\.isOnDisk)
        let suffix = nodes.count > 1 ? " (\(nodes.count) Items)" : ""
        if !onDisk.isEmpty {
            Button("Show in Finder" + suffix) { explorer.revealInFinder(onDisk) }
        }
        if nodes.count == 1, let node = nodes.first, node.isFolder, !node.children.isEmpty {
            Button("Show in Map") { explorer.zoom(into: node) }
        }
        if !onDisk.isEmpty {
            Button(nodes.count > 1 ? "Copy Paths" : "Copy Path") { explorer.copyPaths(onDisk) }
            Divider()
            Button("Move to Trash\u{2026}" + suffix) { onTrash(nodes) }
                .disabled(explorer.trashPlan(for: nodes).isEmpty)
        }
    }
}

/// Shown under the map whenever something is selected.
private struct SelectionBar: View {
    @EnvironmentObject var explorer: ExplorerModel
    let onTrash: ([DiskNode]) -> Void

    var body: some View {
        let nodes = explorer.selectedNodes
        let plan = explorer.trashPlan(for: nodes)
        let total = explorer.selectedSize
        HStack(spacing: 10) {
            Text("\(Format.count(nodes.count)) selected \u{2022} \(Format.bytes(total))")
                .monospacedDigit()
            Text("\u{2318}-click or \u{21E7}-click to select more")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { explorer.clearSelection() }
            Button("Show in Finder") { explorer.revealInFinder(nodes) }
                .disabled(!nodes.contains(where: \.isOnDisk))
            Button(plan.count > 1 ? "Move \(Format.count(plan.count)) to Trash\u{2026}" : "Move to Trash\u{2026}", role: .destructive) {
                onTrash(nodes)
            }
            .disabled(plan.isEmpty)
            .help(plan.isEmpty ? "Only items in your home folder or Applications can be removed here, and not pieces of an app or library (like Photos)." : "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Folder tree

private struct FolderTreeTable: View {
    @EnvironmentObject var explorer: ExplorerModel
    let root: DiskNode
    let onTrash: ([DiskNode]) -> Void

    var body: some View {
        Table(root.children, children: \.childNodes, selection: selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    icon(for: node).frame(width: 16)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                }
                .help(node.isOnDisk ? Format.tildePath(URL(fileURLWithPath: node.path)) : node.name)
            }
            .width(min: 140, ideal: 220)

            TableColumn("% of Parent") { node in
                PercentBar(fraction: fraction(of: node))
            }
            .width(min: 90, ideal: 110)

            TableColumn("Size") { node in
                Text(Format.bytes(node.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Files") { node in
                Text(node.fileCount > 0 ? Format.count(node.fileCount) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 80)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            DiskNodeActions(nodes: ids.compactMap(explorer.node(withID:)), onTrash: onTrash)
        } primaryAction: { ids in
            guard ids.count == 1, let node = explorer.node(withID: ids.first) else { return }
            if node.isFolder { explorer.zoom(into: node) } else { explorer.revealInFinder(node) }
        }
        .id(explorer.treeVersion) // the tree is mutable reference data; rebuild rows after a change
    }

    private var selection: Binding<Set<Int>> {
        Binding(get: { explorer.selectedIDs }, set: { explorer.selectFromList($0) })
    }

    private func fraction(of node: DiskNode) -> Double {
        guard let parent = node.parent, parent.size > 0 else { return 0 }
        return Double(node.size) / Double(parent.size)
    }

    @ViewBuilder
    private func icon(for node: DiskNode) -> some View {
        switch node.kind {
        case .folder:
            Image(systemName: node.isUnreadable ? "lock.fill" : "folder.fill")
                .foregroundStyle(node.dominantType?.color ?? .secondary)
        case .file:
            Image(systemName: "doc.fill").foregroundStyle(node.fileType?.color ?? .secondary)
        case .smallFiles:
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(node.dominantType?.color ?? .secondary)
        case .unattributed:
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
        }
    }
}

private struct PercentBar: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor).frame(width: max(2, 54 * fraction))
            }
            .frame(width: 54, height: 6)
            Text(String(format: "%.1f%%", fraction * 100))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    enum Tab { case largestFiles, fileTypes }

    let onTrash: ([DiskNode]) -> Void
    @State private var tab = Tab.largestFiles

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Largest Files").tag(Tab.largestFiles)
                Text("File Types").tag(Tab.fileTypes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            switch tab {
            case .largestFiles: LargestFilesTable(onTrash: onTrash)
            case .fileTypes: FileTypesTable()
            }
        }
    }
}

// MARK: - Largest files

/// Every big file in the scan in one list, wherever it lives.
private struct LargestFilesTable: View {
    @EnvironmentObject var explorer: ExplorerModel
    let onTrash: ([DiskNode]) -> Void

    var body: some View {
        Table(explorer.largestFiles, selection: selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").foregroundStyle(node.fileType?.color ?? .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        Text(node.parent.map { Format.tildePath(URL(fileURLWithPath: $0.path)) } ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .help(Format.tildePath(URL(fileURLWithPath: node.path)))
            }
            .width(min: 160, ideal: 300)
            TableColumn("Size") { node in
                Text(Format.bytes(node.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            DiskNodeActions(nodes: ids.compactMap(explorer.node(withID:)), onTrash: onTrash)
        } primaryAction: { ids in
            explorer.revealInFinder(ids.compactMap(explorer.node(withID:)))
        }
        .id(explorer.treeVersion)
    }

    /// Selecting a file zooms the map to its folder and outlines it there.
    private var selection: Binding<Set<Int>> {
        Binding(get: { explorer.selectedIDs }, set: { explorer.selectFromList($0) })
    }
}

// MARK: - File types

private struct FileTypesTable: View {
    @EnvironmentObject var explorer: ExplorerModel

    var body: some View {
        let stats = Array(explorer.typeStats.prefix(300))
        let total = max(1, explorer.typeStats.reduce(Int64(0)) { $0 + $1.size })

        Table(stats, selection: selection) {
            TableColumn("File Type") { stat in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(stat.fileType.color).frame(width: 10, height: 10)
                    Text(stat.label)
                }
                .help(stat.fileType.title)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size") { stat in
                Text(Format.bytes(stat.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            TableColumn("%") { stat in
                Text(String(format: "%.1f", Double(stat.size) / Double(total) * 100))
                    .monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 44)
            TableColumn("Files") { stat in
                Text(Format.count(stat.count)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
        }
    }

    /// Selecting a type highlights its files on the map.
    private var selection: Binding<String?> {
        Binding(
            get: {
                if case .fileExtension(let ext) = explorer.highlight { return ext }
                return nil
            },
            set: { explorer.highlight = $0.map { .fileExtension($0) } }
        )
    }
}

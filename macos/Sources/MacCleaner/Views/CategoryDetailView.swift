import AppKit
import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var model: AppModel
    let category: ScanCategory

    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if hasOptions {
                Divider()
                options
            }
            Divider()
            content
            if model.results[category]?.items.isEmpty == false && model.activeScans[category] == nil {
                Divider()
                footer
            }
        }
        .navigationTitle(category.title)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: category.systemImage)
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title).font(.title2.bold())
                Text(category.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeScans[category] == nil {
                Button {
                    model.startScan(category)
                } label: {
                    Label(model.results[category] == nil ? "Scan" : "Scan Again", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(20)
    }

    // MARK: Options

    private var hasOptions: Bool {
        category.usesSearchFolder || category == .downloads
    }

    private var options: some View {
        HStack(spacing: 20) {
            if category == .downloads {
                Picker("Not touched in", selection: $model.settings.downloadsAgeDays) {
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .fixedSize()
            }
            if category == .largeFiles {
                Picker("Bigger than", selection: $model.settings.largeFileMinMB) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1_000)
                    Text("5 GB").tag(5_000)
                }
                .fixedSize()
            }
            if category.usesSearchFolder {
                HStack(spacing: 6) {
                    Text(category == .devJunk ? "Look for node_modules in" : "Search in")
                    Button {
                        chooseSearchFolder()
                    } label: {
                        Label(Format.tildePath(model.settings.searchFolder), systemImage: "folder")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .disabled(model.activeScans[category] != nil)
    }

    private func chooseSearchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.searchFolder
        panel.prompt = "Search Here"
        panel.message = "Choose a folder to search. ~/Library is always skipped."
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.searchFolder = url
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let progress = model.activeScans[category] {
            ScanProgressPanel(progress: progress) { model.cancelScan(category) }
        } else if let result = model.results[category] {
            VStack(spacing: 0) {
                if !result.warnings.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(result.warnings, id: \.self) { WarningBanner(warning: $0) }
                    }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 4)
                }
                if result.items.isEmpty && result.warnings.contains(where: { $0.settingsPane != nil }) {
                    emptyState(icon: "lock", title: "Couldn't look here", message: "Allow access using the button above, then scan again.")
                } else if result.items.isEmpty {
                    emptyState(icon: "checkmark.circle", title: "Nothing to clean here", message: "This category is already tidy.")
                } else {
                    itemList(result.items)
                }
            }
        } else {
            emptyState(icon: category.systemImage, title: "Not scanned yet", message: "Scanning only looks. Nothing is removed until you choose to.") {
                Button("Scan") { model.startScan(category) }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func itemList(_ items: [ScanItem]) -> some View {
        if category == .duplicates {
            let groups = Dictionary(grouping: items, by: { $0.duplicateGroup ?? 0 })
            List {
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    let copies = groups[group] ?? []
                    Section("\(copies.count) identical copies \u{2022} \(Format.bytes(copies.first?.size ?? 0)) each") {
                        ForEach(copies) { ItemRow(item: $0) }
                    }
                }
            }
        } else {
            List(items) { ItemRow(item: $0) }
        }
    }

    private func emptyState(icon: String, title: String, message: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        let plan = CleanPlan(model.selectedItems(in: category))

        return HStack(spacing: 12) {
            Menu("Select") {
                Button("Recommended") { model.select(category) { $0.isRecommended } }
                if category == .duplicates {
                    Button("All Extra Copies (keep oldest)") { model.select(category) { !$0.isSuggestedKeeper } }
                }
                Button("All") { model.select(category) { _ in true } }
                Button("None") { model.select(category) { _ in false } }
            }
            .fixedSize()

            Spacer()

            Text("\(Format.count(plan.items.count)) selected \u{2022} \(Format.bytes(plan.totalSize))")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(model.isCleaning ? "Cleaning\u{2026}" : plan.buttonTitle, role: .destructive) {
                confirmClean = true
            }
            .disabled(plan.isEmpty || model.isCleaning)
            .cleanConfirmation(plan, isPresented: $confirmClean) { model.clean(plan.items) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Row

private struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: ScanItem

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.isSelected(item) },
                set: { model.setSelected(item, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            icon.frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.isSuggestedKeeper { Badge(text: "Keep", systemImage: "star") }
                    if item.isRecommended { Badge(text: "Safe", systemImage: "checkmark") }
                    if item.action.isPermanent { Badge(text: "Permanent", systemImage: "exclamationmark.triangle") }
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Text(Format.bytes(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.revealInFinder(item) }
        .contextMenu {
            if let path = item.path {
                Button("Show in Finder") { model.revealInFinder(item) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path.path, forType: .string)
                }
            }
        }
        .help(item.path.map { $0.path + "\nDouble-click to show in Finder" } ?? item.name)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = item.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path.path))
                .resizable()
        } else {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

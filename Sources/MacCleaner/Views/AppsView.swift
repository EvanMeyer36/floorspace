import AppKit
import SwiftUI

/// Installed apps by size and last use, with uninstall that also removes their leftover files.
struct AppsView: View {
    @EnvironmentObject var apps: AppsModel
    @EnvironmentObject var model: AppModel

    @State private var pendingUninstall: [InstalledApp]?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let progress = apps.progress, apps.apps.isEmpty {
                ScanProgressPanel(progress: progress) {}
            } else if apps.apps.isEmpty {
                emptyState
            } else {
                HSplitView {
                    AppsTable(onUninstall: { pendingUninstall = $0 })
                        .frame(minWidth: 420, idealWidth: 560)
                    AppDetailPanel(onUninstall: { pendingUninstall = $0 })
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                }
            }
        }
        .navigationTitle("Applications")
        .onAppear { if apps.apps.isEmpty && !apps.isScanning { apps.scan() } }
        .confirmationDialog(
            uninstallTitle,
            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }),
            titleVisibility: .visible,
            presenting: pendingUninstall
        ) { targets in
            Button("Uninstall", role: .destructive) { apps.uninstall(targets) }
            Button("Cancel", role: .cancel) {}
        } message: { targets in
            Text(uninstallMessage(targets))
        }
        .alert(
            reportTitle,
            isPresented: Binding(get: { apps.report != nil }, set: { if !$0 { apps.report = nil; model.refreshDisk() } }),
            presenting: apps.report
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(reportMessage(report))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            TextField("Search apps", text: $apps.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("Sort by", selection: $apps.sortOrder) {
                ForEach(AppsModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Toggle("Not opened in 6 months", isOn: $apps.onlyUnused)
                .toggleStyle(.checkbox)
            Spacer()
            if apps.isScanning {
                ProgressView().controlSize(.small)
            } else if !apps.apps.isEmpty {
                Text("\(Format.count(apps.apps.count)) apps \u{2022} \(Format.bytes(apps.apps.reduce(0) { $0 + $1.totalSize }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                apps.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(apps.isScanning || apps.isUninstalling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No apps found").font(.title3.bold())
            Button("Scan Again") { apps.scan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Confirmation & result text

    private var uninstallTitle: String {
        guard let targets = pendingUninstall else { return "" }
        let removable = targets.filter { $0.protectionReason == nil }
        if removable.count == 1, let app = removable.first { return "Uninstall \(app.name)?" }
        return "Uninstall \(removable.count) apps?"
    }

    private func uninstallMessage(_ targets: [InstalledApp]) -> String {
        let removable = targets.filter { $0.protectionReason == nil }
        let relatedCount = removable.reduce(0) { $0 + apps.relatedToRemove(for: $1).count }
        var lines: [String] = []
        if removable.count > 1 {
            lines.append(removable.prefix(6).map { "\u{2022} \($0.name)" }.joined(separator: "\n")
                         + (removable.count > 6 ? "\n\u{2022} \u{2026}and \(removable.count - 6) more" : ""))
        }
        let what = removable.count == 1 ? "the app" : "the apps"
        let extra = relatedCount > 0 ? " and \(relatedCount) related file\(relatedCount == 1 ? "" : "s")" : ""
        lines.append("Moves \(what)\(extra) (\(Format.bytes(apps.sizeToRemove(for: removable)))) to the Trash, so you can put them back until you empty it.")
        let running = removable.filter(apps.isRunning)
        if !running.isEmpty {
            lines.append("\(running.map(\.name).joined(separator: ", ")) \(running.count == 1 ? "is" : "are") open and will be quit first.")
        }
        let needPassword = removable.filter(\.needsPassword)
        if !needPassword.isEmpty {
            lines.append("\(needPassword.count == 1 ? needPassword[0].name + " is" : "\(needPassword.count) of these are") owned by the system, so Finder will ask for your password.")
        }
        let skipped = targets.count - removable.count
        if skipped > 0 { lines.append("\(skipped) protected app\(skipped == 1 ? "" : "s") will be skipped.") }
        return lines.joined(separator: "\n\n")
    }

    private var reportTitle: String {
        guard let report = apps.report else { return "" }
        return report.removedApps.isEmpty ? "Nothing was uninstalled" : "Uninstalled \(report.removedApps.count) app\(report.removedApps.count == 1 ? "" : "s")"
    }

    private func reportMessage(_ report: AppsModel.UninstallReport) -> String {
        var lines: [String] = []
        if !report.removedApps.isEmpty {
            lines.append("Moved \(Format.bytes(report.movedBytes)) to the Trash. The space comes back once you empty the Trash.")
        }
        if !report.failures.isEmpty {
            lines.append("Couldn't remove:\n" + report.failures.prefix(6).map { "\u{2022} \($0.name): \($0.message)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - App list

private struct AppsTable: View {
    @EnvironmentObject var apps: AppsModel
    let onUninstall: ([InstalledApp]) -> Void

    var body: some View {
        Table(apps.visibleApps, selection: $apps.selectedIDs) {
            TableColumn("App") { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(app.name).lineLimit(1)
                            if apps.isRunning(app) { Tag(text: "Open") }
                            if app.isAppStore { Tag(text: "App Store") }
                            if app.isSteamShortcut { Tag(text: "Steam shortcut") }
                            if app.needsPassword && app.protectionReason == nil { Tag(text: "Needs password") }
                            if app.protectionReason != nil { Tag(text: "Protected") }
                        }
                        if let version = app.version {
                            Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .width(min: 200, ideal: 300)

            TableColumn("Size") { app in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.bytes(app.totalSize)).monospacedDigit()
                    if app.relatedSize > 0 {
                        Text("+\(Format.bytes(app.relatedSize)) data").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Last Opened") { app in
                Text(lastOpenedText(app))
                    .foregroundStyle(apps.isUnused(app) ? .primary : .secondary)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = apps.apps.filter { ids.contains($0.id) }
            Button("Show in Finder") { apps.reveal(targets.map(\.url)) }
            Divider()
            Button(targets.count > 1 ? "Uninstall \(targets.count) Apps\u{2026}" : "Uninstall\u{2026}") { onUninstall(targets) }
                .disabled(targets.allSatisfy { $0.protectionReason != nil })
        } primaryAction: { ids in
            apps.reveal(apps.apps.filter { ids.contains($0.id) }.map(\.url))
        }
    }

    private func lastOpenedText(_ app: InstalledApp) -> String {
        guard let date = app.lastUsed,
              let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day else { return "Unknown" }
        return Format.age(days: days).capitalizingFirstLetter
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

// MARK: - Detail

private struct AppDetailPanel: View {
    @EnvironmentObject var apps: AppsModel
    let onUninstall: ([InstalledApp]) -> Void

    var body: some View {
        let selected = apps.selectedApps
        Group {
            if selected.count == 1, let app = selected.first {
                singleApp(app)
            } else if selected.count > 1 {
                multipleApps(selected)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.point.left").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Select an app to see everything it stores on your Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("\u{2318}-click to select several.").font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func singleApp(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title3.bold())
                    Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " \u{2022} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Format.tildePath(app.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(16)

            if app.isSteamShortcut {
                Label("This is only a Steam shortcut. The game itself is in your Steam library, so uninstall it from Steam to free its space. Its save files are left alone.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()

            List {
                Section("The app") {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 18, height: 18)
                        Text(app.url.lastPathComponent)
                        Spacer()
                        Text(Format.bytes(app.appSize)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Section(app.related.isEmpty ? "No related files found" : "Related files in ~/Library") {
                    ForEach(app.related) { item in
                        RelatedRow(item: item)
                    }
                }
            }

            Divider()

            HStack {
                if let reason = app.protectionReason {
                    Label(reason, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Text("\(Format.bytes(apps.sizeToRemove(for: [app]))) to remove")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(apps.isUninstalling ? "Uninstalling\u{2026}" : "Uninstall\u{2026}", role: .destructive) { onUninstall([app]) }
                        .disabled(apps.isUninstalling)
                }
            }
            .padding(12)
        }
    }

    private func multipleApps(_ selected: [InstalledApp]) -> some View {
        let removable = selected.filter { $0.protectionReason == nil }
        return VStack(spacing: 14) {
            HStack(spacing: -14) {
                ForEach(selected.prefix(5)) { app in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                }
            }
            Text("\(selected.count) apps selected").font(.title3.bold())
            Text("\(Format.bytes(apps.sizeToRemove(for: removable))) including their related files")
                .foregroundStyle(.secondary)
            if removable.count < selected.count {
                Text("\(selected.count - removable.count) protected app\(selected.count - removable.count == 1 ? " is" : "s are") skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(apps.isUninstalling ? "Uninstalling\u{2026}" : "Uninstall \(removable.count) Apps\u{2026}", role: .destructive) {
                onUninstall(selected)
            }
            .disabled(removable.isEmpty || apps.isUninstalling)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RelatedRow: View {
    @EnvironmentObject var apps: AppsModel
    let item: RelatedItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !apps.keptRelatedPaths.contains(item.id) },
                set: { remove in
                    if remove { apps.keptRelatedPaths.remove(item.id) } else { apps.keptRelatedPaths.insert(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(item.matchedByName ? "\(item.kind) \u{2022} matched by app name" : item.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.size.map(Format.bytes) ?? "Not measured")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(item.size == nil ? "macOS didn't let Mac Cleaner look inside to measure it." : "")
            Button {
                apps.reveal([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

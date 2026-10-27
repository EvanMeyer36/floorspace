import AppKit
import Foundation

@MainActor
final class AppsModel: ObservableObject {
    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last Opened"
        var id: String { rawValue }
    }

    struct UninstallReport: Identifiable {
        let id = UUID()
        var removedApps: [String] = []
        var movedBytes: Int64 = 0
        var failures: [(name: String, message: String)] = []
    }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var isUninstalling = false
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var sortOrder = SortOrder.size
    @Published var onlyUnused = false
    /// Related files the user unticked, by path. They're kept when the app is uninstalled.
    @Published var keptRelatedPaths: Set<String> = []
    @Published var report: UninstallReport?

    /// Apps not opened in this long count as unused.
    static let unusedDays = 180

    var isScanning: Bool { progress != nil }

    var visibleApps: [InstalledApp] {
        var list = apps
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(searchText) }
        }
        if onlyUnused {
            list = list.filter(isUnused)
        }
        switch sortOrder {
        case .size: list.sort { $0.totalSize > $1.totalSize }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Longest-unused first; apps with no usage record at all go last, since unknown isn't the same as old.
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        }
        return list
    }

    var selectedApps: [InstalledApp] {
        apps.filter { selectedIDs.contains($0.id) }
    }

    /// Apps with no usage record at all aren't counted as unused: unknown isn't the same as old.
    func isUnused(_ app: InstalledApp) -> Bool {
        guard let lastUsed = app.lastUsed else { return false }
        return Date().timeIntervalSince(lastUsed) > Double(Self.unusedDays) * 86_400
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Scanning

    func scan(includeOtherAppsData: Bool = true) {
        guard progress == nil else { return }
        let progress = ScanProgress()
        self.progress = progress
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppsScanner.scan(includeOtherAppsData: includeOtherAppsData, progress: progress)
            }.value
            apps = found
            selectedIDs = selectedIDs.intersection(found.map(\.id))
            self.progress = nil
        }
    }

    // MARK: - Uninstalling

    /// Related files that will be removed along with the app (everything except what the user unticked).
    func relatedToRemove(for app: InstalledApp) -> [RelatedItem] {
        app.related.filter { !keptRelatedPaths.contains($0.id) }
    }

    func sizeToRemove(for apps: [InstalledApp]) -> Int64 {
        apps.reduce(0) { total, app in
            total + app.appSize + relatedToRemove(for: app).reduce(0) { $0 + ($1.size ?? 0) }
        }
    }

    func uninstall(_ targets: [InstalledApp]) {
        let removable = targets.filter { $0.protectionReason == nil }
        guard !removable.isEmpty, !isUninstalling else { return }
        isUninstalling = true

        Task {
            var report = UninstallReport()
            for app in removable {
                if isRunning(app), !(await quit(app)) {
                    report.failures.append((app.name, "It's still running. Quit it and try again."))
                    continue
                }
                guard await moveAppToTrash(app.url) else {
                    report.failures.append((app.name, "macOS didn't allow it to be moved to the Trash."))
                    continue
                }
                report.removedApps.append(app.name)
                report.movedBytes += app.appSize

                for item in relatedToRemove(for: app) {
                    do {
                        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        report.movedBytes += item.size ?? 0
                    } catch {
                        report.failures.append(("\(app.name): \(item.url.lastPathComponent)", error.localizedDescription))
                    }
                }
            }

            let removedPaths = Set(removable.filter { !DiskUtils.exists($0.url) }.map(\.id))
            apps.removeAll { removedPaths.contains($0.id) }
            selectedIDs.subtract(removedPaths)
            isUninstalling = false
            self.report = report
        }
    }

    /// Asks the app to quit (it may show its own "save changes?" prompt) and waits up to 10 seconds.
    private func quit(_ app: InstalledApp) async -> Bool {
        guard let bundleID = app.bundleID else { return false }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !isRunning(app) { return true }
        }
        return false
    }

    /// Apps owned by the system (most App Store apps) can't be moved by a normal app, so
    /// those are handed to Finder, which asks for an administrator password like it does
    /// when you drag them to the Trash yourself.
    private func moveAppToTrash(_ url: URL) async -> Bool {
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return true }

        // The path goes in as an argument, never pasted into the script, so no file name can change what it does.
        let script = ["on run argv", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)", "end run"]
        let arguments = script.flatMap { ["-e", $0] } + [url.path]
        return await Task.detached {
            // Generous timeout: Finder waits while the user types their password.
            let result = Shell.run("/usr/bin/osascript", arguments, timeout: 300)
            return result?.succeeded == true && !DiskUtils.exists(url)
        }.value
    }

    // MARK: - Finder

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

import AppKit
import Foundation

/// A file or folder an app left in ~/Library (caches, settings, saved data).
struct RelatedItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// Nil when macOS wouldn't let the engine measure it.
    let size: Int64?
    let kind: String
    /// Found by the app's name rather than its bundle ID, so slightly less certain.
    let matchedByName: Bool
    var id: String { url.path }
}

/// An installed app as listed by the engine.
struct InstalledApp: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let appSize: Int64
    let related: [RelatedItem]
    let lastUsed: Date?
    let isAppStore: Bool
    /// Why this app can't be uninstalled here, if it can't.
    let protectionReason: String?
    let note: String?
    let needsPassword: Bool

    init(_ app: EngineApp) {
        id = app.id
        url = URL(fileURLWithPath: app.location ?? app.id)
        name = app.name
        bundleID = app.identifier
        version = app.version
        appSize = app.size
        related = app.leftovers.map { RelatedItem(url: URL(fileURLWithPath: $0.path), size: $0.size, kind: $0.kind, matchedByName: $0.matchedByName) }
        lastUsed = app.lastUsed.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        isAppStore = app.source == "macAppStore"
        protectionReason = app.protection
        note = app.note
        needsPassword = app.needsPassword
    }

    /// The app is only a Steam launcher; the game itself lives in the Steam library.
    var isSteamShortcut: Bool { note?.hasPrefix("Only a Steam shortcut") == true }
    var relatedSize: Int64 { related.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { appSize + relatedSize }
}

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

    // MARK: - Scanning (in the engine)

    /// - Parameter includeOtherAppsData: also measure apps' sandboxed data, which macOS asks the user about.
    func scan(includeOtherAppsData: Bool = true) {
        guard progress == nil else { return }
        progress = ScanProgress(kind: "apps")
        Task {
            let found = (try? await Engine.background {
                try Engine.call("apps_list", ["includeSandboxedData": includeOtherAppsData], as: [EngineApp].self)
            }) ?? []
            apps = found.map(InstalledApp.init)
            selectedIDs = selectedIDs.intersection(apps.map(\.id))
            progress = nil
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

    /// Uninstalls in the engine: it quits the app if it's open, moves it to the Trash (through Finder,
    /// with a password, when the system owns it) and moves the leftovers the user left ticked.
    func uninstall(_ targets: [InstalledApp]) {
        let removable = targets.filter { $0.protectionReason == nil }
        guard !removable.isEmpty, !isUninstalling else { return }
        isUninstalling = true

        Task {
            var report = UninstallReport()
            for app in removable {
                let keep = app.related.filter { keptRelatedPaths.contains($0.id) }.map(\.url.path)
                let result = try? await Engine.background {
                    try Engine.call("apps_uninstall", ["appId": app.id, "keep": keep], as: EngineUninstallReport.self)
                }
                guard let result else {
                    report.failures.append((app.name, "The engine couldn't uninstall it."))
                    continue
                }
                for failure in result.outcomes where !failure.ok {
                    report.failures.append((Format.tildePath(failure.target), failure.message ?? ""))
                }
                if result.removed {
                    report.removedApps.append(app.name)
                    report.movedBytes += app.appSize + relatedToRemove(for: app).reduce(0) { $0 + ($1.size ?? 0) }
                }
            }

            let removedPaths = Set(removable.filter { !DiskUtils.exists($0.url) }.map(\.id))
            apps.removeAll { removedPaths.contains($0.id) }
            selectedIDs.subtract(removedPaths)
            isUninstalling = false
            self.report = report
        }
    }

    // MARK: - Finder

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

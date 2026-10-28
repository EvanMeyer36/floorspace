import AppKit
import Foundation

/// One thing a cleanup category offers to remove, as found by the engine.
struct ScanItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// On-disk location. Nil for tool-managed items such as Docker images or "everything in the Trash".
    let path: URL?
    let size: Int64
    let category: ScanCategory
    let detail: String?
    /// Safe to remove without the user needing to think about it. Pre-selected after a scan.
    let isRecommended: Bool
    let action: EngineAction
    /// Duplicates only: items with the same group number have identical content.
    let duplicateGroup: Int?
    /// Duplicates only: the copy we suggest keeping.
    let isSuggestedKeeper: Bool

    init(_ item: EngineItem) {
        id = item.id
        path = item.path.map { URL(fileURLWithPath: $0) }
        // Cache folders are usually named after a bundle ID; show the app's real name when it's installed.
        name = item.category == .caches ? Self.appName(forBundleID: item.name) ?? item.name : item.name
        size = item.size
        category = item.category
        detail = item.detail.isEmpty ? nil : item.detail
        isRecommended = item.recommended
        action = item.action
        duplicateGroup = item.group
        isSuggestedKeeper = item.keeper
    }

    private static func appName(forBundleID bundleID: String) -> String? {
        guard bundleID.contains("."), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Something the user should know about a scan, usually a permission problem.
struct ScanWarning: Hashable, Sendable {
    enum SettingsPane: Sendable {
        case fullDiskAccess
        case filesAndFolders

        var url: URL {
            switch self {
            case .fullDiskAccess:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            case .filesAndFolders:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
            }
        }
    }

    let message: String
    var settingsPane: SettingsPane? = nil

    init(message: String, settingsPane: SettingsPane? = nil) {
        self.message = message
        self.settingsPane = settingsPane
    }

    init(_ warning: EngineWarning) {
        self.init(message: warning.message, settingsPane: warning.needsFullDiskAccess ? .fullDiskAccess : nil)
    }
}

struct ScanResult: Sendable {
    let category: ScanCategory
    var items: [ScanItem]
    var warnings: [ScanWarning] = []

    init(_ result: EngineCategoryResult) {
        category = result.category
        items = result.items.map(ScanItem.init)
        warnings = result.warnings.map(ScanWarning.init)
    }

    /// What could be freed. For duplicates that excludes the copy we suggest keeping.
    var reclaimableSize: Int64 { items.filter { !$0.isSuggestedKeeper }.reduce(0) { $0 + $1.size } }
    var recommendedSize: Int64 { items.filter(\.isRecommended).reduce(0) { $0 + $1.size } }
}

struct ScanSettings: Sendable {
    var downloadsAgeDays = 30
    var largeFileMinMB = 250
    var searchFolder = FileManager.default.homeDirectoryForCurrentUser

    /// Arguments for the engine's scan calls.
    var engineArgs: [String: Any] {
        ["searchRoot": searchFolder.path, "downloadsAgeDays": downloadsAgeDays, "largeFileMinMb": largeFileMinMB]
    }
}

extension Array where Element == ScanItem {
    /// Each path once, and nothing inside a folder that's also listed, so sizes aren't counted twice
    /// (the same file can show up in two categories).
    var outermost: [ScanItem] {
        var kept: [ScanItem] = []
        var keptPaths: [String] = []
        for item in sorted(by: { ($0.path?.path.count ?? 0) < ($1.path?.path.count ?? 0) }) {
            guard let path = item.path?.standardizedFileURL.path else {
                if !kept.contains(where: { $0.id == item.id }) { kept.append(item) }
                continue
            }
            if keptPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            keptPaths.append(path)
            kept.append(item)
        }
        return kept
    }
}

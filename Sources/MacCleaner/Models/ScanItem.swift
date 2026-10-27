import Foundation

/// How an item gets removed.
enum CleanAction: Hashable, Sendable {
    /// Move to the macOS Trash. Recoverable; space is freed when the Trash is emptied.
    case moveToTrash
    /// Remove outright. Only used for items that are already in the Trash.
    case deletePermanently
    /// Let the owning tool remove it (e.g. `docker image prune`). Permanent.
    case runCommand(executable: String, arguments: [String])

    var isPermanent: Bool { self != .moveToTrash }
}

struct ScanItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// On-disk location. Nil for tool-managed items such as Docker images.
    let path: URL?
    let size: Int64
    let category: ScanCategory
    let detail: String?
    /// Safe to remove without the user needing to think about it. Pre-selected after a scan.
    let isRecommended: Bool
    let action: CleanAction
    /// Duplicates only: items with the same group number have identical content.
    let duplicateGroup: Int?
    /// Duplicates only: the copy we suggest keeping.
    let isSuggestedKeeper: Bool

    init(
        path: URL,
        size: Int64,
        category: ScanCategory,
        name: String? = nil,
        detail: String? = nil,
        isRecommended: Bool = false,
        action: CleanAction = .moveToTrash,
        duplicateGroup: Int? = nil,
        isSuggestedKeeper: Bool = false
    ) {
        self.id = path.path
        self.name = name ?? path.lastPathComponent
        self.path = path
        self.size = size
        self.category = category
        self.detail = detail
        self.isRecommended = isRecommended
        self.action = action
        self.duplicateGroup = duplicateGroup
        self.isSuggestedKeeper = isSuggestedKeeper
    }

    /// A tool-managed item with no single path on disk.
    init(id: String, name: String, size: Int64, category: ScanCategory, detail: String?, action: CleanAction, isRecommended: Bool = false) {
        self.id = id
        self.name = name
        self.path = nil
        self.size = size
        self.category = category
        self.detail = detail
        self.isRecommended = isRecommended
        self.action = action
        self.duplicateGroup = nil
        self.isSuggestedKeeper = false
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
}

struct ScanResult: Sendable {
    let category: ScanCategory
    var items: [ScanItem]
    var warnings: [ScanWarning] = []

    /// What could be freed. For duplicates that excludes the copy we suggest keeping.
    var reclaimableSize: Int64 { items.filter { !$0.isSuggestedKeeper }.reduce(0) { $0 + $1.size } }
    var recommendedSize: Int64 { items.filter(\.isRecommended).reduce(0) { $0 + $1.size } }
}

struct ScanSettings: Sendable {
    var downloadsAgeDays = 30
    var largeFileMinMB = 250
    var searchFolder = FileManager.default.homeDirectoryForCurrentUser
}

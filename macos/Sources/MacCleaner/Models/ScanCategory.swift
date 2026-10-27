import Foundation

enum ScanCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case caches
    case devJunk
    case appleData
    case downloads
    case largeFiles
    case duplicates
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "App Caches & Logs"
        case .devJunk: return "Developer Junk"
        case .appleData: return "Backups & Mail"
        case .downloads: return "Old Downloads"
        case .largeFiles: return "Large Files"
        case .duplicates: return "Duplicates"
        case .trash: return "Trash"
        }
    }

    var subtitle: String {
        switch self {
        case .caches: return "Per-app caches in ~/Library/Caches plus ~/Library/Logs. Apps rebuild these."
        case .devJunk: return "Xcode, simulators, Docker, package manager caches and stale node_modules."
        case .appleData: return "iPhone/iPad backups, downloaded iOS updates and Mail attachments."
        case .downloads: return "Things in ~/Downloads you haven't touched in a while."
        case .largeFiles: return "Big individual files in your folders, with when you last opened them."
        case .duplicates: return "Files with byte-for-byte identical content."
        case .trash: return "Items already in the Trash. Emptying it is what actually frees the space."
        }
    }

    var systemImage: String {
        switch self {
        case .caches: return "shippingbox"
        case .devJunk: return "hammer"
        case .appleData: return "iphone"
        case .downloads: return "arrow.down.circle"
        case .largeFiles: return "doc.zipper"
        case .duplicates: return "doc.on.doc"
        case .trash: return "trash"
        }
    }

    /// Categories that walk the user-chosen search folder rather than fixed locations.
    var usesSearchFolder: Bool {
        self == .largeFiles || self == .duplicates || self == .devJunk
    }
}

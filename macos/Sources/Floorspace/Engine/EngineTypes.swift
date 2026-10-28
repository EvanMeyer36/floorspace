import Foundation

// Swift mirrors of the engine's JSON replies (floorspace_core::session and friends).
// Field names match the engine's camelCase JSON.

struct DiskSpace: Codable, Sendable {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }

    /// The startup disk as Finder reports it: purgeable space counts as free.
    static func current() -> DiskSpace {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        return DiskSpace(total: Int64(values?.volumeTotalCapacity ?? 0), free: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

struct ProgressSnapshot: Decodable, Sendable {
    let itemsSeen: Int
    let phase: String
    let currentPath: String
}

struct Outcome: Decodable, Sendable, Hashable {
    let target: String
    let ok: Bool
    let message: String?
}

// MARK: - Disk tree

typealias NodeID = UInt32

enum NodeKind: Decodable, Sendable, Hashable {
    case folder, file, smallFiles(count: Int), unattributed

    private enum CodingKeys: String, CodingKey { case type, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "folder": self = .folder
        case "file": self = .file
        case "smallFiles": self = .smallFiles(count: try c.decode(Int.self, forKey: .count))
        default: self = .unattributed
        }
    }
}

/// One folder or file in the engine's disk tree.
struct DiskNode: Decodable, Sendable, Identifiable, Hashable {
    let id: NodeID
    let name: String
    let kind: NodeKind
    let size: Int64
    let files: Int64
    let fileType: FileType?
    let childCount: Int
    let unreadable: Bool
    let path: String?
    let parent: NodeID?
    let canTrash: Bool

    var isFolder: Bool { kind == .folder }
    var isOnDisk: Bool { path != nil }
    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    var fileExtension: String {
        guard kind == .file, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

struct TreeSummary: Decodable, Sendable {
    let files: Int
    let folders: Int
    let durationMs: Int
    let unreadableCount: Int
    let unreadableExamples: [String]
    let otherVolumes: [String]
}

struct TypeStat: Decodable, Sendable, Identifiable, Hashable {
    let ext: String
    let size: Int64
    let count: Int
    let fileType: FileType
    var id: String { ext }
    var label: String { ext.isEmpty ? "(no extension)" : "." + ext }
}

struct TreeOverview: Decodable, Sendable {
    let root: DiskNode
    let summary: TreeSummary
    let typeStats: [TypeStat]
}

struct EngineRect: Decodable, Sendable, Hashable {
    let x: Double, y: Double, w: Double, h: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// One block of the treemap, laid out by the engine.
struct TreemapCell: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case folder, collapsedFolder, file, smallFiles, unattributed, sliver }

    let node: NodeID?
    let name: String
    let size: Int64
    let rect: EngineRect
    let header: EngineRect?
    let depth: Int
    let kind: Kind
    let fileType: FileType?
    let hiddenCount: Int
    let container: NodeID?
    let parentCell: Int?
}

struct TreeTrashResult: Decodable, Sendable {
    let moved: [NodeID]
    let movedBytes: Int64
    let failures: [Outcome]
}

// MARK: - Cleanup

struct EngineAction: Decodable, Sendable, Hashable {
    let type: String
    var isPermanent: Bool { type != "moveToTrash" }
}

struct EngineItem: Decodable, Sendable {
    let id: String
    let category: ScanCategory
    let name: String
    let path: String?
    let size: Int64
    let detail: String
    let recommended: Bool
    let action: EngineAction
    let group: Int?
    let keeper: Bool
}

struct EngineWarning: Decodable, Sendable {
    let message: String
    let needsFullDiskAccess: Bool
}

struct EngineCategoryResult: Decodable, Sendable {
    let category: ScanCategory
    let items: [EngineItem]
    let warnings: [EngineWarning]
}

struct EngineCleanResult: Decodable, Sendable {
    let cleaned: [String]
    let freedToTrash: Int64
    let freedPermanently: Int64
    let failures: [Outcome]
}

// MARK: - Apps

struct EngineLeftover: Decodable, Sendable, Hashable {
    let path: String
    let size: Int64?
    let kind: String
    let matchedByName: Bool
}

struct EngineApp: Decodable, Sendable {
    let id: String
    let identifier: String?
    let name: String
    let version: String?
    let location: String?
    let source: String
    let size: Int64
    let leftovers: [EngineLeftover]
    let lastUsed: Int64?
    let protection: String?
    let note: String?
    let needsPassword: Bool
}

struct EngineUninstallReport: Decodable, Sendable {
    let removed: Bool
    let outcomes: [Outcome]
    let wouldAlsoRemove: [String]
}

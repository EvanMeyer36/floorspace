import Foundation

/// Live progress of an engine operation, by its progress key ("tree", "junk", "junk:caches", "apps").
/// Views sample it a few times a second; each sample is one cheap engine call.
final class ScanProgress: @unchecked Sendable {
    let kind: String

    struct Snapshot {
        let filesSeen: Int
        let currentPath: String
        let phase: String
    }

    init(kind: String) {
        self.kind = kind
    }

    var snapshot: Snapshot {
        let s = Engine.progress(kind)
        return Snapshot(filesSeen: s?.itemsSeen ?? 0, currentPath: s?.currentPath ?? "", phase: s?.phase ?? "Starting\u{2026}")
    }

    func cancel() {
        Engine.cancel(kind)
    }
}

enum DiskUtils {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

enum Format {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func age(days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(days) days ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    /// `/Users/me/Documents/x` -> `~/Documents/x`
    static func tildePath(_ url: URL) -> String {
        let path = url.path
        let home = DiskUtils.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func tildePath(_ path: String) -> String {
        tildePath(URL(fileURLWithPath: path))
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }
}

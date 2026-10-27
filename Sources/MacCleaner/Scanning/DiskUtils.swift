import Foundation

enum DiskUtils {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let library = home.appendingPathComponent("Library")

    /// Recursively computes the on-disk size of a file or directory, including hidden files.
    /// Returns early (with a partial total) if the surrounding task is cancelled.
    static func size(of url: URL, progress: ScanProgress? = nil) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return allocatedSize(url) }

        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            progress?.tick(fileURL)
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Lists a directory's children, distinguishing "empty/missing" from "macOS won't let us look".
    static func contents(of dir: URL, includingHidden: Bool = false) -> (urls: [URL], denied: Bool) {
        guard exists(dir) else { return ([], false) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: includingHidden ? [] : [.skipsHiddenFiles]
            )
            return (urls, false)
        } catch {
            return ([], isPermissionError(error))
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    static func daysSinceModified(_ url: URL) -> Int? {
        days(since: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }

    static func daysSinceOpened(_ url: URL) -> Int? {
        days(since: (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate)
    }

    private static func days(since date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
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

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }
}

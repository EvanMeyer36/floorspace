import Foundation

/// Depth-first walk of a user folder, shared by the large-file, duplicate and
/// node_modules searches.
///
/// Skips hidden files, the insides of packages (apps, Photos libraries), and
/// ~/Library, which is system/app territory that the targeted categories
/// already cover and which is unsafe to clean file-by-file.
enum FileWalker {
    enum Decision {
        case keepGoing
        case skipDescendants
    }

    static func walk(
        _ root: URL,
        keys: [URLResourceKey],
        progress: ScanProgress,
        visit: (URL, URLResourceValues) -> Decision
    ) {
        let libraryPath = DiskUtils.library.path
        let rootIsInsideLibrary = root.path.hasPrefix(libraryPath)
        let allKeys = Set(keys + [.isDirectoryKey])

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(allKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if DiskUtils.isPermissionError(error) { progress.recordUnreadable(url) }
                return true
            }
        ) else { return }

        for case let url as URL in enumerator {
            if Task.isCancelled { return }
            progress.tick(url)

            if !rootIsInsideLibrary && url.path == libraryPath {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: allKeys) else { continue }
            if visit(url, values) == .skipDescendants {
                enumerator.skipDescendants()
            }
        }
    }

    /// Turns folders macOS refused to let us read into a single user-facing warning.
    static func permissionWarning(from progress: ScanProgress) -> ScanWarning? {
        let denied = progress.unreadableFolders
        guard !denied.isEmpty else { return nil }
        let examples = denied.prefix(3).map(Format.tildePath).joined(separator: ", ")
        let more = denied.count > 3 ? " and \(denied.count - 3) more" : ""
        return ScanWarning(
            message: "macOS didn't let Floorspace look inside \(examples)\(more), so those weren't searched.",
            settingsPane: .filesAndFolders
        )
    }
}

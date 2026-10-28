import CryptoKit
import Foundation

/// Scans that walk the user's chosen search folder file by file.
enum SearchScanners {

    // MARK: - Large files

    static func largeFiles(in root: URL, minMB: Int, progress: ScanProgress) -> ScanResult {
        progress.setPhase("Searching \(Format.tildePath(root))")
        let minBytes = Int64(minMB) * 1_000_000
        var items: [ScanItem] = []

        FileWalker.walk(root, keys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentAccessDateKey], progress: progress) { url, values in
            if url.lastPathComponent == "node_modules" { return .skipDescendants }
            guard values.isRegularFile == true else { return .keepGoing }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= minBytes else { return .keepGoing }

            var detail = Format.tildePath(url.deletingLastPathComponent())
            if let opened = values.contentAccessDate,
               let days = Calendar.current.dateComponents([.day], from: opened, to: Date()).day {
                detail += " \u{2022} last opened \(Format.age(days: days))"
            }
            items.append(ScanItem(path: url, size: size, category: .largeFiles, detail: detail))
            return .keepGoing
        }

        let warnings = [FileWalker.permissionWarning(from: progress)].compactMap { $0 }
        return ScanResult(category: .largeFiles, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }

    // MARK: - Duplicates

    private struct Candidate {
        let url: URL
        let logicalSize: Int
        let allocatedSize: Int64
        let contentID: Int64?
        let created: Date
    }

    /// Files smaller than this aren't worth the hashing time.
    static let duplicateMinBytes = 512_000

    static func duplicates(in root: URL, progress: ScanProgress) -> ScanResult {
        progress.setPhase("Searching \(Format.tildePath(root))")

        // 1. Collect every reasonably-sized file, grouped by exact byte size.
        var bySize: [Int: [Candidate]] = [:]
        var seenFiles = Set<NSObject>() // hard links are the same file; never offer to delete "both"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .fileResourceIdentifierKey, .fileContentIdentifierKey, .creationDateKey]

        FileWalker.walk(root, keys: keys, progress: progress) { url, values in
            if url.lastPathComponent == "node_modules" { return .skipDescendants }
            guard values.isRegularFile == true,
                  let size = values.fileSize, size >= duplicateMinBytes,
                  // iCloud files that aren't downloaded take no space here; hashing them would download them.
                  let allocated = values.totalFileAllocatedSize, allocated > 0 else { return .keepGoing }

            if let fileID = values.fileResourceIdentifier as? NSObject {
                guard seenFiles.insert(fileID).inserted else { return .keepGoing }
            }
            bySize[size, default: []].append(Candidate(
                url: url, logicalSize: size, allocatedSize: Int64(allocated),
                contentID: values.fileContentIdentifier, created: values.creationDate ?? .distantFuture))
            return .keepGoing
        }

        // 2. Same size -> same first 64 KB -> same full SHA-256.
        let sameSize = bySize.values.filter { $0.count > 1 }
        let totalCandidates = sameSize.reduce(0) { $0 + $1.count }
        var hashed = 0
        var groups: [[Candidate]] = []

        for bucket in sameSize {
            if Task.isCancelled { break }
            progress.setPhase("Comparing contents (\(Format.count(hashed)) of \(Format.count(totalCandidates)) files)")

            let byHead = Dictionary(grouping: bucket) { hash(of: $0.url, limit: 65_536) ?? $0.url.path }
            for headMatches in byHead.values where headMatches.count > 1 {
                if bucket[0].logicalSize <= 65_536 {
                    groups.append(headMatches)
                    continue
                }
                let byFull = Dictionary(grouping: headMatches) { hash(of: $0.url, limit: nil) ?? $0.url.path }
                groups += byFull.values.filter { $0.count > 1 }
            }
            hashed += bucket.count
        }

        // 3. Collapse APFS clones (copies that share storage) and pick a copy to keep.
        var items: [ScanItem] = []
        var skippedClones = 0
        var groupNumber = 0
        let ranked = groups.sorted { ($0[0].allocatedSize * Int64($0.count)) > ($1[0].allocatedSize * Int64($1.count)) }

        for group in ranked {
            var seenContentIDs = Set<Int64>()
            let distinct = group
                .sorted { ($0.created, $0.url.path.count) < ($1.created, $1.url.path.count) }
                .filter { candidate in
                    guard let id = candidate.contentID else { return true }
                    if seenContentIDs.insert(id).inserted { return true }
                    skippedClones += 1
                    return false
                }
            guard distinct.count > 1 else { continue }

            groupNumber += 1
            for (index, candidate) in distinct.enumerated() {
                let isKeeper = index == 0
                let folder = Format.tildePath(candidate.url.deletingLastPathComponent())
                items.append(ScanItem(
                    path: candidate.url,
                    size: candidate.allocatedSize,
                    category: .duplicates,
                    detail: isKeeper ? "\(folder) \u{2022} oldest copy, suggested to keep" : folder,
                    duplicateGroup: groupNumber,
                    isSuggestedKeeper: isKeeper
                ))
            }
        }

        var warnings = [FileWalker.permissionWarning(from: progress)].compactMap { $0 }
        if skippedClones > 0 {
            warnings.append(ScanWarning(message: "Left out \(skippedClones) cop\(skippedClones == 1 ? "y" : "ies") that macOS stores as clones of another file. They share storage, so deleting them would free almost nothing."))
        }
        return ScanResult(category: .duplicates, items: items, warnings: warnings)
    }

    /// SHA-256 of the first `limit` bytes (or the whole file). Nil if unreadable or cancelled.
    private static func hash(of url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            if Task.isCancelled { return nil }
            let chunk: Data? = autoreleasepool {
                try? handle.read(upToCount: min(1_048_576, remaining))
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

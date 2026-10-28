import Foundation

/// Live progress for one running scan. Written from the scan's background
/// thread, read by the UI on a timer, so it's guarded by a lock rather than
/// published through SwiftUI on every file.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var filesSeen = 0
    private var currentPath = ""
    private var phase = "Starting\u{2026}"
    private var unreadable: [URL] = []

    struct Snapshot {
        let filesSeen: Int
        let currentPath: String
        let phase: String
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(filesSeen: filesSeen, currentPath: currentPath, phase: phase) }
    }

    func tick(_ url: URL) {
        lock.withLock {
            filesSeen += 1
            // Updating the path string on every file is wasted work; the UI only samples a few times a second.
            if filesSeen % 64 == 1 { currentPath = url.path }
        }
    }

    /// Batched version of `tick` for scanners that read a whole folder at once.
    func add(_ count: Int, currentPath path: String) {
        lock.withLock {
            filesSeen += count
            currentPath = path
        }
    }

    func setPhase(_ text: String) {
        lock.withLock { phase = text }
    }

    func recordUnreadable(_ url: URL) {
        lock.withLock { unreadable.append(url) }
    }

    var unreadableFolders: [URL] {
        lock.withLock { unreadable }
    }
}

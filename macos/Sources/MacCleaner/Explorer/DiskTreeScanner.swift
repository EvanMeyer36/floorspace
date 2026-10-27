import Darwin
import Foundation

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// WizTree-style whole-folder scan. Reads directories in bulk with
/// getattrlistbulk(2), which returns names, types and allocated sizes for many
/// entries per system call, and scans folders on several threads at once.
final class DiskTreeScanner: @unchecked Sendable {
    struct Output {
        let root: DiskNode
        let typeStats: [TypeStat]
        let unreadableCount: Int
        let unreadableExamples: [String]
        let folderCount: Int
        let fileCount: Int
        let duration: TimeInterval
    }

    /// Files at least this big get their own node; smaller ones are grouped per folder.
    static let individualFileMinBytes: Int64 = 256 * 1024
    /// Below this depth folders are queued for other threads; deeper ones are scanned inline.
    private static let parallelDepth = 8

    /// Never descended into: other volumes, the firmlinked data volume (already
    /// reached through /Users etc.), virtual file systems, and cloud-provider
    /// folders whose listing could start downloads.
    static var skippedPaths: Set<String> {
        let home = DiskUtils.home.path
        return ["/System/Volumes", "/Volumes", "/dev", "/.nofollow", "/.resolve", "/.vol", "/net", "/home", "/Network",
                home + "/Library/CloudStorage", home + "/Library/Mobile Documents"]
    }

    private let progress: ScanProgress
    private let cancel: CancelToken
    private let queue = OperationQueue()
    private let lock = NSLock()
    private let skipped = DiskTreeScanner.skippedPaths

    private var stats: [String: TypeStat] = [:]
    private var unreadable: [String] = []
    private var unreadableCount = 0
    private var hardLinksSeen = Set<UInt64>()
    private var folderCount = 0
    private var fileCount = 0

    init(progress: ScanProgress, cancel: CancelToken) {
        self.progress = progress
        self.cancel = cancel
        queue.maxConcurrentOperationCount = max(4, ProcessInfo.processInfo.activeProcessorCount)
        queue.qualityOfService = .userInitiated
    }

    func scan(path: String, displayName: String) -> Output {
        let start = Date()
        let root = DiskNode(name: displayName, kind: .folder, parent: nil)
        root.rootPath = path

        progress.setPhase("Reading folders\u{2026}")
        queue.addOperation { self.scanFolder(root, path: path, depth: 0) }
        queue.waitUntilAllOperationsAreFinished()

        progress.setPhase("Adding up sizes\u{2026}")
        Self.finalize(root)

        return Output(
            root: root,
            typeStats: stats.values.sorted { $0.size > $1.size },
            unreadableCount: unreadableCount,
            unreadableExamples: unreadable,
            folderCount: folderCount,
            fileCount: fileCount,
            duration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Reading one folder

    // getattrlistbulk attribute bits (sys/attr.h).
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private func scanFolder(_ node: DiskNode, path: String, depth: Int) {
        if cancel.isCancelled {
            queue.cancelAllOperations()
            return
        }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            markUnreadable(node, path: path)
            return
        }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnObjType | Self.cmnFileID | Self.cmnError
        request.fileattr = Self.fileLinkCount | Self.fileAllocSize

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var subfolders: [(DiskNode, String)] = []
        var smallFilesSize: Int64 = 0
        var smallFilesCount = 0
        var smallTypeSizes = [Int64](repeating: 0, count: FileType.allCases.count)
        var localStats: [String: TypeStat] = [:]
        var localFiles = 0
        var hardLinks: [UInt64: (size: Int64, name: String)] = [:]
        var readFailed = false

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { readFailed = true }
            if count <= 0 { break }

            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + MemoryLayout<UInt32>.size

                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // ATTR_CMN_ERROR, when present, comes straight after the returned-attributes set.
                if returned.commonattr & Self.cmnError != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                    if error != 0 { continue }
                }
                guard returned.commonattr & Self.cmnName != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                field += MemoryLayout<attrreference_t>.size

                var objectType: UInt32 = 0
                if returned.commonattr & Self.cmnObjType != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & Self.cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }
                var linkCount: UInt32 = 1
                if returned.fileattr & Self.fileLinkCount != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var allocated: Int64 = 0
                if returned.fileattr & Self.fileAllocSize != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                }

                if objectType == UInt32(VDIR.rawValue) {
                    let name = String(cString: namePointer)
                    let childPath = path == "/" ? "/" + name : path + "/" + name
                    guard !skipped.contains(childPath) else { continue }
                    let child = DiskNode(name: name, kind: .folder, parent: node)
                    node.children.append(child)
                    subfolders.append((child, childPath))
                    continue
                }
                guard objectType == UInt32(VREG.rawValue) else { continue } // symlinks, sockets, etc. take no real space

                localFiles += 1
                // A hard-linked file's blocks are shared by every link; count them once.
                if linkCount > 1 {
                    hardLinks[fileID] = (allocated, String(cString: namePointer))
                    continue
                }
                let ext = Self.fileExtension(namePointer)
                localStats[ext, default: TypeStat(ext: ext, size: 0, count: 0)].size += allocated
                localStats[ext]!.count += 1

                if allocated >= Self.individualFileMinBytes {
                    node.children.append(DiskNode(name: String(cString: namePointer), kind: .file, size: allocated, fileCount: 1, parent: node))
                } else {
                    smallFilesSize += allocated
                    smallFilesCount += 1
                    smallTypeSizes[FileType.of(extension: ext).rawValue] += allocated
                }
            }
        }
        close(fd)

        if readFailed && localFiles == 0 && subfolders.isEmpty {
            markUnreadable(node, path: path)
            return
        }

        let firstSightings = lock.withLock {
            let unseen = hardLinks.filter { hardLinksSeen.insert($0.key).inserted }.map(\.value)
            for (ext, stat) in localStats {
                stats[ext, default: TypeStat(ext: ext, size: 0, count: 0)].size += stat.size
                stats[ext]!.count += stat.count
            }
            folderCount += 1
            fileCount += localFiles
            return unseen
        }
        for link in firstSightings {
            if link.size >= Self.individualFileMinBytes {
                node.children.append(DiskNode(name: link.name, kind: .file, size: link.size, fileCount: 1, parent: node))
            } else {
                smallFilesSize += link.size
                smallFilesCount += 1
                smallTypeSizes[FileType.of(extension: (link.name as NSString).pathExtension.lowercased()).rawValue] += link.size
            }
        }
        if smallFilesCount > 0 {
            let group = DiskNode(
                name: "\(Format.count(smallFilesCount)) smaller file\(smallFilesCount == 1 ? "" : "s")",
                kind: .smallFiles(count: smallFilesCount), size: smallFilesSize, fileCount: smallFilesCount, parent: node)
            group.typeSizes = smallTypeSizes
            group.dominantType = FileType.dominant(in: smallTypeSizes)
            node.children.append(group)
        }
        progress.add(localFiles + subfolders.count, currentPath: path)

        for (child, childPath) in subfolders {
            if depth < Self.parallelDepth {
                queue.addOperation { self.scanFolder(child, path: childPath, depth: depth + 1) }
            } else {
                scanFolder(child, path: childPath, depth: depth + 1)
            }
        }
    }

    private func markUnreadable(_ node: DiskNode, path: String) {
        node.isUnreadable = true
        lock.withLock {
            unreadableCount += 1
            if unreadable.count < 50 { unreadable.append(path) }
        }
    }

    /// Lowercased extension straight from the C string, without building the whole name.
    private static func fileExtension(_ name: UnsafePointer<CChar>) -> String {
        let length = strlen(name)
        var i = length - 1
        while i > 0 && i + 12 > length {
            if name[i] == 0x2E /* . */ {
                return String(cString: name + i + 1).lowercased()
            }
            i -= 1
        }
        return ""
    }

    // MARK: - Totals

    /// Rolls sizes up the tree, sorts every folder biggest-first and numbers the nodes.
    /// Iterative so very deep folder trees can't overflow the stack.
    private static func finalize(_ root: DiskNode) {
        var order: [DiskNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children)
        }
        let typeCount = FileType.allCases.count
        for node in order.reversed() where node.isFolder {
            node.size = node.children.reduce(0) { $0 + $1.size }
            node.fileCount = node.children.reduce(0) { $0 + $1.fileCount }
            node.children.sort { $0.size > $1.size }

            var sizes = [Int64](repeating: 0, count: typeCount)
            for child in node.children {
                if let type = child.fileType {
                    sizes[type.rawValue] += child.size
                } else if let childSizes = child.typeSizes {
                    for i in 0..<typeCount { sizes[i] += childSizes[i] }
                    child.typeSizes = nil
                }
            }
            node.typeSizes = sizes
            node.dominantType = FileType.dominant(in: sizes)
        }
        root.typeSizes = nil
        for (index, node) in order.enumerated() {
            node.id = index + 1
        }
    }
}

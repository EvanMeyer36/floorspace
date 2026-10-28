import AppKit
import Foundation

@MainActor
final class ExplorerModel: ObservableObject {
    enum Target: Hashable {
        case startupDisk
        case home
        case folder(URL)

        var path: String {
            switch self {
            case .startupDisk: return "/"
            case .home: return DiskUtils.home.path
            case .folder(let url): return url.path
            }
        }

        var title: String {
            switch self {
            case .startupDisk:
                let name = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
                return name ?? "Macintosh HD"
            case .home: return "Home folder"
            case .folder(let url): return Format.tildePath(url)
            }
        }
    }

    enum Highlight: Equatable {
        case fileExtension(String)
        case fileType(FileType)

        func matches(_ node: DiskNode) -> Bool {
            switch self {
            case .fileExtension(let ext): return node.fileExtension == ext && node.fileType != nil
            case .fileType(let type): return node.fileType == type
            }
        }
    }

    struct Summary {
        let files: Int
        let folders: Int
        let duration: TimeInterval
        let unreadableCount: Int
        let unreadableExamples: [String]
        let otherVolumes: [String]
    }

    @Published var target: Target = .startupDisk
    @Published private(set) var root: DiskNode?
    @Published private(set) var typeStats: [TypeStat] = []
    /// The biggest individual files anywhere in the scan, biggest first (WizTree's file view).
    @Published private(set) var largestFiles: [DiskNode] = []
    @Published private(set) var summary: Summary?
    @Published private(set) var progress: ScanProgress?
    /// The folder the treemap is zoomed into.
    @Published var focus: DiskNode?
    /// Everything currently selected, across the tree, the file list and the map.
    @Published private(set) var selectedIDs: Set<Int> = []
    @Published var highlight: Highlight?
    /// Bumped whenever the tree changes shape so views re-read it.
    @Published private(set) var treeVersion = 0

    nonisolated static let largestFilesLimit = 1_000

    private var nodesByID: [Int: DiskNode] = [:]
    private var cancelToken: CancelToken?

    var isScanning: Bool { progress != nil }

    // MARK: - Scanning

    func scan() {
        guard progress == nil else { return }
        let progress = ScanProgress()
        let token = CancelToken()
        let target = target
        self.progress = progress
        cancelToken = token

        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> (DiskTreeScanner.Output, [Int: DiskNode], [DiskNode]) in
                let scanner = DiskTreeScanner(progress: progress, cancel: token)
                let output = scanner.scan(path: target.path, displayName: target.title)
                if target == .startupDisk { Self.addUnattributedSpace(to: output.root) }
                let index = Self.index(output.root)
                let largest = index.values
                    .filter { if case .file = $0.kind { return true } else { return false } }
                    .sorted { $0.size > $1.size }
                    .prefix(Self.largestFilesLimit)
                return (output, index, Array(largest))
            }.value

            self.progress = nil
            cancelToken = nil
            guard !token.isCancelled else { return }

            let (result, index, largest) = output
            root = result.root
            nodesByID = index
            typeStats = result.typeStats
            largestFiles = largest
            summary = Summary(files: result.fileCount, folders: result.folderCount, duration: result.duration,
                              unreadableCount: result.unreadableCount, unreadableExamples: result.unreadableExamples,
                              otherVolumes: result.otherVolumes)
            focus = result.root
            selectedIDs = []
            highlight = nil
            treeVersion += 1
        }
    }

    func cancelScan() {
        cancelToken?.cancel()
    }

    /// On the startup disk, space the scan couldn't see (sealed system volume internals,
    /// local snapshots, swap, folders macOS wouldn't open) shows up as one block so the
    /// map adds up to what the disk reports as used.
    nonisolated private static func addUnattributedSpace(to root: DiskNode) {
        let unaccounted = DiskSpace.current().used - root.size
        guard unaccounted > 0 else { return }
        let node = DiskNode(name: "System data, snapshots & unreadable folders", kind: .unattributed,
                            size: unaccounted, parent: root)
        node.id = -1
        root.children.append(node)
        root.children.sort { $0.size > $1.size }
        root.size += unaccounted
    }

    nonisolated private static func index(_ root: DiskNode) -> [Int: DiskNode] {
        var index: [Int: DiskNode] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            index[node.id] = node
            stack.append(contentsOf: node.children)
        }
        return index
    }

    // MARK: - Selection & navigation

    func node(withID id: Int?) -> DiskNode? {
        guard let id, let node = nodesByID[id], node === root || node.parent != nil else { return nil }
        return node
    }

    var selectedNodes: [DiskNode] {
        selectedIDs.compactMap { node(withID: $0) }.sorted { $0.size > $1.size }
    }

    /// Total size of the selection, counting a folder and something inside it only once.
    var selectedSize: Int64 {
        let nodes = selectedNodes
        return nodes.filter { node in !nodes.contains { $0 !== node && node.isDescendant(of: $0) } }
            .reduce(0) { $0 + $1.size }
    }

    /// Selection from the tree or file list. Picking a single item zooms the map
    /// to its folder so it's visible in context; picking several leaves the map where it is.
    func selectFromList(_ ids: Set<Int>) {
        let added = ids.subtracting(selectedIDs)
        selectedIDs = ids
        if ids.count == 1, let node = node(withID: ids.first), node !== root {
            focus = node.parent
        } else if added.count == 1, let node = node(withID: added.first), let parent = node.parent,
                  let focus, !(parent === focus || parent.isDescendant(of: focus)) {
            self.focus = parent
        }
    }

    /// Click on the map: replaces the selection, or with ⌘ held, adds/removes the item.
    func selectFromMap(_ node: DiskNode?, toggling: Bool) {
        guard let node else {
            if !toggling { selectedIDs = [] }
            return
        }
        if toggling {
            if selectedIDs.contains(node.id) { selectedIDs.remove(node.id) } else { selectedIDs.insert(node.id) }
        } else {
            selectedIDs = [node.id]
        }
    }

    func clearSelection() {
        selectedIDs = []
    }

    func zoom(into node: DiskNode) {
        guard node.isFolder, !node.children.isEmpty else { return }
        focus = node
    }

    func zoomOut() {
        if let parent = focus?.parent { focus = parent }
    }

    // MARK: - Actions

    /// Only things inside the home folder or /Applications can be trashed from here,
    /// never the standard top-level folders themselves, and never pieces of an app or
    /// a media library (removing a file from inside one breaks it; trash the whole thing instead).
    func canTrash(_ node: DiskNode) -> Bool {
        guard node.isOnDisk, node !== root, protectingPackage(of: node) == nil else { return false }
        let path = node.path
        let home = DiskUtils.home.path
        let protected = Set([home, "/Applications"] +
            ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public"]
                .map { home + "/" + $0 })
        guard !protected.contains(path) else { return false }
        return path.hasPrefix(home + "/") || path.hasPrefix("/Applications/")
    }

    /// Bundles whose insides must only be changed by their own app: apps, and libraries
    /// such as Photos, whose database files (e.g. Photos.sqlite-wal) look like junk but aren't.
    private static let protectedPackageExtensions: Set<String> = [
        "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "theater",
    ]

    /// The app or library this item is part of, if any.
    func protectingPackage(of node: DiskNode) -> DiskNode? {
        node.ancestors.last { Self.protectedPackageExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
    }

    struct TrashResult {
        var movedCount = 0
        var movedBytes: Int64 = 0
        var failures: [(name: String, message: String)] = []
    }

    /// The items that would actually be trashed: removable ones, without anything
    /// inside a folder that's also being trashed.
    func trashPlan(for nodes: [DiskNode]) -> [DiskNode] {
        let removable = nodes.filter(canTrash)
        return removable.filter { node in !removable.contains { $0 !== node && node.isDescendant(of: $0) } }
    }

    /// Moves the items to the Trash and takes them out of the tree.
    func moveToTrash(_ nodes: [DiskNode]) -> TrashResult {
        var result = TrashResult()
        // Decide refusals up front: once an item is detached its path can't be rebuilt.
        for node in nodes where node.isOnDisk && !canTrash(node) {
            let reason: String
            if let package = protectingPackage(of: node) {
                reason = package.name.hasSuffix(".app")
                    ? "It's part of \(package.name), and removing it would break the app. Trash the whole app instead."
                    : "It's part of \(package.name), and removing it could damage the library. Manage it from its app instead."
            } else {
                reason = "It's outside your home folder and Applications, so Floorspace won't remove it."
            }
            result.failures.append((node.name, reason))
        }
        for node in trashPlan(for: nodes) {
            guard let url = node.url else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                result.failures.append((node.name, error.localizedDescription))
                continue
            }
            result.movedCount += 1
            result.movedBytes += node.size
            detach(node)
        }
        if result.movedCount > 0 { treeVersion += 1 }
        return result
    }

    private func detach(_ node: DiskNode) {
        if node.fileType != nil, let index = typeStats.firstIndex(where: { $0.ext == node.fileExtension }) {
            typeStats[index].size -= node.size
            typeStats[index].count -= 1
        }
        if let focus, focus === node || focus.isDescendant(of: node) {
            self.focus = node.parent
        }
        selectedIDs.remove(node.id)
        largestFiles.removeAll { $0 === node || $0.isDescendant(of: node) }
        let parent = node.parent
        node.removeFromTree()
        parent?.children.sort { $0.size > $1.size }
    }

    func revealInFinder(_ nodes: [DiskNode]) {
        let urls = nodes.compactMap(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func revealInFinder(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPaths(_ nodes: [DiskNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.filter(\.isOnDisk).map(\.path).joined(separator: "\n"), forType: .string)
    }
}

import AppKit
import Foundation

/// Nodes of the engine's latest disk tree, cached per scan/change so tables can ask for children
/// synchronously while scrolling. Reset whenever the tree changes.
final class TreeCache: @unchecked Sendable {
    static let shared = TreeCache()
    private let lock = NSLock()
    private var children: [NodeID: [DiskNode]] = [:]
    private var nodes: [NodeID: DiskNode] = [:]

    func reset() {
        lock.withLock {
            children = [:]
            nodes = [:]
        }
    }

    func children(of id: NodeID) -> [DiskNode] {
        if let cached = lock.withLock({ children[id] }) { return cached }
        let list = (try? Engine.call("tree_children", ["id": id], as: [DiskNode].self)) ?? []
        lock.withLock {
            children[id] = list
            for node in list { nodes[node.id] = node }
        }
        return list
    }

    func remember(_ list: [DiskNode]) {
        lock.withLock { for node in list { nodes[node.id] = node } }
    }

    func node(_ id: NodeID) -> DiskNode? {
        if let cached = lock.withLock({ nodes[id] }) { return cached }
        guard let (node, ancestors) = try? Engine.call("tree_node", ["id": id], as: Pair?.self)?.value else { return nil }
        remember([node] + ancestors)
        return node
    }

    /// Root first, ending with the node's parent.
    func ancestors(of id: NodeID) -> [DiskNode] {
        guard let pair = try? Engine.call("tree_node", ["id": id], as: Pair?.self) else { return [] }
        remember(pair.value.1)
        return pair.value.1
    }

    /// The engine replies with a [node, ancestors] pair.
    private struct Pair: Decodable {
        let value: (DiskNode, [DiskNode])
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            value = (try c.decode(DiskNode.self), try c.decode([DiskNode].self))
        }
    }
}

extension DiskNode {
    /// For the folder tree table: nil marks a row without a disclosure triangle.
    var childNodes: [DiskNode]? {
        isFolder && childCount > 0 ? TreeCache.shared.children(of: id) : nil
    }
}

/// WizTree-style disk explorer, backed by the shared engine: the tree, the treemap layout and
/// removals all happen in the engine; this keeps the UI's selection, zoom and highlight.
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
    @Published private(set) var selectedIDs: Set<NodeID> = []
    @Published var highlight: Highlight?
    /// Bumped whenever the tree changes shape so views re-read it.
    @Published private(set) var treeVersion = 0

    var isScanning: Bool { progress != nil }

    // MARK: - Scanning

    func scan() {
        guard progress == nil else { return }
        let progress = ScanProgress(kind: "tree")
        self.progress = progress
        let path = target.path
        Task {
            let overview = try? await Engine.background { try Engine.call("tree_scan", ["path": path], as: TreeOverview?.self) }
            self.progress = nil
            guard let overview = overview ?? nil else { return } // cancelled or failed: keep the previous results
            TreeCache.shared.reset()
            TreeCache.shared.remember([overview.root])
            root = overview.root
            typeStats = overview.typeStats
            largestFiles = (try? Engine.call("tree_largest", as: [DiskNode].self)) ?? []
            TreeCache.shared.remember(largestFiles)
            let s = overview.summary
            summary = Summary(files: s.files, folders: s.folders, duration: Double(s.durationMs) / 1000, unreadableCount: s.unreadableCount,
                              unreadableExamples: s.unreadableExamples, otherVolumes: s.otherVolumes)
            focus = overview.root
            selectedIDs = []
            highlight = nil
            treeVersion += 1
        }
    }

    func cancelScan() {
        progress?.cancel()
    }

    // MARK: - Tree access

    func children(of node: DiskNode) -> [DiskNode] {
        TreeCache.shared.children(of: node.id)
    }

    func node(withID id: NodeID?) -> DiskNode? {
        id.flatMap(TreeCache.shared.node)
    }

    func parent(of node: DiskNode) -> DiskNode? {
        self.node(withID: node.parent)
    }

    func ancestors(of node: DiskNode) -> [DiskNode] {
        TreeCache.shared.ancestors(of: node.id)
    }

    func isDescendant(_ node: DiskNode, of other: DiskNode) -> Bool {
        ancestors(of: node).contains { $0.id == other.id }
    }

    // MARK: - Selection & navigation

    var selectedNodes: [DiskNode] {
        selectedIDs.compactMap { node(withID: $0) }.sorted { $0.size > $1.size }
    }

    /// Total size of the selection, counting a folder and something inside it only once.
    var selectedSize: Int64 {
        guard !selectedIDs.isEmpty else { return 0 }
        return (try? Engine.call("tree_selection_size", ["ids": Array(selectedIDs)], as: Int64.self)) ?? 0
    }

    /// Selection from the tree or file list. Picking a single item zooms the map
    /// to its folder so it's visible in context; picking several leaves the map where it is.
    func selectFromList(_ ids: Set<NodeID>) {
        let added = ids.subtracting(selectedIDs)
        selectedIDs = ids
        if ids.count == 1, let node = self.node(withID: ids.first), node.id != root?.id {
            focus = parent(of: node)
        } else if added.count == 1, let node = self.node(withID: added.first), let parent = parent(of: node),
                  let focus, !(parent.id == focus.id || isDescendant(parent, of: focus)) {
            self.focus = parent
        }
    }

    /// Click on the map: replaces the selection, or with ⌘ held, adds/removes the item.
    func selectFromMap(_ id: NodeID?, toggling: Bool) {
        guard let id else {
            if !toggling { selectedIDs = [] }
            return
        }
        if toggling {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else {
            selectedIDs = [id]
        }
    }

    func clearSelection() {
        selectedIDs = []
    }

    func zoom(into node: DiskNode) {
        guard node.isFolder, node.childCount > 0 else { return }
        focus = node
    }

    func zoomOut() {
        if let focus, let parent = parent(of: focus) { self.focus = parent }
    }

    // MARK: - Actions

    /// The engine decides what's removable: inside the home folder or a whole app in
    /// /Applications, never the standard folders and never pieces of an app or media library.
    func canTrash(_ node: DiskNode) -> Bool {
        node.canTrash
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
        let ids = Set(removable.map(\.id))
        return removable.filter { node in !ancestors(of: node).contains { ids.contains($0.id) } }
    }

    /// Moves the items to the Trash (in the engine) and refreshes the tree.
    func moveToTrash(_ nodes: [DiskNode]) -> TrashResult {
        var result = TrashResult()
        for node in nodes where node.isOnDisk && !node.canTrash {
            result.failures.append((node.name, "It's part of an app or library (like Photos), or outside your home folder and Applications, so Floorspace won't remove it."))
        }
        let plan = trashPlan(for: nodes)
        guard !plan.isEmpty else { return result }
        guard let engine = try? Engine.call("tree_trash", ["ids": plan.map(\.id)], as: TreeTrashResult.self) else {
            result.failures.append(("Floorspace", "The engine couldn't move these to the Trash."))
            return result
        }
        result.movedCount = engine.moved.count
        result.movedBytes = engine.movedBytes
        result.failures += engine.failures.map { (Format.tildePath($0.target), $0.message ?? "") }
        if !engine.moved.isEmpty { refreshAfterRemoval(moved: Set(engine.moved)) }
        return result
    }

    private func refreshAfterRemoval(moved: Set<NodeID>) {
        let focusWasRemoved = focus.map { f in moved.contains(f.id) || ancestors(of: f).contains { moved.contains($0.id) } } ?? false
        TreeCache.shared.reset()
        root = node(withID: 0)
        focus = focusWasRemoved ? root : focus.flatMap { node(withID: $0.id) } ?? root
        largestFiles = (try? Engine.call("tree_largest", as: [DiskNode].self)) ?? []
        TreeCache.shared.remember(largestFiles)
        typeStats = (try? Engine.call("tree_types", as: [TypeStat].self)) ?? typeStats
        selectedIDs.subtract(moved)
        treeVersion += 1
    }

    func revealInFinder(_ nodes: [DiskNode]) {
        let urls = nodes.compactMap(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func revealInFinder(_ node: DiskNode) {
        revealInFinder([node])
    }

    func copyPaths(_ nodes: [DiskNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.compactMap(\.path).joined(separator: "\n"), forType: .string)
    }
}

import SwiftUI

/// Breadcrumb for the map's current folder, plus the color legend.
struct TreemapHeader: View {
    @EnvironmentObject var explorer: ExplorerModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
        }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                explorer.zoomOut()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Up one folder")
            .disabled(explorer.focus?.parent == nil)

            if let focus = explorer.focus {
                ForEach(explorer.ancestors(of: focus) + [focus], id: \.id) { node in
                    if node.parent != nil {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(node.name) { explorer.focus = node }
                        .buttonStyle(.plain)
                        .foregroundStyle(node.id == focus.id ? .primary : .secondary)
                        .lineLimit(1)
                }
                Text(Format.bytes(focus.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 6)
            }

            Spacer(minLength: 16)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)

        legend
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Clicking a legend entry highlights that kind of file on the map.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(FileType.allCases) { type in
                Button {
                    explorer.highlight = explorer.highlight == .fileType(type) ? nil : .fileType(type)
                } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(type.color).frame(width: 10, height: 10)
                        Text(type.title)
                            .foregroundStyle(explorer.highlight == .fileType(type) ? .primary : .secondary)
                            .fontWeight(explorer.highlight == .fileType(type) ? .semibold : .regular)
                    }
                }
                .buttonStyle(.plain)
                .help("Highlight \(type.title.lowercased())")
            }
        }
        .font(.caption)
    }
}

/// The engine's treemap layout for one folder and size, fetched off the main thread.
@MainActor
final class TreemapLayoutLoader: ObservableObject {
    struct Layout {
        var id = 0
        var cells: [TreemapCell] = []
        /// Cell indices under each cell (the last entry holds the top-level cells), for hit-testing.
        var children: [[Int]] = [[]]
    }

    @Published private(set) var layout = Layout()
    private var key: (NodeID, CGSize, Int)?
    private var pending: Task<Void, Never>?

    /// Asks for a new layout once resizing pauses; ignores repeats of the current request.
    func request(focus: NodeID, size: CGSize, version: Int) {
        if let key, key.0 == focus, key.1 == size, key.2 == version { return }
        let sizeOnly = key.map { $0.0 == focus && $0.2 == version } ?? false
        key = (focus, size, version)
        pending?.cancel()
        pending = Task {
            if sizeOnly { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled, size.width > 4, size.height > 4 else { return }
            let args: [String: Any] = ["focus": focus, "width": Double(size.width), "height": Double(size.height)]
            guard let cells = try? await Engine.background({ try Engine.call("treemap", args, as: [TreemapCell].self) }), !Task.isCancelled else { return }
            var children: [[Int]] = Array(repeating: [], count: cells.count + 1)
            for (i, cell) in cells.enumerated() { children[cell.parentCell ?? cells.count].append(i) }
            layout = Layout(id: layout.id + 1, cells: cells, children: children)
        }
    }

    /// The deepest cell under a point, walking down through folder cells.
    func hit(_ point: CGPoint) -> Int? {
        var level = layout.cells.count
        var found: Int?
        while let next = layout.children[level].first(where: { layout.cells[$0].rect.cgRect.contains(point) }) {
            found = next
            level = next
        }
        return found
    }
}

struct TreemapView: View {
    @EnvironmentObject var explorer: ExplorerModel
    let onTrash: ([DiskNode]) -> Void

    @StateObject private var loader = TreemapLayoutLoader()
    @State private var hovered: Int?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let layout = loader.layout
            let hoveredCell = hovered.flatMap { $0 < layout.cells.count ? layout.cells[$0] : nil }

            TreemapCanvas(cells: layout.cells, layoutID: layout.id, highlight: explorer.highlight, selectedIDs: explorer.selectedIDs)
                .equatable()
                .overlay {
                    if let rect = hoveredCell?.rect.cgRect {
                        Rectangle()
                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hoveredCell {
                        Tooltip(cell: hoveredCell, focus: explorer.focus)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in -min(hoverPoint.x + 16, max(0, geo.size.width - d.width - 4)) }
                            .alignmentGuide(.top) { d in -min(hoverPoint.y + 16, max(0, geo.size.height - d.height - 4)) }
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        let cell = loader.hit(point)
                        if cell != hovered { hovered = cell }
                    case .ended:
                        hovered = nil
                    }
                }
                .onTapGesture(count: 2) { drillDown(hoveredCell) }
                .onTapGesture {
                    explorer.selectFromMap(hoveredCell?.node, toggling: NSEvent.modifierFlags.contains(.command))
                }
                .contextMenu {
                    // Right-clicking inside the selection acts on all of it; elsewhere, on the item under the pointer.
                    if let id = hoveredCell?.node, let node = explorer.node(withID: id) {
                        let nodes = explorer.selectedIDs.contains(id) ? explorer.selectedNodes : [node]
                        DiskNodeActions(nodes: nodes, onTrash: onTrash)
                    }
                }
                .onAppear { request(geo.size) }
                .onChange(of: geo.size) { request($1) }
                .onChange(of: explorer.focus?.id) { request(geo.size) }
                .onChange(of: explorer.treeVersion) { request(geo.size) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func request(_ size: CGSize) {
        guard let focus = explorer.focus else { return }
        hovered = nil
        loader.request(focus: focus.id, size: size, version: explorer.treeVersion)
    }

    /// Double-click zooms into the top-level block under the pointer, one level at a time.
    /// On a "more items" sliver it jumps straight into the folder holding them; on grouped
    /// small files it opens their folder in Finder, since they aren't kept individually.
    private func drillDown(_ cell: TreemapCell?) {
        guard let cell, let focus = explorer.focus else { return }
        if cell.kind == .sliver, let container = cell.container {
            if container != focus.id, let folder = explorer.node(withID: container) { explorer.zoom(into: folder) }
            return
        }
        guard let id = cell.node, let node = explorer.node(withID: id) else { return }
        switch cell.kind {
        case .smallFiles:
            if let folder = explorer.parent(of: node) { explorer.revealInFinder(folder) }
        case .file:
            explorer.revealInFinder(node)
        default:
            // Zoom one level: the ancestor of this block that's a direct child of the current folder.
            let chain = explorer.ancestors(of: node) + [node]
            if let index = chain.firstIndex(where: { $0.id == focus.id }), index + 1 < chain.count {
                explorer.zoom(into: chain[index + 1])
            }
        }
    }
}

/// The drawing itself, split out so hovering (which only moves the outline and
/// tooltip) doesn't redraw thousands of cells.
private struct TreemapCanvas: View, Equatable {
    let cells: [TreemapCell]
    let layoutID: Int
    let highlight: ExplorerModel.Highlight?
    let selectedIDs: Set<NodeID>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layoutID == rhs.layoutID && lhs.highlight == rhs.highlight && lhs.selectedIDs == rhs.selectedIDs
    }

    var body: some View {
        Canvas { context, _ in
            var selectedRects: [CGRect] = []

            for cell in cells {
                let rect = cell.rect.cgRect
                if let id = cell.node, selectedIDs.contains(id) { selectedRects.append(rect) }

                switch cell.kind {
                case .sliver:
                    // Stands in for many tiny items: tinted with the biggest one's type.
                    fillBlock(rect, type: cell.fileType, opacity: 0.6, context: context)
                case .collapsedFolder:
                    fillBlock(rect, type: cell.fileType, opacity: 0.85, context: context)
                case .folder:
                    // Nested fills would stack into mud, so only top-level folders are shaded.
                    if cell.depth == 1 {
                        context.fill(Path(rect), with: .color(Color.primary.opacity(0.05)))
                    }
                    context.stroke(Path(rect.insetBy(dx: 0.25, dy: 0.25)), with: .color(Color.primary.opacity(0.16)), lineWidth: 0.5)
                    if let header = cell.header?.cgRect {
                        context.fill(Path(header.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color.primary.opacity(0.06)))
                        drawLabel("\(cell.name)  \(Format.bytes(cell.size))", in: header, context: context)
                    }
                case .file:
                    let dimmed: Bool
                    switch highlight {
                    case .none: dimmed = false
                    case .fileType(let wanted): dimmed = cell.fileType != wanted
                    case .fileExtension(let ext): dimmed = Self.fileExtension(cell.name) != ext
                    }
                    context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color((cell.fileType ?? .other).color.opacity(dimmed ? 0.15 : 1)))
                case .smallFiles:
                    fillBlock(rect, type: cell.fileType, opacity: 0.75, context: context)
                case .unattributed:
                    // Not files at all, so no file-type color: a hatched block that reads as "unknown".
                    let inner = rect.insetBy(dx: 0.5, dy: 0.5)
                    context.fill(Path(inner), with: .color(Color.primary.opacity(0.06)))
                    var hatch = context
                    hatch.clip(to: Path(inner))
                    var stripes = Path()
                    var x = inner.minX - inner.height
                    while x < inner.maxX {
                        stripes.move(to: CGPoint(x: x, y: inner.maxY))
                        stripes.addLine(to: CGPoint(x: x + inner.height, y: inner.minY))
                        x += 8
                    }
                    hatch.stroke(stripes, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
                    if rect.width > 120 && rect.height > 40 {
                        drawLabel(cell.name + "  " + Format.bytes(cell.size), in: rect.insetBy(dx: 6, dy: 6), context: context, centered: true)
                    }
                }
            }

            for rect in selectedRects {
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 3)
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
            }
        }
    }

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Solid block in its file-type color; faded when another type is highlighted.
    private func fillBlock(_ rect: CGRect, type: FileType?, opacity: Double, context: GraphicsContext) {
        let type = type ?? .other
        let dimmed: Bool
        switch highlight {
        case .none: dimmed = false
        case .fileType(let wanted): dimmed = type != wanted
        case .fileExtension: dimmed = true // only individual files can match an extension
        }
        context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(type.color.opacity(dimmed ? 0.15 : opacity)))
    }

    private func drawLabel(_ text: String, in rect: CGRect, context: GraphicsContext, centered: Bool = false) {
        guard rect.width > 36 else { return }
        var clipped = context
        clipped.clip(to: Path(rect))
        let resolved = clipped.resolve(Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary))
        if centered {
            clipped.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        } else {
            clipped.draw(resolved, at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
        }
    }
}

private struct Tooltip: View {
    @EnvironmentObject var explorer: ExplorerModel
    let cell: TreemapCell
    let focus: DiskNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if cell.kind == .sliver {
                Text("\(Format.count(cell.hiddenCount)) more items").font(.callout.weight(.semibold))
                if let container = cell.container.flatMap(explorer.node(withID:)) {
                    Text(container.name).font(.caption).foregroundStyle(.secondary)
                    if container.id == focus?.id {
                        hint("Each is too small to draw at this size. Find them in the folder tree or Largest Files.")
                    } else {
                        hint("Too small to draw here. Double-click to zoom into this folder.")
                    }
                }
            } else {
                Text(cell.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Format.bytes(cell.size)).monospacedDigit()
                    if let focus, focus.size > 0 {
                        Text(String(format: "%.1f%% of %@", Double(cell.size) / Double(focus.size) * 100, focus.name))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if cell.kind == .file, let type = cell.fileType {
                    Text(type.title).font(.caption).foregroundStyle(.secondary)
                }
                if let node = cell.node.flatMap(explorer.node(withID:)) {
                    if let path = node.path {
                        Text(Format.tildePath(path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                    if node.unreadable {
                        Text("macOS didn't let Floorspace look inside.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if cell.kind == .smallFiles {
                    hint("Files under 256 KB each, grouped so big scans stay fast.\nDouble-click to open the folder in Finder.")
                } else if cell.kind == .collapsedFolder {
                    hint("Double-click to zoom in and see what's inside.")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 300, alignment: .leading)
            .padding(.top, 2)
    }
}

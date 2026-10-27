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
                ForEach(focus.ancestors + [focus], id: \.id) { node in
                    if node.parent != nil {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(node.name) { explorer.focus = node }
                        .buttonStyle(.plain)
                        .foregroundStyle(node === focus ? .primary : .secondary)
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

struct TreemapView: View {
    @EnvironmentObject var explorer: ExplorerModel
    let onTrash: ([DiskNode]) -> Void

    @State private var cache = LayoutCache()
    @State private var hovered: TreemapCell?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = cache.layout(for: explorer.focus, in: bounds, version: explorer.treeVersion)

            TreemapCanvas(
                cells: layout.cells,
                layoutID: layout.id,
                highlight: explorer.highlight,
                selectedIDs: explorer.selectedIDs
            )
            .equatable()
            .overlay {
                if let rect = hovered?.rect {
                    Rectangle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered {
                    Tooltip(cell: hovered, focus: explorer.focus)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            -min(hoverPoint.x + 16, max(0, geo.size.width - d.width - 4))
                        }
                        .alignmentGuide(.top) { d in
                            -min(hoverPoint.y + 16, max(0, geo.size.height - d.height - 4))
                        }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    let cell = layout.cells.last { $0.rect.contains(point) }
                    if cell?.rect != hovered?.rect { hovered = cell }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(count: 2) { drillDown() }
            .onTapGesture {
                explorer.selectFromMap(hovered?.node, toggling: NSEvent.modifierFlags.contains(.command))
            }
            .contextMenu {
                // Right-clicking inside the selection acts on all of it; elsewhere, on the item under the pointer.
                if let node = hovered?.node {
                    let nodes = explorer.selectedIDs.contains(node.id) ? explorer.selectedNodes : [node]
                    DiskNodeActions(nodes: nodes, onTrash: onTrash)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Double-click zooms into the top-level block under the pointer, one level at a time.
    /// On a "more items" sliver it jumps straight into the folder holding them; on grouped
    /// small files it opens their folder in Finder, since they aren't kept individually.
    private func drillDown() {
        guard let cell = hovered, let focus = explorer.focus else { return }
        if cell.node == nil, let container = cell.container {
            if container !== focus {
                explorer.zoom(into: container)
                hovered = nil
            }
            return
        }
        guard let node = cell.node else { return }
        if case .smallFiles = node.kind {
            if let folder = node.parent { explorer.revealInFinder(folder) }
            return
        }
        var target = node
        while let parent = target.parent, parent !== focus { target = parent }
        if target.isFolder {
            explorer.zoom(into: target)
            hovered = nil
        } else {
            explorer.revealInFinder(target)
        }
    }

    final class LayoutCache {
        struct Layout {
            let id: Int
            let cells: [TreemapCell]
        }

        private var key: (ObjectIdentifier?, CGSize, Int)?
        private var current = Layout(id: 0, cells: [])

        func layout(for focus: DiskNode?, in bounds: CGRect, version: Int) -> Layout {
            let newKey = (focus.map(ObjectIdentifier.init), bounds.size, version)
            if let key, key.0 == newKey.0, key.1 == newKey.1, key.2 == newKey.2 { return current }
            key = newKey
            let cells = focus.map { TreemapLayout.layout($0, in: bounds) } ?? []
            current = Layout(id: current.id + 1, cells: cells)
            return current
        }
    }
}

/// The drawing itself, split out so hovering (which only moves the outline and
/// tooltip) doesn't redraw thousands of cells.
private struct TreemapCanvas: View, Equatable {
    let cells: [TreemapCell]
    let layoutID: Int
    let highlight: ExplorerModel.Highlight?
    let selectedIDs: Set<Int>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layoutID == rhs.layoutID && lhs.highlight == rhs.highlight && lhs.selectedIDs == rhs.selectedIDs
    }

    var body: some View {
        Canvas { context, _ in
            var selectedRects: [CGRect] = []

            for cell in cells {
                let rect = cell.rect
                guard let node = cell.node else {
                    // Sliver standing in for many tiny items: tinted with the biggest one's type.
                    fillBlock(rect, type: cell.fillType, opacity: 0.6, context: context)
                    continue
                }
                if selectedIDs.contains(node.id) { selectedRects.append(rect) }

                switch node.kind {
                case .folder where cell.isCollapsed:
                    fillBlock(rect, type: node.dominantType, opacity: 0.85, context: context)
                case .folder:
                    // Nested fills would stack into mud, so only top-level folders are shaded.
                    if cell.depth == 1 {
                        context.fill(Path(rect), with: .color(Color.primary.opacity(0.05)))
                    }
                    context.stroke(Path(rect.insetBy(dx: 0.25, dy: 0.25)), with: .color(Color.primary.opacity(0.16)), lineWidth: 0.5)
                    if let header = cell.headerRect {
                        context.fill(Path(header.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color.primary.opacity(0.06)))
                        drawLabel("\(node.name)  \(Format.bytes(node.size))", in: header, context: context)
                    }
                case .file:
                    let dimmed = highlight.map { !$0.matches(node) } ?? false
                    context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                                 with: .color((node.fileType ?? .other).color.opacity(dimmed ? 0.15 : 1)))
                case .smallFiles:
                    fillBlock(rect, type: node.dominantType, opacity: 0.75, context: context)
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
                        drawLabel(node.name + "  " + Format.bytes(node.size), in: rect.insetBy(dx: 6, dy: 6), context: context, centered: true)
                    }
                }
            }

            for rect in selectedRects {
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 3)
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
            }
        }
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
    let cell: TreemapCell
    let focus: DiskNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let node = cell.node {
                Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Format.bytes(node.size)).monospacedDigit()
                    if let focus, focus.size > 0 {
                        Text(String(format: "%.1f%% of %@", Double(node.size) / Double(focus.size) * 100, focus.name))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if let type = node.fileType {
                    Text(type.title).font(.caption).foregroundStyle(.secondary)
                }
                if node.isOnDisk {
                    Text(Format.tildePath(URL(fileURLWithPath: node.path)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                if node.isUnreadable {
                    Text("macOS didn't let Mac Cleaner look inside.").font(.caption).foregroundStyle(.secondary)
                }
                if case .smallFiles = node.kind {
                    hint("Files under 256 KB each, grouped so big scans stay fast.\nDouble-click to open the folder in Finder.")
                } else if cell.isCollapsed {
                    hint("Double-click to zoom in and see what's inside.")
                }
            } else {
                Text("\(Format.count(cell.hiddenCount)) more items").font(.callout.weight(.semibold))
                if let container = cell.container {
                    Text(container.name).font(.caption).foregroundStyle(.secondary)
                    if container === focus {
                        hint("Each is too small to draw at this size. Find them in the folder tree or Largest Files.")
                    } else {
                        hint("Too small to draw here. Double-click to zoom into this folder.")
                    }
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

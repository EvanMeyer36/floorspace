import CoreGraphics
import Foundation

struct TreemapCell {
    /// Nil for the leftover sliver standing in for many items too small to draw.
    let node: DiskNode?
    let rect: CGRect
    /// Folder name strip, when the folder is big enough to label.
    let headerRect: CGRect?
    let depth: Int
    /// For the leftover sliver: how many items it stands for.
    let hiddenCount: Int
    /// A folder too small to show its contents, drawn as one solid block.
    let isCollapsed: Bool
    /// Color group for blocks that aren't a single file (collapsed folders, slivers).
    let fillType: FileType?
}

enum TreemapLayout {
    static let headerHeight: CGFloat = 16
    /// Items whose share of the area would be smaller than this many square points aren't drawn individually.
    static let minArea: CGFloat = 20

    /// Lays out the whole tree under `root`, nesting folders inside their parents.
    /// Breadth-first so that when the cell budget runs out, it's the deepest, tiniest detail that's dropped.
    static func layout(_ root: DiskNode, in bounds: CGRect, maxCells: Int = 12_000) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        var queue: [(DiskNode, CGRect, Int)] = [(root, bounds, 0)]
        var head = 0

        while head < queue.count && cells.count < maxCells {
            let (folder, area, depth) = queue[head]
            head += 1

            let visible = folder.children.filter { $0.size > 0 }
            let total = Double(visible.reduce(0) { $0 + $1.size })
            guard total > 0, area.width >= 2, area.height >= 2 else { continue }

            // Keep the items big enough to see; lump the long tail into one trailing sliver.
            let pointsPerByte = Double(area.width * area.height) / total
            var shown = visible.prefix { Double($0.size) * pointsPerByte >= Double(minArea) }
            if shown.isEmpty, let first = visible.first { shown = [first] }
            let hidden = visible.dropFirst(shown.count)
            var values = shown.map { Double($0.size) }
            let hiddenSize = Double(hidden.reduce(0) { $0 + $1.size })
            if hiddenSize > 0 { values.append(hiddenSize) }

            let rects = squarify(values, in: area)
            for (index, rect) in rects.enumerated() {
                guard index < shown.count else {
                    cells.append(TreemapCell(node: nil, rect: rect, headerRect: nil, depth: depth + 1, hiddenCount: hidden.count,
                                             isCollapsed: false, fillType: hidden.first?.displayType))
                    continue
                }
                let node = shown[shown.startIndex + index]
                var header: CGRect?
                var inner = rect.insetBy(dx: 1, dy: 1)
                // Only the top two levels get a name strip; deeper, the space goes to the files.
                if node.isFolder && depth < 2 && rect.width >= 48 && rect.height >= headerHeight + 14 {
                    header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
                    inner = CGRect(x: rect.minX + 2, y: rect.minY + headerHeight, width: rect.width - 4, height: rect.height - headerHeight - 2)
                }
                let expands = node.isFolder && !node.children.isEmpty && inner.width >= 6 && inner.height >= 6
                cells.append(TreemapCell(node: node, rect: rect, headerRect: expands ? header : nil, depth: depth + 1, hiddenCount: 0,
                                         isCollapsed: node.isFolder && !expands, fillType: node.displayType))
                if expands {
                    queue.append((node, inner, depth + 1))
                }
            }
        }
        // Parents first, so children are drawn on top of their folder.
        return cells.sorted { $0.depth < $1.depth }
    }

    /// Squarified treemap (Bruls, Huizing & van Wijk). `values` must be sorted biggest-first.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = areas[start]
            var worst = worstRatio(sum: rowSum, largest: areas[start], smallest: areas[start], side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidate = worstRatio(sum: candidateSum, largest: areas[start], smallest: areas[end], side: side)
                if candidate > worst { break }
                rowSum = candidateSum
                worst = candidate
                end += 1
            }

            if remaining.width >= remaining.height {
                let width = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for i in start..<end {
                    let height = CGFloat(areas[i] / Double(width))
                    result[i] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for i in start..<end {
                    let width = CGFloat(areas[i] / Double(height))
                    result[i] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }

    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        let side2 = side * side
        let sum2 = sum * sum
        guard sum2 > 0, smallest > 0 else { return .infinity }
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}

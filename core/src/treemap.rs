//! Squarified treemap layout (Bruls, Huizing & van Wijk) of a [`DiskTree`].

use crate::filetype::FileType;
use crate::tree::{DiskTree, NodeId, NodeKind};
use serde::Serialize;
use std::collections::VecDeque;

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    fn inset(self, d: f64) -> Rect {
        Rect { x: self.x + d, y: self.y + d, w: (self.w - 2.0 * d).max(0.0), h: (self.h - 2.0 * d).max(0.0) }
    }

    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cell {
    /// `None` for a sliver standing in for many items too small to draw.
    pub node: Option<NodeId>,
    /// Name of the node (for labels, tooltips and highlighting by extension); empty for slivers.
    pub name: String,
    /// Bytes this block stands for.
    pub size: u64,
    pub rect: Rect,
    /// Name strip of a labelled folder.
    pub header: Option<Rect>,
    pub depth: u32,
    pub kind: CellKind,
    /// Color group: the file's type, or the main type inside a folder/group.
    pub file_type: Option<FileType>,
    /// Sliver only: how many items it stands for, and the folder they're in.
    pub hidden_count: u32,
    pub container: Option<NodeId>,
    /// Index of the enclosing cell (its folder), for walking down when hit-testing.
    pub parent_cell: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CellKind {
    /// Folder whose contents are drawn inside it.
    Folder,
    /// Folder too small (or past the budget) to show its contents: one solid block.
    CollapsedFolder,
    File,
    SmallFiles,
    Unattributed,
    Sliver,
}

pub const HEADER_HEIGHT: f64 = 16.0;
/// Items whose share of the area would be smaller than this many square points aren't drawn individually.
pub const MIN_AREA: f64 = 8.0;
pub const DEFAULT_MAX_CELLS: usize = 25_000;

/// Lays out everything under `focus` inside a `width` × `height` area. Breadth-first, so when the
/// cell budget runs out it's the deepest, tiniest detail that's dropped. Parents come before
/// their children in the result, so drawing in order paints children on top.
pub fn layout(tree: &DiskTree, focus: NodeId, width: f64, height: f64, max_cells: usize) -> Vec<Cell> {
    let mut cells: Vec<Cell> = Vec::new();
    let mut queue: VecDeque<(NodeId, Rect, u32, Option<u32>)> = VecDeque::new();
    queue.push_back((focus, Rect { x: 0.0, y: 0.0, w: width, h: height }, 0, None));

    while let Some((folder, area, depth, folder_cell)) = queue.pop_front() {
        if cells.len() >= max_cells {
            // Never reached: draw it as one solid block instead of an empty box.
            if let Some(index) = folder_cell {
                let cell = &mut cells[index as usize];
                cell.kind = CellKind::CollapsedFolder;
                cell.header = None;
            }
            continue;
        }
        let Some(node) = tree.node(folder) else { continue };
        let visible: Vec<NodeId> = node.children.iter().copied().filter(|&c| tree.node(c).is_some_and(|n| n.size > 0)).collect();
        let total: f64 = visible.iter().map(|&c| tree.node(c).unwrap().size as f64).sum();
        if total <= 0.0 || area.w < 2.0 || area.h < 2.0 {
            continue;
        }

        // Keep the items big enough to see; lump the long tail into one trailing sliver.
        let per_byte = area.w * area.h / total;
        let mut shown_count = visible.iter().take_while(|&&c| tree.node(c).unwrap().size as f64 * per_byte >= MIN_AREA).count();
        shown_count = shown_count.max(1).min(visible.len());
        let (shown, hidden) = visible.split_at(shown_count);
        let mut values: Vec<f64> = shown.iter().map(|&c| tree.node(c).unwrap().size as f64).collect();
        let hidden_size: f64 = hidden.iter().map(|&c| tree.node(c).unwrap().size as f64).sum();
        if hidden_size > 0.0 {
            values.push(hidden_size);
        }

        for (index, rect) in squarify(&values, area).into_iter().enumerate() {
            if index >= shown.len() {
                let biggest_hidden = hidden.first().and_then(|&h| tree.node(h)).and_then(|n| n.file_type);
                cells.push(Cell {
                    node: None,
                    name: String::new(),
                    size: hidden_size as u64,
                    rect,
                    header: None,
                    depth: depth + 1,
                    kind: CellKind::Sliver,
                    file_type: biggest_hidden,
                    hidden_count: hidden.len() as u32,
                    container: Some(folder),
                    parent_cell: folder_cell,
                });
                continue;
            }
            let child_id = shown[index];
            let child = tree.node(child_id).unwrap();
            let mut header = None;
            let mut inner = rect.inset(1.0);
            // Only the top two levels get a name strip; deeper, the space goes to the files.
            if child.is_folder() && depth < 2 && rect.w >= 48.0 && rect.h >= HEADER_HEIGHT + 14.0 {
                header = Some(Rect { x: rect.x, y: rect.y, w: rect.w, h: HEADER_HEIGHT });
                inner = Rect { x: rect.x + 2.0, y: rect.y + HEADER_HEIGHT, w: rect.w - 4.0, h: rect.h - HEADER_HEIGHT - 2.0 };
            }
            let expands = child.is_folder() && !child.children.is_empty() && inner.w >= 6.0 && inner.h >= 6.0;
            let kind = match child.kind {
                NodeKind::Folder if expands => CellKind::Folder,
                NodeKind::Folder => CellKind::CollapsedFolder,
                NodeKind::File => CellKind::File,
                NodeKind::SmallFiles { .. } => CellKind::SmallFiles,
                NodeKind::Unattributed => CellKind::Unattributed,
            };
            cells.push(Cell {
                node: Some(child_id),
                name: child.name.clone(),
                size: child.size,
                rect,
                header: if expands { header } else { None },
                depth: depth + 1,
                kind,
                file_type: child.file_type,
                hidden_count: 0,
                container: None,
                parent_cell: folder_cell,
            });
            if expands {
                queue.push_back((child_id, inner, depth + 1, Some(cells.len() as u32 - 1)));
            }
        }
    }
    cells
}

/// Squarified layout of `values` (sorted biggest-first) inside `rect`.
pub fn squarify(values: &[f64], rect: Rect) -> Vec<Rect> {
    let mut result = vec![Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }; values.len()];
    let total: f64 = values.iter().sum();
    if total <= 0.0 || rect.w <= 0.0 || rect.h <= 0.0 {
        return result;
    }
    let scale = rect.w * rect.h / total;
    let areas: Vec<f64> = values.iter().map(|v| v * scale).collect();
    let mut remaining = rect;
    let mut start = 0;

    while start < areas.len() {
        let side = remaining.w.min(remaining.h);
        let mut end = start + 1;
        let mut row_sum = areas[start];
        let mut worst = worst_ratio(row_sum, areas[start], areas[start], side);
        while end < areas.len() {
            let candidate_sum = row_sum + areas[end];
            let candidate = worst_ratio(candidate_sum, areas[start], areas[end], side);
            if candidate > worst {
                break;
            }
            row_sum = candidate_sum;
            worst = candidate;
            end += 1;
        }

        if remaining.w >= remaining.h {
            let w = if remaining.h > 0.0 { row_sum / remaining.h } else { 0.0 };
            let mut y = remaining.y;
            for i in start..end {
                let h = if w > 0.0 { areas[i] / w } else { 0.0 };
                result[i] = Rect { x: remaining.x, y, w, h };
                y += h;
            }
            remaining = Rect { x: remaining.x + w, y: remaining.y, w: (remaining.w - w).max(0.0), h: remaining.h };
        } else {
            let h = if remaining.w > 0.0 { row_sum / remaining.w } else { 0.0 };
            let mut x = remaining.x;
            for i in start..end {
                let w = if h > 0.0 { areas[i] / h } else { 0.0 };
                result[i] = Rect { x, y: remaining.y, w, h };
                x += w;
            }
            remaining = Rect { x: remaining.x, y: remaining.y + h, w: remaining.w, h: (remaining.h - h).max(0.0) };
        }
        start = end;
    }
    result
}

fn worst_ratio(sum: f64, largest: f64, smallest: f64, side: f64) -> f64 {
    let side2 = side * side;
    let sum2 = sum * sum;
    if sum2 <= 0.0 || smallest <= 0.0 {
        return f64::INFINITY;
    }
    (side2 * largest / sum2).max(sum2 / (side2 * smallest))
}

/// Finds the deepest cell under a point by walking down through folder cells instead of
/// testing every cell, so hovering stays fast with tens of thousands of cells.
/// Build it once per layout.
pub struct HitIndex {
    /// Cell indices under each cell; the last entry holds the top-level cells.
    children: Vec<Vec<usize>>,
}

impl HitIndex {
    pub fn new(cells: &[Cell]) -> Self {
        let mut children = vec![Vec::new(); cells.len() + 1];
        for (i, cell) in cells.iter().enumerate() {
            children[cell.parent_cell.map_or(cells.len(), |p| p as usize)].push(i);
        }
        HitIndex { children }
    }

    pub fn hit(&self, cells: &[Cell], x: f64, y: f64) -> Option<usize> {
        let mut level = self.children.len() - 1;
        let mut found = None;
        while let Some(&hit) = self.children[level].iter().find(|&&i| cells[i].rect.contains(x, y)) {
            found = Some(hit);
            level = hit;
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn squarify_fills_the_area_proportionally() {
        let rect = Rect { x: 0.0, y: 0.0, w: 400.0, h: 300.0 };
        let values = [500.0, 250.0, 150.0, 60.0, 40.0];
        let rects = squarify(&values, rect);
        let total: f64 = values.iter().sum();
        for (v, r) in values.iter().zip(&rects) {
            let expected = v / total * 120_000.0;
            assert!((r.w * r.h - expected).abs() < 1e-6 * expected.max(1.0) + 1e-6, "area off for {v}");
            assert!(r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.w <= 400.0 + 1e-9 && r.y + r.h <= 300.0 + 1e-9, "outside bounds");
        }
        // Squarified rectangles stay reasonably close to square.
        let worst = rects.iter().map(|r| (r.w / r.h).max(r.h / r.w)).fold(0.0, f64::max);
        assert!(worst < 4.0, "aspect ratio {worst}");
    }

    #[test]
    fn squarify_handles_empty_input() {
        assert!(squarify(&[], Rect { x: 0.0, y: 0.0, w: 10.0, h: 10.0 }).is_empty());
        let zero = squarify(&[0.0, 0.0], Rect { x: 0.0, y: 0.0, w: 10.0, h: 10.0 });
        assert!(zero.iter().all(|r| r.w == 0.0));
    }
}

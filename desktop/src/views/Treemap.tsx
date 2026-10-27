import { useEffect, useMemo, useRef, useState } from "react";
import { api, type Cell, type FileType } from "../api";
import { bytes, count, isDark, tilde, typeColor } from "../format";

export const extension = (name: string) => {
  const dot = name.lastIndexOf(".");
  return dot > 0 && name.length - dot - 1 <= 12 ? name.slice(dot + 1).toLowerCase() : "";
};

export type Highlight = { kind: "type"; type: FileType } | { kind: "ext"; ext: string } | null;

interface Props {
  focus: number;
  version: number;
  selected: Set<number>;
  highlight: Highlight;
  focusName: string;
  focusSize: number;
  onSelect: (id: number | null, toggle: boolean) => void;
  onZoom: (id: number) => void;
  onReveal: (id: number) => void;
  onHover?: (id: number | null) => void;
}

/** Index of cells under each cell, so hit-testing walks down folders instead of testing every cell. */
function buildIndex(cells: Cell[]): number[][] {
  const children: number[][] = Array.from({ length: cells.length + 1 }, () => []);
  cells.forEach((c, i) => children[c.parentCell ?? cells.length].push(i));
  return children;
}

function hit(cells: Cell[], index: number[][], x: number, y: number): number | null {
  let level = cells.length;
  let found: number | null = null;
  for (;;) {
    const next = index[level].find((i) => {
      const r = cells[i].rect;
      return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
    });
    if (next === undefined) return found;
    found = next;
    level = next;
  }
}

export function Treemap(props: Props) {
  const { focus, version, selected, highlight, focusName, focusSize, onSelect, onZoom, onReveal } = props;
  const box = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [cells, setCells] = useState<Cell[]>([]);
  const [hovered, setHovered] = useState<{ cell: number; x: number; y: number } | null>(null);
  const [theme, setTheme] = useState(isDark());
  const [hoverPath, setHoverPath] = useState<{ id: number; path: string | null } | null>(null);
  const index = useMemo(() => buildIndex(cells), [cells]);
  const hoveredNode = hovered ? cells[hovered.cell]?.node ?? null : null;

  // Full path for the tooltip, fetched when the pointer settles on a block.
  useEffect(() => {
    if (hoveredNode == null) return;
    let current = true;
    const timer = setTimeout(() => api.treeNode(hoveredNode).then((r) => current && setHoverPath({ id: hoveredNode, path: r?.[0].path ?? null })), 150);
    return () => { current = false; clearTimeout(timer); };
  }, [hoveredNode]);

  // Track the map's size, but only lay out again once resizing pauses.
  useEffect(() => {
    if (!box.current) return;
    let timer = 0;
    const observer = new ResizeObserver(([entry]) => {
      clearTimeout(timer);
      timer = window.setTimeout(() => setSize({ w: Math.floor(entry.contentRect.width), h: Math.floor(entry.contentRect.height) }), 120);
    });
    observer.observe(box.current);
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const onTheme = () => setTheme(media.matches);
    media.addEventListener("change", onTheme);
    return () => { observer.disconnect(); clearTimeout(timer); media.removeEventListener("change", onTheme); };
  }, []);

  useEffect(() => {
    if (size.w < 10 || size.h < 10) return;
    let current = true;
    api.treemap(focus, size.w, size.h).then((c) => current && setCells(c));
    return () => { current = false; };
  }, [focus, size, version]);

  // Draw.
  useEffect(() => {
    const el = canvas.current;
    if (!el) return;
    const ratio = window.devicePixelRatio || 1;
    el.width = size.w * ratio;
    el.height = size.h * ratio;
    el.style.width = `${size.w}px`;
    el.style.height = `${size.h}px`;
    const ctx = el.getContext("2d");
    if (!ctx) return;
    ctx.scale(ratio, ratio);
    ctx.clearRect(0, 0, size.w, size.h);
    const ink = theme ? "240,239,236" : "11,11,11";
    const matches = (c: Cell) => {
      if (!highlight) return true;
      if (highlight.kind === "type") return c.fileType === highlight.type && c.kind !== "folder";
      return c.kind === "file" && extension(c.name) === highlight.ext;
    };
    ctx.font = "500 10px -apple-system, Segoe UI, Ubuntu, sans-serif";
    ctx.textBaseline = "middle";

    for (const c of cells) {
      const { x, y, w, h } = c.rect;
      if (c.kind === "folder") {
        if (c.depth === 1) { ctx.fillStyle = `rgba(${ink},0.05)`; ctx.fillRect(x, y, w, h); }
        ctx.strokeStyle = `rgba(${ink},0.16)`;
        ctx.lineWidth = 0.5;
        ctx.strokeRect(x + 0.25, y + 0.25, w - 0.5, h - 0.5);
        if (c.header) {
          const head = c.header;
          ctx.fillStyle = `rgba(${ink},0.06)`;
          ctx.fillRect(head.x + 0.5, head.y + 0.5, head.w - 1, head.h - 1);
          if (head.w > 40) {
            ctx.save();
            ctx.beginPath();
            ctx.rect(head.x, head.y, head.w, head.h);
            ctx.clip();
            ctx.fillStyle = `rgba(${ink},0.62)`;
            ctx.fillText(`${c.name}  ${bytes(c.size)}`, head.x + 4, head.y + head.h / 2);
            ctx.restore();
          }
        }
        continue;
      }
      if (c.kind === "unattributed") {
        ctx.fillStyle = `rgba(${ink},0.06)`;
        ctx.fillRect(x + 0.5, y + 0.5, w - 1, h - 1);
        ctx.save();
        ctx.beginPath();
        ctx.rect(x, y, w, h);
        ctx.clip();
        ctx.strokeStyle = `rgba(${ink},0.12)`;
        for (let s = x - h; s < x + w; s += 8) { ctx.beginPath(); ctx.moveTo(s, y + h); ctx.lineTo(s + h, y); ctx.stroke(); }
        if (w > 140 && h > 40) {
          ctx.fillStyle = `rgba(${ink},0.62)`;
          ctx.textAlign = "center";
          ctx.fillText("System data, snapshots & unreadable folders", x + w / 2, y + h / 2);
          ctx.textAlign = "start";
        }
        ctx.restore();
        continue;
      }
      const opacity = !matches(c) ? 0.15 : c.kind === "file" ? 1 : c.kind === "collapsedFolder" ? 0.85 : c.kind === "smallFiles" ? 0.75 : 0.6;
      ctx.globalAlpha = opacity;
      ctx.fillStyle = typeColor(c.fileType);
      ctx.fillRect(x + 0.5, y + 0.5, Math.max(0, w - 1), Math.max(0, h - 1));
      ctx.globalAlpha = 1;
    }
    // Selection outlines: dark ring with a light inner ring, visible on any color.
    for (const c of cells) {
      if (c.node == null || !selected.has(c.node)) continue;
      const { x, y, w, h } = c.rect;
      ctx.lineWidth = 3;
      ctx.strokeStyle = `rgb(${ink})`;
      ctx.strokeRect(x + 1.5, y + 1.5, w - 3, h - 3);
      ctx.lineWidth = 1;
      ctx.strokeStyle = theme ? "#1a1a19" : "#ffffff";
      ctx.strokeRect(x + 1.5, y + 1.5, w - 3, h - 3);
    }
  }, [cells, size, selected, highlight, theme]);

  const at = (e: React.MouseEvent) => {
    const r = box.current!.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };
  const cellAt = (e: React.MouseEvent) => {
    const p = at(e);
    return hit(cells, index, p.x, p.y);
  };

  const onDoubleClick = (e: React.MouseEvent) => {
    const i = cellAt(e);
    if (i == null) return;
    const c = cells[i];
    if (c.kind === "sliver" && c.container != null) {
      if (c.container !== focus) onZoom(c.container);
      return;
    }
    if (c.node == null) return;
    if (c.kind === "file") return onReveal(c.node);
    if (c.kind === "smallFiles") return onReveal(c.node);
    // Folders: zoom one level, into the top-level block under the pointer.
    let top = i;
    while (cells[top].parentCell != null) top = cells[top].parentCell!;
    const target = cells[top].node;
    if (target != null && cells[top].kind !== "file") onZoom(target);
  };

  const hoveredCell = hovered ? cells[hovered.cell] : null;
  const path = hoverPath && hoverPath.id === hoveredNode ? hoverPath.path : null;

  return (
    <div className="map" ref={box}
      onMouseMove={(e) => {
        const i = cellAt(e);
        const p = at(e);
        setHovered(i == null ? null : { cell: i, x: p.x, y: p.y });
        props.onHover?.(i == null ? null : cells[i].node);
      }}
      onMouseLeave={() => { setHovered(null); props.onHover?.(null); }}
      onClick={(e) => {
        const i = cellAt(e);
        onSelect(i == null ? null : cells[i].node, e.metaKey || e.ctrlKey);
      }}
      onDoubleClick={onDoubleClick}
      role="img" aria-label="Treemap of the current folder. Use the folder tree for keyboard navigation.">
      <canvas ref={canvas} />
      {hoveredCell && (
        <>
          <div style={{ position: "absolute", pointerEvents: "none", left: hoveredCell.rect.x, top: hoveredCell.rect.y, width: hoveredCell.rect.w, height: hoveredCell.rect.h, outline: "1.5px solid var(--text)", outlineOffset: -1.5 }} />
          <div className="tooltip" style={{ left: Math.min(hovered!.x + 16, size.w - 300), top: Math.min(hovered!.y + 16, size.h - 110) }}>
            {hoveredCell.kind === "sliver" ? (
              <>
                <b>{count(hoveredCell.hiddenCount)} more items</b>
                <span className="muted">{hoveredCell.container === focus ? "Each is too small to draw here. Find them in the folder tree or Largest Files." : "Too small to draw here. Double-click to zoom into this folder."}</span>
              </>
            ) : hoveredCell.node != null ? (
              <>
                <b>{hoveredCell.name}</b>
                <span className="num">{bytes(hoveredCell.size)}</span>
                {focusSize > 0 && <span className="muted"> · {((hoveredCell.size / focusSize) * 100).toFixed(1)}% of {focusName}</span>}
                {path && <div className="muted small" style={{ marginTop: 3, wordBreak: "break-all" }}>{tilde(path)}</div>}
                <div className="faint small" style={{ marginTop: 4 }}>
                  {hoveredCell.kind === "smallFiles" ? "Files under 256 KB each, grouped so big scans stay fast. Double-click to open the folder."
                    : hoveredCell.kind === "collapsedFolder" ? "Double-click to zoom in and see what's inside."
                    : hoveredCell.kind === "file" ? "Double-click to show it in the file manager." : ""}
                </div>
              </>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}

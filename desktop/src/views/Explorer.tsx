import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { useCallback, useEffect, useMemo, useState } from "react";
import { api, type DiskSpace, type NodeInfo, type Platform, type TreeOverview, type TypeStat } from "../api";
import { Empty, ProgressPanel, StorageBar, useProgress, type ConfirmRequest } from "../components/common";
import { Icon } from "../components/Icon";
import { bytes, count, fileTypeOrder, tilde, typeColor } from "../format";
import { Treemap, type Highlight } from "./Treemap";

const typeTitles: Record<string, string> = {
  images: "Images", video: "Video", appsAndCode: "Apps & code", audio: "Music & audio",
  documents: "Documents", data: "Data & AI models", archives: "Archives & disk images", other: "Other",
};

export function Explorer({ platform, disk, onDiskChanged, confirm }: {
  platform: Platform; disk: DiskSpace; onDiskChanged: () => void; confirm: (r: ConfirmRequest) => void;
}) {
  const [target, setTarget] = useState(platform.startupDisk);
  const [scanning, setScanning] = useState(false);
  const [overview, setOverview] = useState<TreeOverview | null>(null);
  const [version, setVersion] = useState(0);
  /** Changes only on a new scan: node IDs from an older scan mean nothing. */
  const [scanId, setScanId] = useState(0);
  const [focus, setFocus] = useState(0);
  const [crumbs, setCrumbs] = useState<NodeInfo[]>([]);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [known, setKnown] = useState<Map<number, NodeInfo>>(new Map());
  const [ancestors, setAncestors] = useState<Map<number, number[]>>(new Map());
  const [highlight, setHighlight] = useState<Highlight>(null);
  const [tab, setTab] = useState<"largest" | "types">("largest");
  const [largest, setLargest] = useState<NodeInfo[]>([]);
  const snapshot = useProgress("tree", scanning);

  const remember = useCallback((nodes: NodeInfo[]) => {
    setKnown((prev) => {
      const next = new Map(prev);
      nodes.forEach((n) => next.set(n.id, n));
      return next;
    });
  }, []);

  const scan = () => {
    setScanning(true);
    setSelected(new Set());
    api.treeScan(target)
      .then((o) => {
        setOverview(o);
        setFocus(0);
        setKnown(new Map([[0, o.root]]));
        setAncestors(new Map());
        setScanId((s) => s + 1);
        setVersion((v) => v + 1);
        api.treeLargest().then((l) => { setLargest(l); remember(l); });
      })
      .catch(() => {})
      .finally(() => { setScanning(false); onDiskChanged(); });
  };

  // Breadcrumb for the map's folder.
  useEffect(() => {
    if (!overview) return;
    api.treeNode(focus).then((r) => {
      if (!r) return;
      setCrumbs([...r[1], r[0]]);
      remember([...r[1], r[0]]);
    });
  }, [focus, overview, version, remember]);

  /** Selecting: plain click replaces, ⌘/Ctrl toggles, Shift extends within a list. */
  const select = useCallback((id: number | null, mode: "replace" | "toggle" | { range: number[] }) => {
    setSelected((prev) => {
      if (id == null) return mode === "replace" ? new Set() : prev;
      if (mode === "replace") return new Set([id]);
      if (mode === "toggle") {
        const next = new Set(prev);
        if (next.has(id)) next.delete(id); else next.add(id);
        return next;
      }
      return new Set([...prev, ...mode.range]);
    });
    if (id != null) {
      api.treeNode(id).then((r) => {
        if (!r) return;
        remember([r[0]]);
        setAncestors((prev) => new Map(prev).set(id, r[1].map((a) => a.id)));
      });
    }
  }, [remember]);

  const selectedNodes = [...selected].map((id) => known.get(id)).filter((n): n is NodeInfo => !!n);
  // Count a folder and something inside it only once.
  const selectedSize = selectedNodes.filter((n) => !(ancestors.get(n.id) ?? []).some((a) => selected.has(a))).reduce((s, n) => s + n.size, 0);
  const trashable = selectedNodes.filter((n) => n.canTrash);

  const moveToTrash = () => {
    const names = trashable.slice(0, 5).map((n) => `• ${n.name}`).join("\n");
    const skipped = selectedNodes.length - trashable.length;
    confirm({
      title: trashable.length === 1 ? `Move “${trashable[0].name}” (${bytes(trashable[0].size)}) to the ${platform.trashName}?` : `Move ${trashable.length} items (${bytes(selectedSize)}) to the ${platform.trashName}?`,
      message: [
        trashable.length > 1 ? names + (trashable.length > 5 ? `\n• …and ${trashable.length - 5} more` : "") : "",
        skipped ? `${skipped} selected item${skipped === 1 ? " is" : "s are"} part of an app, library or system folder and will be left alone.` : "",
        `You can restore items from the ${platform.trashName} until you empty it.`,
      ].filter(Boolean).join("\n\n"),
      confirm: `Move to ${platform.trashName}`,
      danger: true,
      onConfirm: () => {
        api.treeTrash(trashable.map((n) => n.id)).then((r) => {
          setSelected(new Set());
          setKnown((prev) => { const next = new Map(prev); r.moved.forEach((id) => next.delete(id)); return next; });
          setVersion((v) => v + 1);
          api.treeNode(0).then((n) => n && setOverview((o) => o && { ...o, root: n[0] }));
          api.treeLargest().then((l) => { setLargest(l); remember(l); });
          if (focus !== 0 && r.moved.includes(focus)) setFocus(0);
          onDiskChanged();
          if (r.failures.length) {
            confirm({ title: "Some items weren't moved", message: r.failures.slice(0, 6).map((f) => `• ${tilde(f.target)}: ${f.message}`).join("\n"), confirm: "OK", informational: true, onConfirm: () => {} });
          }
        });
      },
    });
  };

  const chooseFolder = async () => {
    const folder = await openDialog({ directory: true, defaultPath: platform.home });
    if (typeof folder === "string") setTarget(folder);
  };

  const wholeDisk = target === platform.startupDisk;
  const used = Math.max(0, disk.total - disk.free);
  const scannedSize = overview ? (wholeDisk ? used : Math.min(overview.root.size, used)) : 0;
  const focusNode = crumbs[crumbs.length - 1];

  return (
    <div className="explorer">
      <div className="toolbar">
        <label>Scan{" "}
          <select value={target} disabled={scanning} onChange={(e) => e.target.value === "__choose" ? chooseFolder() : setTarget(e.target.value)}>
            <option value={platform.startupDisk}>{platform.os === "windows" ? `Drive ${platform.startupDisk}` : platform.os === "macos" ? "Macintosh HD" : "Whole disk (/)"}</option>
            <option value={platform.home}>Home folder</option>
            {target !== platform.startupDisk && target !== platform.home && <option value={target}>{tilde(target)}</option>}
            <option value="__choose">Choose folder…</option>
          </select>
        </label>
        {scanning ? <button className="btn" onClick={() => api.cancel("tree")}>Stop</button>
          : <button className="btn primary" onClick={scan}><Icon name="refresh" /> {overview ? "Scan Again" : "Scan"}</button>}
        <span className="spacer" />
        {overview && !scanning && (
          <>
            <span className="muted small num">{count(overview.summary.files)} files · {count(overview.summary.folders)} folders · {(overview.summary.durationMs / 1000).toFixed(1)} s</span>
            {overview.summary.otherVolumes.length > 0 && <span className="muted small" title={overview.summary.otherVolumes.join("\n")}><Icon name="drive" size={13} /> {overview.summary.otherVolumes.length} other volumes skipped</span>}
            {overview.summary.unreadableCount > 0 && <span className="muted small" title={overview.summary.unreadableExamples.join("\n")}><Icon name="lock" size={13} /> {count(overview.summary.unreadableCount)} folders locked</span>}
          </>
        )}
      </div>

      {scanning ? <div style={{ gridRow: "2 / 6", display: "flex" }}><ProgressPanel snapshot={snapshot} onStop={() => api.cancel("tree")} /></div>
        : !overview ? (
          <div style={{ gridRow: "2 / 6", display: "flex" }}>
            <Empty title="See exactly where your space went"
              message="Scans every folder and shows them biggest-first, plus a map where each block's size is the space it takes. Nothing is changed by scanning."
              action={<button className="btn large primary" onClick={scan}>Scan {wholeDisk ? "the whole disk" : tilde(target)}</button>} />
          </div>
        ) : (
          <>
            <div className="panes">
              <FolderTree key={scanId} root={overview.root} version={version} selected={selected} onSelect={select} remember={remember}
                onOpen={(n) => n.kind.type === "folder" && n.childCount ? setFocus(n.id) : n.path && revealItemInDir(n.path)} />
              <div className="pane">
                <div className="tabs">
                  <button className={tab === "largest" ? "on" : ""} onClick={() => setTab("largest")}>Largest Files</button>
                  <button className={tab === "types" ? "on" : ""} onClick={() => setTab("types")}>File Types</button>
                </div>
                {tab === "largest" ? <LargestFiles files={largest} selected={selected} onSelect={select} />
                  : <FileTypes stats={overview.typeStats} highlight={highlight} onHighlight={setHighlight} />}
              </div>
            </div>
            <div>
              <div className="crumbs">
                <button className="btn" disabled={focus === 0} onClick={() => crumbs.length > 1 && setFocus(crumbs[crumbs.length - 2].id)} aria-label="Up one folder"><Icon name="up" /></button>
                {crumbs.map((c, i) => (
                  <span key={c.id} style={{ display: "inline-flex", alignItems: "center" }}>
                    {i > 0 && <Icon name="chevronRight" size={12} color="var(--text-3)" />}
                    <button className={c.id === focus ? "current" : ""} onClick={() => setFocus(c.id)}>{i === 0 ? tilde(c.path) || c.name : c.name}</button>
                  </span>
                ))}
                {focusNode && <span className="muted num">{bytes(focusNode.size)}</span>}
              </div>
              <div className="type-legend">
                {fileTypeOrder.map((t) => (
                  <button key={t} className={highlight?.kind === "type" && highlight.type === t ? "on" : ""}
                    onClick={() => setHighlight(highlight?.kind === "type" && highlight.type === t ? null : { kind: "type", type: t })}>
                    <i style={{ background: typeColor(t) }} />{typeTitles[t]}
                  </button>
                ))}
              </div>
            </div>
            <Treemap focus={focus} version={version} selected={selected} highlight={highlight}
              focusName={focusNode?.name ?? ""} focusSize={focusNode?.size ?? 0}
              onSelect={(id, toggle) => select(id, toggle ? "toggle" : "replace")}
              onZoom={setFocus}
              onReveal={(id) => api.treeNode(id).then((r) => {
                const path = r?.[0].path ?? [...(r?.[1] ?? [])].reverse().find((a) => a.path)?.path;
                if (path) revealItemInDir(path);
              })} />
            <div>
              <div style={{ padding: "10px 16px", borderTop: "1px solid var(--border)" }}>
                <StorageBar total={disk.total} segments={[
                  { label: wholeDisk ? "Used" : overview.root.name, value: Math.max(0, scannedSize - selectedSize), color: "var(--used)" },
                  { label: "Selected", value: Math.min(selectedSize, scannedSize), color: "var(--reclaim)" },
                  { label: "Rest of disk", value: wholeDisk ? 0 : used - scannedSize, color: "color-mix(in srgb, var(--used) 35%, transparent)" },
                  { label: "Free", value: disk.free, color: "var(--track)" },
                ]} />
              </div>
              {selected.size > 0 && (
                <div className="footerbar">
                  <span className="num">{count(selected.size)} selected · {bytes(selectedSize)}</span>
                  <span className="faint small">⌘/Ctrl-click or Shift-click to select more</span>
                  <span className="spacer" />
                  <button className="btn" onClick={() => setSelected(new Set())}>Clear</button>
                  <button className="btn" onClick={() => selectedNodes.forEach((n) => n.path && revealItemInDir(n.path))}>Show</button>
                  <button className="btn primary" disabled={!trashable.length} onClick={moveToTrash}
                    title={trashable.length ? "" : "Only items in your home folder can be removed here, and not pieces of an app or library."}>
                    Move {trashable.length > 1 ? `${trashable.length} ` : ""}to {platform.trashName}…
                  </button>
                </div>
              )}
            </div>
          </>
        )}
    </div>
  );
}

// MARK: - Folder tree

function FolderTree({ root, version, selected, onSelect, onOpen, remember }: {
  root: NodeInfo; version: number; selected: Set<number>;
  onSelect: (id: number, mode: "replace" | "toggle" | { range: number[] }) => void;
  onOpen: (n: NodeInfo) => void; remember: (n: NodeInfo[]) => void;
}) {
  const [expanded, setExpanded] = useState<Set<number>>(new Set([root.id]));
  const [children, setChildren] = useState<Map<number, NodeInfo[]>>(new Map());
  const [anchor, setAnchor] = useState<number | null>(null);

  const load = useCallback((id: number) => api.treeChildren(id).then((list) => {
    setChildren((prev) => new Map(prev).set(id, list));
    remember(list);
  }), [remember]);

  // After a scan or a removal, reload what's open (keeping it open, unlike rebuilding the table).
  useEffect(() => { [...expanded].forEach(load); }, [version, load]); // eslint-disable-line react-hooks/exhaustive-deps

  const rows = useMemo(() => {
    const out: { node: NodeInfo; depth: number; parentSize: number }[] = [];
    const walk = (id: number, depth: number, parentSize: number) => {
      for (const node of children.get(id) ?? []) {
        out.push({ node, depth, parentSize });
        if (expanded.has(node.id)) walk(node.id, depth + 1, node.size);
      }
    };
    walk(root.id, 0, root.size);
    return out;
  }, [children, expanded, root]);

  const toggleOpen = (n: NodeInfo) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(n.id)) next.delete(n.id);
      else { next.add(n.id); if (!children.has(n.id)) load(n.id); }
      return next;
    });
  };

  const click = (e: React.MouseEvent, n: NodeInfo, index: number) => {
    if (e.shiftKey && anchor != null) {
      const from = rows.findIndex((r) => r.node.id === anchor);
      const [a, b] = from < index ? [from, index] : [index, from];
      onSelect(n.id, { range: rows.slice(a, b + 1).map((r) => r.node.id) });
    } else {
      onSelect(n.id, e.metaKey || e.ctrlKey ? "toggle" : "replace");
      setAnchor(n.id);
    }
  };

  return (
    <div className="pane">
      <div className="table-head"><span>Name</span><span>% of Parent</span><span className="right">Size</span><span className="right">Files</span></div>
      <div className="list" role="tree" aria-label="Folders by size">
        {rows.map(({ node, depth, parentSize }, index) => {
          const folder = node.kind.type === "folder";
          const share = parentSize > 0 ? node.size / parentSize : 0;
          return (
            <div key={node.id} className={`tree-row ${selected.has(node.id) ? "selected" : ""}`} role="treeitem" aria-expanded={folder && node.childCount ? expanded.has(node.id) : undefined}
              aria-selected={selected.has(node.id)} onClick={(e) => click(e, node, index)} onDoubleClick={() => onOpen(node)} title={node.path ? tilde(node.path) : node.name}>
              <span className="cell-name" style={{ paddingLeft: depth * 16 }}>
                <span className="twisty" onClick={(e) => { e.stopPropagation(); if (folder && node.childCount) toggleOpen(node); }}>
                  {folder && node.childCount > 0 && <Icon name={expanded.has(node.id) ? "chevronDown" : "chevronRight"} size={12} />}
                </span>
                <Icon name={node.unreadable ? "lock" : folder ? "folder" : node.kind.type === "smallFiles" ? "stack" : "file"} size={14} color={node.fileType ? typeColor(node.fileType) : "var(--text-3)"} />
                {node.name}
              </span>
              <span className="pct"><span className="track"><span className="fill" style={{ display: "block", width: `${Math.max(2, share * 100)}%` }} /></span>{(share * 100).toFixed(1)}%</span>
              <span className="right">{bytes(node.size)}</span>
              <span className="right faint">{node.files ? count(node.files) : ""}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function LargestFiles({ files, selected, onSelect }: {
  files: NodeInfo[]; selected: Set<number>; onSelect: (id: number, mode: "replace" | "toggle") => void;
}) {
  return (
    <div className="list">
      {files.map((f) => (
        <div key={f.id} className={`row ${selected.has(f.id) ? "selected" : ""}`} style={{ padding: "5px 12px" }}
          onClick={(e) => onSelect(f.id, e.metaKey || e.ctrlKey ? "toggle" : "replace")} onDoubleClick={() => f.path && revealItemInDir(f.path)}>
          <Icon name="file" color={typeColor(f.fileType)} />
          <div className="name">
            <div>{f.name}</div>
            <div className="small faint" style={{ direction: "rtl", textAlign: "left" }}>{tilde(f.path?.slice(0, f.path.length - f.name.length - 1))}</div>
          </div>
          <span className="size">{bytes(f.size)}</span>
        </div>
      ))}
    </div>
  );
}

function FileTypes({ stats, highlight, onHighlight }: { stats: TypeStat[]; highlight: Highlight; onHighlight: (h: Highlight) => void }) {
  const total = Math.max(1, stats.reduce((s, t) => s + t.size, 0));
  return (
    <div className="list">
      {stats.map((t) => {
        const on = highlight?.kind === "ext" && highlight.ext === t.ext;
        return (
          <div key={t.ext} className={`row ${on ? "selected" : ""}`} style={{ padding: "5px 12px" }} title={typeTitles[t.fileType]}
            onClick={() => onHighlight(on ? null : { kind: "ext", ext: t.ext })}>
            <i style={{ width: 10, height: 10, borderRadius: 2, background: typeColor(t.fileType), display: "inline-block" }} />
            <div className="name"><div>{t.ext ? `.${t.ext}` : "(no extension)"}</div></div>
            <span className="faint num small">{((t.size / total) * 100).toFixed(1)}%</span>
            <span className="faint num small" style={{ width: 60, textAlign: "right" }}>{count(t.count)}</span>
            <span className="size">{bytes(t.size)}</span>
          </div>
        );
      })}
    </div>
  );
}

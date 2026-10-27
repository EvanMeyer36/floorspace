import type { Cleanup, Page } from "../App";
import type { Category, DiskSpace, Platform, Snapshot } from "../api";
import { StorageBar } from "../components/common";
import { Icon } from "../components/Icon";
import { bytes, categoryInfo, count } from "../format";

const categories: Category[] = ["caches", "devJunk", "systemJunk", "downloads", "largeFiles", "duplicates", "trash"];

export function Overview({ platform, disk, cleanup, snapshot, open }: {
  platform: Platform; disk: DiskSpace; cleanup: Cleanup; snapshot: Snapshot | null; open: (p: Page) => void;
}) {
  const { results, scanning, selected } = cleanup;
  const allItems = results ? [...results.values()].flatMap((r) => r.items) : [];
  const reclaimable = allItems.filter((i) => !i.keeper).reduce((s, i) => s + i.size, 0);
  const chosen = allItems.filter((i) => selected.has(i.id));
  const chosenSize = chosen.reduce((s, i) => s + i.size, 0);
  const used = Math.max(0, disk.total - disk.free);
  const freeable = Math.min(reclaimable, used);

  return (
    <div className="scroll">
      <div className="page">
        <div className="card">
          <div style={{ display: "flex", alignItems: "baseline", gap: 12, marginBottom: 14 }}>
            <h2>{platform.os === "windows" ? `Drive ${platform.startupDisk.replace(/\\$/, "")}` : platform.os === "macos" ? "Macintosh HD" : "Your disk"}</h2>
            <span className="spacer" />
            <span className="muted num">{bytes(disk.free)} free of {bytes(disk.total)}</span>
            <button className="btn" onClick={() => open("explorer")}>Explore Disk…</button>
            <button className="btn" onClick={() => open("apps")}>Apps…</button>
          </div>
          <StorageBar total={disk.total} segments={[
            { label: "Used", value: used - freeable, color: "var(--used)" },
            { label: "Can be freed", value: freeable, color: "var(--reclaim)" },
            { label: "Free", value: disk.free, color: "var(--track)" },
          ]} />
        </div>

        <div className="card" style={{ display: "flex", alignItems: "center", gap: 16 }}>
          {scanning ? (
            <>
              <div className="spinner" />
              <div style={{ flex: 1 }}>
                <h2>Scanning…</h2>
                <div className="muted small num">{snapshot?.phase} · {count(snapshot?.itemsSeen ?? 0)} items checked</div>
              </div>
              <button className="btn large" onClick={cleanup.cancel}>Stop</button>
            </>
          ) : results ? (
            <>
              <div style={{ flex: 1 }}>
                <h2>Found {bytes(reclaimable)} you could free</h2>
                <div className="muted">
                  {chosen.length ? `${count(chosen.length)} items (${bytes(chosenSize)}) are selected. The safe ones were picked for you.` : "Nothing selected. Open a category to pick what to remove."}
                </div>
              </div>
              <button className="btn large" onClick={cleanup.scan}>Scan Again</button>
              <button className="btn large primary" disabled={!chosen.length || cleanup.cleaning} onClick={() => cleanup.clean(chosen)}>
                {cleanup.cleaning ? "Cleaning…" : "Clean Selected"}
              </button>
            </>
          ) : (
            <>
              <div style={{ flex: 1 }}>
                <h2>Find out what's using your space</h2>
                <div className="muted">Smart Scan checks caches, developer junk, old downloads, large files, duplicates and the {platform.trashName}. Nothing is deleted.</div>
              </div>
              <button className="btn large primary" onClick={cleanup.scan}><Icon name="search" /> Smart Scan</button>
            </>
          )}
        </div>

        <div className="grid">
          {categories.map((c) => {
            const r = results?.get(c);
            const size = r ? r.items.filter((i) => !i.keeper).reduce((s, i) => s + i.size, 0) : 0;
            const safe = r ? r.items.filter((i) => i.recommended).reduce((s, i) => s + i.size, 0) : 0;
            const blocked = r && r.items.length === 0 && r.warnings.some((w) => w.needsFullDiskAccess);
            return (
              <button key={c} className="card cat-card" onClick={() => open(c)}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <Icon name={categoryInfo[c].icon} size={18} color="var(--accent)" />
                  <strong>{c === "trash" ? platform.trashName : categoryInfo[c].title}</strong>
                  <span className="spacer" />
                  {r?.warnings.length ? <span title="This scan has a note"><Icon name="info" color="var(--text-3)" /></span> : null}
                  <Icon name="chevronRight" color="var(--text-3)" />
                </div>
                {scanning ? <span className="muted">Scanning…</span>
                  : blocked ? <><span className="big" style={{ fontSize: 16 }}>Needs permission</span><span className="muted">Open to see how to allow it.</span></>
                  : r ? <><span className="big">{bytes(size)}</span><span className="muted">{r.items.length === 0 ? "Nothing found" : safe ? `${bytes(safe)} safe to clean` : `${count(r.items.length)} items to review`}</span></>
                  : <><span className="muted">Not scanned yet</span><span className="faint small">{categoryInfo[c].subtitle}</span></>}
              </button>
            );
          })}
        </div>
        <p className="faint small">Nothing is removed until you confirm. Most items go to the {platform.trashName}, so you can restore them. Quit apps before clearing their caches.</p>
      </div>
    </div>
  );
}

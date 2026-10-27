import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import type { Cleanup } from "../App";
import { isPermanent, type Category, type Item, type Platform, type Snapshot } from "../api";
import { Badge, Empty, ProgressPanel, WarningBox } from "../components/common";
import { Icon } from "../components/Icon";
import { bytes, categoryInfo, count, tilde } from "../format";

export function CategoryView({ category, platform, cleanup, snapshot }: {
  category: Category; platform: Platform; cleanup: Cleanup; snapshot: Snapshot | null;
}) {
  const info = categoryInfo[category];
  const result = cleanup.results?.get(category);
  const items = result?.items ?? [];
  const chosen = items.filter((i) => cleanup.selected.has(i.id));
  const title = category === "trash" ? platform.trashName : info.title;
  const { settings, setSettings } = cleanup;

  const chooseFolder = async () => {
    const folder = await openDialog({ directory: true, defaultPath: settings.searchRoot });
    if (typeof folder === "string") setSettings({ ...settings, searchRoot: folder });
  };

  return (
    <>
      <div className="header">
        <Icon name={info.icon} size={28} color="var(--accent)" />
        <div style={{ flex: 1 }}>
          <h1>{title}</h1>
          <p>{info.subtitle}</p>
        </div>
        {!cleanup.scanning && <button className="btn" onClick={cleanup.scan}><Icon name="refresh" /> {result ? "Scan Again" : "Scan"}</button>}
      </div>

      {(category === "downloads" || category === "largeFiles" || category === "duplicates" || category === "devJunk") && (
        <div className="toolbar">
          {category === "downloads" && (
            <label>Not touched in{" "}
              <select value={settings.downloadsAgeDays} onChange={(e) => setSettings({ ...settings, downloadsAgeDays: Number(e.target.value) })}>
                {[[7, "1 week"], [30, "1 month"], [90, "3 months"], [180, "6 months"], [365, "1 year"]].map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
          )}
          {category === "largeFiles" && (
            <label>Bigger than{" "}
              <select value={settings.largeFileMinMb} onChange={(e) => setSettings({ ...settings, largeFileMinMb: Number(e.target.value) })}>
                {[100, 250, 500, 1000, 5000].map((v) => <option key={v} value={v}>{v >= 1000 ? `${v / 1000} GB` : `${v} MB`}</option>)}
              </select>
            </label>
          )}
          {category !== "downloads" && (
            <span>{category === "devJunk" ? "Look for node_modules in" : "Search in"}{" "}
              <button className="btn" onClick={chooseFolder}><Icon name="folder" /> {tilde(settings.searchRoot)}</button>
            </span>
          )}
          <span className="faint small">Changes apply to the next scan.</span>
        </div>
      )}

      {cleanup.scanning ? (
        <ProgressPanel snapshot={snapshot} onStop={cleanup.cancel} />
      ) : !result ? (
        <Empty title="Not scanned yet" message="Scanning only looks. Nothing is removed until you choose to."
          action={<button className="btn large primary" onClick={cleanup.scan}>Scan</button>} />
      ) : (
        <>
          {result.warnings.map((w) => (
            <WarningBox key={w.message} message={w.message}
              action={w.needsFullDiskAccess ? <span className="small faint">System Settings → Privacy & Security → Full Disk Access</span> : undefined} />
          ))}
          {items.length === 0 ? (
            result.warnings.some((w) => w.needsFullDiskAccess)
              ? <Empty title="Couldn't look here" message="Allow access as described above, then scan again." />
              : <Empty title="Nothing to clean here" message="This category is already tidy." />
          ) : (
            <ItemList items={items} cleanup={cleanup} grouped={category === "duplicates"} />
          )}
          {items.length > 0 && (
            <div className="footerbar">
              <select value="" onChange={(e) => {
                const choice = e.target.value;
                cleanup.select(category, choice === "safe" ? (i) => i.recommended : choice === "extra" ? (i) => !i.keeper : choice === "all" ? () => true : () => false);
              }} aria-label="Select">
                <option value="" disabled>Select…</option>
                <option value="safe">Recommended</option>
                {category === "duplicates" && <option value="extra">All extra copies (keep oldest)</option>}
                <option value="all">All</option>
                <option value="none">None</option>
              </select>
              <span className="spacer" />
              <span className="muted num">{count(chosen.length)} selected · {bytes(chosen.reduce((s, i) => s + i.size, 0))}</span>
              <button className="btn primary" disabled={!chosen.length || cleanup.cleaning} onClick={() => cleanup.clean(chosen)}>
                {cleanup.cleaning ? "Cleaning…" : chosen.every((i) => isPermanent(i.action)) && chosen.length ? "Delete Permanently" : `Move to ${platform.trashName}`}
              </button>
            </div>
          )}
        </>
      )}
    </>
  );
}

function ItemList({ items, cleanup, grouped }: { items: Item[]; cleanup: Cleanup; grouped: boolean }) {
  if (!grouped) {
    return <div className="list">{items.map((i) => <ItemRow key={i.id} item={i} cleanup={cleanup} />)}</div>;
  }
  const groups = new Map<number, Item[]>();
  for (const item of items) groups.set(item.group ?? 0, [...(groups.get(item.group ?? 0) ?? []), item]);
  return (
    <div className="list">
      {[...groups].map(([group, copies]) => (
        <section key={group}>
          <div className="section-head">{copies.length} identical copies · {bytes(copies[0].size)} each</div>
          {copies.map((i) => <ItemRow key={i.id} item={i} cleanup={cleanup} />)}
        </section>
      ))}
    </div>
  );
}

function ItemRow({ item, cleanup }: { item: Item; cleanup: Cleanup }) {
  const checked = cleanup.selected.has(item.id);
  return (
    <div className={`row ${checked ? "selected" : ""}`} onDoubleClick={() => item.path && revealItemInDir(item.path)}
      title={item.path ? `${item.path}\nDouble-click to show it` : item.name}>
      <input type="checkbox" checked={checked} onChange={(e) => cleanup.toggle(item, e.target.checked)} aria-label={`Select ${item.name}`} />
      <Icon name={item.path ? "folder" : "stack"} color="var(--text-3)" />
      <div className="name">
        <div>
          {item.name}
          {item.keeper && <Badge>Keep</Badge>}
          {item.recommended && <Badge><Icon name="check" size={10} /> Safe</Badge>}
          {isPermanent(item.action) && <Badge>Permanent</Badge>}
        </div>
        <div className="small muted">{item.detail}</div>
      </div>
      <span className="size">{bytes(item.size)}</span>
    </div>
  );
}

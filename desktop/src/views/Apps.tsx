import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { useMemo, useState } from "react";
import { api, type InstalledApp, type Platform, type Source } from "../api";
import { Badge, Empty, ProgressPanel, useProgress, type ConfirmRequest } from "../components/common";
import { Icon } from "../components/Icon";
import { age, bytes, count, tilde } from "../format";

const sourceLabel: Partial<Record<Source, string>> = {
  macAppStore: "App Store", windowsStore: "Microsoft Store", flatpak: "Flatpak", snap: "Snap", appImage: "AppImage", systemPackage: "Package",
};
const UNUSED_DAYS = 180;

export function Apps({ platform, confirm, onDiskChanged }: { platform: Platform; confirm: (r: ConfirmRequest) => void; onDiskChanged: () => void }) {
  const [apps, setApps] = useState<InstalledApp[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<"size" | "name" | "lastUsed">("size");
  const [onlyUnused, setOnlyUnused] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [kept, setKept] = useState<Set<string>>(new Set());
  const snapshot = useProgress("apps", loading);
  const isMac = platform.os === "macos";

  const load = (includeSandboxedData: boolean) => {
    setLoading(true);
    api.appsList(includeSandboxedData).then(setApps).finally(() => setLoading(false));
  };

  const unused = (a: InstalledApp) => a.lastUsed != null && Date.now() / 1000 - a.lastUsed > UNUSED_DAYS * 86_400;
  const total = (a: InstalledApp) => a.size + a.leftovers.reduce((s, l) => s + (l.size ?? 0), 0);

  const visible = useMemo(() => {
    let list = apps ?? [];
    if (search) list = list.filter((a) => `${a.name} ${a.identifier ?? ""} ${a.publisher ?? ""}`.toLowerCase().includes(search.toLowerCase()));
    if (onlyUnused) list = list.filter(unused);
    const sorted = [...list];
    if (sort === "size") sorted.sort((a, b) => total(b) - total(a));
    if (sort === "name") sorted.sort((a, b) => a.name.localeCompare(b.name));
    // Longest-unused first; apps with no usage record go last, since unknown isn't the same as old.
    if (sort === "lastUsed") sorted.sort((a, b) => (a.lastUsed ?? Infinity) - (b.lastUsed ?? Infinity));
    return sorted;
  }, [apps, search, onlyUnused, sort]);

  const app = apps?.find((a) => a.id === selectedId) ?? null;

  const uninstall = (target: InstalledApp) => {
    const leftovers = target.leftovers.filter((l) => !kept.has(l.path));
    const size = target.size + leftovers.reduce((s, l) => s + (l.size ?? 0), 0);
    const how = target.removal?.type === "uninstaller"
      ? "Its own uninstaller will open; follow its steps. Afterwards, the ticked leftover files go to the " + platform.trashName + "."
      : target.removal?.type === "command"
        ? `It's removed with ${target.source === "flatpak" ? "Flatpak" : target.source === "snap" ? "Snap" : "your package manager"}${target.removal.admin ? ", which will ask for your password" : ""}. The ticked leftover files go to the ${platform.trashName}.`
        : `Moves the app${leftovers.length ? ` and ${leftovers.length} related file${leftovers.length === 1 ? "" : "s"}` : ""} (${bytes(size)}) to the ${platform.trashName}. ${isMac ? "If it's open it will be quit first." : ""}`;
    confirm({
      title: `Uninstall ${target.name}?`,
      message: [how, target.note ?? ""].filter(Boolean).join("\n\n"),
      confirm: "Uninstall",
      danger: true,
      onConfirm: () => {
        setBusy(true);
        api.appsUninstall(target.id, [...kept]).then((report) => {
          if (report.removed) {
            setApps((prev) => prev?.filter((a) => a.id !== target.id) ?? null);
            setSelectedId(null);
          }
          const failures = report.outcomes.filter((o) => !o.ok);
          confirm({
            title: report.removed ? `Uninstalled ${target.name}` : `${target.name} wasn't uninstalled`,
            message: [
              report.wouldAlsoRemove.length ? `Removing it would also remove: ${report.wouldAlsoRemove.join(", ")}. Nothing was changed.` : "",
              failures.map((f) => `• ${tilde(f.target)}: ${f.message ?? ""}`).join("\n"),
              report.removed ? `Space comes back once you empty the ${platform.trashName}.` : "",
            ].filter(Boolean).join("\n\n"),
            confirm: "OK",
            informational: true,
            onConfirm: () => {},
          });
        }).finally(() => { setBusy(false); onDiskChanged(); });
      },
    });
  };

  if (!apps) {
    return loading ? <ProgressPanel snapshot={snapshot} label="Finding apps…" />
      : (
        <Empty title="See every app and what it really takes"
          message={isMac
            ? "Lists your apps with their size, the data they keep, and when you last opened them. To include apps' sandboxed data, macOS will ask you once to allow access to other apps' data."
            : "Lists your apps with their size, the data they keep, and when you last opened them. Nothing is changed by looking."}
          action={<div style={{ display: "flex", gap: 8 }}>
            <button className="btn large primary" onClick={() => load(isMac)}>Show Apps</button>
            {isMac && <button className="btn large" onClick={() => load(false)}>Without sandboxed data</button>}
          </div>} />
      );
  }

  return (
    <>
      <div className="toolbar">
        <input type="text" placeholder="Search apps" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search apps" />
        <label>Sort by{" "}
          <select value={sort} onChange={(e) => setSort(e.target.value as typeof sort)}>
            <option value="size">Size</option><option value="name">Name</option><option value="lastUsed">Last opened</option>
          </select>
        </label>
        <label><input type="checkbox" checked={onlyUnused} onChange={(e) => setOnlyUnused(e.target.checked)} /> Not opened in 6 months</label>
        <span className="spacer" />
        <span className="muted num small">{count(apps.length)} apps · {bytes(apps.reduce((s, a) => s + total(a), 0))}</span>
        <button className="btn" onClick={() => load(isMac)} disabled={loading}><Icon name="refresh" /> Rescan</button>
      </div>
      <div className="apps">
        <div className="list">
          {visible.map((a) => (
            <div key={a.id} className={`row ${a.id === selectedId ? "selected" : ""}`} onClick={() => setSelectedId(a.id)}>
              <AppIcon name={a.name} />
              <div className="name">
                <div>
                  {a.name}
                  {sourceLabel[a.source] && <Badge>{sourceLabel[a.source]}</Badge>}
                  {a.protection && <Badge><Icon name="lock" size={10} /> Protected</Badge>}
                  {a.needsPassword && !a.protection && <Badge>Needs password</Badge>}
                </div>
                <div className="small faint">{[a.version, a.publisher].filter(Boolean).join(" · ")}</div>
              </div>
              <span className="small muted" style={{ width: 110, textAlign: "right" }}>{age(a.lastUsed)}</span>
              <span className="size">
                {bytes(total(a))}
                {total(a) > a.size && <div className="small faint">+{bytes(total(a) - a.size)} data</div>}
              </span>
            </div>
          ))}
        </div>
        <div className="detail">
          {!app ? <Empty title="Select an app" message="See everything it stores on your computer, then uninstall it with its leftovers." /> : (
            <>
              <div style={{ display: "flex", gap: 12, padding: 16, alignItems: "center" }}>
                <AppIcon name={app.name} size={48} />
                <div style={{ minWidth: 0 }}>
                  <h2 style={{ margin: 0, fontSize: 17 }}>{app.name}</h2>
                  <div className="small muted">{[app.version && `Version ${app.version}`, app.identifier].filter(Boolean).join(" · ")}</div>
                  {app.location && <div className="small faint" style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{tilde(app.location)}</div>}
                </div>
              </div>
              {app.note && <p className="small muted" style={{ margin: "0 16px 12px" }}><Icon name="info" size={12} /> {app.note}</p>}
              <div className="list" style={{ borderTop: "1px solid var(--border)" }}>
                <div className="section-head">The app</div>
                <div className="row"><AppIcon name={app.name} size={18} /><div className="name"><div>{app.name}</div></div><span className="size">{bytes(app.size)}</span></div>
                <div className="section-head">{app.leftovers.length ? "Related files" : "No related files found"}</div>
                {app.leftovers.map((l) => (
                  <div className="row" key={l.path}>
                    <input type="checkbox" checked={!kept.has(l.path)} aria-label={`Remove ${l.path}`}
                      onChange={(e) => setKept((prev) => { const next = new Set(prev); if (e.target.checked) next.delete(l.path); else next.add(l.path); return next; })} />
                    <div className="name">
                      <div>{l.path.split(/[\\/]/).pop()}</div>
                      <div className="small faint">{l.kind}{l.matchedByName ? " · matched by app name" : ""}</div>
                    </div>
                    <span className="size" title={l.size == null ? "Not allowed to measure it" : ""}>{l.size == null ? "—" : bytes(l.size)}</span>
                    <button className="link" onClick={() => revealItemInDir(l.path)} aria-label="Show in file manager"><Icon name="search" size={13} /></button>
                  </div>
                ))}
              </div>
              <div className="footerbar">
                {app.protection ? <span className="muted small"><Icon name="lock" size={12} /> {app.protection}</span> : (
                  <>
                    <span className="muted num">{bytes(app.size + app.leftovers.filter((l) => !kept.has(l.path)).reduce((s, l) => s + (l.size ?? 0), 0))} to remove</span>
                    <span className="spacer" />
                    <button className="btn primary" style={{ background: "var(--danger)", borderColor: "var(--danger)" }} disabled={busy || !app.removal} onClick={() => uninstall(app)}>
                      {busy ? "Uninstalling…" : "Uninstall…"}
                    </button>
                  </>
                )}
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}

/** A colored initial: app icons come in formats a web view can't show on every OS. */
function AppIcon({ name, size = 28 }: { name: string; size?: number }) {
  const hue = [...name].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
  return (
    <span className="app-icon" aria-hidden="true" style={{ width: size, height: size, fontSize: size * 0.45, background: `hsl(${hue} 45% 48%)` }}>
      {name.trim().charAt(0).toUpperCase()}
    </span>
  );
}

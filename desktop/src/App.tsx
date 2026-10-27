import { useCallback, useEffect, useMemo, useState } from "react";
import { api, isPermanent, type Category, type CategoryResult, type DiskSpace, type Item, type Platform } from "./api";
import { ConfirmDialog, type ConfirmRequest, useProgress } from "./components/common";
import { Icon } from "./components/Icon";
import { bytes, categoryInfo, setHome } from "./format";
import { Overview } from "./views/Overview";
import { CategoryView } from "./views/CategoryView";
import { Explorer } from "./views/Explorer";
import { Apps } from "./views/Apps";
import "./styles.css";

export type Page = "overview" | "explorer" | "apps" | Category;
const categories: Category[] = ["caches", "devJunk", "systemJunk", "downloads", "largeFiles", "duplicates", "trash"];

export interface CleanupSettings { downloadsAgeDays: number; largeFileMinMb: number; searchRoot: string }

export interface Cleanup {
  results: Map<Category, CategoryResult> | null;
  scanning: boolean;
  selected: Set<string>;
  settings: CleanupSettings;
  setSettings: (s: CleanupSettings) => void;
  scan: () => void;
  cancel: () => void;
  toggle: (item: Item, on: boolean) => void;
  select: (category: Category, predicate: (i: Item) => boolean) => void;
  clean: (items: Item[]) => void;
  cleaning: boolean;
}

export default function App() {
  const [platform, setPlatform] = useState<Platform | null>(null);
  const [disk, setDisk] = useState<DiskSpace>({ total: 0, free: 0 });
  const [page, setPage] = useState<Page>("overview");
  const [results, setResults] = useState<Map<Category, CategoryResult> | null>(null);
  const [scanning, setScanning] = useState(false);
  const [cleaning, setCleaning] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [settings, setSettings] = useState<CleanupSettings>({ downloadsAgeDays: 30, largeFileMinMb: 250, searchRoot: "" });
  const [confirm, setConfirm] = useState<ConfirmRequest | null>(null);
  const snapshot = useProgress("junk", scanning);

  useEffect(() => {
    api.platform().then((p) => {
      setPlatform(p);
      setDisk(p.disk);
      setHome(p.home);
      setSettings((s) => ({ ...s, searchRoot: s.searchRoot || p.home }));
    });
  }, []);

  const refreshDisk = useCallback(() => api.diskSpace().then(setDisk), []);

  const scan = useCallback(() => {
    setScanning(true);
    api.junkScan(settings)
      .then((list) => {
        setResults(new Map(list.map((r) => [r.category, r])));
        setSelected(new Set(list.flatMap((r) => r.items.filter((i) => i.recommended).map((i) => i.id))));
      })
      .catch((e) => console.error(e))
      .finally(() => {
        setScanning(false);
        refreshDisk();
      });
  }, [settings, refreshDisk]);

  const toggle = useCallback((item: Item, on: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (on) next.add(item.id); else next.delete(item.id);
      return next;
    });
  }, []);

  const select = useCallback((category: Category, predicate: (i: Item) => boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      for (const item of results?.get(category)?.items ?? []) {
        if (predicate(item)) next.add(item.id); else next.delete(item.id);
      }
      return next;
    });
  }, [results]);

  const clean = useCallback((items: Item[]) => {
    if (items.length === 0) return;
    const toTrash = items.filter((i) => !isPermanent(i.action));
    const permanent = items.filter((i) => isPermanent(i.action));
    const lines: string[] = [];
    if (toTrash.length) lines.push(`${bytes(toTrash.reduce((s, i) => s + i.size, 0))} will be moved to the ${platform?.trashName ?? "Trash"}. You can put things back from there until you empty it.`);
    if (permanent.length) lines.push(`These are removed permanently and can't be undone: ${permanent.slice(0, 4).map((i) => i.name).join(", ")}${permanent.length > 4 ? ` and ${permanent.length - 4} more` : ""}.`);
    setConfirm({
      title: `Clean up ${items.length} item${items.length === 1 ? "" : "s"} (${bytes(items.reduce((s, i) => s + i.size, 0))})?`,
      message: lines.join("\n\n"),
      confirm: permanent.length && !toTrash.length ? "Delete Permanently" : toTrash.length && !permanent.length ? `Move to ${platform?.trashName ?? "Trash"}` : "Clean Up",
      danger: true,
      onConfirm: () => {
        setCleaning(true);
        api.clean(items.map((i) => i.id))
          .then((r) => {
            const gone = new Set(r.cleaned);
            setResults((prev) => prev && new Map([...prev].map(([c, res]) => [c, { ...res, items: res.items.filter((i) => !gone.has(i.id)) }])));
            setSelected((prev) => new Set([...prev].filter((id) => !gone.has(id))));
            const parts = [];
            if (r.freedToTrash) parts.push(`Moved ${bytes(r.freedToTrash)} to the ${platform?.trashName ?? "Trash"}. The space comes back once you empty it.`);
            if (r.freedPermanently) parts.push(`Permanently freed ${bytes(r.freedPermanently)}.`);
            if (r.failures.length) parts.push(`${r.failures.length} couldn't be removed:\n` + r.failures.slice(0, 5).map((f) => `• ${f.target}: ${f.message ?? ""}`).join("\n"));
            setConfirm({ title: r.cleaned.length ? "Cleaned up" : "Nothing was removed", message: parts.join("\n\n"), confirm: "OK", informational: true, onConfirm: () => {} });
          })
          .finally(() => {
            setCleaning(false);
            refreshDisk();
          });
      },
    });
  }, [platform, refreshDisk]);

  const cleanup: Cleanup = {
    results, scanning, selected, settings, setSettings, scan, cancel: () => api.cancel("junk"), toggle, select, clean, cleaning,
  };

  const sizes = useMemo(() => {
    const map = new Map<Category, number>();
    for (const [c, r] of results ?? []) map.set(c, r.items.filter((i) => !i.keeper).reduce((s, i) => s + i.size, 0));
    return map;
  }, [results]);

  if (!platform) return <div className="progress"><div className="spinner" /></div>;

  return (
    <div className="app">
      <nav className="sidebar" aria-label="Sections">
        <NavButton page="overview" current={page} onClick={setPage} icon="overview" label="Overview" />
        <NavButton page="explorer" current={page} onClick={setPage} icon="explorer" label="Disk Explorer" />
        <NavButton page="apps" current={page} onClick={setPage} icon="apps" label="Applications" />
        <h6>Categories</h6>
        {categories.map((c) => (
          <NavButton key={c} page={c} current={page} onClick={setPage} icon={categoryInfo[c].icon}
            label={c === "trash" ? platform.trashName : categoryInfo[c].title}
            trailing={scanning ? <span className="size">…</span> : sizes.get(c) ? <span className="size">{bytes(sizes.get(c)!)}</span> : null} />
        ))}
        <div className="footer"><b>{bytes(disk.free)} free</b>of {bytes(disk.total)}</div>
      </nav>
      <main className="main">
        {page === "overview" && <Overview platform={platform} disk={disk} cleanup={cleanup} snapshot={snapshot} open={setPage} />}
        {page === "explorer" && <Explorer platform={platform} disk={disk} onDiskChanged={refreshDisk} confirm={setConfirm} />}
        {page === "apps" && <Apps platform={platform} confirm={setConfirm} onDiskChanged={refreshDisk} />}
        {categories.includes(page as Category) && (
          <CategoryView key={page} category={page as Category} platform={platform} cleanup={cleanup} snapshot={snapshot} />
        )}
      </main>
      <ConfirmDialog request={confirm} onClose={() => setConfirm(null)} />
    </div>
  );
}

function NavButton({ page, current, onClick, icon, label, trailing }: {
  page: Page; current: Page; onClick: (p: Page) => void; icon: Parameters<typeof Icon>[0]["name"]; label: string; trailing?: React.ReactNode;
}) {
  return (
    <button className={`nav ${page === current ? "active" : ""}`} onClick={() => onClick(page)} aria-current={page === current ? "page" : undefined}>
      <Icon name={icon} />
      <span>{label}</span>
      {trailing}
    </button>
  );
}

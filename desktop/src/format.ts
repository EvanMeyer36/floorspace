import type { Category, FileType } from "./api";

export function bytes(n: number): string {
  if (n < 1000) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = n;
  let unit = -1;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}

export const count = (n: number) => n.toLocaleString();

export function age(unixSeconds: number | null): string {
  if (unixSeconds == null) return "Unknown";
  const days = Math.floor((Date.now() / 1000 - unixSeconds) / 86_400);
  if (days < 1) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 60) return `${days} days ago`;
  if (days < 730) return `${Math.floor(days / 30)} months ago`;
  return `${Math.floor(days / 365)} years ago`;
}

let home = "";
export const setHome = (h: string) => (home = h.replace(/[\\/]$/, ""));
export function tilde(path: string | null | undefined): string {
  if (!path) return "";
  return home && path.startsWith(home) ? "~" + path.slice(home.length) : path;
}

export const categoryInfo: Record<Category, { title: string; icon: Category; subtitle: string }> = {
  caches: { title: "App Caches & Logs", icon: "caches", subtitle: "Per-app caches and logs. Apps rebuild these." },
  devJunk: { title: "Developer Junk", icon: "devJunk", subtitle: "Package manager caches, build output, Docker and stale node_modules." },
  systemJunk: { title: "System Junk", icon: "systemJunk", subtitle: "Crash dumps, device backups, downloaded updates and similar." },
  downloads: { title: "Old Downloads", icon: "downloads", subtitle: "Things in Downloads you haven't touched in a while." },
  largeFiles: { title: "Large Files", icon: "largeFiles", subtitle: "Big individual files, with when you last opened them." },
  duplicates: { title: "Duplicates", icon: "duplicates", subtitle: "Files with byte-for-byte identical content." },
  trash: { title: "Trash", icon: "trash", subtitle: "Emptying it is what actually frees the space." },
};

/** The 8-hue palette from the validated reference instance, stepped separately for light and dark. */
const palette: Record<FileType, [string, string]> = {
  images: ["#2a78d6", "#3987e5"],
  video: ["#eb6834", "#d95926"],
  appsAndCode: ["#1baf7a", "#199e70"],
  other: ["#eda100", "#c98500"],
  audio: ["#e87ba4", "#d55181"],
  documents: ["#008300", "#008300"],
  data: ["#6250d6", "#9085e9"],
  archives: ["#e34948", "#e66767"],
};
export const isDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;
export const typeColor = (t: FileType | null) => palette[t ?? "other"][isDark() ? 1 : 0];
export const fileTypeOrder: FileType[] = ["images", "video", "appsAndCode", "audio", "documents", "data", "archives", "other"];

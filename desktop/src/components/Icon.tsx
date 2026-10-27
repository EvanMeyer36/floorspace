// A few stroke icons drawn inline, so they look the same on every OS.
const paths: Record<string, string> = {
  overview: "M3 13a9 9 0 0 1 18 0M12 13l4-4M5 19h14",
  explorer: "M3 3h8v8H3zM13 3h8v5h-8zM13 10h8v11h-8zM3 13h8v8H3z",
  apps: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
  caches: "M21 8l-9-5-9 5 9 5 9-5zM3 8v8l9 5 9-5V8M12 13v8",
  devJunk: "M14 6l4 4M4 20l9-9M15 4l5 5-3 3-5-5z",
  systemJunk: "M4 20l8-8M14 4l6 6-6 2-2-2zM4 20h8",
  downloads: "M12 3v12M7 10l5 5 5-5M4 21h16",
  largeFiles: "M6 3h9l4 4v14H6zM14 3v5h5M10 12h5M10 16h5",
  duplicates: "M8 8h11v13H8zM5 16V3h11",
  trash: "M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14",
  folder: "M3 6h6l2 2h10v11H3z",
  file: "M6 3h9l4 4v14H6zM14 3v5h5",
  chevronRight: "M9 6l6 6-6 6",
  chevronDown: "M6 9l6 6 6-6",
  up: "M6 15l6-6 6 6",
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4",
  refresh: "M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5",
  lock: "M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4",
  info: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.5",
  drive: "M3 14h18v6H3zM5 14l3-9h8l3 9M17 17h.01",
  check: "M5 12l5 5 9-10",
  stack: "M4 8l8-4 8 4-8 4zM4 12l8 4 8-4M4 16l8 4 8-4",
};

export type IconName = keyof typeof paths;

export function Icon({ name, size = 16, color }: { name: IconName; size?: number; color?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color ?? "currentColor"} strokeWidth={1.8}
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ flexShrink: 0 }}>
      <path d={paths[name]} />
    </svg>
  );
}

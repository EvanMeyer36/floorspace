// Typed wrappers around the Rust backend (src-tauri/src/lib.rs).
import { invoke } from "@tauri-apps/api/core";

export type FileType = "images" | "video" | "appsAndCode" | "audio" | "documents" | "data" | "archives" | "other";
export type Category = "caches" | "devJunk" | "systemJunk" | "downloads" | "largeFiles" | "duplicates" | "trash";

export interface DiskSpace { total: number; free: number }
export interface Platform {
  os: "macos" | "windows" | "linux" | string;
  startupDisk: string;
  home: string;
  disk: DiskSpace;
  trashName: string;
  fileTypes: [FileType, string][];
}
export interface Snapshot { itemsSeen: number; phase: string; currentPath: string }

export type NodeKind = { type: "folder" } | { type: "file" } | { type: "smallFiles"; count: number } | { type: "unattributed" };
export interface NodeInfo {
  id: number;
  name: string;
  kind: NodeKind;
  size: number;
  files: number;
  fileType: FileType | null;
  childCount: number;
  unreadable: boolean;
  path: string | null;
  parent: number | null;
  canTrash: boolean;
}
export interface Summary {
  files: number;
  folders: number;
  durationMs: number;
  unreadableCount: number;
  unreadableExamples: string[];
  otherVolumes: string[];
}
export interface TypeStat { ext: string; size: number; count: number; fileType: FileType }
export interface TreeOverview { root: NodeInfo; summary: Summary; typeStats: TypeStat[] }
export interface Rect { x: number; y: number; w: number; h: number }
export type CellKind = "folder" | "collapsedFolder" | "file" | "smallFiles" | "unattributed" | "sliver";
export interface Cell {
  node: number | null;
  name: string;
  size: number;
  rect: Rect;
  header: Rect | null;
  depth: number;
  kind: CellKind;
  fileType: FileType | null;
  hiddenCount: number;
  container: number | null;
  parentCell: number | null;
}
export interface Outcome { target: string; ok: boolean; message: string | null }
export interface TrashResult { moved: number[]; movedBytes: number; failures: Outcome[] }
export interface CleanResult { cleaned: string[]; freedToTrash: number; freedPermanently: number; failures: Outcome[] }

export type Action = { type: "moveToTrash" } | { type: "deletePermanently" } | { type: "runCommand"; program: string; args: string[] };
export interface Item {
  id: string;
  category: Category;
  name: string;
  path: string | null;
  size: number;
  detail: string;
  recommended: boolean;
  action: Action;
  group: number | null;
  keeper: boolean;
}
export interface Warning { message: string; needsFullDiskAccess: boolean }
export interface CategoryResult { category: Category; items: Item[]; warnings: Warning[] }

export type Source = "macApp" | "macAppStore" | "windowsInstaller" | "windowsStore" | "flatpak" | "snap" | "appImage" | "systemPackage";
export interface Leftover { path: string; size: number | null; kind: string; matchedByName: boolean }
export interface InstalledApp {
  id: string;
  identifier: string | null;
  name: string;
  version: string | null;
  publisher: string | null;
  location: string | null;
  source: Source;
  size: number;
  leftovers: Leftover[];
  lastUsed: number | null;
  protection: string | null;
  note: string | null;
  removal: { type: "trash" } | { type: "uninstaller" } | { type: "command"; admin: boolean } | null;
}
export interface UninstallReport { removed: boolean; outcomes: Outcome[]; wouldAlsoRemove: string[] }

export const isPermanent = (a: Action) => a.type !== "moveToTrash";

export const api = {
  platform: () => invoke<Platform>("platform"),
  diskSpace: () => invoke<DiskSpace>("disk_space"),
  progress: (kind: "tree" | "junk" | "apps") => invoke<Snapshot | null>("progress", { kind }),
  cancel: (kind: "tree" | "junk" | "apps") => invoke<void>("cancel", { kind }),

  treeScan: (path: string) => invoke<TreeOverview>("tree_scan", { path }),
  treeChildren: (id: number) => invoke<NodeInfo[]>("tree_children", { id }),
  treeNode: (id: number) => invoke<[NodeInfo, NodeInfo[]] | null>("tree_node", { id }),
  treeLargest: () => invoke<NodeInfo[]>("tree_largest"),
  treeTypes: () => invoke<TypeStat[]>("tree_types"),
  treemap: (focus: number, width: number, height: number) => invoke<Cell[]>("treemap", { focus, width, height }),
  treeTrash: (ids: number[]) => invoke<TrashResult>("tree_trash", { ids }),

  junkScan: (opts: { searchRoot?: string; downloadsAgeDays?: number; largeFileMinMb?: number }) =>
    invoke<CategoryResult[]>("junk_scan", opts),
  clean: (ids: string[]) => invoke<CleanResult>("clean", { ids }),

  appsList: (includeSandboxedData: boolean) => invoke<InstalledApp[]>("apps_list", { includeSandboxedData }),
  appsUninstall: (id: string, keep: string[]) => invoke<UninstallReport>("apps_uninstall", { id, keep }),
};

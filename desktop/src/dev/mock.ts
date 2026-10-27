// Development only: answers the UI's backend calls from a fixture of real engine output, so the
// UI can be previewed in a normal browser. Never bundled into the app (see main.tsx).
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import type { Cell } from "../api";

export async function installMock() {
  // glob instead of import: a missing fixture (e.g. in CI) must not break the build.
  const load = import.meta.glob("./fixture.json")["./fixture.json"];
  if (!load) throw new Error("No UI fixture. Run: cargo run -p cleaner-core --example ui_fixture -- <scan> <search> desktop/src/dev/fixture.json");
  const fixture = ((await load()) as any).default;
  mockWindows("main");
  let junk = fixture.junk;
  const delay = <T,>(value: T, ms = 400) => new Promise<T>((r) => setTimeout(() => r(value), ms));

  mockIPC((cmd, args: any) => {
    switch (cmd) {
      case "platform": return fixture.platform;
      case "disk_space": return fixture.platform.disk;
      case "progress": return { itemsSeen: 123456, phase: "Reading folders…", currentPath: fixture.scanPath };
      case "cancel": return null;
      case "tree_scan": return delay(fixture.overview, 900);
      case "tree_children": return fixture.children[args.id] ?? [];
      case "tree_node": {
        const node = fixture.nodes[args.id];
        return node ? [node, (fixture.ancestors[args.id] ?? []).map((a: number) => fixture.nodes[a]).filter(Boolean)] : null;
      }
      case "tree_largest": return fixture.largest;
      case "tree_types": return fixture.overview.typeStats;
      case "treemap": {
        // The fixture holds one layout; stretch it to the requested size (good enough to preview).
        const sx = args.width / fixture.cells.width, sy = args.height / fixture.cells.height;
        const scale = (r: any) => r && { x: r.x * sx, y: r.y * sy, w: r.w * sx, h: r.h * sy };
        return args.focus === 0 ? fixture.cells.cells.map((c: Cell) => ({ ...c, rect: scale(c.rect), header: scale(c.header) })) : [];
      }
      case "tree_trash": return { moved: [], movedBytes: 0, failures: [{ target: "preview", ok: false, message: "Removing is disabled in the browser preview." }] };
      case "junk_scan": return delay(junk, 1200);
      case "clean": {
        junk = junk.map((r: any) => ({ ...r, items: r.items.filter((i: any) => !args.ids.includes(i.id)) }));
        return { cleaned: args.ids, freedToTrash: 1_234_000_000, freedPermanently: 0, failures: [] };
      }
      case "apps_list": return delay(fixture.apps, 700);
      case "apps_uninstall": return { removed: false, outcomes: [{ target: "preview", ok: false, message: "Uninstalling is disabled in the browser preview." }], wouldAlsoRemove: [] };
      case "plugin:dialog|open": return null;
      case "plugin:opener|reveal_item_in_dir": return null;
      default:
        console.warn("unmocked command", cmd, args);
        return null;
    }
  });
}

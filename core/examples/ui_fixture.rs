//! Writes a JSON snapshot of real engine output for previewing the desktop UI in a browser
//! without the Tauri backend (see desktop/src/dev/mock.ts). Read-only: nothing is changed.
//!
//!   cargo run -p cleaner-core --example ui_fixture -- <folder-to-scan> <search-folder> <out.json>
//!
//! Avoids places macOS guards with permission prompts (Downloads, other apps' data).

use cleaner_core::cleanup::{self, Category, Settings};
use cleaner_core::fsutil;
use cleaner_core::progress::Progress;
use cleaner_core::tree::{self, DiskTree};
use cleaner_core::{apps, treemap};
use serde_json::{json, Value};
use std::path::PathBuf;

fn node(tree: &DiskTree, id: u32) -> Value {
    let n = tree.node(id).unwrap();
    let path = tree.path(id);
    json!({
        "id": id, "name": n.name, "kind": n.kind, "size": n.size, "files": n.files, "fileType": n.file_type,
        "childCount": n.children.len(), "unreadable": n.unreadable, "parent": n.parent,
        "canTrash": id != 0 && path.as_deref().is_some_and(|p| cleaner_core::remove::protection_reason(p).is_none()),
        "path": path,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (scan_root, search_root, out) = (PathBuf::from(&args[0]), PathBuf::from(&args[1]), PathBuf::from(&args[2]));
    let progress = Progress::new();
    let tree = tree::scan(&scan_root, &progress);

    // Every folder down to depth 3, plus every node the largest-files list and the map refer to.
    let mut nodes = serde_json::Map::new();
    let mut children = serde_json::Map::new();
    let mut stack = vec![(DiskTree::ROOT, 0)];
    while let Some((id, depth)) = stack.pop() {
        nodes.insert(id.to_string(), node(&tree, id));
        let kids = &tree.node(id).unwrap().children;
        if depth < 3 {
            children.insert(id.to_string(), Value::Array(kids.iter().map(|&k| node(&tree, k)).collect()));
            stack.extend(kids.iter().map(|&k| (k, depth + 1)));
        }
    }
    for &f in &tree.largest_files {
        nodes.insert(f.to_string(), node(&tree, f));
    }
    let cells = treemap::layout(&tree, DiskTree::ROOT, 1200.0, 420.0, treemap::DEFAULT_MAX_CELLS);
    let ancestors: serde_json::Map<String, Value> =
        nodes.keys().map(|k| (k.clone(), json!(tree.ancestors(k.parse().unwrap())))).collect();

    let settings = Settings { search_root: search_root.clone(), ..Settings::default() };
    let mut junk: Vec<Value> = [Category::Caches, Category::DevJunk]
        .into_iter()
        .map(|c| serde_json::to_value(cleanup::scan(c, &settings, &progress)).unwrap())
        .collect();
    let found = cleaner_core::search::scan(&search_root, &cleaner_core::search::Options::from(&settings), &progress);
    junk.push(serde_json::to_value(found.large_files).unwrap());
    junk.push(serde_json::to_value(found.duplicates).unwrap());

    let start = fsutil::startup_disk();
    let fixture = json!({
        "platform": {
            "os": std::env::consts::OS, "startupDisk": start, "home": fsutil::home(),
            "disk": fsutil::disk_space(&start).unwrap_or_default(), "trashName": Category::Trash.title(), "fileTypes": [],
        },
        "overview": { "root": node(&tree, 0), "summary": tree.summary, "typeStats": tree.type_stats.iter().take(300).collect::<Vec<_>>() },
        "scanPath": scan_root,
        "nodes": nodes,
        "children": children,
        "ancestors": ancestors,
        "largest": tree.largest_files.iter().map(|&f| node(&tree, f)).collect::<Vec<_>>(),
        "cells": { "width": 1200, "height": 420, "cells": cells },
        "junk": junk,
        "apps": apps::list_with(&progress, &apps::ListOptions { include_sandboxed_data: false }),
    });
    std::fs::write(&out, serde_json::to_string(&fixture).unwrap()).unwrap();
    eprintln!("wrote {}", out.display());
}

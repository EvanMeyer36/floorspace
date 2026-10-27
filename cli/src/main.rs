//! `cleaner`: the Mac Cleaner engine from the command line (macOS, Windows, Linux).
//!
//!   cleaner scan [PATH] [--json]       folder sizes, largest files and file types (WizTree-style)
//!   cleaner junk [--search PATH] [--json]  what the cleanup categories would offer to remove
//!   cleaner apps [--json]              installed apps with sizes and leftovers
//!   cleaner trash PATH... --yes        move things to the OS trash (same safety rules as the app)
//!
//! Scanning never changes anything; only `trash` with `--yes` does.

use cleaner_core::cleanup::{self, Settings};
use cleaner_core::progress::Progress;
use cleaner_core::tree::{self, DiskTree};
use cleaner_core::{apps, fsutil, remove};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().any(|a| a == "--json");
    let positional: Vec<&String> = args.iter().skip(1).filter(|a| !a.starts_with("--")).collect();
    match args.first().map(String::as_str) {
        Some("scan") => scan(positional.first().map(PathBuf::from).unwrap_or_else(fsutil::startup_disk), json),
        Some("junk") => junk(option(&args, "--search").map(PathBuf::from), json),
        Some("apps") => list_apps(json),
        Some("trash") => trash(positional.iter().map(PathBuf::from).collect(), args.iter().any(|a| a == "--yes")),
        _ => {
            eprintln!("usage: cleaner scan [PATH] | junk [--search PATH] | apps | trash PATH... --yes   [--json]");
            ExitCode::from(2)
        }
    }
}

fn option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn bytes(n: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut value = n as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < units.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 { format!("{n} B") } else { format!("{value:.1} {}", units[unit]) }
}

fn scan(path: PathBuf, json: bool) -> ExitCode {
    let progress = Progress::new();
    let tree = tree::scan(&path, &progress);
    let root = tree.node(DiskTree::ROOT).expect("root");
    let children: Vec<_> = root.children.iter().take(15).filter_map(|&c| tree.node(c).map(|n| (n, c))).collect();
    let largest: Vec<_> = tree.largest_files.iter().take(15).filter_map(|&f| Some((tree.node(f)?, tree.path(f)?))).collect();

    if json {
        let value = serde_json::json!({
            "path": path,
            "size": root.size,
            "summary": tree.summary,
            "children": children.iter().map(|(n, _)| serde_json::json!({ "name": n.name, "size": n.size, "files": n.files, "kind": n.kind, "fileType": n.file_type })).collect::<Vec<_>>(),
            "largestFiles": largest.iter().map(|(n, p)| serde_json::json!({ "path": p, "size": n.size })).collect::<Vec<_>>(),
            "fileTypes": tree.type_stats.iter().take(15).collect::<Vec<_>>(),
        });
        println!("{}", serde_json::to_string_pretty(&value).unwrap());
        return ExitCode::SUCCESS;
    }
    let s = &tree.summary;
    println!("{}: {} in {} files, {} folders ({:.1}s)", path.display(), bytes(root.size), s.files, s.folders, s.duration_ms as f64 / 1000.0);
    if s.unreadable_count > 0 {
        println!("  {} folders couldn't be read", s.unreadable_count);
    }
    if !s.other_volumes.is_empty() {
        println!("  skipped other volumes: {}", s.other_volumes.join(", "));
    }
    println!("\nBiggest items:");
    for (node, _) in children {
        let share = if root.size > 0 { node.size as f64 / root.size as f64 * 100.0 } else { 0.0 };
        println!("  {:>10}  {:>5.1}%  {}", bytes(node.size), share, node.name);
    }
    println!("\nLargest files:");
    for (node, path) in largest {
        println!("  {:>10}  {}", bytes(node.size), fsutil::tilde(&path));
    }
    ExitCode::SUCCESS
}

fn junk(search: Option<PathBuf>, json: bool) -> ExitCode {
    let mut settings = Settings::default();
    if let Some(root) = search {
        settings.search_root = root;
    }
    let results = cleanup::scan_all(&settings, &Progress::new());
    if json {
        println!("{}", serde_json::to_string_pretty(&results).unwrap());
        return ExitCode::SUCCESS;
    }
    for result in &results {
        let safe: u64 = result.items.iter().filter(|i| i.recommended).map(|i| i.size).sum();
        println!("{}: {} ({} safe to clean)", result.category.title(), bytes(result.reclaimable()), bytes(safe));
        for item in result.items.iter().take(5) {
            let mark = if item.recommended { "safe" } else if item.action.is_permanent() { "PERM" } else { "    " };
            println!("  [{mark}] {:>10}  {}  {}", bytes(item.size), item.name, item.detail);
        }
        for warning in &result.warnings {
            println!("  ! {}", warning.message);
        }
    }
    ExitCode::SUCCESS
}

fn list_apps(json: bool) -> ExitCode {
    let list = apps::list(&Progress::new());
    if json {
        println!("{}", serde_json::to_string_pretty(&list).unwrap());
        return ExitCode::SUCCESS;
    }
    println!("{} apps", list.len());
    for app in &list {
        let flags = [app.protection.as_ref().map(|_| "protected"), app.needs_admin().then_some("needs password")].into_iter().flatten().collect::<Vec<_>>().join(", ");
        println!(
            "  {:>10} (+{:>9} data)  {}{}{}",
            bytes(app.size),
            bytes(app.leftovers_size()),
            app.name,
            app.version.as_deref().map(|v| format!(" {v}")).unwrap_or_default(),
            if flags.is_empty() { String::new() } else { format!("  [{flags}]") }
        );
    }
    ExitCode::SUCCESS
}

fn trash(paths: Vec<PathBuf>, confirmed: bool) -> ExitCode {
    if paths.is_empty() || !confirmed {
        eprintln!("Moves the given paths to the trash. Add --yes to confirm.");
        return ExitCode::from(2);
    }
    let mut failed = false;
    for outcome in remove::move_to_trash(&paths) {
        match (outcome.ok, outcome.message) {
            (true, _) => println!("moved to trash: {}", outcome.target),
            (false, message) => {
                failed = true;
                eprintln!("not removed: {}: {}", outcome.target, message.unwrap_or_default());
            }
        }
    }
    if failed { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

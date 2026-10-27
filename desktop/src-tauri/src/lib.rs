//! Tauri backend: exposes the shared engine (`cleaner-core`) to the web UI.
//!
//! The UI never hands the backend a path to delete or a command to run. It refers to things by
//! ID from the latest scan (a tree node, a cleanup item, an app), and the backend looks them up
//! in its own results. A compromised web view can't make it remove arbitrary files.

use cleaner_core::apps::{self, InstalledApp, ListOptions, UninstallReport};
use cleaner_core::cleanup::{self, Category, CategoryResult, Settings};
use cleaner_core::fsutil::{self, DiskSpace};
use cleaner_core::progress::{Progress, Snapshot};
use cleaner_core::remove::{self, Action, Outcome};
use cleaner_core::tree::{self, DiskTree, NodeId, NodeKind, Summary, TypeStat};
use cleaner_core::treemap::{self, Cell};
use cleaner_core::FileType;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::State;

#[derive(Default)]
struct AppState {
    tree: Mutex<Option<DiskTree>>,
    junk: Mutex<Vec<CategoryResult>>,
    apps: Mutex<Vec<InstalledApp>>,
    /// Progress of the running operation of each kind ("tree", "junk", "apps").
    progress: Mutex<HashMap<&'static str, Progress>>,
}

impl AppState {
    fn start(&self, kind: &'static str) -> Progress {
        let progress = Progress::new();
        self.progress.lock().unwrap().insert(kind, progress.clone());
        progress
    }

    fn finish(&self, kind: &'static str) {
        self.progress.lock().unwrap().remove(kind);
    }
}

type Result<T> = std::result::Result<T, String>;

async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T> {
    tauri::async_runtime::spawn_blocking(work).await.map_err(|e| e.to_string())
}

// MARK: - General

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Platform {
    os: &'static str,
    startup_disk: PathBuf,
    home: PathBuf,
    disk: DiskSpace,
    trash_name: &'static str,
    file_types: Vec<(FileType, &'static str)>,
}

#[tauri::command]
fn platform() -> Platform {
    let startup = fsutil::startup_disk();
    Platform {
        os: std::env::consts::OS,
        disk: fsutil::disk_space(&startup).unwrap_or_default(),
        startup_disk: startup,
        home: fsutil::home(),
        trash_name: Category::Trash.title(),
        file_types: FileType::ALL.iter().map(|t| (*t, t.title())).collect(),
    }
}

#[tauri::command]
fn disk_space() -> DiskSpace {
    fsutil::disk_space(&fsutil::startup_disk()).unwrap_or_default()
}

#[tauri::command]
fn progress(state: State<AppState>, kind: String) -> Option<Snapshot> {
    state.progress.lock().unwrap().get(kind.as_str()).map(Progress::snapshot)
}

#[tauri::command]
fn cancel(state: State<AppState>, kind: String) {
    if let Some(p) = state.progress.lock().unwrap().get(kind.as_str()) {
        p.cancel();
    }
}

// MARK: - Disk Explorer

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NodeInfo {
    id: NodeId,
    name: String,
    kind: NodeKind,
    size: u64,
    files: u64,
    file_type: Option<FileType>,
    child_count: usize,
    unreadable: bool,
    path: Option<PathBuf>,
    parent: Option<NodeId>,
    can_trash: bool,
}

fn node_info(tree: &DiskTree, id: NodeId) -> Option<NodeInfo> {
    let node = tree.node(id)?;
    let path = tree.path(id);
    Some(NodeInfo {
        id,
        name: node.name.clone(),
        kind: node.kind,
        size: node.size,
        files: node.files,
        file_type: node.file_type,
        child_count: node.children.len(),
        unreadable: node.unreadable,
        can_trash: id != DiskTree::ROOT && path.as_deref().is_some_and(|p| remove::protection_reason(p).is_none()),
        path,
        parent: node.parent,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TreeOverview {
    root: NodeInfo,
    summary: Summary,
    type_stats: Vec<TypeStat>,
}

#[tauri::command]
async fn tree_scan(state: State<'_, AppState>, path: PathBuf) -> Result<TreeOverview> {
    let progress = state.start("tree");
    let whole_disk = path == fsutil::startup_disk();
    let scanned = blocking(move || {
        let mut tree = tree::scan(&path, &progress);
        if whole_disk && !progress.is_cancelled() {
            if let Some(disk) = fsutil::disk_space(&path) {
                tree.add_unattributed(disk.used());
            }
        }
        (tree, progress.is_cancelled())
    })
    .await?;
    state.finish("tree");
    let (tree, cancelled) = scanned;
    if cancelled {
        return Err("cancelled".into());
    }
    let overview = TreeOverview {
        root: node_info(&tree, DiskTree::ROOT).ok_or("empty scan")?,
        summary: tree.summary.clone(),
        type_stats: tree.type_stats.iter().take(300).cloned().collect(),
    };
    *state.tree.lock().unwrap() = Some(tree);
    Ok(overview)
}

#[tauri::command]
fn tree_children(state: State<AppState>, id: NodeId) -> Vec<NodeInfo> {
    let guard = state.tree.lock().unwrap();
    let Some(tree) = guard.as_ref() else { return Vec::new() };
    tree.node(id).map(|n| n.children.iter().filter_map(|&c| node_info(tree, c)).collect()).unwrap_or_default()
}

/// A node plus its ancestors (root first), for breadcrumbs.
#[tauri::command]
fn tree_node(state: State<AppState>, id: NodeId) -> Option<(NodeInfo, Vec<NodeInfo>)> {
    let guard = state.tree.lock().unwrap();
    let tree = guard.as_ref()?;
    let ancestors = tree.ancestors(id).into_iter().filter_map(|a| node_info(tree, a)).collect();
    Some((node_info(tree, id)?, ancestors))
}

#[tauri::command]
fn tree_largest(state: State<AppState>) -> Vec<NodeInfo> {
    let guard = state.tree.lock().unwrap();
    let Some(tree) = guard.as_ref() else { return Vec::new() };
    tree.largest_files.iter().filter_map(|&f| node_info(tree, f)).collect()
}

#[tauri::command]
fn tree_types(state: State<AppState>) -> Vec<TypeStat> {
    state.tree.lock().unwrap().as_ref().map(|t| t.type_stats.iter().take(300).cloned().collect()).unwrap_or_default()
}

#[tauri::command]
async fn treemap(state: State<'_, AppState>, focus: NodeId, width: f64, height: f64) -> Result<Vec<Cell>> {
    let guard = state.tree.lock().unwrap();
    let Some(tree) = guard.as_ref() else { return Ok(Vec::new()) };
    Ok(treemap::layout(tree, focus, width, height, treemap::DEFAULT_MAX_CELLS))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TrashResult {
    moved: Vec<NodeId>,
    moved_bytes: u64,
    failures: Vec<Outcome>,
}

#[tauri::command]
async fn tree_trash(state: State<'_, AppState>, ids: Vec<NodeId>) -> Result<TrashResult> {
    let targets: Vec<(NodeId, PathBuf, u64)> = {
        let guard = state.tree.lock().unwrap();
        let tree = guard.as_ref().ok_or("No scan")?;
        // Drop anything inside a folder that's also selected.
        ids.iter()
            .filter(|&&id| !ids.iter().any(|&other| other != id && tree.is_descendant(id, other)))
            .filter_map(|&id| Some((id, tree.path(id)?, tree.node(id)?.size)))
            .collect()
    };
    let paths: Vec<PathBuf> = targets.iter().map(|(_, p, _)| p.clone()).collect();
    let outcomes = blocking(move || remove::move_to_trash(&paths)).await?;

    let mut result = TrashResult { moved: Vec::new(), moved_bytes: 0, failures: Vec::new() };
    let mut guard = state.tree.lock().unwrap();
    let tree = guard.as_mut().ok_or("No scan")?;
    for ((id, _, size), outcome) in targets.into_iter().zip(outcomes) {
        if outcome.ok {
            tree.detach(id);
            result.moved.push(id);
            result.moved_bytes += size;
        } else {
            result.failures.push(outcome);
        }
    }
    Ok(result)
}

// MARK: - Cleanup

#[tauri::command]
async fn junk_scan(state: State<'_, AppState>, search_root: Option<PathBuf>, downloads_age_days: Option<u64>, large_file_min_mb: Option<u64>) -> Result<Vec<CategoryResult>> {
    let progress = state.start("junk");
    let mut settings = Settings::default();
    if let Some(root) = search_root {
        settings.search_root = root;
    }
    if let Some(days) = downloads_age_days {
        settings.downloads_age_days = days;
    }
    if let Some(mb) = large_file_min_mb {
        settings.large_file_min_bytes = mb * 1_000_000;
    }
    let results = blocking(move || cleanup::scan_all(&settings, &progress)).await?;
    state.finish("junk");
    *state.junk.lock().unwrap() = results.clone();
    Ok(results)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CleanResult {
    cleaned: Vec<String>,
    freed_to_trash: u64,
    freed_permanently: u64,
    failures: Vec<Outcome>,
}

/// Cleans the given items from the latest cleanup scan, by ID.
#[tauri::command]
async fn clean(state: State<'_, AppState>, ids: Vec<String>) -> Result<CleanResult> {
    let wanted: HashSet<String> = ids.into_iter().collect();
    let items: Vec<cleanup::Item> = state.junk.lock().unwrap().iter().flat_map(|r| r.items.iter()).filter(|i| wanted.contains(&i.id)).cloned().collect();
    let result = blocking(move || {
        let mut failures = Vec::new();
        let to_trash: Vec<PathBuf> = items.iter().filter(|i| i.action == Action::MoveToTrash).filter_map(|i| i.path.clone()).collect();
        failures.extend(remove::move_to_trash(&to_trash).into_iter().filter(|o| !o.ok));
        let mut permanent_ok = HashSet::new();
        for item in &items {
            let outcomes = match &item.action {
                Action::DeletePermanently if item.category == Category::Trash => remove::empty_trash(),
                Action::RunCommand { program, args } => vec![remove::run_command(program, args, std::time::Duration::from_secs(900))],
                _ => continue,
            };
            if outcomes.iter().all(|o| o.ok) {
                permanent_ok.insert(item.id.clone());
            }
            failures.extend(outcomes.into_iter().filter(|o| !o.ok));
        }
        // An item is cleaned when it's gone: moved itself, or inside a folder that was moved.
        let cleaned: Vec<&cleanup::Item> = items
            .iter()
            .filter(|i| match &i.action {
                Action::MoveToTrash => i.path.as_ref().is_some_and(|p| !p.exists()),
                _ => permanent_ok.contains(&i.id),
            })
            .collect();
        let freed = |permanent: bool| cleaned.iter().filter(|i| i.action.is_permanent() == permanent).map(|i| i.size).sum::<u64>();
        CleanResult { freed_to_trash: freed(false), freed_permanently: freed(true), cleaned: cleaned.iter().map(|i| i.id.clone()).collect(), failures }
    })
    .await?;
    // Drop what's gone from the stored results so it can't be targeted again.
    let gone: HashSet<&String> = result.cleaned.iter().collect();
    for category in state.junk.lock().unwrap().iter_mut() {
        category.items.retain(|i| !gone.contains(&i.id));
    }
    Ok(result)
}

// MARK: - Apps

#[tauri::command]
async fn apps_list(state: State<'_, AppState>, include_sandboxed_data: bool) -> Result<Vec<InstalledApp>> {
    let progress = state.start("apps");
    let list = blocking(move || apps::list_with(&progress, &ListOptions { include_sandboxed_data })).await?;
    state.finish("apps");
    *state.apps.lock().unwrap() = list.clone();
    Ok(list)
}

#[tauri::command]
async fn apps_uninstall(state: State<'_, AppState>, id: String, keep: Vec<PathBuf>) -> Result<UninstallReport> {
    let app = state.apps.lock().unwrap().iter().find(|a| a.id == id).cloned().ok_or("That app isn't in the latest list.")?;
    let keep: HashSet<PathBuf> = keep.into_iter().collect();
    let report = blocking(move || apps::uninstall(&app, &keep)).await?;
    if report.removed {
        state.apps.lock().unwrap().retain(|a| a.id != id);
    }
    Ok(report)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            platform,
            disk_space,
            progress,
            cancel,
            tree_scan,
            tree_children,
            tree_node,
            tree_largest,
            tree_types,
            treemap,
            tree_trash,
            junk_scan,
            clean,
            apps_list,
            apps_uninstall,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Mac Cleaner");
}

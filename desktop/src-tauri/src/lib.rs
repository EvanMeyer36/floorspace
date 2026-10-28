//! Tauri backend: thin commands over the shared engine session (`floorspace_core::session`), the
//! same one the native Mac app uses. The UI refers to things by ID from the latest results; the
//! session looks them up, so the web view can't name arbitrary paths or commands.

use floorspace_core::apps::{InstalledApp, UninstallReport};
use floorspace_core::cleanup::CategoryResult;
use floorspace_core::fsutil::DiskSpace;
use floorspace_core::progress::Snapshot;
use floorspace_core::session::{CleanResult, NodeInfo, Platform, ScanOptions, Session, TrashResult, TreeOverview};
use floorspace_core::tree::{NodeId, TypeStat};
use floorspace_core::treemap::Cell;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::State;

type Shared<'a> = State<'a, Arc<Session>>;
type Result<T> = std::result::Result<T, String>;

/// Runs blocking engine work off the UI thread.
async fn blocking<T: Send + 'static>(session: &Shared<'_>, work: impl FnOnce(&Session) -> T + Send + 'static) -> Result<T> {
    let session = Arc::clone(session);
    tauri::async_runtime::spawn_blocking(move || work(&session)).await.map_err(|e| e.to_string())
}

#[tauri::command]
fn platform(s: Shared) -> Platform {
    s.platform()
}

#[tauri::command]
fn disk_space(s: Shared) -> DiskSpace {
    s.disk_space()
}

#[tauri::command]
fn progress(s: Shared, kind: String) -> Option<Snapshot> {
    s.progress(&kind)
}

#[tauri::command]
fn cancel(s: Shared, kind: String) {
    s.cancel(&kind)
}

#[tauri::command]
async fn tree_scan(s: Shared<'_>, path: PathBuf) -> Result<TreeOverview> {
    blocking(&s, move |s| s.tree_scan(path)).await?.ok_or_else(|| "cancelled".into())
}

#[tauri::command]
fn tree_children(s: Shared, id: NodeId) -> Vec<NodeInfo> {
    s.tree_children(id)
}

#[tauri::command]
fn tree_node(s: Shared, id: NodeId) -> Option<(NodeInfo, Vec<NodeInfo>)> {
    s.tree_node(id)
}

#[tauri::command]
fn tree_largest(s: Shared) -> Vec<NodeInfo> {
    s.tree_largest()
}

#[tauri::command]
fn tree_types(s: Shared) -> Vec<TypeStat> {
    s.tree_types()
}

#[tauri::command]
async fn treemap(s: Shared<'_>, focus: NodeId, width: f64, height: f64) -> Result<Vec<Cell>> {
    blocking(&s, move |s| s.treemap(focus, width, height)).await
}

#[tauri::command]
async fn tree_trash(s: Shared<'_>, ids: Vec<NodeId>) -> Result<TrashResult> {
    blocking(&s, move |s| s.tree_trash(&ids)).await
}

#[tauri::command]
async fn junk_scan(s: Shared<'_>, search_root: Option<PathBuf>, downloads_age_days: Option<u64>, large_file_min_mb: Option<u64>) -> Result<Vec<CategoryResult>> {
    let options = ScanOptions { search_root, downloads_age_days, large_file_min_mb };
    blocking(&s, move |s| s.junk_scan(&options)).await
}

#[tauri::command]
async fn clean(s: Shared<'_>, ids: Vec<String>) -> Result<CleanResult> {
    blocking(&s, move |s| s.clean(&ids)).await
}

#[tauri::command]
async fn apps_list(s: Shared<'_>, include_sandboxed_data: bool) -> Result<Vec<InstalledApp>> {
    blocking(&s, move |s| s.apps_list(include_sandboxed_data)).await
}

#[tauri::command]
async fn apps_uninstall(s: Shared<'_>, id: String, keep: Vec<PathBuf>) -> Result<UninstallReport> {
    blocking(&s, move |s| s.apps_uninstall(&id, keep)).await?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(Arc::new(Session::new()))
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
        .expect("error while running Floorspace");
}

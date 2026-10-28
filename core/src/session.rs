//! The engine as an app uses it: holds the latest disk tree, cleanup results and app list, and
//! answers requests about them. The desktop app (Tauri) and the native Mac app (through `ffi/`)
//! both drive this, so they behave identically.
//!
//! Callers refer to things by ID from the latest results (tree nodes, cleanup items, apps), never
//! by path or command, so a UI can't ask for anything the engine didn't itself find.
//! Long operations block; call them off the UI thread.

use crate::apps::{self, InstalledApp, ListOptions, UninstallReport};
use crate::cleanup::{self, Category, CategoryResult, Settings};
use crate::filetype::FileType;
use crate::fsutil::{self, DiskSpace};
use crate::progress::{Progress, Snapshot};
use crate::remove::{self, Action, Outcome};
use crate::tree::{self, DiskTree, NodeId, NodeKind, Summary, TypeStat};
use crate::treemap::{self, Cell};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Default)]
pub struct Session {
    tree: Mutex<Option<DiskTree>>,
    junk: Mutex<Vec<CategoryResult>>,
    apps: Mutex<Vec<InstalledApp>>,
    progress: Mutex<HashMap<String, Progress>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Platform {
    pub os: &'static str,
    pub startup_disk: PathBuf,
    pub home: PathBuf,
    pub disk: DiskSpace,
    pub trash_name: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeInfo {
    pub id: NodeId,
    pub name: String,
    pub kind: NodeKind,
    pub size: u64,
    pub files: u64,
    pub file_type: Option<FileType>,
    pub child_count: usize,
    pub unreadable: bool,
    pub path: Option<PathBuf>,
    pub parent: Option<NodeId>,
    pub can_trash: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeOverview {
    pub root: NodeInfo,
    pub summary: Summary,
    pub type_stats: Vec<TypeStat>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrashResult {
    pub moved: Vec<NodeId>,
    pub moved_bytes: u64,
    pub failures: Vec<Outcome>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanResult {
    pub cleaned: Vec<String>,
    pub freed_to_trash: u64,
    pub freed_permanently: u64,
    pub failures: Vec<Outcome>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanOptions {
    pub search_root: Option<PathBuf>,
    pub downloads_age_days: Option<u64>,
    pub large_file_min_mb: Option<u64>,
}

impl ScanOptions {
    fn settings(&self) -> Settings {
        let mut settings = Settings::default();
        if let Some(root) = &self.search_root {
            settings.search_root = root.clone();
        }
        if let Some(days) = self.downloads_age_days {
            settings.downloads_age_days = days;
        }
        if let Some(mb) = self.large_file_min_mb {
            settings.large_file_min_bytes = mb * 1_000_000;
        }
        settings
    }
}

impl Session {
    pub fn new() -> Self {
        Self::default()
    }

    // MARK: Progress

    fn start(&self, kind: &str) -> Progress {
        let progress = Progress::new();
        self.progress.lock().unwrap().insert(kind.to_string(), progress.clone());
        progress
    }

    fn finish(&self, kind: &str) {
        self.progress.lock().unwrap().remove(kind);
    }

    /// Live progress of the running operation of this kind ("tree", "junk", "junk:caches", "apps").
    pub fn progress(&self, kind: &str) -> Option<Snapshot> {
        self.progress.lock().unwrap().get(kind).map(Progress::snapshot)
    }

    pub fn cancel(&self, kind: &str) {
        if let Some(p) = self.progress.lock().unwrap().get(kind) {
            p.cancel();
        }
    }

    // MARK: General

    pub fn platform(&self) -> Platform {
        let startup = fsutil::startup_disk();
        Platform {
            os: std::env::consts::OS,
            disk: fsutil::disk_space(&startup).unwrap_or_default(),
            startup_disk: startup,
            home: fsutil::home(),
            trash_name: Category::Trash.title(),
        }
    }

    pub fn disk_space(&self) -> DiskSpace {
        fsutil::disk_space(&fsutil::startup_disk()).unwrap_or_default()
    }

    // MARK: Disk Explorer

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

    /// Scans a folder (the whole disk when it's the startup disk). `None` if cancelled.
    pub fn tree_scan(&self, path: PathBuf) -> Option<TreeOverview> {
        let progress = self.start("tree");
        let mut scanned = tree::scan(&path, &progress);
        let cancelled = progress.is_cancelled();
        self.finish("tree");
        if cancelled {
            return None;
        }
        if path == fsutil::startup_disk() {
            if let Some(disk) = fsutil::disk_space(&path) {
                scanned.add_unattributed(disk.used());
            }
        }
        let overview = TreeOverview {
            root: Self::node_info(&scanned, DiskTree::ROOT)?,
            summary: scanned.summary.clone(),
            type_stats: scanned.type_stats.iter().take(300).cloned().collect(),
        };
        *self.tree.lock().unwrap() = Some(scanned);
        Some(overview)
    }

    pub fn tree_children(&self, id: NodeId) -> Vec<NodeInfo> {
        let guard = self.tree.lock().unwrap();
        let Some(tree) = guard.as_ref() else { return Vec::new() };
        tree.node(id).map(|n| n.children.iter().filter_map(|&c| Self::node_info(tree, c)).collect()).unwrap_or_default()
    }

    /// A node plus its ancestors, root first.
    pub fn tree_node(&self, id: NodeId) -> Option<(NodeInfo, Vec<NodeInfo>)> {
        let guard = self.tree.lock().unwrap();
        let tree = guard.as_ref()?;
        let ancestors = tree.ancestors(id).into_iter().filter_map(|a| Self::node_info(tree, a)).collect();
        Some((Self::node_info(tree, id)?, ancestors))
    }

    pub fn tree_largest(&self) -> Vec<NodeInfo> {
        let guard = self.tree.lock().unwrap();
        let Some(tree) = guard.as_ref() else { return Vec::new() };
        tree.largest_files.iter().filter_map(|&f| Self::node_info(tree, f)).collect()
    }

    pub fn tree_types(&self) -> Vec<TypeStat> {
        self.tree.lock().unwrap().as_ref().map(|t| t.type_stats.iter().take(300).cloned().collect()).unwrap_or_default()
    }

    pub fn treemap(&self, focus: NodeId, width: f64, height: f64) -> Vec<Cell> {
        let guard = self.tree.lock().unwrap();
        let Some(tree) = guard.as_ref() else { return Vec::new() };
        treemap::layout(tree, focus, width, height, treemap::DEFAULT_MAX_CELLS)
    }

    /// Total size of a selection, counting a folder and something inside it once.
    pub fn tree_selection_size(&self, ids: &[NodeId]) -> u64 {
        let guard = self.tree.lock().unwrap();
        let Some(tree) = guard.as_ref() else { return 0 };
        ids.iter()
            .filter(|&&id| !ids.iter().any(|&other| other != id && tree.is_descendant(id, other)))
            .filter_map(|&id| tree.node(id).map(|n| n.size))
            .sum()
    }

    /// Moves tree nodes to the trash and takes them out of the tree.
    pub fn tree_trash(&self, ids: &[NodeId]) -> TrashResult {
        let targets: Vec<(NodeId, PathBuf, u64)> = {
            let guard = self.tree.lock().unwrap();
            let Some(tree) = guard.as_ref() else { return TrashResult { moved: vec![], moved_bytes: 0, failures: vec![] } };
            ids.iter()
                .filter(|&&id| !ids.iter().any(|&other| other != id && tree.is_descendant(id, other)))
                .filter_map(|&id| Some((id, tree.path(id)?, tree.node(id)?.size)))
                .collect()
        };
        let paths: Vec<PathBuf> = targets.iter().map(|(_, p, _)| p.clone()).collect();
        let outcomes = remove::move_to_trash(&paths);

        let mut result = TrashResult { moved: Vec::new(), moved_bytes: 0, failures: Vec::new() };
        let mut guard = self.tree.lock().unwrap();
        let Some(tree) = guard.as_mut() else { return result };
        for ((id, _, size), outcome) in targets.into_iter().zip(outcomes) {
            if outcome.ok {
                tree.detach(id);
                result.moved.push(id);
                result.moved_bytes += size;
            } else {
                result.failures.push(outcome);
            }
        }
        result
    }

    // MARK: Cleanup

    /// Scans every cleanup category (one shared walk of the search folder).
    pub fn junk_scan(&self, options: &ScanOptions) -> Vec<CategoryResult> {
        let progress = self.start("junk");
        let results = cleanup::scan_all(&options.settings(), &progress);
        self.finish("junk");
        *self.junk.lock().unwrap() = results.clone();
        results
    }

    /// Scans one category and replaces just its results.
    pub fn junk_scan_category(&self, category: Category, options: &ScanOptions) -> CategoryResult {
        let key = format!("junk:{}", serde_json::to_value(category).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default());
        let progress = self.start(&key);
        let result = cleanup::scan(category, &options.settings(), &progress);
        self.finish(&key);
        let mut junk = self.junk.lock().unwrap();
        junk.retain(|r| r.category != category);
        junk.push(result.clone());
        result
    }

    /// Cleans items from the latest cleanup results, by ID.
    pub fn clean(&self, ids: &[String]) -> CleanResult {
        let wanted: HashSet<&String> = ids.iter().collect();
        let items: Vec<cleanup::Item> = self.junk.lock().unwrap().iter().flat_map(|r| r.items.iter()).filter(|i| wanted.contains(&i.id)).cloned().collect();

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
        let result = CleanResult {
            freed_to_trash: freed(false),
            freed_permanently: freed(true),
            cleaned: cleaned.iter().map(|i| i.id.clone()).collect(),
            failures,
        };
        // Drop what's gone everywhere it was listed (the same file can appear in two categories).
        let gone: HashSet<&String> = result.cleaned.iter().collect();
        for category in self.junk.lock().unwrap().iter_mut() {
            category.items.retain(|i| !gone.contains(&i.id) && i.path.as_ref().map_or(true, |p| p.exists()));
        }
        result
    }

    // MARK: Apps

    pub fn apps_list(&self, include_sandboxed_data: bool) -> Vec<InstalledApp> {
        let progress = self.start("apps");
        let list = apps::list_with(&progress, &ListOptions { include_sandboxed_data });
        self.finish("apps");
        *self.apps.lock().unwrap() = list.clone();
        list
    }

    /// Uninstalls an app from the latest list, keeping the leftovers in `keep`.
    pub fn apps_uninstall(&self, id: &str, keep: Vec<PathBuf>) -> Result<UninstallReport, String> {
        let app = self.apps.lock().unwrap().iter().find(|a| a.id == id).cloned().ok_or("That app isn't in the latest list.")?;
        let report = apps::uninstall(&app, &keep.into_iter().collect());
        if report.removed {
            self.apps.lock().unwrap().retain(|a| a.id != id);
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_from_other_scans_are_ignored() {
        let session = Session::new();
        // Nothing scanned yet: every lookup is empty, nothing is removed.
        assert!(session.tree_children(0).is_empty());
        assert!(session.tree_trash(&[0, 1, 2]).moved.is_empty());
        assert!(session.clean(&["/etc/hosts".into()]).cleaned.is_empty());
        assert!(session.apps_uninstall("/Applications/Safari.app", vec![]).is_err());
    }

    #[test]
    fn scans_and_answers_about_a_folder() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("a/b")).unwrap();
        std::fs::write(dir.path().join("a/b/big.bin"), vec![7u8; 400_000]).unwrap();
        let session = Session::new();
        let overview = session.tree_scan(dir.path().to_path_buf()).unwrap();
        assert!(overview.root.size >= 400_000);
        let a = &session.tree_children(0)[0];
        assert_eq!(a.name, "a");
        assert!(!session.treemap(0, 400.0, 300.0).is_empty());
        let file = session.tree_largest()[0].clone();
        let (_, ancestors) = session.tree_node(file.id).unwrap();
        assert_eq!(ancestors.iter().map(|n| n.name.as_str()).collect::<Vec<_>>()[1..], ["a", "b"]);
        assert_eq!(session.tree_selection_size(&[a.id, file.id]), a.size, "nested selection counted twice");
    }
}

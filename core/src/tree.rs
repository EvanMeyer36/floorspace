//! WizTree-style scan of a disk or folder into a size-sorted tree.

use crate::filetype::{extension, FileType};
use crate::fsutil;
use crate::progress::Progress;
use rayon::prelude::*;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

/// Files at least this big get their own node; smaller ones are grouped per folder, which keeps
/// memory bounded on disks with millions of files.
pub const INDIVIDUAL_FILE_MIN: u64 = 256 * 1024;
/// How many entries the "largest files" list keeps.
pub const LARGEST_FILES: usize = 1_000;

pub type NodeId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum NodeKind {
    Folder,
    File,
    /// Files under [`INDIVIDUAL_FILE_MIN`] in one folder, grouped.
    SmallFiles { count: u64 },
    /// Space on the disk the scan couldn't attribute to a folder (system data, snapshots, unreadable folders).
    Unattributed,
}

#[derive(Debug, Clone)]
pub struct Node {
    pub name: String,
    pub parent: Option<NodeId>,
    pub kind: NodeKind,
    pub size: u64,
    pub files: u64,
    pub children: Vec<NodeId>,
    /// A file's own type; for folders and grouped files, the type taking the most space inside.
    pub file_type: Option<FileType>,
    pub unreadable: bool,
}

impl Node {
    pub fn is_folder(&self) -> bool {
        self.kind == NodeKind::Folder
    }

    /// A real file or folder on disk (not a grouped or pseudo entry).
    pub fn is_on_disk(&self) -> bool {
        matches!(self.kind, NodeKind::Folder | NodeKind::File)
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeStat {
    pub ext: String,
    pub size: u64,
    pub count: u64,
    pub file_type: FileType,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub files: u64,
    pub folders: u64,
    pub duration_ms: u64,
    pub unreadable_count: u64,
    pub unreadable_examples: Vec<String>,
    /// Other volumes mounted inside the scanned folder, which aren't counted.
    pub other_volumes: Vec<String>,
}

/// The result of a scan. Node 0 is the scanned folder.
pub struct DiskTree {
    nodes: Vec<Node>,
    root_path: PathBuf,
    pub type_stats: Vec<TypeStat>,
    pub largest_files: Vec<NodeId>,
    pub summary: Summary,
}

impl DiskTree {
    pub const ROOT: NodeId = 0;

    pub fn root_path(&self) -> &Path {
        &self.root_path
    }

    pub fn node(&self, id: NodeId) -> Option<&Node> {
        self.nodes.get(id as usize)
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// Still part of the tree (not removed by [`DiskTree::detach`]).
    pub fn is_attached(&self, id: NodeId) -> bool {
        id == Self::ROOT || self.node(id).is_some_and(|n| n.parent.is_some())
    }

    /// Root first, ending with the node's parent.
    pub fn ancestors(&self, id: NodeId) -> Vec<NodeId> {
        let mut chain = Vec::new();
        let mut current = self.node(id).and_then(|n| n.parent);
        while let Some(parent) = current {
            chain.push(parent);
            current = self.nodes[parent as usize].parent;
        }
        chain.reverse();
        chain
    }

    pub fn is_descendant(&self, id: NodeId, of: NodeId) -> bool {
        self.ancestors(id).contains(&of)
    }

    /// Full path on disk; `None` for grouped/pseudo entries.
    pub fn path(&self, id: NodeId) -> Option<PathBuf> {
        let node = self.node(id)?;
        if !node.is_on_disk() || !self.is_attached(id) {
            return None;
        }
        let mut path = self.root_path.clone();
        for ancestor in self.ancestors(id).into_iter().skip(1).chain(std::iter::once(id).filter(|&i| i != Self::ROOT)) {
            path.push(&self.nodes[ancestor as usize].name);
        }
        Some(path)
    }

    /// Takes a node out of the tree (after it was moved to the trash) and its size out of every ancestor.
    pub fn detach(&mut self, id: NodeId) {
        if id == Self::ROOT || !self.is_attached(id) {
            return;
        }
        let (size, files) = (self.nodes[id as usize].size, self.nodes[id as usize].files);
        for ancestor in self.ancestors(id) {
            let a = &mut self.nodes[ancestor as usize];
            a.size = a.size.saturating_sub(size);
            a.files = a.files.saturating_sub(files);
        }
        if let Some(parent) = self.nodes[id as usize].parent.take() {
            self.nodes[parent as usize].children.retain(|&c| c != id);
        }
        if self.nodes[id as usize].kind == NodeKind::File {
            let ext = extension(&self.nodes[id as usize].name);
            if let Some(stat) = self.type_stats.iter_mut().find(|s| s.ext == ext) {
                stat.size = stat.size.saturating_sub(size);
                stat.count = stat.count.saturating_sub(1);
            }
        }
        let nodes = &self.nodes;
        self.largest_files.retain(|&f| {
            let mut current = Some(f);
            while let Some(c) = current {
                if c == id {
                    return false;
                }
                current = nodes[c as usize].parent;
            }
            true
        });
    }

    /// Adds a block for disk space the scan couldn't see, so a whole-disk map adds up to what
    /// the disk reports as used.
    pub fn add_unattributed(&mut self, disk_used: u64) {
        let missing = disk_used.saturating_sub(self.nodes[0].size);
        if missing == 0 {
            return;
        }
        let id = self.nodes.len() as NodeId;
        self.nodes.push(Node {
            name: "System data, snapshots & unreadable folders".into(),
            parent: Some(Self::ROOT),
            kind: NodeKind::Unattributed,
            size: missing,
            files: 0,
            children: Vec::new(),
            file_type: None,
            unreadable: false,
        });
        self.nodes[0].size += missing;
        self.nodes[0].children.push(id);
        let nodes = &self.nodes;
        let mut children = nodes[0].children.clone();
        children.sort_by_key(|&c| std::cmp::Reverse(nodes[c as usize].size));
        self.nodes[0].children = children;
    }
}

/// Folders a scan never descends into: other volumes and virtual file systems, the macOS
/// firmlinked data volume (already reached through /Users etc.), and cloud-provider folders
/// whose listing could trigger downloads.
pub fn default_skips() -> Vec<PathBuf> {
    let home = fsutil::home();
    let mut skips: Vec<PathBuf> = Vec::new();
    if cfg!(target_os = "macos") {
        for p in ["/System/Volumes", "/Volumes", "/dev", "/.nofollow", "/.resolve", "/.vol", "/net", "/home", "/Network"] {
            skips.push(p.into());
        }
        skips.push(home.join("Library/CloudStorage"));
        skips.push(home.join("Library/Mobile Documents"));
    } else if cfg!(target_os = "linux") {
        for p in ["/proc", "/sys", "/dev", "/run", "/snap", "/mnt", "/media", "/tmp/.X11-unix"] {
            skips.push(p.into());
        }
    }
    skips
}

struct Ctx {
    progress: Progress,
    skips: HashSet<PathBuf>,
    allowed_devices: HashSet<u64>,
    stats: Mutex<HashMap<String, (u64, u64)>>,
    hard_links: Mutex<HashSet<(u64, u64)>>,
    unreadable: Mutex<(u64, Vec<String>)>,
    other_volumes: Mutex<Vec<String>>,
    folders: AtomicU64,
    files: AtomicU64,
}

/// Built in parallel, then flattened into the arena.
struct Draft {
    name: String,
    kind: NodeKind,
    size: u64,
    files: u64,
    children: Vec<Draft>,
    type_sizes: [u64; 8],
    file_type: Option<FileType>,
    unreadable: bool,
}

impl Draft {
    fn folder(name: String) -> Self {
        Draft { name, kind: NodeKind::Folder, size: 0, files: 0, children: Vec::new(), type_sizes: [0; 8], file_type: None, unreadable: false }
    }
}

/// Scans `root`. Stops early, with a partial tree, if `progress` is cancelled.
pub fn scan(root: &Path, progress: &Progress) -> DiskTree {
    scan_with_skips(root, progress, default_skips())
}

pub fn scan_with_skips(root: &Path, progress: &Progress, skips: Vec<PathBuf>) -> DiskTree {
    let start = Instant::now();
    let mut allowed_devices = HashSet::new();
    let mut device_roots = vec![root.to_path_buf()];
    if cfg!(target_os = "macos") && root == Path::new("/") {
        device_roots.push("/System/Volumes/Data".into()); // the other half of the startup disk
    }
    for p in device_roots {
        if let Some(dev) = fs::metadata(&p).ok().as_ref().and_then(fsutil::device) {
            allowed_devices.insert(dev);
        }
    }

    let ctx = Ctx {
        progress: progress.clone(),
        skips: skips.into_iter().collect(),
        allowed_devices,
        stats: Mutex::default(),
        hard_links: Mutex::default(),
        unreadable: Mutex::default(),
        other_volumes: Mutex::default(),
        folders: AtomicU64::new(0),
        files: AtomicU64::new(0),
    };

    progress.set_phase("Reading folders\u{2026}");
    let display_name = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| root.display().to_string());
    // Folders are scanned recursively on worker threads; give them roomy stacks so pathologically
    // deep trees (nested node_modules) can't overflow.
    let pool = rayon::ThreadPoolBuilder::new().stack_size(16 << 20).build();
    let mut draft = match pool {
        Ok(pool) => pool.install(|| scan_folder(root, display_name, &ctx)),
        Err(_) => scan_folder(root, display_name, &ctx),
    };
    progress.set_phase("Adding up sizes\u{2026}");
    total_up(&mut draft);

    let mut nodes = Vec::new();
    flatten(draft, None, &mut nodes);

    let mut largest: Vec<NodeId> = (0..nodes.len() as NodeId).filter(|&i| nodes[i as usize].kind == NodeKind::File).collect();
    largest.sort_by_key(|&i| std::cmp::Reverse(nodes[i as usize].size));
    largest.truncate(LARGEST_FILES);

    let mut type_stats: Vec<TypeStat> = ctx
        .stats
        .into_inner()
        .unwrap_or_default()
        .into_iter()
        .map(|(ext, (size, count))| TypeStat { file_type: FileType::of_extension(&ext), ext, size, count })
        .collect();
    type_stats.sort_by_key(|s| std::cmp::Reverse(s.size));

    let (unreadable_count, unreadable_examples) = ctx.unreadable.into_inner().unwrap_or_default();
    let mut other_volumes = ctx.other_volumes.into_inner().unwrap_or_default();
    other_volumes.sort();

    DiskTree {
        nodes,
        root_path: root.to_path_buf(),
        type_stats,
        largest_files: largest,
        summary: Summary {
            files: ctx.files.load(Ordering::Relaxed),
            folders: ctx.folders.load(Ordering::Relaxed),
            duration_ms: start.elapsed().as_millis() as u64,
            unreadable_count,
            unreadable_examples,
            other_volumes,
        },
    }
}

fn scan_folder(path: &Path, name: String, ctx: &Ctx) -> Draft {
    let mut draft = Draft::folder(name);
    if ctx.progress.is_cancelled() {
        return draft;
    }
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => {
            draft.unreadable = true;
            if let Ok(mut u) = ctx.unreadable.lock() {
                u.0 += 1;
                if u.1.len() < 50 {
                    u.1.push(path.display().to_string());
                }
            }
            return draft;
        }
    };

    let mut subfolders = Vec::new();
    let mut local_stats: HashMap<String, (u64, u64)> = HashMap::new();
    let mut linked = Vec::new();
    let (mut small_size, mut small_count, mut small_types) = (0u64, 0u64, [0u64; 8]);
    let mut local_files = 0u64;

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else { continue };
        // Symlinks (and Windows junctions) aren't followed: their target is counted where it really lives.
        if file_type.is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if file_type.is_dir() {
            let child = entry.path();
            if ctx.skips.contains(&child) {
                continue;
            }
            // Looking a mount point up by name lands on the mounted volume, so its device shows here.
            if !ctx.allowed_devices.is_empty() {
                if let Some(dev) = entry.metadata().ok().as_ref().and_then(fsutil::device) {
                    if !ctx.allowed_devices.contains(&dev) {
                        if let Ok(mut v) = ctx.other_volumes.lock() {
                            v.push(child.display().to_string());
                        }
                        continue;
                    }
                }
            }
            subfolders.push((child, name));
        } else if file_type.is_file() {
            let Ok(meta) = entry.metadata() else { continue };
            local_files += 1;
            let size = fsutil::allocated_size(&meta);
            if let Some(id) = fsutil::hard_link_id(&meta) {
                linked.push((id, size, name));
                continue;
            }
            add_file(&mut draft, name, size, &mut local_stats, &mut small_size, &mut small_count, &mut small_types);
        }
    }

    if !linked.is_empty() {
        // A hard-linked file's blocks are shared by every link: count them where they're seen first.
        let first: Vec<_> = {
            let mut seen = ctx.hard_links.lock().unwrap();
            linked.into_iter().filter(|(id, _, _)| seen.insert(*id)).collect()
        };
        for (_, size, name) in first {
            add_file(&mut draft, name, size, &mut local_stats, &mut small_size, &mut small_count, &mut small_types);
        }
    }
    if small_count > 0 {
        let plural = if small_count == 1 { "" } else { "s" };
        draft.children.push(Draft {
            name: format!("{small_count} smaller file{plural}"),
            kind: NodeKind::SmallFiles { count: small_count },
            size: small_size,
            files: small_count,
            children: Vec::new(),
            type_sizes: small_types,
            file_type: FileType::dominant(&small_types),
            unreadable: false,
        });
    }

    if let Ok(mut stats) = ctx.stats.lock() {
        for (ext, (size, count)) in local_stats {
            let entry = stats.entry(ext).or_default();
            entry.0 += size;
            entry.1 += count;
        }
    }
    ctx.folders.fetch_add(1, Ordering::Relaxed);
    ctx.files.fetch_add(local_files, Ordering::Relaxed);
    ctx.progress.add(local_files + subfolders.len() as u64, path);

    let folders: Vec<Draft> = subfolders.into_par_iter().map(|(p, n)| scan_folder(&p, n, ctx)).collect();
    draft.children.extend(folders);
    draft
}

fn add_file(
    draft: &mut Draft,
    name: String,
    size: u64,
    stats: &mut HashMap<String, (u64, u64)>,
    small_size: &mut u64,
    small_count: &mut u64,
    small_types: &mut [u64; 8],
) {
    let ext = extension(&name);
    let file_type = FileType::of_extension(&ext);
    let stat = stats.entry(ext).or_default();
    stat.0 += size;
    stat.1 += 1;
    if size >= INDIVIDUAL_FILE_MIN {
        let mut type_sizes = [0; 8];
        type_sizes[file_type.index()] = size;
        draft.children.push(Draft { name, kind: NodeKind::File, size, files: 1, children: Vec::new(), type_sizes, file_type: Some(file_type), unreadable: false });
    } else {
        *small_size += size;
        *small_count += 1;
        small_types[file_type.index()] += size;
    }
}

/// Rolls sizes and type breakdowns up the tree and sorts each folder biggest-first.
fn total_up(draft: &mut Draft) {
    if draft.kind != NodeKind::Folder {
        return;
    }
    for child in &mut draft.children {
        total_up(child);
    }
    draft.size = draft.children.iter().map(|c| c.size).sum();
    draft.files = draft.children.iter().map(|c| c.files).sum();
    let mut sizes = [0u64; 8];
    for child in &draft.children {
        for (total, s) in sizes.iter_mut().zip(child.type_sizes) {
            *total += s;
        }
    }
    draft.type_sizes = sizes;
    draft.file_type = FileType::dominant(&sizes);
    draft.children.sort_by_key(|c| std::cmp::Reverse(c.size));
}

fn flatten(draft: Draft, parent: Option<NodeId>, nodes: &mut Vec<Node>) -> NodeId {
    let id = nodes.len() as NodeId;
    nodes.push(Node {
        name: draft.name,
        parent,
        kind: draft.kind,
        size: draft.size,
        files: draft.files,
        children: Vec::new(),
        file_type: draft.file_type,
        unreadable: draft.unreadable,
    });
    let children: Vec<NodeId> = draft.children.into_iter().map(|c| flatten(c, Some(id), nodes)).collect();
    nodes[id as usize].children = children;
    id
}

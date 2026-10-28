//! One walk of a folder that finds large files, duplicates and `node_modules` folders together.
//!
//! The walk skips hidden folders, app/library bundles, the OS's own app-data area (~/Library on
//! macOS, AppData on Windows: the cleanup rules cover those), cloud-provider folders, other
//! volumes, and the inside of `node_modules`.

use crate::cleanup::{Category, CategoryResult, Item, Settings, Warning};
use crate::fsutil;
use crate::progress::Progress;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Debug, Clone)]
pub struct Options {
    pub large_min_bytes: u64,
    pub find_duplicates: bool,
    /// Files smaller than this aren't worth hashing.
    pub duplicate_min_bytes: u64,
    /// node_modules untouched for this long are pre-selected.
    pub stale_days: u64,
}

impl From<&Settings> for Options {
    fn from(settings: &Settings) -> Self {
        Options { large_min_bytes: settings.large_file_min_bytes, find_duplicates: true, duplicate_min_bytes: 512_000, stale_days: 30 }
    }
}

pub struct SearchResult {
    pub large_files: CategoryResult,
    pub duplicates: CategoryResult,
    pub node_modules: CategoryResult,
}

/// Bundles that look like folders but are one thing to the user.
const PACKAGES: [&str; 16] = [
    "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "photolibrary", "musiclibrary",
    "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcarchive", "pkg", "appex",
];

struct Candidate {
    path: PathBuf,
    len: u64,
    allocated: u64,
    created: SystemTime,
}

struct Walk<'a> {
    progress: &'a Progress,
    options: &'a Options,
    skips: HashSet<PathBuf>,
    device: Option<u64>,
    large: Mutex<Vec<Item>>,
    node_modules: Mutex<Vec<PathBuf>>,
    candidates: Mutex<Vec<Candidate>>,
    hard_links: Mutex<HashSet<(u64, u64)>>,
    unreadable: Mutex<Vec<PathBuf>>,
}

pub fn scan(root: &Path, options: &Options, progress: &Progress) -> SearchResult {
    let home = fsutil::home();
    let mut skips: HashSet<PathBuf> = crate::tree::default_skips().into_iter().collect();
    if cfg!(target_os = "macos") {
        skips.insert(home.join("Library"));
    }
    if cfg!(windows) {
        skips.insert(home.join("AppData"));
    }
    let walk = Walk {
        progress,
        options,
        skips,
        device: fs::metadata(root).ok().as_ref().and_then(fsutil::device),
        large: Mutex::default(),
        node_modules: Mutex::default(),
        candidates: Mutex::default(),
        hard_links: Mutex::default(),
        unreadable: Mutex::default(),
    };
    progress.set_phase(format!("Searching {}", fsutil::tilde(root)));
    visit(root, &walk);

    let unreadable = walk.unreadable.into_inner().unwrap_or_default();
    let warning = (!unreadable.is_empty()).then(|| {
        let examples: Vec<String> = unreadable.iter().take(3).map(|p| fsutil::tilde(p)).collect();
        let more = if unreadable.len() > 3 { format!(" and {} more", unreadable.len() - 3) } else { String::new() };
        // On macOS these are privacy-protected folders, which Full Disk Access opens up.
        Warning { message: format!("Couldn't look inside {}{more}, so those weren't searched.", examples.join(", ")), needs_full_disk_access: cfg!(target_os = "macos") }
    });

    let mut large = CategoryResult { category: Category::LargeFiles, items: walk.large.into_inner().unwrap_or_default(), warnings: warning.clone().into_iter().collect() };
    large.items.sort_by_key(|i| std::cmp::Reverse(i.size));

    let node_modules = CategoryResult {
        category: Category::DevJunk,
        items: walk.node_modules.into_inner().unwrap_or_default().into_iter().map(|p| node_modules_item(p, options, progress)).collect(),
        warnings: Vec::new(),
    };

    let duplicates = if options.find_duplicates {
        let (items, clones) = find_duplicates(walk.candidates.into_inner().unwrap_or_default(), progress);
        let mut warnings: Vec<Warning> = warning.into_iter().collect();
        if clones > 0 {
            warnings.push(Warning {
                message: format!("Left out {clones} cop{} that macOS stores as clones of another file. They share storage, so deleting them would free almost nothing.", if clones == 1 { "y" } else { "ies" }),
                needs_full_disk_access: false,
            });
        }
        CategoryResult { category: Category::Duplicates, items, warnings }
    } else {
        CategoryResult { category: Category::Duplicates, items: Vec::new(), warnings: Vec::new() }
    };
    SearchResult { large_files: large, duplicates, node_modules }
}

fn visit(dir: &Path, walk: &Walk) {
    if walk.progress.is_cancelled() {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        if let Ok(mut u) = walk.unreadable.lock() {
            u.push(dir.to_path_buf());
        }
        return;
    };
    let mut subfolders = Vec::new();
    let mut count = 0;
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(meta) = entry.metadata() else { continue };
        if fsutil::is_hidden(&name, Some(&meta)) {
            continue;
        }
        count += 1;
        let path = entry.path();
        if kind.is_dir() {
            if walk.skips.contains(&path) || walk.device.is_some_and(|d| fsutil::device(&meta) != Some(d)) {
                continue;
            }
            if name == "node_modules" {
                walk.node_modules.lock().unwrap().push(path); // nested node_modules are inside this one
                continue;
            }
            let ext = crate::filetype::extension(&name);
            if !PACKAGES.contains(&ext.as_str()) {
                subfolders.push(path);
            }
        } else if kind.is_file() {
            let allocated = fsutil::allocated_size(&meta);
            if allocated >= walk.options.large_min_bytes {
                walk.large.lock().unwrap().push(large_item(&path, allocated, &meta));
            }
            let placeholder = fsutil::is_cloud_placeholder(&meta);
            if walk.options.find_duplicates && meta.len() >= walk.options.duplicate_min_bytes && !placeholder {
                if let Some(id) = fsutil::hard_link_id(&meta) {
                    if !walk.hard_links.lock().unwrap().insert(id) {
                        continue; // another name for a file already counted
                    }
                }
                let created = meta.created().or_else(|_| meta.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
                walk.candidates.lock().unwrap().push(Candidate { path, len: meta.len(), allocated, created });
            }
        }
    }
    walk.progress.add(count, dir);
    subfolders.par_iter().for_each(|p| visit(p, walk));
}

fn large_item(path: &Path, size: u64, meta: &fs::Metadata) -> Item {
    let folder = path.parent().map(fsutil::tilde).unwrap_or_default();
    let opened = meta.accessed().ok().and_then(fsutil::days_since).map(|d| format!(" \u{2022} last opened {}", fsutil::age(d))).unwrap_or_default();
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Item::at(Category::LargeFiles, path.to_path_buf(), size, name, format!("{folder}{opened}"), false)
}

fn node_modules_item(path: PathBuf, options: &Options, progress: &Progress) -> Item {
    let project = path.parent().map(Path::to_path_buf).unwrap_or_default();
    let days = fs::metadata(&path).ok().and_then(|m| m.modified().ok()).and_then(fsutil::days_since).unwrap_or(0);
    let size = fsutil::size_of(&path, Some(progress));
    let project_name = project.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Item::at(
        Category::DevJunk,
        path,
        size,
        format!("{project_name}/node_modules"),
        format!("{} \u{2022} dependencies installed {}. Restored by `npm install`.", fsutil::tilde(&project), fsutil::age(days)),
        days >= options.stale_days,
    )
}

/// Same size, then same first 64 KB, then same full BLAKE3 hash. The oldest copy in each group is
/// suggested to keep. APFS clones of a copy already in the group are left out (they free nothing);
/// returns how many were.
fn find_duplicates(candidates: Vec<Candidate>, progress: &Progress) -> (Vec<Item>, usize) {
    let mut by_len: HashMap<u64, Vec<Candidate>> = HashMap::new();
    for c in candidates {
        by_len.entry(c.len).or_default().push(c);
    }
    let buckets: Vec<Vec<Candidate>> = by_len.into_values().filter(|b| b.len() > 1).collect();
    let total: usize = buckets.iter().map(Vec::len).sum();
    progress.set_phase(format!("Comparing contents of {total} files with matching sizes"));

    let mut groups: Vec<Vec<Candidate>> = buckets
        .into_par_iter()
        .flat_map_iter(|bucket| {
            if progress.is_cancelled() {
                return Vec::new();
            }
            let full_hash_needed = bucket[0].len > 65_536;
            let mut by_head: HashMap<Option<[u8; 32]>, Vec<Candidate>> = HashMap::new();
            for c in bucket {
                by_head.entry(hash(&c.path, Some(65_536))).or_default().push(c);
            }
            let mut out = Vec::new();
            for (head, same_head) in by_head {
                if head.is_none() || same_head.len() < 2 {
                    continue;
                }
                if !full_hash_needed {
                    out.push(same_head);
                    continue;
                }
                let mut by_full: HashMap<Option<[u8; 32]>, Vec<Candidate>> = HashMap::new();
                for c in same_head {
                    by_full.entry(hash(&c.path, None)).or_default().push(c);
                }
                out.extend(by_full.into_iter().filter(|(h, g)| h.is_some() && g.len() > 1).map(|(_, g)| g));
            }
            out
        })
        .collect();

    groups.sort_by_key(|g| std::cmp::Reverse(g[0].allocated * g.len() as u64));
    let mut items = Vec::new();
    let mut clones = 0;
    let mut index = 0;
    for mut group in groups {
        group.sort_by(|a, b| a.created.cmp(&b.created).then(a.path.as_os_str().len().cmp(&b.path.as_os_str().len())));
        let mut seen_clone_ids = std::collections::HashSet::new();
        group.retain(|c| match fsutil::clone_id(&c.path) {
            Some(id) if !seen_clone_ids.insert(id) => {
                clones += 1;
                false
            }
            _ => true,
        });
        if group.len() < 2 {
            continue;
        }
        index += 1;
        for (position, c) in group.into_iter().enumerate() {
            let keeper = position == 0;
            let folder = c.path.parent().map(fsutil::tilde).unwrap_or_default();
            let detail = if keeper { format!("{folder} \u{2022} oldest copy, suggested to keep") } else { folder };
            let name = c.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let mut item = Item::at(Category::Duplicates, c.path, c.allocated, name, detail, false);
            item.group = Some(index);
            item.keeper = keeper;
            items.push(item);
        }
    }
    (items, clones)
}

/// BLAKE3 of the first `limit` bytes, or the whole file. `None` if unreadable.
fn hash(path: &Path, limit: Option<u64>) -> Option<[u8; 32]> {
    let file = File::open(path).ok()?;
    let mut hasher = blake3::Hasher::new();
    match limit {
        Some(limit) => {
            let mut buffer = Vec::with_capacity(limit as usize);
            file.take(limit).read_to_end(&mut buffer).ok()?;
            hasher.update(&buffer);
        }
        None => {
            hasher.update_reader(file).ok()?;
        }
    }
    Some(*hasher.finalize().as_bytes())
}

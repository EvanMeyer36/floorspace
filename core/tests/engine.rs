//! End-to-end checks of the engine against folders with known contents.

use cleaner_core::cleanup::{Category, Settings};
use cleaner_core::fsutil;
use cleaner_core::progress::Progress;
use cleaner_core::search;
use cleaner_core::tree::{self, DiskTree, NodeKind};
use cleaner_core::treemap::{self, CellKind, HitIndex};
use std::fs;
use std::path::Path;

fn write(path: &Path, bytes: usize, seed: u8) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    // Varying content so identical-looking files only match when the seed matches.
    let data: Vec<u8> = (0..bytes).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect();
    fs::write(path, data).unwrap();
}

fn fixture() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(&root.join("videos/big.mov"), 3_000_000, 1);
    write(&root.join("photos/a.jpg"), 700_000, 2);
    write(&root.join("backup/a-copy.jpg"), 700_000, 2); // duplicate of a.jpg
    write(&root.join("photos/same-size.jpg"), 700_000, 9); // same size, different content
    for i in 0..20 {
        write(&root.join(format!("notes/n{i}.txt")), 1_000, i as u8);
    }
    write(&root.join("proj/node_modules/lib/node_modules/inner/x.js"), 400_000, 3);
    write(&root.join("proj/src/main.js"), 2_000, 4);
    dir
}

fn find(tree: &DiskTree, name: &str) -> u32 {
    (0..tree.len() as u32).find(|&i| tree.node(i).unwrap().name == name).unwrap_or_else(|| panic!("{name} not in tree"))
}

#[test]
fn disk_tree_matches_the_filesystem() {
    let dir = fixture();
    let progress = Progress::new();
    let tree = tree::scan_with_skips(dir.path(), &progress, Vec::new());
    let root = tree.node(DiskTree::ROOT).unwrap();

    assert_eq!(root.size, fsutil::size_of(dir.path(), None), "tree total differs from an independent walk");
    assert_eq!(root.files, 26);
    assert_eq!(tree.summary.files, 26);

    // Children are sorted biggest-first all the way down.
    for id in 0..tree.len() as u32 {
        let sizes: Vec<u64> = tree.node(id).unwrap().children.iter().map(|&c| tree.node(c).unwrap().size).collect();
        assert!(sizes.windows(2).all(|w| w[0] >= w[1]), "children of {} not sorted", tree.node(id).unwrap().name);
    }

    // The 20 tiny notes are grouped, not individual nodes.
    let notes = find(&tree, "notes");
    let grouped = tree.node(notes).unwrap();
    assert_eq!(grouped.children.len(), 1);
    assert_eq!(tree.node(grouped.children[0]).unwrap().kind, NodeKind::SmallFiles { count: 20 });

    // Largest files list and paths.
    let first = tree.largest_files[0];
    assert_eq!(tree.node(first).unwrap().name, "big.mov");
    assert_eq!(tree.path(first).unwrap(), dir.path().join("videos/big.mov"));
    assert_eq!(tree.node(first).unwrap().file_type, Some(cleaner_core::FileType::Video));
    assert_eq!(tree.node(find(&tree, "videos")).unwrap().file_type, Some(cleaner_core::FileType::Video), "folder takes its main type");
}

#[cfg(unix)]
#[test]
fn hard_links_are_counted_once() {
    let dir = fixture();
    fs::hard_link(dir.path().join("videos/big.mov"), dir.path().join("photos/big-link.mov")).unwrap();
    let tree = tree::scan_with_skips(dir.path(), &Progress::new(), Vec::new());
    assert_eq!(tree.node(DiskTree::ROOT).unwrap().size, fsutil::size_of(dir.path(), None));
    let movs = (0..tree.len() as u32).filter(|&i| tree.node(i).unwrap().name.ends_with(".mov")).count();
    assert_eq!(movs, 1, "both names of a hard-linked file were counted");
}

#[test]
fn detaching_updates_every_ancestor() {
    let dir = fixture();
    let mut tree = tree::scan_with_skips(dir.path(), &Progress::new(), Vec::new());
    let before = tree.node(DiskTree::ROOT).unwrap().size;
    let mov = find(&tree, "big.mov");
    let size = tree.node(mov).unwrap().size;
    tree.detach(mov);
    assert_eq!(tree.node(DiskTree::ROOT).unwrap().size, before - size);
    assert_eq!(tree.node(find(&tree, "videos")).unwrap().size, 0);
    assert!(!tree.largest_files.contains(&mov));
    assert!(tree.path(mov).is_none(), "a detached node has no path");
}

#[test]
fn treemap_stays_in_bounds_and_hit_tests() {
    let dir = fixture();
    let tree = tree::scan_with_skips(dir.path(), &Progress::new(), Vec::new());
    let (w, h) = (800.0, 500.0);
    let cells = treemap::layout(&tree, DiskTree::ROOT, w, h, treemap::DEFAULT_MAX_CELLS);
    assert!(!cells.is_empty());
    for cell in &cells {
        let r = cell.rect;
        assert!(r.x >= -1e-6 && r.y >= -1e-6 && r.x + r.w <= w + 1e-6 && r.y + r.h <= h + 1e-6, "cell outside the map");
        if let Some(parent) = cell.parent_cell {
            let p = cells[parent as usize].rect;
            assert!(r.x >= p.x - 1e-6 && r.x + r.w <= p.x + p.w + 1e-6, "cell outside its folder");
        }
    }
    let index = HitIndex::new(&cells);
    let mov = cells.iter().position(|c| c.node.and_then(|n| tree.node(n)).is_some_and(|n| n.name == "big.mov")).expect("big.mov drawn");
    let r = cells[mov].rect;
    assert_eq!(index.hit(&cells, r.x + r.w / 2.0, r.y + r.h / 2.0), Some(mov));
    assert_eq!(cells[mov].kind, CellKind::File);

    // A tiny budget never leaves folders as empty boxes.
    let few = treemap::layout(&tree, DiskTree::ROOT, w, h, 3);
    assert!(few.iter().all(|c| c.kind != CellKind::Folder || few.iter().any(|d| d.parent_cell.map(|p| &few[p as usize] as *const _) == Some(c as *const _))));
}

#[test]
fn search_finds_large_files_duplicates_and_node_modules_in_one_walk() {
    let dir = fixture();
    #[cfg(unix)]
    fs::hard_link(dir.path().join("photos/a.jpg"), dir.path().join("photos/a-hardlink.jpg")).unwrap();
    let settings = Settings { large_file_min_bytes: 2_000_000, search_root: dir.path().into(), ..Settings::default() };
    let found = search::scan(dir.path(), &search::Options::from(&settings), &Progress::new());

    let large: Vec<&str> = found.large_files.items.iter().map(|i| i.name.as_str()).collect();
    assert_eq!(large, ["big.mov"]);

    let dupes = &found.duplicates.items;
    assert_eq!(dupes.len(), 2, "expected exactly a.jpg + a-copy.jpg, got {:?}", dupes.iter().map(|d| &d.name).collect::<Vec<_>>());
    assert!(dupes.iter().all(|d| d.group == Some(1)));
    assert_eq!(dupes.iter().filter(|d| d.keeper).count(), 1);
    assert!(dupes.iter().all(|d| d.category == Category::Duplicates && !d.recommended));

    let modules: Vec<&str> = found.node_modules.items.iter().map(|i| i.name.as_str()).collect();
    assert_eq!(modules, ["proj/node_modules"], "nested node_modules listed separately");
}

#[test]
fn cancelling_stops_a_scan() {
    let dir = fixture();
    let progress = Progress::new();
    progress.cancel();
    let tree = tree::scan_with_skips(dir.path(), &progress, Vec::new());
    assert_eq!(tree.node(DiskTree::ROOT).unwrap().size, 0);
}

/// Moves real files to the real trash, so it only runs where that's harmless (CI sets this).
#[test]
fn moves_files_to_the_trash() {
    if std::env::var("CLEANER_TEST_TRASH").is_err() {
        eprintln!("skipped: set CLEANER_TEST_TRASH=1 to run");
        return;
    }
    let dir = tempfile::Builder::new().prefix("cleaner-trash-test").tempdir_in(fsutil::home()).unwrap();
    write(&dir.path().join("junk/a.bin"), 10_000, 1);
    write(&dir.path().join("junk/b.bin"), 10_000, 2);
    let outcomes = cleaner_core::remove::move_to_trash(&[dir.path().join("junk"), dir.path().join("junk/a.bin")]);
    assert_eq!(outcomes.len(), 1, "nested path should be folded into its folder");
    assert!(outcomes[0].ok, "{:?}", outcomes[0].message);
    assert!(!dir.path().join("junk").exists());
}

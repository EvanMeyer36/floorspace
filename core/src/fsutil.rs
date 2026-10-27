//! Small filesystem helpers whose details differ per OS.

use crate::progress::Progress;
use rayon::prelude::*;
use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Space a file really takes on disk. On Unix that's allocated blocks (sparse and compressed files
/// take less than their length); on Windows the logical length is used.
pub fn allocated_size(meta: &Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        meta.blocks() * 512
    }
    #[cfg(not(unix))]
    {
        meta.len()
    }
}

/// Identity of a file that has other hard links, so its blocks are counted once.
pub fn hard_link_id(meta: &Metadata) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.nlink() > 1).then(|| (meta.dev(), meta.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

/// Volume a file lives on (Unix only). Used to stay off other mounted volumes.
pub fn device(meta: &Metadata) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(meta.dev())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

/// A cloud file that isn't downloaded (OneDrive/iCloud "online-only"). Reading one would start a
/// download, so content checks like duplicate hashing must skip it.
pub fn is_cloud_placeholder(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const OFFLINE: u32 = 0x1000;
        const RECALL_ON_OPEN: u32 = 0x40000;
        const RECALL_ON_DATA_ACCESS: u32 = 0x400000;
        meta.file_attributes() & (OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS) != 0
    }
    #[cfg(not(windows))]
    {
        // Evicted iCloud files have data on the server but no blocks here.
        meta.len() > 0 && allocated_size(meta) == 0
    }
}

/// Hidden by convention: a leading dot, or on Windows the hidden attribute.
pub fn is_hidden(name: &str, meta: Option<&Metadata>) -> bool {
    if name.starts_with('.') {
        return true;
    }
    #[cfg(windows)]
    if let Some(meta) = meta {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        return meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0;
    }
    let _ = meta;
    false
}

#[derive(Debug, Clone, Copy, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskSpace {
    pub total: u64,
    pub free: u64,
}

impl DiskSpace {
    pub fn used(&self) -> u64 {
        self.total.saturating_sub(self.free)
    }
}

/// Total and free space of the volume holding `path`.
pub fn disk_space(path: &Path) -> Option<DiskSpace> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
        let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c_path.as_ptr(), &mut stats) } != 0 {
            return None;
        }
        let block = stats.f_frsize as u64;
        Some(DiskSpace { total: stats.f_blocks as u64 * block, free: stats.f_bavail as u64 * block })
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        let (mut free, mut total, mut total_free) = (0u64, 0u64, 0u64);
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free, &mut total, &mut total_free) };
        (ok != 0).then_some(DiskSpace { total, free })
    }
}

/// The folder the OS starts from: `/` on macOS and Linux, the system drive on Windows.
pub fn startup_disk() -> PathBuf {
    #[cfg(windows)]
    {
        let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
        PathBuf::from(format!("{drive}\\"))
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/")
    }
}

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Expands a location template used by the cleanup rules:
/// `~` home, `{cache}` per-user cache dir, `{local}` local app data, `{roaming}` roaming app data
/// (Windows), `{config}`, `{data}`, `{temp}`, `{downloads}`, `{library}` (macOS `~/Library`).
/// Returns `None` if a placeholder doesn't exist on this OS.
pub fn expand(template: &str) -> Option<PathBuf> {
    let (head, rest) = match template.find('/') {
        Some(i) => (&template[..i], &template[i + 1..]),
        None => (template, ""),
    };
    let base = match head {
        "~" => Some(home()),
        "{cache}" => dirs::cache_dir(),
        "{local}" => dirs::data_local_dir(),
        "{roaming}" => if cfg!(windows) { dirs::data_dir() } else { None },
        "{config}" => dirs::config_dir(),
        "{data}" => dirs::data_dir(),
        "{temp}" => Some(std::env::temp_dir()),
        "{downloads}" => dirs::download_dir(),
        "{library}" => if cfg!(target_os = "macos") { Some(home().join("Library")) } else { None },
        absolute if absolute.is_empty() => Some(PathBuf::from("/")),
        other => Some(PathBuf::from(other)),
    }?;
    Some(rest.split('/').filter(|part| !part.is_empty()).fold(base, |path, part| path.join(part)))
}

/// Recursive on-disk size of a file or folder. Doesn't follow symlinks or leave the volume,
/// counts hard-linked files once, and stops early (with a partial total) when cancelled.
pub fn size_of(path: &Path, progress: Option<&Progress>) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else { return 0 };
    if !meta.is_dir() {
        return allocated_size(&meta);
    }
    let seen = std::sync::Mutex::new(std::collections::HashSet::new());
    folder_size(path, device(&meta), progress, &seen)
}

fn folder_size(
    path: &Path,
    dev: Option<u64>,
    progress: Option<&Progress>,
    seen: &std::sync::Mutex<std::collections::HashSet<(u64, u64)>>,
) -> u64 {
    if progress.is_some_and(Progress::is_cancelled) {
        return 0;
    }
    let Ok(entries) = fs::read_dir(path) else { return 0 };
    let mut total = 0;
    let mut subfolders = Vec::new();
    let mut count = 0;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        count += 1;
        if meta.is_dir() {
            if dev.is_none() || device(&meta) == dev {
                subfolders.push(entry.path());
            }
        } else if meta.is_file() {
            if let Some(id) = hard_link_id(&meta) {
                if !seen.lock().map(|mut s| s.insert(id)).unwrap_or(true) {
                    continue;
                }
            }
            total += allocated_size(&meta);
        }
    }
    if let Some(progress) = progress {
        progress.add(count, path);
    }
    total + subfolders.par_iter().map(|p| folder_size(p, dev, progress, seen)).sum::<u64>()
}

pub fn days_since(time: SystemTime) -> Option<u64> {
    SystemTime::now().duration_since(time).ok().map(|d| d.as_secs() / 86_400)
}

/// "today", "3 days ago", "5 months ago", "2 years ago".
pub fn age(days: u64) -> String {
    match days {
        0 => "today".into(),
        1 => "yesterday".into(),
        2..=59 => format!("{days} days ago"),
        60..=729 => format!("{} months ago", days / 30),
        _ => format!("{} years ago", days / 365),
    }
}

/// `/Users/me/x` -> `~/x` for display.
pub fn tilde(path: &Path) -> String {
    let home = home();
    match path.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        Err(_) => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_home_and_unknown_placeholders() {
        assert_eq!(expand("~/a/b"), Some(home().join("a").join("b")));
        if !cfg!(target_os = "macos") {
            assert_eq!(expand("{library}/Caches"), None);
        }
        assert!(expand("{temp}").is_some());
    }

    #[test]
    fn sizes_count_hard_links_once() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a"), vec![1u8; 100_000]).unwrap();
        let one = size_of(dir.path(), None);
        #[cfg(unix)]
        {
            fs::hard_link(dir.path().join("a"), dir.path().join("b")).unwrap();
            assert_eq!(size_of(dir.path(), None), one, "hard link counted twice");
        }
        assert!(one >= 100_000);
    }

    #[test]
    fn ages() {
        assert_eq!(age(0), "today");
        assert_eq!(age(45), "45 days ago");
        assert_eq!(age(400), "13 months ago");
        assert_eq!(age(1000), "2 years ago");
    }
}

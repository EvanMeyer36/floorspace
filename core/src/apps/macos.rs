//! macOS: app bundles in /Applications and ~/Applications, leftovers in ~/Library.

use super::{leftover, unix_time, usable_name, InstalledApp, Leftover, Removal, Source};
use crate::fsutil;
use crate::progress::Progress;
use crate::remove::{self, Outcome};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub fn list(progress: &Progress, include_sandboxed_data: bool) -> Vec<InstalledApp> {
    let library = LibraryIndex::new(include_sandboxed_data);
    let apps = find_apps();
    progress.set_phase(format!("Measuring {} apps", apps.len()));
    let opened = spotlight_last_used(&apps);
    apps.par_iter()
        .zip(opened.par_iter())
        .map(|(path, spotlight)| {
            let mut app = inspect(path, &library, progress);
            // Spotlight misses apps opened from the Dock; the program file's access time covers those.
            app.last_used = app.last_used.max(*spotlight);
            app
        })
        .collect()
}

/// When Spotlight last saw each app opened (kMDItemLastUsedDate), in one `mdls` call.
fn spotlight_last_used(apps: &[PathBuf]) -> Vec<Option<u64>> {
    let output = Command::new("mdls").args(["-raw", "-name", "kMDItemLastUsedDate"]).args(apps).output();
    let text = output.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let mut values: Vec<Option<u64>> = text.split('\0').map(parse_mdls_date).collect();
    values.resize(apps.len(), None);
    values
}

/// "2026-10-21 23:32:52 +0000" -> Unix seconds. "(null)" -> None.
pub(crate) fn parse_mdls_date(text: &str) -> Option<u64> {
    let mut parts = text.trim().split([' ', '-', ':']);
    let mut next = || parts.next()?.parse::<i64>().ok();
    let (y, m, d, hh, mm, ss) = (next()?, next()?, next()?, next()?, next()?, next()?);
    // Days from the civil calendar (Howard Hinnant's algorithm).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + hh * 3_600 + mm * 60 + ss).ok()
}

/// Apps directly in the app folders, plus one level of subfolders (e.g. /Applications/Utilities).
fn find_apps() -> Vec<PathBuf> {
    let mut found = Vec::new();
    for folder in [PathBuf::from("/Applications"), fsutil::home().join("Applications")] {
        let Ok(entries) = fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if is_app(&path) {
                found.push(path);
            } else if entry.file_type().is_ok_and(|t| t.is_dir()) {
                if let Ok(inner) = fs::read_dir(&path) {
                    found.extend(inner.flatten().map(|e| e.path()).filter(|p| is_app(p)));
                }
            }
        }
    }
    found
}

fn is_app(path: &Path) -> bool {
    path.extension().is_some_and(|e| e == "app")
}

fn inspect(path: &Path, library: &LibraryIndex, progress: &Progress) -> InstalledApp {
    let info = plist::Value::from_file(path.join("Contents/Info.plist")).ok();
    let field = |key: &str| info.as_ref().and_then(|v| v.as_dictionary()).and_then(|d| d.get(key)).and_then(|v| v.as_string()).map(String::from);
    let bundle_id = field("CFBundleIdentifier");
    let name = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let executable = field("CFBundleExecutable").map(|e| path.join("Contents/MacOS").join(e));
    let icon = field("CFBundleIconFile").map(|i| {
        let file = if i.ends_with(".icns") { i } else { format!("{i}.icns") };
        path.join("Contents/Resources").join(file)
    });
    let steam_shortcut = executable.as_deref().is_some_and(is_steam_launcher);
    let app_store = path.join("Contents/_MASReceipt").exists();
    let movable = writable(path) && path.parent().is_some_and(writable);
    progress.add(1, path);

    InstalledApp {
        id: path.display().to_string(),
        identifier: bundle_id.clone(),
        version: field("CFBundleShortVersionString").or_else(|| field("CFBundleVersion")),
        publisher: None,
        location: Some(path.to_path_buf()),
        icon: icon.filter(|i| i.exists()),
        source: if app_store { Source::MacAppStore } else { Source::MacApp },
        size: fsutil::size_of(path, None),
        // A shortcut's name matches the game's own folders (often its save files), which aren't the shortcut's to remove.
        leftovers: if steam_shortcut { Vec::new() } else { library.leftovers(bundle_id.as_deref(), &name) },
        last_used: executable.as_deref().and_then(|e| unix_time(e, true)),
        protection: protection(path, bundle_id.as_deref()),
        note: if steam_shortcut {
            Some("Only a Steam shortcut. The game itself is in your Steam library, so uninstall it from Steam to free its space. Its save files are left alone.".into())
        } else if !movable {
            Some("Owned by the system, so Finder will ask for your password to remove it.".into())
        } else {
            None
        },
        removal: Some(Removal::Trash { path: path.to_path_buf() }),
        needs_password: !movable,
        name,
    }
}

fn writable(path: &Path) -> bool {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    CString::new(path.as_os_str().as_bytes()).is_ok_and(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0)
}

/// Steam's "create desktop shortcut" makes a tiny .app whose program runs steam://run/<id>.
fn is_steam_launcher(executable: &Path) -> bool {
    use std::io::Read;
    let mut head = Vec::new();
    fs::File::open(executable).and_then(|f| f.take(4096).read_to_end(&mut head)).is_ok()
        && String::from_utf8_lossy(&head).contains("steam://run/")
}

fn protection(path: &Path, bundle_id: Option<&str>) -> Option<String> {
    if let Ok(meta) = fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            let target = fs::canonicalize(path).unwrap_or_default();
            return Some(if target.starts_with("/System") {
                "Part of macOS, which protects it from being removed.".into()
            } else {
                format!("Only a link to the app at {}. Uninstall it from there.", fsutil::tilde(&target))
            });
        }
    }
    if on_read_only_volume(path) {
        return Some("Part of macOS, which protects it from being removed.".into());
    }
    let this_app = std::env::current_exe().ok().is_some_and(|exe| exe.starts_with(path));
    if this_app || bundle_id == Some("io.github.evanmeyer36.floorspace") {
        return Some("This is Floorspace itself.".into());
    }
    None
}

fn on_read_only_volume(path: &Path) -> bool {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let Ok(c_path) = CString::new(path.as_os_str().as_bytes()) else { return false };
    let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
    unsafe { libc::statfs(c_path.as_ptr(), &mut stats) == 0 && stats.f_flags & libc::MNT_RDONLY as u32 != 0 }
}

/// Asks the app to quit (it may ask to save changes) and waits up to 10 seconds.
pub fn quit(app: &InstalledApp) {
    let (Some(id), Some(location)) = (&app.identifier, &app.location) else { return };
    let running = || {
        Command::new("ps").args(["-A", "-o", "comm="]).output().is_ok_and(|o| {
            String::from_utf8_lossy(&o.stdout).lines().any(|l| l.starts_with(&format!("{}/Contents/MacOS/", location.display())))
        })
    };
    if !running() {
        return;
    }
    let script = ["on run argv", "tell application id (item 1 of argv) to quit", "end run"];
    let mut args: Vec<String> = script.iter().flat_map(|l| ["-e".to_string(), l.to_string()]).collect();
    args.push(id.clone());
    remove::run_command("/usr/bin/osascript", &args, Duration::from_secs(15));
    for _ in 0..50 {
        if !running() {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Moves an app to the Trash. Apps owned by the system (most App Store apps) can't be moved by a
/// normal process, so those go through Finder, which asks for an administrator password the way it
/// does when you drag them to the Trash yourself. The path is passed as an argument, never pasted
/// into the script.
pub fn trash_app(path: &Path) -> Outcome {
    let first = remove::move_to_trash(&[path.to_path_buf()]).remove(0);
    if first.ok || remove::protection_reason(path).is_some() {
        return first;
    }
    let script = ["on run argv", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)", "end run"];
    let mut args: Vec<String> = script.iter().flat_map(|l| ["-e".to_string(), l.to_string()]).collect();
    args.push(path.display().to_string());
    let finder = remove::run_command("/usr/bin/osascript", &args, Duration::from_secs(300));
    if finder.ok && !path.exists() {
        Outcome::ok(path.display().to_string())
    } else {
        Outcome::failed(path.display().to_string(), finder.message.unwrap_or_else(|| "macOS didn't allow it to be moved to the Trash.".into()))
    }
}

/// One listing of each ~/Library folder that apps leave files in, shared by every app.
struct LibraryIndex {
    locations: Vec<(PathBuf, &'static str, &'static str, HashSet<String>)>, // (folder, folder key, kind, names)
}

impl LibraryIndex {
    fn new(include_sandboxed_data: bool) -> Self {
        let lib = fsutil::home().join("Library");
        let folders: [(&str, &str); 13] = [
            ("Application Support", "App data"),
            ("Caches", "Cache"),
            ("Preferences", "Settings"),
            ("Preferences/ByHost", "Settings"),
            ("Saved Application State", "Saved windows"),
            ("Logs", "Logs"),
            ("HTTPStorages", "Web data"),
            ("WebKit", "Web data"),
            ("Cookies", "Cookies"),
            ("Application Scripts", "Scripts"),
            ("LaunchAgents", "Background helper"),
            ("Containers", "Sandboxed app data"),
            ("Group Containers", "Shared app data"),
        ];
        let locations = folders
            .into_iter()
            .filter(|(folder, _)| include_sandboxed_data || !folder.contains("Containers"))
            .map(|(folder, kind)| {
                let path = lib.join(folder);
                let names = fs::read_dir(&path).map(|e| e.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
                (path, folder, kind, names)
            })
            .collect();
        LibraryIndex { locations }
    }

    fn leftovers(&self, bundle_id: Option<&str>, app_name: &str) -> Vec<Leftover> {
        let mut found = Vec::new();
        for (path, folder, kind, names) in &self.locations {
            for name in names {
                if let Some(id) = bundle_id {
                    if belongs(name, id, folder) {
                        found.push(leftover(path.join(name), kind, false));
                        continue;
                    }
                }
                if ["Application Support", "Caches", "Logs"].contains(folder) && usable_name(app_name) && name == app_name {
                    found.push(leftover(path.join(name), kind, true));
                }
            }
        }
        found.sort_by_key(|l| std::cmp::Reverse(l.size.unwrap_or(0)));
        found
    }
}

/// Exact bundle-ID matches only, so one app's uninstall never takes another app's files.
pub(crate) fn belongs(name: &str, bundle_id: &str, folder: &str) -> bool {
    match folder {
        "Preferences" | "Preferences/ByHost" | "LaunchAgents" => {
            name == format!("{bundle_id}.plist") || (name.starts_with(&format!("{bundle_id}.")) && name.ends_with(".plist"))
        }
        "Saved Application State" => name == format!("{bundle_id}.savedState"),
        "Cookies" => name == format!("{bundle_id}.binarycookies"),
        "HTTPStorages" => name == bundle_id || name == format!("{bundle_id}.binarycookies"),
        // Team-prefixed, e.g. "ABCDE12345.com.example.app". Shared suite containers (like Office's) don't match.
        "Group Containers" => name == bundle_id || name.ends_with(&format!(".{bundle_id}")) || name == format!("group.{bundle_id}"),
        _ => name == bundle_id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spotlight_dates() {
        assert_eq!(parse_mdls_date("1970-01-02 00:00:10 +0000"), Some(86_410));
        assert_eq!(parse_mdls_date("2026-10-21 23:32:52 +0000"), Some(1_792_625_572));
        assert_eq!(parse_mdls_date("(null)"), None);
    }

    #[test]
    fn leftover_matching_is_exact() {
        assert!(belongs("com.spotify.client.plist", "com.spotify.client", "Preferences"));
        assert!(belongs("com.spotify.client.ABCD.plist", "com.spotify.client", "Preferences/ByHost"));
        assert!(!belongs("com.spotify.clientx.plist", "com.spotify.client", "Preferences"));
        assert!(belongs("UBF8T346G9.com.microsoft.Word", "com.microsoft.Word", "Group Containers"));
        assert!(!belongs("UBF8T346G9.Office", "com.microsoft.Word", "Group Containers"), "shared Office container must stay");
        assert!(!belongs("com.spotify", "com.spotify.client", "Application Support"));
    }

    /// Reads the real /Applications and ~/Library, so it only runs where that's harmless (CI sets this).
    #[test]
    fn lists_real_apps() {
        if std::env::var("FLOORSPACE_TEST_APPS").is_err() {
            return;
        }
        let apps = list(&Progress::new(), false);
        assert!(!apps.is_empty(), "no apps found in /Applications");
        assert!(apps.iter().all(|a| a.removal.is_some()));
    }
}

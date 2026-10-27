//! Everything that removes anything goes through here, so the safety rules live in one place.
//!
//! - Removal means the OS trash (macOS Trash, Windows Recycle Bin, freedesktop Trash on Linux).
//! - Only things inside the user's home folder, or whole apps in /Applications on macOS, can be
//!   removed. Never system folders, the standard user folders themselves, or pieces of an app or
//!   media library (a file like `Photos.sqlite-wal` looks like junk but isn't).
//! - Permanent deletion is only for emptying the trash and for tools cleaning up after
//!   themselves (e.g. `docker image prune`), and every UI must label those as permanent.

use crate::fsutil;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Action {
    /// Recoverable until the trash is emptied.
    MoveToTrash,
    /// Removed outright; only used for items that are already in the trash.
    DeletePermanently,
    /// The owning tool removes it (e.g. `docker image prune`). Permanent.
    RunCommand { program: String, args: Vec<String> },
}

impl Action {
    pub fn is_permanent(&self) -> bool {
        !matches!(self, Action::MoveToTrash)
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub target: String,
    pub ok: bool,
    pub message: Option<String>,
}

impl Outcome {
    pub(crate) fn ok(target: impl Into<String>) -> Self {
        Outcome { target: target.into(), ok: true, message: None }
    }
    pub(crate) fn failed(target: impl Into<String>, message: impl Into<String>) -> Self {
        Outcome { target: target.into(), ok: false, message: Some(message.into()) }
    }
}

/// Bundles whose insides must only be changed by their own app.
const PROTECTED_PACKAGES: [&str; 12] = [
    "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary",
    "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "theater",
];

/// Folders directly in the home folder that are never removed as a whole.
const STANDARD_FOLDERS: [&str; 14] = [
    "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Videos", "Music", "Library",
    "Applications", "Public", "AppData", "OneDrive", ".config", ".local",
];

/// Why `path` must not be removed, or `None` if it may be.
pub fn protection_reason(path: &Path) -> Option<String> {
    let home = fsutil::home();
    if path == home || path.parent().is_none() {
        return Some("This is a top-level folder.".into());
    }
    if let Ok(rest) = path.strip_prefix(&home) {
        let mut parts = rest.components();
        let first = parts.next().map(|c| c.as_os_str().to_string_lossy().into_owned()).unwrap_or_default();
        if parts.next().is_none() && STANDARD_FOLDERS.contains(&first.as_str()) {
            return Some(format!("{first} is one of your standard folders."));
        }
    } else if !is_whole_mac_app(path) {
        return Some("Only items inside your home folder can be removed (and whole apps in Applications on a Mac).".into());
    }
    if let Some(package) = protecting_package(path) {
        return Some(format!("It's part of {package}, and removing pieces of it would damage it. Remove the whole thing instead."));
    }
    None
}

/// A whole `.app` bundle somewhere under /Applications (including subfolders like /Applications/Utilities).
fn is_whole_mac_app(path: &Path) -> bool {
    cfg!(target_os = "macos")
        && path.starts_with("/Applications")
        && path.extension().is_some_and(|e| e.eq_ignore_ascii_case("app"))
}

/// The app or library bundle a path is inside of, if any.
pub fn protecting_package(path: &Path) -> Option<String> {
    let ancestors: Vec<&Path> = path.ancestors().skip(1).collect();
    ancestors.iter().rev().find_map(|a| {
        let ext = a.extension()?.to_string_lossy().to_ascii_lowercase();
        PROTECTED_PACKAGES.contains(&ext.as_str()).then(|| a.file_name().unwrap().to_string_lossy().into_owned())
    })
}

/// Keeps each path once and drops anything inside a folder that's also being removed.
pub fn outermost(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut sorted: Vec<&PathBuf> = paths.iter().collect();
    sorted.sort_by_key(|p| p.components().count());
    let mut kept: Vec<PathBuf> = Vec::new();
    for path in sorted {
        if !kept.iter().any(|k| path.starts_with(k)) {
            kept.push(path.clone());
        }
    }
    kept
}

/// Moves each path to the OS trash, refusing protected ones. One outcome per path removed or refused.
pub fn move_to_trash(paths: &[PathBuf]) -> Vec<Outcome> {
    let context = trash_context();
    outermost(paths)
        .into_iter()
        .map(|path| {
            let target = path.display().to_string();
            if let Some(reason) = protection_reason(&path) {
                return Outcome::failed(target, reason);
            }
            match context.delete(&path) {
                Ok(()) => Outcome::ok(target),
                Err(e) => Outcome::failed(target, e.to_string()),
            }
        })
        .collect()
}

fn trash_context() -> trash::TrashContext {
    #[allow(unused_mut)]
    let mut context = trash::TrashContext::default();
    #[cfg(target_os = "macos")]
    {
        // The default asks Finder over AppleScript, which makes macOS prompt for permission to
        // control Finder; NSFileManager moves to the Trash directly.
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        context.set_delete_method(DeleteMethod::NsFileManager);
    }
    context
}

/// Empties the current user's trash. Permanent.
pub fn empty_trash() -> Vec<Outcome> {
    #[cfg(any(windows, all(unix, not(target_os = "macos"), not(target_os = "ios"), not(target_os = "android"))))]
    {
        match trash::os_limited::list() {
            Ok(items) => {
                let count = items.len();
                match trash::os_limited::purge_all(items) {
                    Ok(()) => vec![Outcome::ok(format!("{count} items"))],
                    Err(e) => vec![Outcome::failed("Trash", e.to_string())],
                }
            }
            Err(e) => vec![Outcome::failed("Trash", e.to_string())],
        }
    }
    #[cfg(target_os = "macos")]
    {
        let trash = fsutil::home().join(".Trash");
        match std::fs::read_dir(&trash) {
            Ok(entries) => entries
                .flatten()
                .map(|e| {
                    let path = e.path();
                    let result = if e.file_type().is_ok_and(|t| t.is_dir()) { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
                    match result {
                        Ok(()) => Outcome::ok(path.display().to_string()),
                        Err(err) => Outcome::failed(path.display().to_string(), err.to_string()),
                    }
                })
                .collect(),
            Err(e) => vec![Outcome::failed("Trash", format!("{e}. On macOS this needs Full Disk Access."))],
        }
    }
}

/// Runs a cleanup command (e.g. `docker builder prune`) with a timeout.
pub fn run_command(program: &str, args: &[String], timeout: Duration) -> Outcome {
    let label = format!("{program} {}", args.join(" "));
    let mut child = match Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(child) => child,
        Err(e) => return Outcome::failed(label, format!("Couldn't run it: {e}")),
    };
    // Read output on threads so a chatty tool can't fill the pipe and stall.
    let mut stderr = child.stderr.take();
    let err_reader = std::thread::spawn(move || {
        let mut text = String::new();
        if let Some(s) = stderr.as_mut() {
            let _ = s.read_to_string(&mut text);
        }
        text
    });
    let mut stdout = child.stdout.take();
    std::thread::spawn(move || {
        let mut sink = Vec::new();
        if let Some(s) = stdout.as_mut() {
            let _ = s.read_to_end(&mut sink);
        }
    });

    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if start.elapsed() > timeout => {
                let _ = child.kill();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => break None,
        }
    };
    match status {
        Some(s) if s.success() => Outcome::ok(label),
        Some(s) => {
            let detail = err_reader.join().unwrap_or_default();
            let last = detail.lines().last().unwrap_or("").to_string();
            Outcome::failed(label, if last.is_empty() { format!("Exited with {s}") } else { last })
        }
        None => Outcome::failed(label, "Timed out and was stopped."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protects_system_and_standard_folders() {
        let home = fsutil::home();
        assert!(protection_reason(&home).is_some());
        assert!(protection_reason(&home.join("Documents")).is_some());
        assert!(protection_reason(&home.join("Library")).is_some());
        assert!(protection_reason(Path::new("/usr/lib")).is_some());
        assert!(protection_reason(&home.join("Documents/old.zip")).is_none());
        assert!(protection_reason(&home.join("Library/Caches/com.example")).is_none());
    }

    #[test]
    fn protects_inside_apps_and_libraries() {
        let home = fsutil::home();
        let wal = home.join("Pictures/Photos Library.photoslibrary/database/Photos.sqlite-wal");
        assert!(protection_reason(&wal).unwrap().contains("Photos Library.photoslibrary"));
        assert!(protection_reason(&home.join("Applications/Game.app/Contents/x")).is_some());
        assert!(protection_reason(&home.join("Applications/Game.app")).is_none(), "whole app is fine");
    }

    #[test]
    fn outermost_drops_nested_and_duplicates() {
        let kept = outermost(&["/a/b/c".into(), "/a/b".into(), "/a/b".into(), "/x".into()]);
        assert_eq!(kept, vec![PathBuf::from("/x"), PathBuf::from("/a/b")]);
    }

    #[test]
    fn refuses_protected_paths_without_touching_them() {
        let outcome = &move_to_trash(&[PathBuf::from("/usr/bin/true")])[0];
        assert!(!outcome.ok);
        assert!(Path::new("/usr/bin/true").exists() || cfg!(windows));
    }

    #[test]
    fn commands_time_out_and_report_failures() {
        if cfg!(windows) {
            return;
        }
        let slow = run_command("sleep", &["5".into()], Duration::from_millis(300));
        assert!(!slow.ok && slow.message.unwrap().contains("Timed out"));
        let failing = run_command("sh", &["-c".into(), "echo nope >&2; exit 3".into()], Duration::from_secs(5));
        assert_eq!(failing.message.as_deref(), Some("nope"));
        assert!(run_command("true", &[], Duration::from_secs(5)).ok);
    }
}

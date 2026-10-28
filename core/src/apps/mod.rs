//! Installed apps and uninstalling them, with their leftover files.
//!
//! Each OS finds apps differently ([`macos`], [`windows`], [`linux`]); they all produce
//! [`InstalledApp`]s with the same shape, and uninstall goes through [`uninstall`].

use crate::fsutil;
use crate::progress::Progress;
use crate::remove::{self, Outcome};
use serde::Serialize;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(windows)]
pub mod windows;

/// Where an app came from, which decides how it's removed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    MacApp,
    MacAppStore,
    /// Listed in the Windows "installed programs" registry; removed by its own uninstaller.
    WindowsInstaller,
    WindowsStore,
    Flatpak,
    Snap,
    AppImage,
    /// A distro package (deb/rpm/pacman) that shows up in the app menu.
    SystemPackage,
}

/// How [`uninstall`] removes the app itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Removal {
    /// Move the app (a bundle, AppImage file or folder) to the trash.
    Trash { path: PathBuf },
    /// Run the app's own uninstaller (Windows), which shows its own window and UAC prompt.
    Uninstaller { command: String },
    /// Run a package manager command; `admin` means it asks for a password.
    Command { program: String, args: Vec<String>, admin: bool },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Leftover {
    pub path: PathBuf,
    /// `None` when the OS wouldn't let us measure it.
    pub size: Option<u64>,
    pub kind: String,
    /// Found by the app's name rather than an exact ID, so slightly less certain.
    pub matched_by_name: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApp {
    /// Stable within one listing: bundle path, registry key, package name, ...
    pub id: String,
    /// Bundle ID, package name, Flatpak/Store ID, ... when there is one.
    pub identifier: Option<String>,
    pub name: String,
    pub version: Option<String>,
    pub publisher: Option<String>,
    pub location: Option<PathBuf>,
    /// An icon file (macOS .icns, Windows .exe/.ico, Linux icon path) if one was found.
    pub icon: Option<PathBuf>,
    pub source: Source,
    pub size: u64,
    pub leftovers: Vec<Leftover>,
    /// Seconds since the Unix epoch.
    pub last_used: Option<u64>,
    /// Why it can't be uninstalled here, if it can't.
    pub protection: Option<String>,
    /// Extra context shown with the app (e.g. "only a Steam shortcut").
    pub note: Option<String>,
    pub removal: Option<Removal>,
    /// Removing it asks for an administrator password (system-owned app, system-wide package, ...).
    pub needs_password: bool,
}

impl InstalledApp {
    pub fn leftovers_size(&self) -> u64 {
        self.leftovers.iter().filter_map(|l| l.size).sum()
    }

    pub fn total_size(&self) -> u64 {
        self.size + self.leftovers_size()
    }

}

#[derive(Debug, Clone)]
pub struct ListOptions {
    /// macOS: also measure other apps' sandboxed data (~/Library/Containers). macOS asks the user
    /// before allowing that, so UIs should explain first and only then set this.
    pub include_sandboxed_data: bool,
}

impl Default for ListOptions {
    fn default() -> Self {
        ListOptions { include_sandboxed_data: true }
    }
}

/// Every installed app this OS knows how to list.
pub fn list(progress: &Progress) -> Vec<InstalledApp> {
    list_with(progress, &ListOptions::default())
}

pub fn list_with(progress: &Progress, options: &ListOptions) -> Vec<InstalledApp> {
    progress.set_phase("Finding apps\u{2026}");
    let _ = options;
    #[cfg(target_os = "macos")]
    let mut apps = macos::list(progress, options.include_sandboxed_data);
    #[cfg(windows)]
    let mut apps = windows::list(progress);
    #[cfg(target_os = "linux")]
    let mut apps = linux::list(progress);
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    let mut apps: Vec<InstalledApp> = Vec::new();

    apps.sort_by_key(|a| std::cmp::Reverse(a.total_size()));
    apps
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallReport {
    pub removed: bool,
    pub outcomes: Vec<Outcome>,
    /// For packages whose removal would take others with it: what else would go. Nothing was removed.
    pub would_also_remove: Vec<String>,
}

/// Removes the app, then the leftovers that aren't in `keep`. Leftovers always go to the trash.
pub fn uninstall(app: &InstalledApp, keep: &HashSet<PathBuf>) -> UninstallReport {
    let mut report = UninstallReport::default();
    if let Some(reason) = &app.protection {
        report.outcomes.push(failed(&app.name, reason));
        return report;
    }
    let Some(removal) = &app.removal else {
        report.outcomes.push(failed(&app.name, "There's no way to uninstall this app from here."));
        return report;
    };

    #[cfg(target_os = "linux")]
    if let Some(others) = linux::other_packages_removed(app) {
        if !others.is_empty() {
            report.would_also_remove = others;
            report.outcomes.push(failed(&app.name, "Removing it would also remove other packages, so nothing was changed. Use your package manager if you're sure."));
            return report;
        }
    }

    let outcome = match removal {
        Removal::Trash { path } => {
            #[cfg(target_os = "macos")]
            {
                macos::quit(app);
                macos::trash_app(path)
            }
            #[cfg(not(target_os = "macos"))]
            {
                remove::move_to_trash(std::slice::from_ref(path)).remove(0)
            }
        }
        Removal::Uninstaller { command } => {
            #[cfg(windows)]
            {
                windows::run_uninstaller(app, command)
            }
            #[cfg(not(windows))]
            {
                failed(command, "Uninstallers only run on Windows.")
            }
        }
        Removal::Command { program, args, .. } => remove::run_command(program, args, std::time::Duration::from_secs(900)),
    };
    report.removed = outcome.ok;
    report.outcomes.push(outcome);
    if !report.removed {
        return report;
    }

    let leftovers: Vec<PathBuf> = app.leftovers.iter().map(|l| l.path.clone()).filter(|p| !keep.contains(p) && p.exists()).collect();
    report.outcomes.extend(remove::move_to_trash(&leftovers));
    report
}

fn failed(target: &str, message: &str) -> Outcome {
    Outcome::failed(target, message)
}

/// Names too generic to match a folder on: a folder called "Music" isn't necessarily Music.app's.
pub(crate) fn usable_name(name: &str) -> bool {
    name.chars().count() >= 4
        && !["Music", "Photos", "Notes", "Books", "Maps", "Mail", "News", "Home", "Clock", "Games", "Google", "Microsoft", "Mozilla", "Apple", "Adobe", "Programs", "Packages", "Temp"]
            .iter()
            .any(|g| g.eq_ignore_ascii_case(name))
}

/// Measures a leftover; `None` if the OS refused to let us look inside.
pub(crate) fn leftover(path: PathBuf, kind: &str, matched_by_name: bool) -> Leftover {
    let size = if path.is_dir() && std::fs::read_dir(&path).is_err() { None } else { Some(fsutil::size_of(&path, None)) };
    Leftover { path, size, kind: kind.into(), matched_by_name }
}

/// Modification/access time of a file as Unix seconds.
pub(crate) fn unix_time(path: &Path, accessed: bool) -> Option<u64> {
    let meta = std::fs::metadata(path).ok()?;
    let time = if accessed { meta.accessed().ok()? } else { meta.modified().ok()? };
    time.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs())
}

//! Linux: Flatpak, Snap, AppImage, and distro packages that put an app in the menu.

use super::{leftover, unix_time, usable_name, InstalledApp, Leftover, Removal, Source};
use crate::fsutil;
use crate::progress::Progress;
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

pub fn list(progress: &Progress) -> Vec<InstalledApp> {
    let mut apps = Vec::new();
    progress.set_phase("Listing Flatpak apps");
    apps.extend(flatpaks());
    progress.set_phase("Listing Snap apps");
    apps.extend(snaps());
    progress.set_phase("Looking for AppImages");
    apps.extend(appimages());
    progress.set_phase("Listing installed packages");
    apps.extend(packages(progress));
    apps
}

fn run(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn has(program: &str) -> bool {
    Command::new("sh").args(["-c", &format!("command -v {program}")]).output().is_ok_and(|o| o.status.success())
}

/// Config, data and cache folders an app commonly leaves in the home folder.
fn home_leftovers(names: &[&str]) -> Vec<Leftover> {
    let mut found: Vec<Leftover> = Vec::new();
    let bases = [(dirs::config_dir(), "Settings"), (dirs::data_dir(), "App data"), (dirs::cache_dir(), "Cache")];
    for (base, kind) in bases {
        let Some(base) = base else { continue };
        for name in names.iter().filter(|n| usable_name(n)) {
            let path = base.join(name);
            if path.exists() && !found.iter().any(|f| f.path == path) {
                found.push(leftover(path, kind, true));
            }
        }
    }
    found
}

// MARK: - Flatpak

fn flatpaks() -> Vec<InstalledApp> {
    if !has("flatpak") {
        return Vec::new();
    }
    let Some(text) = run("flatpak", &["list", "--app", "--columns=application,name,version,size,installation"]) else { return Vec::new() };
    parse_flatpak_list(&text)
        .into_iter()
        .map(|(id, name, version, size, installation)| {
            let data = fsutil::home().join(".var/app").join(&id);
            InstalledApp {
                id: format!("flatpak:{id}"),
                identifier: Some(id.clone()),
                name,
                version,
                publisher: None,
                location: None,
                icon: None,
                source: Source::Flatpak,
                size,
                leftovers: if data.exists() { vec![leftover(data.clone(), "App data", false)] } else { Vec::new() },
                last_used: unix_time(&data, true),
                protection: None,
                note: None,
                removal: Some(Removal::Command {
                    program: "flatpak".into(),
                    args: vec!["uninstall".into(), "-y".into(), format!("--{installation}"), id],
                    // System-wide Flatpaks ask for a password through Flatpak itself.
                    admin: installation == "system",
                }),
            }
        })
        .collect()
}

/// `flatpak list --columns=application,name,version,size,installation` (tab-separated).
pub(crate) fn parse_flatpak_list(text: &str) -> Vec<(String, String, Option<String>, u64, String)> {
    text.lines()
        .filter_map(|line| {
            let cols: Vec<&str> = line.split('\t').collect();
            let [id, name, version, size, installation] = cols.as_slice() else { return None };
            Some((
                id.trim().to_string(),
                name.trim().to_string(),
                Some(version.trim().to_string()).filter(|v| !v.is_empty()),
                parse_human_size(size).unwrap_or(0),
                installation.trim().to_string(),
            ))
        })
        .collect()
}

/// "1.2 GB", "345.6 MB", "12 kB" (Flatpak uses powers of 1000).
pub(crate) fn parse_human_size(text: &str) -> Option<u64> {
    let text = text.trim().replace('\u{a0}', " ");
    let (number, unit) = text.split_once(' ')?;
    let multiplier = match unit.trim() {
        "bytes" | "B" => 1.0,
        "kB" | "KB" => 1e3,
        "MB" => 1e6,
        "GB" => 1e9,
        "TB" => 1e12,
        _ => return None,
    };
    number.replace(',', ".").parse::<f64>().ok().map(|n| (n * multiplier) as u64)
}

// MARK: - Snap

/// Snaps that make up the system or runtimes, which aren't "apps" to uninstall.
const SNAP_BASES: [&str; 6] = ["core", "core18", "core20", "core22", "core24", "snapd"];

fn snaps() -> Vec<InstalledApp> {
    if !has("snap") {
        return Vec::new();
    }
    let Some(text) = run("snap", &["list"]) else { return Vec::new() };
    parse_snap_list(&text)
        .into_iter()
        .filter(|(name, _, _, notes)| !SNAP_BASES.contains(&name.as_str()) && !notes.contains("base") && !name.starts_with("gnome-") && !name.starts_with("gtk-common"))
        .map(|(name, version, revision, _)| {
            let file = PathBuf::from(format!("/var/lib/snapd/snaps/{name}_{revision}.snap"));
            let data = fsutil::home().join("snap").join(&name);
            InstalledApp {
                id: format!("snap:{name}"),
                identifier: Some(name.clone()),
                version: Some(version),
                publisher: None,
                location: Some(PathBuf::from("/snap").join(&name)),
                icon: None,
                source: Source::Snap,
                size: fs::metadata(&file).map(|m| m.len()).unwrap_or(0),
                leftovers: if data.exists() { vec![leftover(data.clone(), "App data", false)] } else { Vec::new() },
                last_used: unix_time(&data, true),
                protection: None,
                note: None,
                removal: Some(Removal::Command { program: "pkexec".into(), args: vec!["snap".into(), "remove".into(), name.clone()], admin: true }),
                name,
            }
        })
        .collect()
}

/// `snap list`: Name Version Rev Tracking Publisher Notes.
pub(crate) fn parse_snap_list(text: &str) -> Vec<(String, String, String, String)> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 3 {
                return None;
            }
            Some((cols[0].to_string(), cols[1].to_string(), cols[2].to_string(), cols.get(5).unwrap_or(&"").to_string()))
        })
        .collect()
}

// MARK: - AppImage

fn appimages() -> Vec<InstalledApp> {
    let home = fsutil::home();
    let folders = [home.join("Applications"), home.join("Downloads"), home.join(".local/bin"), home.join("AppImages")];
    folders
        .iter()
        .filter_map(|f| fs::read_dir(f).ok())
        .flat_map(|entries| entries.flatten())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("appimage")))
        .map(|path| {
            let file_name = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            // "Obsidian-1.5.3.AppImage" -> "Obsidian"
            let name = file_name.split(['-', '_']).next().unwrap_or(&file_name).to_string();
            InstalledApp {
                id: path.display().to_string(),
                identifier: None,
                version: None,
                publisher: None,
                location: Some(path.clone()),
                icon: None,
                source: Source::AppImage,
                size: fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
                leftovers: home_leftovers(&[&name, &name.to_lowercase()]),
                last_used: unix_time(&path, true),
                protection: None,
                note: None,
                removal: Some(Removal::Trash { path: path.clone() }),
                name,
            }
        })
        .collect()
}

// MARK: - Distro packages

#[derive(Debug, Clone, Copy, PartialEq)]
enum Manager {
    Dpkg,
    Rpm,
    Pacman,
}

fn manager() -> Option<Manager> {
    [("dpkg-query", Manager::Dpkg), ("rpm", Manager::Rpm), ("pacman", Manager::Pacman)].into_iter().find(|(p, _)| has(p)).map(|(_, m)| m)
}

/// App-menu entries: (desktop file, display name, icon name).
fn desktop_entries() -> Vec<(PathBuf, String, Option<String>)> {
    let Ok(entries) = fs::read_dir("/usr/share/applications") else { return Vec::new() };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "desktop"))
        .filter_map(|path| {
            let text = fs::read_to_string(&path).ok()?;
            let (name, icon, hidden) = parse_desktop_entry(&text);
            (!hidden).then_some((path, name?, icon))
        })
        .collect()
}

/// Name, Icon and whether the entry is hidden from the menu, from the [Desktop Entry] section.
pub(crate) fn parse_desktop_entry(text: &str) -> (Option<String>, Option<String>, bool) {
    let (mut name, mut icon, mut hidden, mut in_main) = (None, None, false, false);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_main = line == "[Desktop Entry]";
            continue;
        }
        if !in_main {
            continue;
        }
        match line.split_once('=') {
            Some(("Name", v)) if name.is_none() => name = Some(v.to_string()),
            Some(("Icon", v)) => icon = Some(v.to_string()),
            Some(("NoDisplay", "true")) | Some(("Hidden", "true")) => hidden = true,
            Some(("Type", t)) if t != "Application" => hidden = true,
            _ => {}
        }
    }
    (name, icon, hidden)
}

fn packages(progress: &Progress) -> Vec<InstalledApp> {
    let Some(manager) = manager() else { return Vec::new() };
    let entries = desktop_entries();
    if entries.is_empty() {
        return Vec::new();
    }
    // Which package owns each desktop file.
    let files: Vec<String> = entries.iter().map(|(p, _, _)| p.display().to_string()).collect();
    let file_args: Vec<&str> = files.iter().map(String::as_str).collect();
    let owners: HashMap<String, String> = match manager {
        Manager::Dpkg => run("dpkg", &[&["-S"], file_args.as_slice()].concat()).map(|t| parse_dpkg_owners(&t)).unwrap_or_default(),
        Manager::Rpm => file_args.iter().zip(run("rpm", &[&["-qf", "--qf", "%{NAME}\\n"], file_args.as_slice()].concat()).unwrap_or_default().lines()).map(|(f, p)| (f.to_string(), p.to_string())).collect(),
        Manager::Pacman => file_args.iter().filter_map(|f| run("pacman", &["-Qqo", f]).map(|p| (f.to_string(), p.trim().to_string()))).collect(),
    };

    let mut by_package: HashMap<String, (String, Option<String>)> = HashMap::new();
    for (path, name, icon) in entries {
        if let Some(package) = owners.get(&path.display().to_string()) {
            by_package.entry(package.clone()).or_insert((name, icon));
        }
    }
    progress.set_phase(format!("Measuring {} packages", by_package.len()));
    by_package
        .into_par_iter()
        .map(|(package, (name, icon))| {
            let (size, version, essential) = package_info(manager, &package);
            let protection = essential.then(|| "Part of the operating system, so removing it could break things.".to_string());
            InstalledApp {
                id: format!("package:{package}"),
                identifier: Some(package.clone()),
                version,
                publisher: None,
                location: None,
                icon: icon.map(PathBuf::from).filter(|p| p.is_absolute()),
                source: Source::SystemPackage,
                size,
                leftovers: home_leftovers(&[&package, &name, &name.to_lowercase()]),
                last_used: None,
                protection,
                note: None,
                removal: Some(match manager {
                    Manager::Dpkg => Removal::Command { program: "pkexec".into(), args: vec!["apt-get".into(), "remove".into(), "-y".into(), package.clone()], admin: true },
                    Manager::Rpm => Removal::Command { program: "pkexec".into(), args: vec!["dnf".into(), "remove".into(), "-y".into(), package.clone()], admin: true },
                    Manager::Pacman => Removal::Command { program: "pkexec".into(), args: vec!["pacman".into(), "-R".into(), "--noconfirm".into(), package.clone()], admin: true },
                }),
                name,
            }
        })
        .collect()
}

/// `dpkg -S` lines: "package[:arch][, other]: /path".
pub(crate) fn parse_dpkg_owners(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let (packages, path) = line.rsplit_once(": ")?;
            let package = packages.split(',').next()?.trim().split(':').next()?.to_string();
            Some((path.trim().to_string(), package))
        })
        .collect()
}

/// (installed size in bytes, version, essential to the system).
fn package_info(manager: Manager, package: &str) -> (u64, Option<String>, bool) {
    match manager {
        Manager::Dpkg => {
            let text = run("dpkg-query", &["-W", "-f=${Installed-Size}\t${Version}\t${Essential}\t${Priority}", package]).unwrap_or_default();
            let cols: Vec<&str> = text.split('\t').collect();
            let size = cols.first().and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0) * 1024;
            let essential = cols.get(2) == Some(&"yes") || matches!(cols.get(3).map(|s| s.trim()), Some("required" | "important"));
            (size, cols.get(1).map(|s| s.to_string()), essential)
        }
        Manager::Rpm => {
            let text = run("rpm", &["-q", "--qf", "%{SIZE}\t%{VERSION}", package]).unwrap_or_default();
            let (size, version) = text.split_once('\t').unwrap_or(("0", ""));
            (size.trim().parse().unwrap_or(0), Some(version.to_string()).filter(|v| !v.is_empty()), false)
        }
        Manager::Pacman => {
            let text = run("pacman", &["-Qi", package]).unwrap_or_default();
            let field = |key: &str| text.lines().find(|l| l.starts_with(key)).and_then(|l| l.split_once(':')).map(|(_, v)| v.trim().to_string());
            let size = field("Installed Size").and_then(|s| parse_human_size(&s.replace("MiB", "MB").replace("KiB", "kB").replace("GiB", "GB"))).unwrap_or(0);
            (size, field("Version"), false)
        }
    }
}

/// For distro packages: what else the package manager would remove along with this one.
/// `None` if it couldn't be checked (then the removal itself is skipped by the caller only if Some(non-empty)).
pub fn other_packages_removed(app: &InstalledApp) -> Option<Vec<String>> {
    if app.source != Source::SystemPackage {
        return None;
    }
    let package = app.identifier.as_deref()?;
    let others = match manager()? {
        Manager::Dpkg => parse_apt_simulation(&run("apt-get", &["-s", "remove", package])?),
        Manager::Rpm => {
            let output = Command::new("dnf").args(["remove", "--assumeno", package]).output().ok()?;
            parse_dnf_preview(&String::from_utf8_lossy(&output.stdout))
        }
        Manager::Pacman => {
            // pacman -R refuses on its own when other packages depend on this one.
            Vec::new()
        }
    };
    Some(others.into_iter().filter(|p| p != package).collect())
}

/// `apt-get -s remove`: lines like "Remv firefox [123.0]".
pub(crate) fn parse_apt_simulation(text: &str) -> Vec<String> {
    text.lines().filter_map(|l| l.strip_prefix("Remv ")).filter_map(|l| l.split_whitespace().next()).map(String::from).collect()
}

/// `dnf remove --assumeno`: package rows between "Removing" headings and the summary.
pub(crate) fn parse_dnf_preview(text: &str) -> Vec<String> {
    let mut packages = Vec::new();
    let mut in_table = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("Removing") {
            in_table = true;
            continue;
        }
        if trimmed.starts_with("Transaction Summary") || trimmed.is_empty() {
            in_table = false;
            continue;
        }
        if in_table && line.starts_with(' ') {
            if let Some(name) = trimmed.split_whitespace().next() {
                packages.push(name.to_string());
            }
        }
    }
    packages
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flatpak_list() {
        let text = "org.mozilla.firefox\tFirefox\t131.0\t289.5 MB\tsystem\ncom.spotify.Client\tSpotify\t1.2.4\t1.1 GB\tuser\n";
        let apps = parse_flatpak_list(text);
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].3, 289_500_000);
        assert_eq!(apps[1].4, "user");
    }

    #[test]
    fn snap_list() {
        let text = "Name      Version   Rev    Tracking       Publisher   Notes\ncore22    20240111  1122   latest/stable  canonical✓  base\nfirefox   131.0     4955   latest/stable  mozilla✓    -\n";
        let snaps = parse_snap_list(text);
        assert_eq!(snaps.len(), 2);
        assert_eq!(snaps[1].0, "firefox");
        assert_eq!(snaps[1].2, "4955");
        assert_eq!(snaps[0].3, "base");
    }

    #[test]
    fn desktop_entries() {
        let text = "[Desktop Entry]\nType=Application\nName=GIMP\nName[de]=GIMP-Bildbearbeitung\nIcon=gimp\n\n[Desktop Action new]\nName=New Window\n";
        assert_eq!(parse_desktop_entry(text), (Some("GIMP".into()), Some("gimp".into()), false));
        assert!(parse_desktop_entry("[Desktop Entry]\nName=X\nNoDisplay=true\n").2);
    }

    #[test]
    fn dpkg_owners() {
        let owners = parse_dpkg_owners("gimp: /usr/share/applications/gimp.desktop\nlibreoffice-writer:amd64, other: /usr/share/applications/writer.desktop\n");
        assert_eq!(owners["/usr/share/applications/gimp.desktop"], "gimp");
        assert_eq!(owners["/usr/share/applications/writer.desktop"], "libreoffice-writer");
    }

    #[test]
    fn apt_and_dnf_previews() {
        let apt = "NOTE: This is only a simulation!\nRemv ubuntu-desktop [1.481]\nRemv nautilus [1:42.2]\n";
        assert_eq!(parse_apt_simulation(apt), ["ubuntu-desktop", "nautilus"]);
        let dnf = "Dependencies resolved.\n=====\n Package   Arch   Version   Repo   Size\n=====\nRemoving:\n gimp      x86_64 2.10      @fedora 90 M\nRemoving dependent packages:\n gimp-help noarch 2.10     @fedora 10 M\n\nTransaction Summary\n";
        assert_eq!(parse_dnf_preview(dnf), ["gimp", "gimp-help"]);
    }

    #[test]
    fn human_sizes() {
        assert_eq!(parse_human_size("1.1 GB"), Some(1_100_000_000));
        assert_eq!(parse_human_size("12\u{a0}kB"), Some(12_000));
        assert_eq!(parse_human_size("weird"), None);
    }
}

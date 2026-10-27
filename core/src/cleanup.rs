//! Cleanup categories: per-OS junk described as data (rules), plus the shared search results.

use crate::fsutil;
use crate::progress::Progress;
use crate::remove::Action;
use crate::search;
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    Caches,
    DevJunk,
    /// macOS: device backups, iOS updates, Mail attachments. Windows/Linux: crash dumps and similar.
    SystemJunk,
    Downloads,
    LargeFiles,
    Duplicates,
    Trash,
}

impl Category {
    pub const ALL: [Category; 7] =
        [Category::Caches, Category::DevJunk, Category::SystemJunk, Category::Downloads, Category::LargeFiles, Category::Duplicates, Category::Trash];

    pub fn title(self) -> &'static str {
        match self {
            Category::Caches => "App Caches & Logs",
            Category::DevJunk => "Developer Junk",
            Category::SystemJunk => if cfg!(target_os = "macos") { "Backups & Mail" } else { "System Junk" },
            Category::Downloads => "Old Downloads",
            Category::LargeFiles => "Large Files",
            Category::Duplicates => "Duplicates",
            Category::Trash => if cfg!(windows) { "Recycle Bin" } else { "Trash" },
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub category: Category,
    pub name: String,
    pub path: Option<PathBuf>,
    pub size: u64,
    pub detail: String,
    /// Safe to remove without thinking about it; pre-selected.
    pub recommended: bool,
    pub action: Action,
    /// Duplicates: items with the same group have identical content.
    pub group: Option<u32>,
    /// Duplicates: the copy suggested to keep.
    pub keeper: bool,
}

impl Item {
    pub(crate) fn at(category: Category, path: PathBuf, size: u64, name: impl Into<String>, detail: impl Into<String>, recommended: bool) -> Item {
        Item {
            id: path.display().to_string(),
            category,
            name: name.into(),
            path: Some(path),
            size,
            detail: detail.into(),
            recommended,
            action: Action::MoveToTrash,
            group: None,
            keeper: false,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Warning {
    pub message: String,
    /// Fixed by granting Full Disk Access (macOS) rather than anything else.
    pub needs_full_disk_access: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryResult {
    pub category: Category,
    pub items: Vec<Item>,
    pub warnings: Vec<Warning>,
}

impl CategoryResult {
    fn new(category: Category) -> Self {
        CategoryResult { category, items: Vec::new(), warnings: Vec::new() }
    }

    /// What could be freed. For duplicates that excludes the copy suggested to keep.
    pub fn reclaimable(&self) -> u64 {
        self.items.iter().filter(|i| !i.keeper).map(|i| i.size).sum()
    }
}

#[derive(Debug, Clone)]
pub struct Settings {
    pub downloads_age_days: u64,
    pub large_file_min_bytes: u64,
    /// Where large files, duplicates and node_modules are searched for.
    pub search_root: PathBuf,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { downloads_age_days: 30, large_file_min_bytes: 250_000_000, search_root: fsutil::home() }
    }
}

// MARK: - Rules

#[derive(Debug, Clone, Copy)]
enum Mode {
    /// The location is one item.
    Whole,
    /// Each thing inside is its own item (e.g. one per app in a caches folder).
    EachChild { min_size: u64, min_age_days: u64 },
}

#[derive(Debug, Clone, Copy)]
struct Rule {
    category: Category,
    name: &'static str,
    /// Template for [`fsutil::expand`]; a `*` path segment matches every entry (e.g. browser profiles).
    location: &'static str,
    mode: Mode,
    recommended: bool,
    note: &'static str,
}

const fn whole(category: Category, name: &'static str, location: &'static str, recommended: bool, note: &'static str) -> Rule {
    Rule { category, name, location, mode: Mode::Whole, recommended, note }
}

const fn each(category: Category, name: &'static str, location: &'static str, min_age_days: u64, recommended: bool, note: &'static str) -> Rule {
    Rule { category, name, location, mode: Mode::EachChild { min_size: 1_000_000, min_age_days }, recommended, note }
}

use Category::{Caches, DevJunk, SystemJunk};

fn rules() -> Vec<Rule> {
    let mut rules = Vec::new();
    if cfg!(target_os = "macos") {
        rules.extend([
            each(Caches, "", "{library}/Caches", 0, true, "Cache \u{2022} the app rebuilds it"),
            each(Caches, "", "{library}/Logs", 0, true, "Log files"),
            whole(DevJunk, "Xcode DerivedData", "{library}/Developer/Xcode/DerivedData", true, "Build products. Xcode rebuilds them."),
            whole(DevJunk, "iOS Device Support", "{library}/Developer/Xcode/iOS DeviceSupport", true, "Debug symbols. Re-downloaded when a device is next connected."),
            whole(DevJunk, "Simulator caches", "{library}/Developer/CoreSimulator/Caches", true, "Rebuilt by the simulator."),
            whole(DevJunk, "Xcode Archives", "{library}/Developer/Xcode/Archives", false, "Old app builds. Needed to symbolicate crash reports for shipped versions."),
            whole(DevJunk, "Yarn cache", "{library}/Caches/Yarn", true, "Re-downloaded by Yarn as needed."),
            whole(DevJunk, "pip cache", "{library}/Caches/pip", true, "Re-downloaded by pip as needed."),
            whole(DevJunk, "Homebrew downloads", "{library}/Caches/Homebrew", true, "Old installers. Same as `brew cleanup`."),
            whole(DevJunk, "CocoaPods cache", "{library}/Caches/CocoaPods", true, "Re-downloaded by CocoaPods as needed."),
            whole(DevJunk, "pnpm store", "{library}/pnpm/store", true, "Re-downloaded by pnpm as needed."),
            each(SystemJunk, "", "{library}/Application Support/MobileSync/Backup", 0, false, "iPhone/iPad backup. Deleting it means you can't restore that device from this Mac."),
            whole(SystemJunk, "iPhone software updates", "{library}/iTunes/iPhone Software Updates", true, "Downloaded again if needed."),
            whole(SystemJunk, "iPad software updates", "{library}/iTunes/iPad Software Updates", true, "Downloaded again if needed."),
            whole(SystemJunk, "Mail attachments you opened", "{library}/Containers/com.apple.mail/Data/Library/Mail Downloads", true, "Copies saved when you opened attachments. The originals stay in your email."),
        ]);
    }
    if cfg!(windows) {
        rules.extend([
            each(Caches, "", "{temp}", 1, true, "Temporary files left behind by an app"),
            whole(Caches, "Chrome cache", "{local}/Google/Chrome/User Data/*/Cache", true, "Web cache. Chrome rebuilds it."),
            whole(Caches, "Chrome code cache", "{local}/Google/Chrome/User Data/*/Code Cache", true, "Chrome rebuilds it."),
            whole(Caches, "Edge cache", "{local}/Microsoft/Edge/User Data/*/Cache", true, "Web cache. Edge rebuilds it."),
            whole(Caches, "Firefox cache", "{local}/Mozilla/Firefox/Profiles/*/cache2", true, "Web cache. Firefox rebuilds it."),
            each(Caches, "", "{local}/Microsoft/Windows/INetCache", 0, true, "Windows web cache"),
            whole(Caches, "DirectX shader cache", "{local}/D3DSCache", true, "Rebuilt by games and apps."),
            whole(Caches, "NVIDIA shader cache", "{local}/NVIDIA/DXCache", true, "Rebuilt by games."),
            whole(SystemJunk, "Crash dumps", "{local}/CrashDumps", true, "Saved when apps crashed. Only useful for debugging."),
            whole(DevJunk, "npm cache", "{local}/npm-cache/_cacache", true, "Re-downloaded by npm as needed."),
            whole(DevJunk, "pip cache", "{local}/pip/Cache", true, "Re-downloaded by pip as needed."),
            whole(DevJunk, "Yarn cache", "{local}/Yarn/Cache", true, "Re-downloaded by Yarn as needed."),
            whole(DevJunk, "Go build cache", "{local}/go-build", true, "Rebuilt by Go."),
            whole(DevJunk, "NuGet packages", "~/.nuget/packages", false, "Re-downloaded by NuGet, but every project restores again."),
        ]);
    }
    if cfg!(target_os = "linux") {
        rules.extend([
            each(Caches, "", "{cache}", 0, true, "Cache \u{2022} the app rebuilds it"),
            whole(DevJunk, "pip cache", "{cache}/pip", true, "Re-downloaded by pip as needed."),
            whole(DevJunk, "Yarn cache", "{cache}/yarn", true, "Re-downloaded by Yarn as needed."),
            whole(DevJunk, "Go build cache", "{cache}/go-build", true, "Rebuilt by Go."),
            whole(DevJunk, "pnpm store", "{data}/pnpm/store", true, "Re-downloaded by pnpm as needed."),
            whole(DevJunk, "Maven repository", "~/.m2/repository", false, "Re-downloaded by Maven, but every project resolves again."),
        ]);
    }
    // The same on every OS.
    rules.extend([
        whole(DevJunk, "npm cache", "~/.npm/_cacache", true, "Re-downloaded by npm as needed."),
        whole(DevJunk, "Cargo registry cache", "~/.cargo/registry/cache", true, "Re-downloaded by Cargo as needed."),
        whole(DevJunk, "Cargo registry sources", "~/.cargo/registry/src", true, "Re-extracted by Cargo as needed."),
        whole(DevJunk, "Gradle caches", "~/.gradle/caches", true, "Re-downloaded by Gradle as needed."),
        whole(DevJunk, "Go module cache", "~/go/pkg/mod", false, "Re-downloaded by Go as needed. Files are read-only, so this may need a manual delete."),
    ]);
    rules
}

/// Expands a rule location, including `*` segments, to the folders that exist.
fn locations(template: &str) -> Vec<PathBuf> {
    let Some((before, after)) = template.split_once("/*") else {
        return fsutil::expand(template).into_iter().filter(|p| p.exists()).collect();
    };
    let Some(base) = fsutil::expand(before) else { return Vec::new() };
    let Ok(entries) = fs::read_dir(&base) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .flat_map(|e| locations(&format!("{}{}", e.path().display(), after)))
        .collect()
}

// MARK: - Scanning

/// Scans one category. For large files, duplicates and node_modules prefer [`scan_all`], which
/// shares a single walk of the search folder between them.
pub fn scan(category: Category, settings: &Settings, progress: &Progress) -> CategoryResult {
    match category {
        Category::LargeFiles | Category::Duplicates => {
            let found = search::scan(&settings.search_root, &search::Options::from(settings), progress);
            if category == Category::LargeFiles { found.large_files } else { found.duplicates }
        }
        Category::DevJunk => {
            let mut result = scan_rules(category, progress);
            let found = search::scan(&settings.search_root, &search::Options { find_duplicates: false, ..search::Options::from(settings) }, progress);
            result.items.extend(found.node_modules.items);
            result.warnings.extend(found.node_modules.warnings);
            result.items.sort_by_key(|i| std::cmp::Reverse(i.size));
            result
        }
        Category::Downloads => downloads(settings.downloads_age_days, progress),
        Category::Trash => trash(progress),
        _ => scan_rules(category, progress),
    }
}

/// Scans every category, walking the search folder only once.
pub fn scan_all(settings: &Settings, progress: &Progress) -> Vec<CategoryResult> {
    let (found, mut results) = rayon::join(
        || search::scan(&settings.search_root, &search::Options::from(settings), progress),
        || {
            [Category::Caches, Category::DevJunk, Category::SystemJunk]
                .into_iter()
                .map(|c| scan_rules(c, progress))
                .chain([downloads(settings.downloads_age_days, progress), trash(progress)])
                .collect::<Vec<_>>()
        },
    );
    if let Some(dev) = results.iter_mut().find(|r| r.category == Category::DevJunk) {
        dev.items.extend(found.node_modules.items);
        dev.warnings.extend(found.node_modules.warnings);
        dev.items.sort_by_key(|i| std::cmp::Reverse(i.size));
    }
    results.push(found.large_files);
    results.push(found.duplicates);
    results
}

fn scan_rules(category: Category, progress: &Progress) -> CategoryResult {
    let mut result = CategoryResult::new(category);
    let all_rules = rules();
    // Locations owned by a more specific rule aren't listed again as a child of a broader one
    // (e.g. ~/.cache/pip is "pip cache" in Developer Junk, not an item under ~/.cache).
    let specific: HashSet<PathBuf> =
        all_rules.iter().filter(|r| matches!(r.mode, Mode::Whole)).flat_map(|r| locations(r.location)).collect();
    let open = OpenApps::detect();

    for rule in all_rules.iter().filter(|r| r.category == category) {
        if progress.is_cancelled() {
            break;
        }
        progress.set_phase(format!("Checking {}", if rule.name.is_empty() { rule.location } else { rule.name }));
        if let Some(template_base) = fsutil::expand(rule.location.split("/*").next().unwrap_or(rule.location)) {
            if fs::read_dir(&template_base).is_err() && template_base.exists() {
                result.warnings.push(Warning {
                    message: format!("Couldn't read {}.", fsutil::tilde(&template_base)),
                    needs_full_disk_access: cfg!(target_os = "macos"),
                });
                continue;
            }
        }
        for location in locations(rule.location) {
            match rule.mode {
                Mode::Whole => {
                    let size = fsutil::size_of(&location, Some(progress));
                    if size > 0 {
                        result.items.push(Item::at(category, location, size, rule.name, rule.note, rule.recommended));
                    }
                }
                Mode::EachChild { min_size, min_age_days } => {
                    let Ok(entries) = fs::read_dir(&location) else { continue };
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if specific.contains(&path) {
                            continue;
                        }
                        let name = entry.file_name().to_string_lossy().into_owned();
                        let age = entry.metadata().ok().and_then(|m| m.modified().ok()).and_then(fsutil::days_since).unwrap_or(0);
                        if age < min_age_days {
                            continue;
                        }
                        let size = fsutil::size_of(&path, Some(progress));
                        if size < min_size {
                            continue;
                        }
                        result.items.push(child_item(category, rule, path, name, size, &open));
                    }
                }
            }
        }
    }
    if category == Category::DevJunk {
        progress.set_phase("Checking Docker");
        match docker_items() {
            Ok(items) => result.items.extend(items),
            Err(warning) => result.warnings.push(warning),
        }
    }
    result.items.sort_by_key(|i| std::cmp::Reverse(i.size));
    result
}

fn child_item(category: Category, rule: &Rule, path: PathBuf, name: String, size: u64, open: &OpenApps) -> Item {
    if category != Category::Caches {
        return Item::at(category, path, size, name, rule.note, rule.recommended);
    }
    let system_owned = name.starts_with("com.apple.") || name.starts_with("Microsoft.Windows");
    if system_owned {
        return Item::at(category, path, size, name, "System cache. Often in use and recreated right away.", false);
    }
    // An open app keeps using its cache: moving it frees nothing until the app restarts, and some apps misbehave.
    if let Some(app) = open.matching(&name) {
        return Item::at(category, path, size, name, format!("Cache \u{2022} {app} is open. Quit it first so the space is actually freed."), false);
    }
    Item::at(category, path, size, name, rule.note, rule.recommended)
}

/// Running programs, for not pre-selecting caches that are in use.
struct OpenApps {
    names: Vec<String>,
}

impl OpenApps {
    fn detect() -> Self {
        let output = if cfg!(windows) {
            Command::new("tasklist").args(["/fo", "csv", "/nh"]).output()
        } else {
            Command::new("ps").args(["-A", "-o", "comm="]).output()
        };
        let text = output.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
        OpenApps { names: Self::parse(&text) }
    }

    /// Program names from `ps -o comm=` (full paths) or `tasklist /fo csv` lines.
    fn parse(text: &str) -> Vec<String> {
        let mut names: Vec<String> = text
            .lines()
            .filter_map(|line| {
                let first = line.split(',').next()?.trim().trim_matches('"');
                let base = first.rsplit(['/', '\\']).next()?;
                let base = base.strip_suffix(".exe").unwrap_or(base);
                // macOS app processes: /Applications/Spotify.app/Contents/MacOS/Spotify -> "Spotify"
                (!base.is_empty()).then(|| base.to_string())
            })
            .collect();
        names.sort();
        names.dedup();
        names
    }

    /// The open program a cache folder belongs to. Folders are named by bundle ID
    /// ("com.spotify.client"), app name in any case ("ollama"), or maker ("Google" for Google Chrome).
    fn matching(&self, folder: &str) -> Option<String> {
        let folder_lower = folder.to_lowercase();
        let id_parts: Vec<&str> = if folder.contains('.') { folder_lower.split('.').skip(1).collect() } else { Vec::new() };
        self.names.iter().find(|name| {
            let n = name.to_lowercase();
            n == folder_lower || n.starts_with(&format!("{folder_lower} ")) || (n.len() > 3 && id_parts.contains(&n.as_str()))
        }).cloned()
    }
}

// MARK: - Downloads

fn downloads(age_days: u64, progress: &Progress) -> CategoryResult {
    let mut result = CategoryResult::new(Category::Downloads);
    let Some(folder) = dirs::download_dir() else { return result };
    progress.set_phase("Looking through Downloads");
    let entries = match fs::read_dir(&folder) {
        Ok(entries) => entries,
        Err(_) => {
            result.warnings.push(Warning { message: "Couldn't read your Downloads folder.".into(), needs_full_disk_access: false });
            return result;
        }
    };
    let (installers, archives): (&[&str], &[&str]) = if cfg!(windows) {
        (&["exe", "msi", "msix", "msixbundle", "appx", "iso"], &["zip", "7z", "rar", "tar", "gz"])
    } else if cfg!(target_os = "macos") {
        (&["dmg", "pkg", "mpkg", "xip", "iso"], &["zip", "tar", "gz", "tgz", "7z", "rar"])
    } else {
        (&["deb", "rpm", "iso", "run"], &["zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst"])
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.eq_ignore_ascii_case("desktop.ini") {
            continue;
        }
        let Some(days) = entry.metadata().ok().and_then(|m| m.modified().ok()).and_then(fsutil::days_since) else { continue };
        if days < age_days {
            continue;
        }
        let ext = crate::filetype::extension(&name);
        let when = fsutil::age(days);
        let (detail, recommended) = if installers.contains(&ext.as_str()) {
            (format!("Installer, downloaded {when}. Not needed once the app is installed."), true)
        } else if archives.contains(&ext.as_str()) {
            (format!("Archive, downloaded {when}. Check you've kept what's inside before removing it."), false)
        } else {
            (format!("Downloaded {when}"), false)
        };
        let path = entry.path();
        let size = fsutil::size_of(&path, Some(progress));
        result.items.push(Item::at(Category::Downloads, path, size, name, detail, recommended));
    }
    result.items.sort_by_key(|i| std::cmp::Reverse(i.size));
    result
}

// MARK: - Trash

fn trash(progress: &Progress) -> CategoryResult {
    let mut result = CategoryResult::new(Category::Trash);
    progress.set_phase("Measuring the trash");
    let (size, count) = trash_size();
    match (size, count) {
        (Some(size), count) if size > 0 => result.items.push(Item {
            id: "trash:all".into(),
            category: Category::Trash,
            name: format!("Everything in the {} ({count} item{})", Category::Trash.title(), if count == 1 { "" } else { "s" }),
            path: None,
            size,
            detail: "Emptying it is what actually frees the space. This can't be undone.".into(),
            recommended: false,
            action: Action::DeletePermanently,
            group: None,
            keeper: false,
        }),
        (None, _) => result.warnings.push(Warning {
            message: "Couldn't look inside the Trash. On a Mac this needs Full Disk Access.".into(),
            needs_full_disk_access: cfg!(target_os = "macos"),
        }),
        _ => {}
    }
    result
}

fn trash_size() -> (Option<u64>, usize) {
    #[cfg(target_os = "macos")]
    {
        let folder = fsutil::home().join(".Trash");
        match fs::read_dir(&folder) {
            Ok(entries) => {
                let items: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| !p.ends_with(".DS_Store")).collect();
                (Some(items.iter().map(|p| fsutil::size_of(p, None)).sum()), items.len())
            }
            Err(_) => (None, 0),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        match trash::os_limited::list() {
            Ok(items) => {
                let size = items
                    .iter()
                    .filter_map(|i| trash::os_limited::metadata(i).ok())
                    .map(|m| match m.size {
                        trash::TrashItemSize::Bytes(b) => b,
                        trash::TrashItemSize::Entries(_) => 0,
                    })
                    .sum();
                (Some(size), items.len())
            }
            Err(_) => (None, 0),
        }
    }
}

/// Docker's reclaimable space as tool-managed items. Volumes are deliberately left out: they hold real data.
pub fn docker_items() -> Result<Vec<Item>, Warning> {
    let docker = ["docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"].into_iter().find(|d| Command::new(d).arg("--version").output().is_ok());
    let Some(docker) = docker else { return Ok(Vec::new()) };
    let output = Command::new(docker).args(["system", "df", "--format", "{{json .}}"]).output();
    let Some(output) = output.ok().filter(|o| o.status.success()) else {
        return Err(Warning { message: "Docker is installed but not running, so its images and build cache weren't checked.".into(), needs_full_disk_access: false });
    };
    Ok(parse_docker_df(&String::from_utf8_lossy(&output.stdout), docker))
}

fn parse_docker_df(text: &str, docker: &str) -> Vec<Item> {
    let kinds = [
        ("Images", "Docker images not used by any container", "image prune --all --force", "Pulled again when needed."),
        ("Build Cache", "Docker build cache", "builder prune --all --force", "Next builds will be slower."),
        ("Containers", "Stopped Docker containers", "container prune --force", "Anything stored inside them is lost."),
    ];
    text.lines()
        .filter_map(|line| {
            let field = |key: &str| -> Option<String> {
                let start = line.find(&format!("\"{key}\":\""))? + key.len() + 4;
                Some(line[start..].split('"').next()?.to_string())
            };
            let (kind, name, args, note) = kinds.iter().find(|k| field("Type").as_deref() == Some(k.0))?;
            let size = parse_docker_size(&field("Reclaimable")?)?;
            (size > 0).then(|| Item {
                id: format!("docker:{kind}"),
                category: Category::DevJunk,
                name: name.to_string(),
                path: None,
                size,
                detail: format!("Removed with `docker {args}`. {note}"),
                recommended: false,
                action: Action::RunCommand { program: docker.to_string(), args: args.split(' ').map(String::from).collect() },
                group: None,
                keeper: false,
            })
        })
        .collect()
}

/// Docker's human sizes like "1.23GB (45%)" or "512kB". Docker uses powers of 1000.
pub fn parse_docker_size(text: &str) -> Option<u64> {
    let token = text.split_whitespace().next()?;
    for (suffix, multiplier) in [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1.0)] {
        if let Some(number) = token.strip_suffix(suffix) {
            return number.parse::<f64>().ok().map(|n| (n * multiplier) as u64);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_sizes() {
        assert_eq!(parse_docker_size("1.234GB (45%)"), Some(1_234_000_000));
        assert_eq!(parse_docker_size("512kB"), Some(512_000));
        assert_eq!(parse_docker_size("0B"), Some(0));
        assert_eq!(parse_docker_size("garbage"), None);
    }

    #[test]
    fn docker_df_output() {
        let text = r#"{"Active":"2","Reclaimable":"1.5GB (60%)","Size":"2.5GB","TotalCount":"5","Type":"Images"}
{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
{"Active":"1","Reclaimable":"300MB","Size":"1GB","TotalCount":"3","Type":"Local Volumes"}"#;
        let items = parse_docker_df(text, "docker");
        assert_eq!(items.len(), 1, "volumes and empty kinds are left out");
        assert_eq!(items[0].size, 1_500_000_000);
        assert!(items[0].action.is_permanent());
    }

    #[test]
    fn open_app_matching() {
        let open = OpenApps {
            names: OpenApps::parse("/Applications/Spotify.app/Contents/MacOS/Spotify\n/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n\"ollama.exe\",\"1234\",\"Console\"\nzsh"),
        };
        assert_eq!(open.matching("com.spotify.client").as_deref(), Some("Spotify"));
        assert_eq!(open.matching("Google").as_deref(), Some("Google Chrome"));
        assert_eq!(open.matching("ollama").as_deref(), Some("ollama"));
        assert_eq!(open.matching("com.example.zsh"), None, "short generic names don't match bundle-ID parts");
        assert_eq!(open.matching("Firefox"), None);
    }

    #[test]
    fn rules_expand_and_never_target_protected_places() {
        for rule in rules() {
            for location in locations(rule.location) {
                // A rule may point at a folder whose *children* are items, but whole-folder rules
                // must be removable, and child items must be too.
                if matches!(rule.mode, Mode::Whole) {
                    assert!(crate::remove::protection_reason(&location).is_none(), "{} is protected", location.display());
                }
            }
        }
    }
}

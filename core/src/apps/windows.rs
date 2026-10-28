//! Windows: programs from the "installed programs" registry, and Microsoft Store apps.

use super::{leftover, InstalledApp, Leftover, Removal, Source};
use crate::fsutil;
use crate::progress::Progress;
use crate::remove::Outcome;
use rayon::prelude::*;
use std::path::PathBuf;
use std::process::Command;
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ};
use winreg::RegKey;

const UNINSTALL: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
const UNINSTALL_32: &str = r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall";

pub fn list(progress: &Progress) -> Vec<InstalledApp> {
    let mut apps = registry_apps(progress);
    progress.set_phase("Listing Microsoft Store apps");
    apps.extend(store_apps());
    apps
}

#[derive(Debug, Default)]
pub(crate) struct Entry {
    pub key: String,
    pub name: String,
    pub version: Option<String>,
    pub publisher: Option<String>,
    pub location: Option<String>,
    pub icon: Option<String>,
    pub estimated_kb: u64,
    pub uninstall: Option<String>,
    pub system_component: bool,
    pub is_update: bool,
    pub no_remove: bool,
}

fn registry_apps(progress: &Progress) -> Vec<InstalledApp> {
    let mut entries: Vec<Entry> = Vec::new();
    for (hive, hive_name, path) in [
        (HKEY_LOCAL_MACHINE, "HKLM", UNINSTALL),
        (HKEY_LOCAL_MACHINE, "HKLM", UNINSTALL_32),
        (HKEY_CURRENT_USER, "HKCU", UNINSTALL),
    ] {
        let Ok(root) = RegKey::predef(hive).open_subkey_with_flags(path, KEY_READ) else { continue };
        for sub in root.enum_keys().flatten() {
            let Ok(key) = root.open_subkey_with_flags(&sub, KEY_READ) else { continue };
            let text = |name: &str| key.get_value::<String, _>(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
            let number = |name: &str| key.get_value::<u32, _>(name).ok().unwrap_or(0);
            let Some(name) = text("DisplayName") else { continue };
            entries.push(Entry {
                key: format!(r"{hive_name}\{path}\{sub}"),
                name,
                version: text("DisplayVersion"),
                publisher: text("Publisher"),
                location: text("InstallLocation"),
                icon: text("DisplayIcon"),
                estimated_kb: number("EstimatedSize") as u64,
                uninstall: text("UninstallString"),
                system_component: number("SystemComponent") == 1,
                is_update: text("ParentKeyName").is_some() || text("ReleaseType").is_some_and(|t| t.contains("Update") || t.contains("Hotfix")),
                no_remove: number("NoRemove") == 1,
            });
        }
    }
    // The same program can be registered in more than one place.
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    entries.dedup_by(|a, b| a.name == b.name && a.version == b.version);
    progress.set_phase(format!("Measuring {} programs", entries.len()));
    entries.into_par_iter().filter(|e| !e.system_component && !e.is_update && e.uninstall.is_some()).map(app_from_entry).collect()
}

fn app_from_entry(entry: Entry) -> InstalledApp {
    let location = entry.location.as_deref().map(PathBuf::from).filter(|p| p.is_dir());
    let size = match (&location, entry.estimated_kb) {
        (_, kb) if kb > 0 => kb * 1024,
        (Some(dir), _) => fsutil::size_of(dir, None),
        _ => 0,
    };
    let icon = entry.icon.as_deref().map(|i| PathBuf::from(i.split(',').next().unwrap_or(i).trim_matches('"')));
    InstalledApp {
        id: entry.key.clone(),
        identifier: None,
        version: entry.version.clone(),
        publisher: entry.publisher.clone(),
        location: location.clone(),
        icon: icon.filter(|p| p.exists()),
        source: Source::WindowsInstaller,
        size,
        leftovers: appdata_leftovers(&entry.name, entry.publisher.as_deref()),
        last_used: location.as_deref().and_then(|l| super::unix_time(l, true)),
        protection: entry.no_remove.then(|| "Its installer doesn't allow removing it.".to_string()),
        note: None,
        removal: entry.uninstall.as_deref().map(|u| Removal::Uninstaller { command: uninstall_command(u) }),
        // Uninstallers that need it show their own UAC prompt.
        needs_password: false,
        name: entry.name,
    }
}

/// MSI entries register "MsiExec.exe /I{GUID}" (which repairs); /X uninstalls.
pub(crate) fn uninstall_command(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    if lower.starts_with("msiexec") {
        if let Some(i) = lower.find("/i") {
            let mut fixed = raw.to_string();
            fixed.replace_range(i..i + 2, "/X");
            return fixed;
        }
    }
    raw.to_string()
}

/// Folders programs commonly leave in AppData, matched by exact name.
fn appdata_leftovers(name: &str, publisher: Option<&str>) -> Vec<Leftover> {
    let mut found = Vec::new();
    for (base, kind) in [(dirs::data_dir(), "App data"), (dirs::data_local_dir(), "Local app data")] {
        let Some(base) = base else { continue };
        let mut candidates = vec![base.join(name)];
        if let Some(publisher) = publisher.filter(|p| super::usable_name(p)) {
            candidates.push(base.join(publisher).join(name));
        }
        for path in candidates {
            if super::usable_name(name) && path.is_dir() {
                found.push(leftover(path, kind, true));
            }
        }
    }
    found
}

/// (program, arguments) from an uninstall string, which may or may not quote the program path.
pub(crate) fn split_command(command: &str) -> (String, String) {
    let command = command.trim();
    if let Some(rest) = command.strip_prefix('"') {
        if let Some(end) = rest.find('"') {
            return (rest[..end].to_string(), rest[end + 1..].trim().to_string());
        }
    }
    let lower = command.to_ascii_lowercase();
    if let Some(i) = lower.find(".exe") {
        return (command[..i + 4].to_string(), command[i + 4..].trim().to_string());
    }
    match command.split_once(' ') {
        Some((program, args)) => (program.to_string(), args.trim().to_string()),
        None => (command.to_string(), String::new()),
    }
}

/// Runs the program's own uninstaller through the shell (so Windows can show its UAC prompt),
/// waits for it, then checks the program is really gone.
pub fn run_uninstaller(app: &InstalledApp, command: &str) -> Outcome {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{WaitForSingleObject, INFINITE};
    use windows_sys::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

    let wide = |s: &str| -> Vec<u16> { std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect() };
    let (program, args) = split_command(command);
    let (program_w, args_w, verb_w) = (wide(&program), wide(&args), wide("open"));
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = verb_w.as_ptr();
    info.lpFile = program_w.as_ptr();
    info.lpParameters = args_w.as_ptr();
    info.nShow = SW_SHOWNORMAL;

    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        return Outcome::failed(&app.name, "Couldn't start its uninstaller (it may have been cancelled at the permission prompt).");
    }
    if !info.hProcess.is_null() {
        unsafe {
            WaitForSingleObject(info.hProcess, INFINITE);
            CloseHandle(info.hProcess);
        }
    }
    if still_registered(&app.id) {
        Outcome::failed(&app.name, "The uninstaller closed but the program is still installed. It may have been cancelled, or it may finish after a restart.")
    } else {
        Outcome::ok(&app.name)
    }
}

fn still_registered(key: &str) -> bool {
    let (hive, path) = match key.split_once('\\') {
        Some(("HKLM", path)) => (HKEY_LOCAL_MACHINE, path),
        Some(("HKCU", path)) => (HKEY_CURRENT_USER, path),
        _ => return false,
    };
    RegKey::predef(hive).open_subkey_with_flags(path, KEY_READ).is_ok()
}

// MARK: - Microsoft Store

fn store_apps() -> Vec<InstalledApp> {
    let script = "Get-AppxPackage | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' } | \
                  Select-Object Name,PackageFullName,PackageFamilyName,InstallLocation,Version,Publisher | ConvertTo-Json -Compress";
    let Ok(output) = Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", script]).output() else { return Vec::new() };
    parse_store_apps(&String::from_utf8_lossy(&output.stdout))
}

pub(crate) fn parse_store_apps(json: &str) -> Vec<InstalledApp> {
    let value: serde_json::Value = serde_json::from_str(json.trim()).unwrap_or(serde_json::Value::Null);
    let packages = match value {
        serde_json::Value::Array(items) => items,
        serde_json::Value::Object(_) => vec![value],
        _ => Vec::new(),
    };
    packages
        .into_iter()
        .filter_map(|p| {
            let field = |k: &str| p.get(k).and_then(|v| v.as_str()).map(String::from);
            let full_name = field("PackageFullName")?;
            // The package name ends up in a PowerShell command, so only allow the characters package names use.
            if !full_name.chars().all(|c| c.is_ascii_alphanumeric() || "._-~".contains(c)) {
                return None;
            }
            let location = field("InstallLocation").map(PathBuf::from);
            Some(InstalledApp {
                id: format!("appx:{full_name}"),
                identifier: field("PackageFamilyName"),
                name: friendly_store_name(&field("Name")?),
                version: field("Version"),
                publisher: field("Publisher").map(|p| p.split(',').next().unwrap_or(&p).trim_start_matches("CN=").to_string()),
                size: location.as_deref().map(|l| fsutil::size_of(l, None)).unwrap_or(0),
                location,
                icon: None,
                source: Source::WindowsStore,
                // Windows removes a Store app's data folder together with the app.
                leftovers: Vec::new(),
                last_used: None,
                protection: None,
                note: None,
                removal: Some(Removal::Command {
                    program: "powershell".into(),
                    args: vec!["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), format!("Remove-AppxPackage -Package {full_name}")],
                    admin: false,
                }),
                needs_password: false,
            })
        })
        .collect()
}

/// "SpotifyAB.SpotifyMusic" -> "Spotify Music".
pub(crate) fn friendly_store_name(name: &str) -> String {
    let last = name.rsplit('.').next().unwrap_or(name);
    let mut out = String::new();
    for (i, c) in last.chars().enumerate() {
        if i > 0 && c.is_uppercase() && !out.ends_with(' ') && last.chars().nth(i - 1).is_some_and(|p| p.is_lowercase()) {
            out.push(' ');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn msi_repair_becomes_remove() {
        assert_eq!(uninstall_command("MsiExec.exe /I{1234-ABCD}"), "MsiExec.exe /X{1234-ABCD}");
        assert_eq!(uninstall_command("\"C:\\Program Files\\App\\uninst.exe\""), "\"C:\\Program Files\\App\\uninst.exe\"");
    }

    #[test]
    fn splits_quoted_and_unquoted_commands() {
        assert_eq!(split_command("\"C:\\Program Files\\A\\u.exe\" /S"), ("C:\\Program Files\\A\\u.exe".into(), "/S".into()));
        assert_eq!(split_command("C:\\Program Files\\B\\uninstall.exe --mode x"), ("C:\\Program Files\\B\\uninstall.exe".into(), "--mode x".into()));
        assert_eq!(split_command("MsiExec.exe /X{G}"), ("MsiExec.exe".into(), "/X{G}".into()));
    }

    #[test]
    fn store_apps_from_powershell_json() {
        let json = r#"[{"Name":"SpotifyAB.SpotifyMusic","PackageFullName":"SpotifyAB.SpotifyMusic_1.2.3.0_x64__zpdnekdrzrea0","PackageFamilyName":"SpotifyAB.SpotifyMusic_zpdnekdrzrea0","InstallLocation":null,"Version":"1.2.3.0","Publisher":"CN=Spotify AB, O=Spotify AB"},
                       {"Name":"Evil","PackageFullName":"x; Remove-Item C:\\","PackageFamilyName":"e","InstallLocation":null,"Version":"1","Publisher":"CN=E"}]"#;
        let apps = parse_store_apps(json);
        assert_eq!(apps.len(), 1, "package names with unexpected characters are dropped");
        assert_eq!(apps[0].name, "Spotify Music");
        assert_eq!(apps[0].publisher.as_deref(), Some("Spotify AB"));
    }
}

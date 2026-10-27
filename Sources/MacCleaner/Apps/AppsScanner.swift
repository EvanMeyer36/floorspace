import AppKit
import CoreServices
import Foundation

/// A file or folder an app left in ~/Library (caches, settings, saved data).
struct RelatedItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// Nil when macOS wouldn't let us measure it.
    let size: Int64?
    let kind: String
    /// Found by the app's name rather than its bundle ID, so slightly less certain.
    let matchedByName: Bool
    var id: String { url.path }
}

struct InstalledApp: Identifiable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let appSize: Int64
    let related: [RelatedItem]
    let lastUsed: Date?
    let isAppStore: Bool
    /// Why this app can't be uninstalled here, if it can't.
    let protectionReason: String?
    /// The app is only a Steam launcher; the game itself lives in the Steam library.
    let isSteamShortcut: Bool
    /// Owned by the system or in a folder you can't write to (most App Store apps, some installers):
    /// removing it goes through Finder, which asks for an administrator password.
    let needsPassword: Bool

    var id: String { url.path }
    var relatedSize: Int64 { related.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { appSize + relatedSize }
}

/// Finds installed apps and the files each one keeps in ~/Library.
enum AppsScanner {
    static let appFolders = [URL(fileURLWithPath: "/Applications"), DiskUtils.home.appendingPathComponent("Applications")]

    /// - Parameter includeOtherAppsData: also look in ~/Library/Containers and Group Containers.
    ///   macOS asks the user before an app can read other apps' data there.
    static func scan(includeOtherAppsData: Bool = true, progress: ScanProgress) -> [InstalledApp] {
        progress.setPhase("Finding apps\u{2026}")
        let urls = findApps()
        let library = LibraryIndex(includeOtherAppsData: includeOtherAppsData)

        var apps = [InstalledApp?](repeating: nil, count: urls.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let app = inspect(urls[index], library: library)
            lock.withLock {
                apps[index] = app
                done += 1
                progress.setPhase("Measuring apps (\(done) of \(urls.count))")
            }
            progress.add(1, currentPath: urls[index].path)
        }
        return apps.compactMap { $0 }.sorted { $0.totalSize > $1.totalSize }
    }

    /// Apps directly in the app folders, plus one level of subfolders (e.g. /Applications/Utilities).
    private static func findApps() -> [URL] {
        var found: [URL] = []
        for folder in appFolders {
            for url in DiskUtils.contents(of: folder).urls {
                if url.pathExtension == "app" {
                    found.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                            .map({ $0.isDirectory == true && $0.isPackage != true }) == true {
                    found += DiskUtils.contents(of: url).urls.filter { $0.pathExtension == "app" }
                }
            }
        }
        return found
    }

    private static func inspect(_ url: URL, library: LibraryIndex) -> InstalledApp? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let bundleID = bundle?.bundleIdentifier
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let executable = (info["CFBundleExecutable"] as? String).map { url.appendingPathComponent("Contents/MacOS/\($0)") }
        let isSteamShortcut = executable.map(isSteamLauncher) ?? false

        return InstalledApp(
            url: url,
            name: name,
            bundleID: bundleID,
            version: version,
            appSize: DiskUtils.size(of: url),
            // A shortcut's name matches the game's own folders (often its save files), which aren't the shortcut's to remove.
            related: isSteamShortcut ? [] : library.relatedItems(bundleID: bundleID, appName: name),
            lastUsed: lastUsedDate(url, executable: executable),
            isAppStore: DiskUtils.exists(url.appendingPathComponent("Contents/_MASReceipt")),
            protectionReason: protectionReason(url, bundleID: bundleID),
            isSteamShortcut: isSteamShortcut,
            needsPassword: !canMoveWithoutPassword(url)
        )
    }

    /// When the app was last opened. Spotlight often has no record (it misses apps opened
    /// from the Dock or by other apps), so the time the app's program was last read is used too.
    private static func lastUsedDate(_ url: URL, executable: URL?) -> Date? {
        let spotlight = MDItemCreateWithURL(nil, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let programRead = executable.flatMap { try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }
        return [spotlight, programRead].compactMap { $0 }.max()
    }

    /// Moving a folder needs write access to the folder holding it and, for an app bundle (a folder),
    /// to the bundle itself.
    private static func canMoveWithoutPassword(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Steam's "create desktop shortcut" makes a tiny .app whose program is a script running steam://run/<id>.
    private static func isSteamLauncher(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains("steam://run/")
    }

    private static func protectionReason(_ url: URL, bundleID: String?) -> String? {
        let isSelf = url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
            || (bundleID != nil && bundleID == Bundle.main.bundleIdentifier)
        if isSelf {
            return "This is Mac Cleaner itself."
        }
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            let destination = url.resolvingSymlinksInPath()
            if destination.path.hasPrefix("/System/") {
                return "Part of macOS, which protects it from being removed."
            }
            return "Only a link to the app at \(Format.tildePath(destination)). Uninstall it from there."
        }
        // Built-in apps live on the read-only system volume.
        if values?.volumeIsReadOnly == true {
            return "Part of macOS, which protects it from being removed."
        }
        return nil
    }
}

/// One listing of each ~/Library folder that apps leave files in, shared by every app lookup.
private struct LibraryIndex {
    private struct Location {
        let folder: String
        let kind: String
        let names: Set<String>
    }

    private let lib = DiskUtils.library
    private let locations: [Location]
    private let includeOtherAppsData: Bool

    init(includeOtherAppsData: Bool) {
        self.includeOtherAppsData = includeOtherAppsData
        var folders: [(String, String)] = [
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
        ]
        if includeOtherAppsData {
            folders += [("Containers", "Sandboxed app data"), ("Group Containers", "Shared app data")]
        }
        let lib = DiskUtils.library
        locations = folders.map { folder, kind in
            let names = DiskUtils.contents(of: lib.appendingPathComponent(folder), includingHidden: true).urls.map(\.lastPathComponent)
            return Location(folder: folder, kind: kind, names: Set(names))
        }
    }

    func relatedItems(bundleID: String?, appName: String) -> [RelatedItem] {
        var items: [RelatedItem] = []
        var seen = Set<String>()

        func add(_ folder: String, _ name: String, kind: String, byName: Bool) {
            let url = lib.appendingPathComponent(folder).appendingPathComponent(name)
            guard seen.insert(url.path).inserted else { return }
            items.append(RelatedItem(url: url, size: measure(url), kind: kind, matchedByName: byName))
        }

        for location in locations {
            for name in location.names {
                if let bundleID, Self.belongs(name, to: bundleID, in: location.folder) {
                    add(location.folder, name, kind: location.kind, byName: false)
                } else if Self.nameMatchFolders.contains(location.folder), Self.isUsableName(appName), name == appName {
                    add(location.folder, name, kind: location.kind, byName: true)
                }
            }
        }
        return items.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    /// Only these folders commonly use the app's plain name instead of its bundle ID.
    private static let nameMatchFolders: Set<String> = ["Application Support", "Caches", "Logs"]

    /// Names too generic to safely match a folder on (a folder called "Music" isn't necessarily Music.app's).
    private static func isUsableName(_ name: String) -> Bool {
        name.count >= 4 && !["Music", "Photos", "Notes", "Books", "Maps", "Mail", "News", "Home", "Clock", "Games", "Steam Helper"].contains(name)
    }

    /// Exact bundle-ID matches only, so one app's uninstall never takes another app's files.
    private static func belongs(_ name: String, to bundleID: String, in folder: String) -> Bool {
        switch folder {
        case "Preferences", "Preferences/ByHost":
            return name == bundleID + ".plist" || (name.hasPrefix(bundleID + ".") && name.hasSuffix(".plist"))
        case "Saved Application State":
            return name == bundleID + ".savedState"
        case "Cookies":
            return name == bundleID + ".binarycookies"
        case "HTTPStorages":
            return name == bundleID || name == bundleID + ".binarycookies"
        case "Group Containers":
            // Team-prefixed, e.g. "ABCDE12345.com.example.app". Shared suite containers (like Office's) don't match.
            return name == bundleID || name.hasSuffix("." + bundleID) || name == "group." + bundleID
        case "LaunchAgents":
            return name == bundleID + ".plist" || (name.hasPrefix(bundleID + ".") && name.hasSuffix(".plist"))
        default:
            return name == bundleID
        }
    }

    private func measure(_ url: URL) -> Int64? {
        let size = DiskUtils.size(of: url)
        if size == 0, DiskUtils.contents(of: url).denied { return nil }
        return size
    }
}

import AppKit
import Foundation

/// Entry point for every category's scan. Each scan runs synchronously on a
/// background task, reports into `progress`, and stops early when the task is cancelled.
enum Scanners {
    static func scan(_ category: ScanCategory, settings: ScanSettings, progress: ScanProgress) -> ScanResult {
        switch category {
        case .caches: return caches(progress: progress)
        case .devJunk: return DevJunkScanner.scan(searchFolder: settings.searchFolder, progress: progress)
        case .appleData: return appleData(progress: progress)
        case .downloads: return downloads(olderThanDays: settings.downloadsAgeDays, progress: progress)
        case .largeFiles: return SearchScanners.largeFiles(in: settings.searchFolder, minMB: settings.largeFileMinMB, progress: progress)
        case .duplicates: return SearchScanners.duplicates(in: settings.searchFolder, progress: progress)
        case .trash: return trash(progress: progress)
        }
    }

    // MARK: - Caches & logs

    private static func caches(progress: ScanProgress) -> ScanResult {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []
        let ownedByDevJunk = DevJunkLocations.pathsInsideLibraryCaches
        let minimumSize: Int64 = 1_000_000 // hide the long tail of tiny folders

        for (folder, isLogs) in [("Caches", false), ("Logs", true)] {
            let dir = DiskUtils.library.appendingPathComponent(folder)
            progress.setPhase("Measuring ~/Library/\(folder)")
            let (urls, denied) = DiskUtils.contents(of: dir)
            if denied {
                warnings.append(ScanWarning(message: "Couldn't read ~/Library/\(folder).", settingsPane: .fullDiskAccess))
            }

            for url in urls where !ownedByDevJunk.contains(url.path) {
                if Task.isCancelled { break }
                let size = DiskUtils.size(of: url, progress: progress)
                guard size >= minimumSize else { continue }

                let folderName = url.lastPathComponent
                let isAppleOwned = folderName.hasPrefix("com.apple.")
                let detail: String
                if isLogs {
                    detail = "Log files"
                } else if isAppleOwned {
                    detail = "macOS system cache. Often in use and recreated right away."
                } else {
                    detail = "Cache \u{2022} the app rebuilds it"
                }
                items.append(ScanItem(
                    path: url,
                    size: size,
                    category: .caches,
                    name: appName(forBundleID: folderName) ?? folderName,
                    detail: detail,
                    isRecommended: isLogs || !isAppleOwned
                ))
            }
        }
        return ScanResult(category: .caches, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }

    /// Cache folders are usually named after a bundle ID; show the app's real name when we can find it.
    private static func appName(forBundleID bundleID: String) -> String? {
        guard bundleID.contains("."),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Device backups, iOS updates, Mail attachments

    private static func appleData(progress: ScanProgress) -> ScanResult {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []
        let lib = DiskUtils.library

        progress.setPhase("Looking for iPhone & iPad backups")
        let backups = DiskUtils.contents(of: lib.appendingPathComponent("Application Support/MobileSync/Backup"))
        if backups.denied {
            warnings.append(ScanWarning(message: "iPhone/iPad backups are protected. Give Mac Cleaner Full Disk Access to check them.", settingsPane: .fullDiskAccess))
        }
        for url in backups.urls {
            if Task.isCancelled { break }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String ?? "Unknown device"
            var detail = "Device backup. Deleting it means you can't restore that device from this Mac."
            if let date = info?["Last Backup Date"] as? Date {
                detail = "Backed up \(date.formatted(date: .abbreviated, time: .omitted)). " + detail
            }
            items.append(ScanItem(path: url, size: DiskUtils.size(of: url, progress: progress), category: .appleData,
                                  name: "Backup of \(device)", detail: detail))
        }

        progress.setPhase("Looking for downloaded iOS updates")
        for folder in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            let url = lib.appendingPathComponent("iTunes/\(folder)")
            let size = DiskUtils.size(of: url, progress: progress)
            guard size > 0 else { continue }
            items.append(ScanItem(path: url, size: size, category: .appleData,
                                  detail: "Downloaded software updates. Downloaded again if needed.", isRecommended: true))
        }

        progress.setPhase("Measuring Mail attachments")
        let mailLocations = [
            lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads"),
            lib.appendingPathComponent("Mail Downloads"),
        ]
        for url in mailLocations where DiskUtils.exists(url) {
            let size = DiskUtils.size(of: url, progress: progress)
            guard size > 0 else { continue }
            items.append(ScanItem(path: url, size: size, category: .appleData, name: "Mail attachments you opened",
                                  detail: "Copies saved when you opened attachments. The originals stay in your email.",
                                  isRecommended: true))
        }

        return ScanResult(category: .appleData, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }

    // MARK: - Downloads

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso", "tar", "gz", "tgz", "7z", "rar"]

    private static func downloads(olderThanDays: Int, progress: ScanProgress) -> ScanResult {
        progress.setPhase("Looking through ~/Downloads")
        let (urls, denied) = DiskUtils.contents(of: DiskUtils.home.appendingPathComponent("Downloads"))
        var warnings: [ScanWarning] = []
        if denied {
            warnings.append(ScanWarning(message: "macOS didn't allow access to your Downloads folder.", settingsPane: .filesAndFolders))
        }

        var items: [ScanItem] = []
        for url in urls {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
            guard let date = values?.addedToDirectoryDate ?? values?.contentModificationDate,
                  let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day,
                  days >= olderThanDays else { continue }

            let isArchiveOrInstaller = installerExtensions.contains(url.pathExtension.lowercased())
            let detail = isArchiveOrInstaller
                ? "Installer or archive, downloaded \(Format.age(days: days)). Usually already installed/extracted."
                : "Downloaded \(Format.age(days: days))"
            items.append(ScanItem(path: url, size: DiskUtils.size(of: url, progress: progress), category: .downloads,
                                  detail: detail, isRecommended: isArchiveOrInstaller))
        }
        return ScanResult(category: .downloads, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }

    // MARK: - Trash

    private static func trash(progress: ScanProgress) -> ScanResult {
        progress.setPhase("Measuring the Trash")
        let (urls, denied) = DiskUtils.contents(of: DiskUtils.home.appendingPathComponent(".Trash"))
        var warnings: [ScanWarning] = []
        if denied {
            warnings.append(ScanWarning(message: "macOS protects the Trash folder. Give Mac Cleaner Full Disk Access to see what's in it.", settingsPane: .fullDiskAccess))
        }

        let items = urls.compactMap { url -> ScanItem? in
            if Task.isCancelled { return nil }
            let detail = DiskUtils.daysSinceModified(url).map { "Last changed \(Format.age(days: $0))" }
            return ScanItem(path: url, size: DiskUtils.size(of: url, progress: progress), category: .trash,
                            detail: detail, action: .deletePermanently)
        }
        return ScanResult(category: .trash, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }
}

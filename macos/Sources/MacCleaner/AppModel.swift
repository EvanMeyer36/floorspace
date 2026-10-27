import AppKit
import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case explorer
    case apps
    case category(ScanCategory)
}

struct DiskSpace {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }

    static func current() -> DiskSpace {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        return DiskSpace(total: Int64(values?.volumeTotalCapacity ?? 0),
                         free: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sidebarSelection: SidebarItem? = .overview
    @Published private(set) var results: [ScanCategory: ScanResult] = [:]
    @Published var selection: [ScanCategory: Set<String>] = [:]
    /// Categories currently scanning, with their live progress.
    @Published private(set) var activeScans: [ScanCategory: ScanProgress] = [:]
    @Published private(set) var disk = DiskSpace.current()
    @Published private(set) var isCleaning = false
    @Published var cleanReport: CleanReport?
    @Published var settings: ScanSettings {
        didSet { saveSettings() }
    }

    private var scanTasks: [ScanCategory: Task<ScanResult?, Never>] = [:]

    init() {
        let defaults = UserDefaults.standard
        var settings = ScanSettings()
        if defaults.object(forKey: "downloadsAgeDays") != nil { settings.downloadsAgeDays = defaults.integer(forKey: "downloadsAgeDays") }
        if defaults.object(forKey: "largeFileMinMB") != nil { settings.largeFileMinMB = defaults.integer(forKey: "largeFileMinMB") }
        if let path = defaults.string(forKey: "searchFolder"), DiskUtils.exists(URL(fileURLWithPath: path)) {
            settings.searchFolder = URL(fileURLWithPath: path)
        }
        self.settings = settings
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.downloadsAgeDays, forKey: "downloadsAgeDays")
        defaults.set(settings.largeFileMinMB, forKey: "largeFileMinMB")
        defaults.set(settings.searchFolder.path, forKey: "searchFolder")
    }

    // MARK: - Scanning

    var isScanning: Bool { !activeScans.isEmpty }

    func startScan(_ category: ScanCategory) {
        guard activeScans[category] == nil else { return }
        let progress = ScanProgress()
        let settings = settings
        let task = Task.detached(priority: .userInitiated) { () -> ScanResult? in
            let result = Scanners.scan(category, settings: settings, progress: progress)
            return Task.isCancelled ? nil : result
        }
        activeScans[category] = progress
        scanTasks[category] = task

        Task {
            let result = await task.value
            guard activeScans[category] === progress else { return }
            activeScans[category] = nil
            scanTasks[category] = nil
            if let result {
                results[category] = result
                selection[category] = Set(result.items.filter(\.isRecommended).map(\.id))
            }
        }
    }

    func cancelScan(_ category: ScanCategory) {
        scanTasks[category]?.cancel()
    }

    func smartScan() {
        disk = DiskSpace.current()
        ScanCategory.allCases.forEach(startScan)
    }

    func cancelAllScans() {
        scanTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Selection

    func items(for category: ScanCategory) -> [ScanItem] {
        results[category]?.items ?? []
    }

    func isSelected(_ item: ScanItem) -> Bool {
        selection[item.category]?.contains(item.id) ?? false
    }

    func setSelected(_ item: ScanItem, _ selected: Bool) {
        var ids = selection[item.category] ?? []
        if selected { ids.insert(item.id) } else { ids.remove(item.id) }
        selection[item.category] = ids
    }

    func select(_ category: ScanCategory, where predicate: (ScanItem) -> Bool) {
        selection[category] = Set(items(for: category).filter(predicate).map(\.id))
    }

    func selectedItems(in category: ScanCategory) -> [ScanItem] {
        let ids = selection[category] ?? []
        return items(for: category).filter { ids.contains($0.id) }
    }

    var allSelectedItems: [ScanItem] {
        ScanCategory.allCases.flatMap(selectedItems(in:))
    }

    // MARK: - Totals (de-duplicated across categories)

    /// Sum of item sizes, counting each path once and skipping items inside an already-counted folder.
    func uniqueSize(_ items: [ScanItem]) -> Int64 {
        CleanerEngine.removingNested(items).reduce(0) { $0 + $1.size }
    }

    var totalReclaimable: Int64 {
        uniqueSize(results.values.flatMap { $0.items.filter { !$0.isSuggestedKeeper } })
    }

    var totalRecommended: Int64 {
        uniqueSize(results.values.flatMap { $0.items.filter(\.isRecommended) })
    }

    // MARK: - Cleaning

    func clean(_ items: [ScanItem]) {
        guard !isCleaning, !items.isEmpty else { return }
        isCleaning = true

        Task {
            let outcomes = await Task.detached(priority: .userInitiated) { CleanerEngine.clean(items) }.value
            isCleaning = false
            apply(outcomes)
        }
    }

    private func apply(_ outcomes: [CleanOutcome]) {
        let succeeded = outcomes.filter(\.succeeded)
        let moved = succeeded.filter { $0.item.action == .moveToTrash }
        let permanent = succeeded.filter { $0.item.action.isPermanent }

        // Drop cleaned items everywhere they appeared, including copies listed under other categories.
        let cleanedIDs = Set(succeeded.map(\.item.id))
        for category in results.keys {
            results[category]?.items.removeAll { item in
                cleanedIDs.contains(item.id) || (item.path.map { !DiskUtils.exists($0) } ?? false)
            }
            dropLonelyDuplicates(in: category)
            let remaining = Set(items(for: category).map(\.id))
            selection[category] = selection[category]?.intersection(remaining)
        }

        cleanReport = CleanReport(
            movedToTrash: moved.reduce(0) { $0 + $1.item.size },
            movedCount: moved.count,
            permanentlyFreed: permanent.reduce(0) { $0 + $1.item.size },
            permanentCount: permanent.count,
            failures: outcomes.filter { !$0.succeeded }
        )

        if !succeeded.isEmpty { startScan(.trash) }
        disk = DiskSpace.current()
    }

    /// A duplicate group with one file left isn't a duplicate any more.
    private func dropLonelyDuplicates(in category: ScanCategory) {
        guard category == .duplicates, let items = results[category]?.items else { return }
        let counts = Dictionary(grouping: items.compactMap(\.duplicateGroup), by: { $0 }).mapValues(\.count)
        results[category]?.items.removeAll { ($0.duplicateGroup.flatMap { counts[$0] } ?? 2) < 2 }
    }

    func refreshDisk() {
        disk = DiskSpace.current()
    }

    // MARK: - Finder

    func revealInFinder(_ item: ScanItem) {
        guard let path = item.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    func openSettings(_ pane: ScanWarning.SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}

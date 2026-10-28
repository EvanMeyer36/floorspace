import AppKit
import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case explorer
    case apps
    case category(ScanCategory)
}

/// What a cleanup did, for the summary shown afterwards.
struct CleanReport: Identifiable {
    let id = UUID()
    let movedToTrash: Int64
    let movedCount: Int
    let permanentlyFreed: Int64
    let permanentCount: Int
    let failures: [Outcome]
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

    /// Progress keys whose scans the user stopped; their (partial) results are dropped.
    private var stopped: Set<String> = []

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

    // MARK: - Scanning (in the engine)

    var isScanning: Bool { !activeScans.isEmpty }

    /// Scans one category.
    func startScan(_ category: ScanCategory) {
        guard activeScans[category] == nil else { return }
        let progress = ScanProgress(kind: "junk:\(category.rawValue)")
        activeScans[category] = progress
        stopped.remove(progress.kind)
        var categoryArgs = settings.engineArgs
        categoryArgs["category"] = category.rawValue
        let args = categoryArgs
        Task {
            let result = try? await Engine.background { try Engine.call("junk_scan_category", args, as: EngineCategoryResult.self) }
            activeScans[category] = nil
            if let result, !stopped.contains(progress.kind) { store(ScanResult(result)) }
        }
    }

    /// Scans every category in one engine call, which walks the search folder only once.
    func smartScan() {
        guard !isScanning else { return }
        disk = DiskSpace.current()
        let progress = ScanProgress(kind: "junk")
        stopped.remove(progress.kind)
        for category in ScanCategory.allCases { activeScans[category] = progress }
        let args = settings.engineArgs
        Task {
            let results = try? await Engine.background { try Engine.call("junk_scan", args, as: [EngineCategoryResult].self) }
            activeScans = [:]
            if let results, !stopped.contains(progress.kind) { results.map(ScanResult.init).forEach(store) }
        }
    }

    private func store(_ result: ScanResult) {
        results[result.category] = result
        selection[result.category] = Set(result.items.filter(\.isRecommended).map(\.id))
    }

    func cancelScan(_ category: ScanCategory) {
        guard let progress = activeScans[category] else { return }
        stopped.insert(progress.kind)
        progress.cancel()
    }

    func cancelAllScans() {
        for progress in Set(activeScans.values.map(\.kind)) {
            stopped.insert(progress)
            Engine.cancel(progress)
        }
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
        items.outermost.reduce(0) { $0 + $1.size }
    }

    var totalReclaimable: Int64 {
        uniqueSize(results.values.flatMap { $0.items.filter { !$0.isSuggestedKeeper } })
    }

    var totalRecommended: Int64 {
        uniqueSize(results.values.flatMap { $0.items.filter(\.isRecommended) })
    }

    // MARK: - Cleaning

    /// Cleans the items in the engine (by ID from its latest results) and updates the lists.
    func clean(_ items: [ScanItem]) {
        guard !isCleaning, !items.isEmpty else { return }
        isCleaning = true
        let ids = items.map(\.id)
        Task {
            let result = try? await Engine.background { try Engine.call("clean", ["itemIds": ids], as: EngineCleanResult.self) }
            isCleaning = false
            apply(result, requested: items)
        }
    }

    private func apply(_ result: EngineCleanResult?, requested: [ScanItem]) {
        let cleanedIDs = Set(result?.cleaned ?? [])
        let cleaned = requested.filter { cleanedIDs.contains($0.id) }

        // Drop cleaned items everywhere they appeared, including copies listed under other categories.
        for category in results.keys {
            results[category]?.items.removeAll { item in
                cleanedIDs.contains(item.id) || (item.path.map { !DiskUtils.exists($0) } ?? false)
            }
            dropLonelyDuplicates(in: category)
            let remaining = Set(items(for: category).map(\.id))
            selection[category] = selection[category]?.intersection(remaining)
        }

        cleanReport = CleanReport(
            movedToTrash: result?.freedToTrash ?? 0,
            movedCount: cleaned.filter { !$0.action.isPermanent }.count,
            permanentlyFreed: result?.freedPermanently ?? 0,
            permanentCount: cleaned.filter(\.action.isPermanent).count,
            failures: result?.failures ?? [Outcome(target: "Floorspace", ok: false, message: "The engine couldn't run the cleanup.")]
        )

        if !cleaned.isEmpty { startScan(.trash) }
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

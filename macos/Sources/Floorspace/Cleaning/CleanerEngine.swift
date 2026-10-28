import Foundation

struct CleanOutcome: Sendable {
    let item: ScanItem
    let errorMessage: String?
    var succeeded: Bool { errorMessage == nil }
}

struct CleanReport: Identifiable {
    let id = UUID()
    let movedToTrash: Int64
    let movedCount: Int
    let permanentlyFreed: Int64
    let permanentCount: Int
    let failures: [CleanOutcome]
}

enum CleanerEngine {
    /// Removes each item according to its action. Runs on a background thread.
    static func clean(_ items: [ScanItem]) -> [CleanOutcome] {
        removingNested(items).map { item in
            do {
                switch item.action {
                case .moveToTrash:
                    try FileManager.default.trashItem(at: item.path!, resultingItemURL: nil)
                case .deletePermanently:
                    try FileManager.default.removeItem(at: item.path!)
                case .runCommand(let executable, let arguments):
                    guard let result = Shell.run(executable, arguments, timeout: 600) else {
                        return CleanOutcome(item: item, errorMessage: "Couldn't run \(executable)")
                    }
                    if !result.succeeded {
                        let lastLine = result.output.split(separator: "\n").last.map(String.init) ?? "exit code \(result.status)"
                        return CleanOutcome(item: item, errorMessage: lastLine)
                    }
                }
                return CleanOutcome(item: item, errorMessage: nil)
            } catch {
                return CleanOutcome(item: item, errorMessage: error.localizedDescription)
            }
        }
    }

    /// The same files can show up in more than one category (a big file can also be a
    /// duplicate, a node_modules folder can contain a large file). Keep each path once,
    /// and drop anything inside a folder that's already being removed.
    static func removingNested(_ items: [ScanItem]) -> [ScanItem] {
        var kept: [ScanItem] = []
        var keptPaths = Set<String>()
        for item in items.sorted(by: { ($0.path?.path.count ?? 0) < ($1.path?.path.count ?? 0) }) {
            guard let path = item.path?.standardizedFileURL.path else {
                if !kept.contains(where: { $0.id == item.id }) { kept.append(item) }
                continue
            }
            var ancestor = (path as NSString).deletingLastPathComponent
            var isNested = keptPaths.contains(path)
            while !isNested && ancestor != "/" && !ancestor.isEmpty {
                isNested = keptPaths.contains(ancestor)
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            guard !isNested else { continue }
            keptPaths.insert(path)
            kept.append(item)
        }
        return kept
    }
}

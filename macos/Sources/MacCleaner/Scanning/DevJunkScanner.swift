import Foundation

enum DevJunkScanner {
    /// node_modules folders untouched for this long are pre-selected.
    static let staleProjectDays = 30

    static func scan(searchFolder: URL, progress: ScanProgress) -> ScanResult {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []

        for location in DevJunkLocations.all {
            if Task.isCancelled { break }
            progress.setPhase("Measuring \(location.name)")
            let size = DiskUtils.size(of: location.path, progress: progress)
            guard size > 0 else { continue }
            items.append(ScanItem(path: location.path, size: size, category: .devJunk, name: location.name,
                                  detail: location.note, isRecommended: location.isRecommended))
        }

        progress.setPhase("Checking Docker")
        switch dockerItems() {
        case .items(let dockerItems): items += dockerItems
        case .notRunning:
            warnings.append(ScanWarning(message: "Docker is installed but not running, so its images and build cache weren't checked."))
        case .notInstalled: break
        }

        progress.setPhase("Checking for unavailable simulators")
        if let simulators = unavailableSimulators(progress: progress) { items.append(simulators) }

        progress.setPhase("Searching \(Format.tildePath(searchFolder)) for node_modules")
        items += nodeModules(under: searchFolder, progress: progress)
        if let warning = FileWalker.permissionWarning(from: progress) { warnings.append(warning) }

        return ScanResult(category: .devJunk, items: items.sorted { $0.size > $1.size }, warnings: warnings)
    }

    // MARK: - node_modules

    private static func nodeModules(under root: URL, progress: ScanProgress) -> [ScanItem] {
        var results: [ScanItem] = []
        FileWalker.walk(root, keys: [.isDirectoryKey], progress: progress) { url, values in
            guard values.isDirectory == true, url.lastPathComponent == "node_modules" else { return .keepGoing }

            let project = url.deletingLastPathComponent()
            let days = DiskUtils.daysSinceModified(url) ?? 0
            let isStale = days >= staleProjectDays
            results.append(ScanItem(
                path: url,
                size: DiskUtils.size(of: url, progress: progress),
                category: .devJunk,
                name: "\(project.lastPathComponent)/node_modules",
                detail: "\(Format.tildePath(project)) \u{2022} dependencies installed \(Format.age(days: days)). Restored by `npm install`.",
                isRecommended: isStale
            ))
            return .skipDescendants // nested node_modules are inside this one
        }
        return results
    }

    // MARK: - Docker

    private enum DockerStatus {
        case notInstalled
        case notRunning
        case items([ScanItem])
    }

    private static func dockerItems() -> DockerStatus {
        guard let docker = Shell.locate("docker") else { return .notInstalled }
        guard let result = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20), result.succeeded else {
            return .notRunning
        }

        // Volumes are deliberately left out: they hold databases and other real data.
        let kinds: [String: (name: String, args: [String], note: String)] = [
            "Images": ("Docker images not used by any container", ["image", "prune", "--all", "--force"],
                       "Removed with `docker image prune -a`. Pulled again when needed."),
            "Build Cache": ("Docker build cache", ["builder", "prune", "--all", "--force"],
                            "Removed with `docker builder prune -a`. Next builds will be slower."),
            "Containers": ("Stopped Docker containers", ["container", "prune", "--force"],
                           "Removed with `docker container prune`. Anything stored inside them is lost."),
        ]

        var items: [ScanItem] = []
        for line in result.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let type = row["Type"], let kind = kinds[type],
                  let reclaimable = row["Reclaimable"].flatMap(parseDockerSize), reclaimable > 0 else { continue }
            items.append(ScanItem(id: "docker:\(type)", name: kind.name, size: reclaimable, category: .devJunk,
                                  detail: kind.note, action: .runCommand(executable: docker, arguments: kind.args)))
        }
        return .items(items)
    }

    /// Parses Docker's human sizes like "1.23GB (45%)" or "512kB". Docker uses powers of 1000.
    static func parseDockerSize(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            guard let value = Double(token.dropLast(suffix.count)) else { return nil }
            return Int64(value * multiplier)
        }
        return nil
    }

    // MARK: - Simulators

    private static func unavailableSimulators(progress: ScanProgress) -> ScanItem? {
        let devicesDir = DiskUtils.library.appendingPathComponent("Developer/CoreSimulator/Devices")
        guard DiskUtils.exists(devicesDir),
              let result = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30),
              result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return nil }

        let udids = byRuntime.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
        guard !udids.isEmpty else { return nil }
        let size = udids.reduce(Int64(0)) { $0 + DiskUtils.size(of: devicesDir.appendingPathComponent($1), progress: progress) }
        guard size > 0 else { return nil }

        return ScanItem(
            id: "simctl:unavailable",
            name: "\(udids.count) unavailable simulator\(udids.count == 1 ? "" : "s")",
            size: size,
            category: .devJunk,
            detail: "Simulators for iOS versions Xcode no longer has. Removed with `xcrun simctl delete unavailable`.",
            action: .runCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        )
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                    .tag(SidebarItem.overview)
                Label("Disk Explorer", systemImage: "rectangle.split.3x3")
                    .tag(SidebarItem.explorer)
                Label("Applications", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.apps)

                Section("Categories") {
                    ForEach(ScanCategory.allCases) { category in
                        CategorySidebarRow(category: category)
                            .tag(SidebarItem.category(category))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { SidebarDiskFooter() }
        } detail: {
            switch model.sidebarSelection {
            case .category(let category):
                CategoryDetailView(category: category).id(category)
            case .explorer:
                ExplorerView()
            case .apps:
                AppsView()
            case .overview, nil:
                OverviewView()
            }
        }
        .alert(
            reportTitle,
            isPresented: Binding(get: { model.cleanReport != nil }, set: { if !$0 { model.cleanReport = nil } }),
            presenting: model.cleanReport
        ) { report in
            if report.movedCount > 0 {
                Button("Review Trash") { model.sidebarSelection = .category(.trash) }
            }
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(reportMessage(report))
        }
    }

    private var reportTitle: String {
        guard let report = model.cleanReport else { return "" }
        return report.movedCount + report.permanentCount == 0 ? "Nothing was removed" : "Cleaned up"
    }

    private func reportMessage(_ report: CleanReport) -> String {
        var lines: [String] = []
        if report.movedCount > 0 {
            lines.append("Moved \(Format.count(report.movedCount)) item\(report.movedCount == 1 ? "" : "s") (\(Format.bytes(report.movedToTrash))) to the Trash. The space comes back once you empty the Trash.")
        }
        if report.permanentCount > 0 {
            lines.append("Permanently removed \(Format.count(report.permanentCount)) item\(report.permanentCount == 1 ? "" : "s") (\(Format.bytes(report.permanentlyFreed))).")
        }
        if !report.failures.isEmpty {
            let examples = report.failures.prefix(5).map { "\u{2022} \(Format.tildePath($0.target)): \($0.message ?? "")" }
            let more = report.failures.count > 5 ? ["\u{2022} \u{2026}and \(report.failures.count - 5) more"] : []
            lines.append("\(report.failures.count) couldn't be removed:\n" + (examples + more).joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct CategorySidebarRow: View {
    @EnvironmentObject var model: AppModel
    let category: ScanCategory

    var body: some View {
        HStack {
            Label(category.title, systemImage: category.systemImage)
            Spacer()
            if model.activeScans[category] != nil {
                ProgressView().controlSize(.small)
            } else if let result = model.results[category], result.reclaimableSize > 0 {
                Text(Format.bytes(result.reclaimableSize))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SidebarDiskFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Format.bytes(model.disk.free)) free")
                .font(.caption.weight(.medium))
                .monospacedDigit()
            Text("of \(Format.bytes(model.disk.total))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

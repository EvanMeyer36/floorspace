import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClean = false

    private var hasResults: Bool { !model.results.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskCard
                actionCard
                categoryGrid
                Text("Nothing is removed until you confirm. Most items go to the Trash, so you can restore them. Quit apps before clearing their caches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    // MARK: Disk

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Macintosh HD").font(.title2.bold())
                Spacer()
                Text("\(Format.bytes(model.disk.free)) free of \(Format.bytes(model.disk.total))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Explore Disk\u{2026}") { model.sidebarSelection = .explorer }
                    .help("See every folder by size, WizTree-style")
                    .padding(.leading, 8)
            }
            DiskUsageBar(disk: model.disk, reclaimable: model.totalReclaimable)
        }
        .card()
    }

    // MARK: Scan / clean

    @ViewBuilder
    private var actionCard: some View {
        let selected = CleanPlan(model.allSelectedItems)

        HStack(alignment: .center, spacing: 16) {
            if model.isScanning {
                let done = ScanCategory.allCases.count - model.activeScans.count
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scanning\u{2026}").font(.title3.bold())
                    ProgressView(value: Double(done), total: Double(ScanCategory.allCases.count))
                    Text("\(done) of \(ScanCategory.allCases.count) categories done. Searching your whole home folder can take a few minutes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Stop") { model.cancelAllScans() }
                    .controlSize(.large)
            } else if hasResults {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found \(Format.bytes(model.totalReclaimable)) you could free")
                        .font(.title3.bold())
                    Text(selected.isEmpty
                         ? "Nothing selected. Open a category to pick what to remove."
                         : "\(Format.count(selected.items.count)) items (\(Format.bytes(selected.totalSize))) are selected. The safe ones were picked for you.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan Again") { model.smartScan() }
                    .controlSize(.large)
                Button {
                    confirmClean = true
                } label: {
                    Text(model.isCleaning ? "Cleaning\u{2026}" : "Clean Selected").frame(minWidth: 110)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || model.isCleaning)
                .cleanConfirmation(selected, isPresented: $confirmClean) { model.clean(selected.items) }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find out what's using your space").font(.title3.bold())
                    Text("Smart Scan checks caches, developer junk, device backups, old downloads, large files and duplicates. Nothing is deleted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.smartScan()
                } label: {
                    Label("Smart Scan", systemImage: "sparkle.magnifyingglass").frame(minWidth: 120)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .card()
    }

    // MARK: Categories

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
            ForEach(ScanCategory.allCases) { category in
                Button {
                    model.sidebarSelection = .category(category)
                } label: {
                    CategoryCard(category: category)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CategoryCard: View {
    @EnvironmentObject var model: AppModel
    let category: ScanCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: category.systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                Text(category.title).font(.headline)
                Spacer()
                if model.results[category]?.warnings.isEmpty == false {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("This scan has a note. Open it for details.")
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }

            if let progress = model.activeScans[category] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    ScanProgressLine(progress: progress)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if let result = model.results[category], result.items.isEmpty,
                      result.warnings.contains(where: { $0.settingsPane != nil }) {
                Text("Needs permission").font(.title3.weight(.semibold))
                Text("macOS blocked access. Open to allow it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let result = model.results[category] {
                Text(Format.bytes(result.reclaimableSize))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(summary(result))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not scanned yet").foregroundStyle(.secondary)
                Text(category.subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .card()
        .contentShape(Rectangle())
    }

    private func summary(_ result: ScanResult) -> String {
        if result.items.isEmpty { return "Nothing found" }
        if result.recommendedSize > 0 { return "\(Format.bytes(result.recommendedSize)) safe to clean" }
        return "\(Format.count(result.items.count)) item\(result.items.count == 1 ? "" : "s") to review"
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

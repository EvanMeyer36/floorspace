import AppKit
import SwiftUI

// MARK: - Colors

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

enum ChartColors {
    // Categorical slots 1 and 2 of the validated palette, stepped separately for light and dark.
    static let used = Color(light: NSColor(hex: 0x2a78d6), dark: NSColor(hex: 0x3987e5))
    static let reclaimable = Color(light: NSColor(hex: 0xeb6834), dark: NSColor(hex: 0xd95926))
    static let track = Color(nsColor: .quaternaryLabelColor)
}

// MARK: - Storage bars

struct StorageSegment {
    let label: String
    let value: Int64
    let color: Color
}

/// One stacked horizontal bar over a whole disk, with a legend underneath.
struct StorageBar: View {
    let segments: [StorageSegment]
    let total: Int64

    var body: some View {
        let shown = segments.filter { $0.value > 0 }

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let usableWidth = geo.size.width - gap * CGFloat(max(0, shown.count - 1))
                let scale = max(1, Double(total))

                HStack(spacing: gap) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segment.color)
                            .frame(width: max(4, usableWidth * CGFloat(Double(segment.value) / scale)))
                            .help("\(segment.label): \(Format.bytes(segment.value))")
                    }
                }
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Disk usage")
            .accessibilityValue(shown.map { "\($0.label) \(Format.bytes($0.value))" }.joined(separator: ", "))

            HStack(spacing: 18) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, segment in
                    LegendEntry(color: segment.color, label: segment.label, value: segment.value)
                }
            }
            .font(.callout)
        }
    }
}

/// Overview bar: space used by other things, space we found that can be freed, free space.
struct DiskUsageBar: View {
    let disk: DiskSpace
    let reclaimable: Int64

    var body: some View {
        let reclaimableShown = min(reclaimable, disk.used)
        StorageBar(segments: [
            StorageSegment(label: "Used", value: disk.used - reclaimableShown, color: ChartColors.used),
            StorageSegment(label: "Can be freed", value: reclaimableShown, color: ChartColors.reclaimable),
            StorageSegment(label: "Free", value: disk.free, color: ChartColors.track),
        ], total: disk.total)
    }
}

private struct LegendEntry: View {
    let color: Color
    let label: String
    let value: Int64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
            Text(Format.bytes(value)).monospacedDigit()
        }
    }
}

// MARK: - Live scan progress

struct ScanProgressPanel: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let snapshot = progress.snapshot
            VStack(spacing: 14) {
                ProgressView()
                Text(snapshot.phase).font(.headline)
                Text("\(Format.count(snapshot.filesSeen)) files checked")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(snapshot.currentPath.isEmpty ? " " : Format.tildePath(URL(fileURLWithPath: snapshot.currentPath)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)
                Button("Stop Scan", action: onCancel)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Compact version for cards and sidebar rows.
struct ScanProgressLine: View {
    let progress: ScanProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("\(Format.count(progress.snapshot.filesSeen)) files checked\u{2026}")
                .monospacedDigit()
        }
    }
}

// MARK: - Warnings

struct WarningBanner: View {
    @EnvironmentObject var model: AppModel
    let warning: ScanWarning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: warning.settingsPane == nil ? "info.circle" : "lock")
                .foregroundStyle(.secondary)
            Text(warning.message)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pane = warning.settingsPane {
                Button(pane == .fullDiskAccess ? "Grant Full Disk Access\u{2026}" : "Open Privacy Settings\u{2026}") {
                    model.openSettings(pane)
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.35)))
    }
}

// MARK: - Clean confirmation

/// Shared wording for "are you sure" so the overview and category screens say the same thing.
struct CleanPlan {
    let items: [ScanItem]
    let toTrash: [ScanItem]
    let permanent: [ScanItem]

    init(_ items: [ScanItem]) {
        let unique = items.outermost
        self.items = unique
        self.toTrash = unique.filter { !$0.action.isPermanent }
        self.permanent = unique.filter { $0.action.isPermanent }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }

    var buttonTitle: String {
        if !permanent.isEmpty && toTrash.isEmpty { return "Delete Permanently" }
        if permanent.isEmpty { return "Move to Trash" }
        return "Clean Up"
    }

    var title: String {
        "Clean up \(Format.count(items.count)) item\(items.count == 1 ? "" : "s") (\(Format.bytes(totalSize)))?"
    }

    var message: String {
        var lines: [String] = []
        if !toTrash.isEmpty {
            let size = Format.bytes(toTrash.reduce(0) { $0 + $1.size })
            lines.append("\(size) will be moved to the Trash. You can put things back from there until you empty it.")
        }
        if !permanent.isEmpty {
            let names = permanent.prefix(4).map(\.name).joined(separator: ", ")
            let more = permanent.count > 4 ? " and \(permanent.count - 4) more" : ""
            lines.append("These are removed permanently and can't be undone: \(names)\(more).")
        }
        return lines.joined(separator: "\n\n")
    }
}

extension View {
    func cleanConfirmation(_ plan: CleanPlan, isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog(plan.title, isPresented: isPresented, titleVisibility: .visible) {
            Button(plan.buttonTitle, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan.message)
        }
    }
}

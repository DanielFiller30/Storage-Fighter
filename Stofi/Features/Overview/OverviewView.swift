import AnalysisKit
import Charts
import ScannerKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], spacing: 16) {
                CapacityCard()
                ScanStatusCard()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Group {
                if model.storageCategories.isEmpty {
                    TopFoldersCard()
                } else {
                    StorageCategoriesCard(categories: model.storageCategories)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Capacity

private struct CapacitySegment: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let bytes: UInt64
    let color: Color
    let symbol: String
}

private struct CapacityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(title: "Disk", systemImage: "internaldrive") {
            if let volume = model.volume {
                let segments = Self.segments(for: volume)
                HStack(alignment: .center, spacing: 20) {
                    Chart(segments) { segment in
                        SectorMark(angle: .value("Bytes", Double(segment.bytes)),
                                   innerRadius: .ratio(0.62), angularInset: 1.5)
                            .cornerRadius(4)
                            .foregroundStyle(segment.color)
                            .accessibilityLabel(Text(segment.title))
                            .accessibilityValue(segment.bytes.formattedBytes)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 150, height: 150)
                    .overlay {
                        VStack(spacing: 2) {
                            Text((volume.freeBytes + volume.purgeableBytes).formattedBytes)
                                .font(.title3.bold())
                                .monospacedDigit()
                            Text("available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(volume.name).font(.subheadline.bold())
                        Text("\(volume.totalCapacity.formattedBytes) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(segments) { segment in
                            LegendRow(segment: segment)
                        }
                    }
                }
            } else {
                Text("Capacity unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func segments(for volume: VolumeInfo) -> [CapacitySegment] {
        [
            CapacitySegment(id: "used", title: "Used", detail: "Apps, documents and system data",
                            bytes: volume.usedBytes, color: .accentColor, symbol: "square.fill"),
            CapacitySegment(id: "purgeable", title: "Removable (estimate)",
                            detail: "macOS frees this on demand: caches, local snapshots, optimised iCloud files",
                            bytes: volume.purgeableBytes, color: .teal, symbol: "square.lefthalf.filled"),
            CapacitySegment(id: "free", title: "Free", detail: "Unused space",
                            bytes: volume.freeBytes, color: Color.secondary.opacity(0.35), symbol: "square"),
        ]
    }
}

private struct LegendRow: View {
    let segment: CapacitySegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Different symbol shapes so the legend does not rely on colour alone.
            Image(systemName: segment.symbol)
                .foregroundStyle(segment.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(segment.title)
                    Spacer(minLength: 8)
                    Text(segment.bytes.formattedBytes).monospacedDigit().bold()
                }
                Text(segment.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scan status

private struct ScanStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(title: "Scan", systemImage: "magnifyingglass") {
            switch model.phase {
            case .idle:
                Text("Stofi measures how much space every folder really occupies on disk. The scan only reads.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Scan \(model.targetName)", systemImage: "arrow.clockwise") { model.startScan() }
                    .buttonStyle(.borderedProminent)
            case .scanning, .paused:
                ProgressDetails(snapshot: model.snapshot, estimate: progressEstimate, paused: model.phase == .paused)
            case .finished:
                if let statistics = model.tree?.statistics {
                    FinishedDetails(statistics: statistics, fullDiskAccess: model.fullDiskAccess)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") { model.startScan() }
            }
        }
    }

    /// Rough progress for the startup disk: scanned bytes relative to the used space. Folders have no estimate.
    private var progressEstimate: Double? {
        guard model.target == .startupVolume, let volume = model.volume, volume.usedBytes > 0,
              let scanned = model.snapshot?.statistics.allocatedBytes else { return nil }
        return min(0.99, Double(scanned) / Double(volume.usedBytes))
    }
}

private struct ProgressDetails: View {
    let snapshot: ScanSnapshot?
    let estimate: Double?
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let estimate {
                ProgressView(value: estimate) {
                    Text(paused ? "Paused" : "Scanning…")
                } currentValueLabel: {
                    Text("about \(estimate.formatted(.percent.precision(.fractionLength(0))))")
                }
            } else {
                ProgressView { Text(paused ? "Paused" : "Scanning…") }
                    .progressViewStyle(.linear)
            }
            if let statistics = snapshot?.statistics {
                StatisticsGrid(statistics: statistics)
            }
            if let path = snapshot?.currentPath, !paused {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Current folder: \(path)")
            }
        }
    }
}

private struct FinishedDetails: View {
    let statistics: ScanStatistics
    let fullDiskAccess: FullDiskAccess.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finished in \(statistics.duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            StatisticsGrid(statistics: statistics)
            if statistics.unreadableDirectories > 0 {
                Label(fullDiskAccess == .granted
                      ? "\(statistics.unreadableDirectories.formattedCount) folders could not be read; their size is missing."
                      : "\(statistics.unreadableDirectories.formattedCount) folders could not be read. Full Disk Access would allow Stofi to measure them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatisticsGrid: View {
    let statistics: ScanStatistics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Size")
                Text(statistics.allocatedBytes.formattedBytes).monospacedDigit().bold()
            }
            GridRow {
                Text("Files")
                Text(statistics.regularFiles.formattedCount).monospacedDigit()
            }
            GridRow {
                Text("Folders")
                Text(statistics.directories.formattedCount).monospacedDigit()
            }
            if statistics.skippedHardLinks > 0 {
                GridRow {
                    Text("Hard links counted once")
                    Text(statistics.skippedHardLinks.formattedCount).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}

// MARK: - Top folders

private struct TopFoldersCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard(title: "Largest Folders", systemImage: "chart.bar.xaxis") {
            let items = Array(model.topItems.prefix(10))
            if items.isEmpty {
                Text(model.isScanning ? "Collecting data…" : "Start a scan to see where your space goes.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(items, id: \.name) { item in
                    BarMark(x: .value("Size", Double(item.allocatedSize)),
                            y: .value("Folder", model.displayName(ofTopItem: item.name)))
                        .foregroundStyle(.tint)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(item.allocatedSize.formattedBytes)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(model.displayName(ofTopItem: item.name))
                        .accessibilityValue(item.allocatedSize.formattedBytes)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: items.map { model.displayName(ofTopItem: $0.name) })
                .frame(height: CGFloat(items.count) * 30 + 10)
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: items)

                if model.isScanning {
                    Text("Live while scanning. Categories appear when a scan of the startup disk has finished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Storage categories

private struct StorageCategoriesCard: View {
    let categories: [StorageCategory]

    var body: some View {
        GlassCard(title: "Categories", systemImage: "square.stack.3d.up") {
            Chart(categories) { category in
                BarMark(x: .value("Size", Double(category.bytes)), y: .value("Category", category.kind.rawValue))
                    .foregroundStyle(category.kind.color)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(category.bytes.formattedBytes)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text(category.kind.title))
                    .accessibilityValue(category.bytes.formattedBytes)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { value in
                    if let raw = value.as(String.self), let kind = StorageCategoryKind(rawValue: raw) {
                        AxisValueLabel { Text(kind.title) }
                    }
                }
            }
            .chartYScale(domain: categories.map(\.kind.rawValue))
            .frame(height: CGFloat(categories.count) * 32 + 10)

            if categories.contains(where: { $0.kind == .notCaptured }) {
                Text("“Not captured” is space the disk reports as used that the scan could not attribute: folders without access, local snapshots and the system's own volumes (e.g. virtual memory).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import AnalysisKit
import AppKit
import CleanupKit
import ScannerKit
import SwiftUI

struct RecommendationsView: View {
    @Environment(AppModel.self) private var model

    private var analysis: AnalysisModel { model.analysis }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                SummaryCard()
                ForEach(RecommendationGroup.allCases.filter { $0 != .duplicates }, id: \.self) { group in
                    let items = analysis.recommendations.filter { $0.group == group }
                        .map { $0.removing(model.cleanup.removedPaths) }
                        .filter { !$0.items.isEmpty || $0.availability == .needsFullDiskAccess }
                    if !items.isEmpty {
                        Text(group.title)
                            .font(.title3.bold())
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items) { RecommendationCard(recommendation: $0) }
                    }
                }
                Text(RecommendationGroup.duplicates.title)
                    .font(.title3.bold())
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                DuplicatesCard()
            }
            .padding(20)
        }
        // Runs on first appearance and again after every finished scan (results are reset by a new scan).
        .task(id: model.scanGeneration) {
            if analysis.analysisDate == nil && !analysis.isAnalyzing && !model.isScanning { model.analyze() }
        }
    }
}

private struct SummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let analysis = model.analysis
        GlassCard(title: "Recommendations", systemImage: "sparkles") {
            if analysis.isAnalyzing {
                ProgressView("Analysing…")
            } else if let date = analysis.analysisDate {
                let all = analysis.recommendations + [analysis.duplicateRecommendation].compactMap { $0 }
                HStack(alignment: .top, spacing: 24) {
                    ForEach([RiskLevel.safe, .caution, .expert], id: \.self) { risk in
                        VStack(alignment: .leading, spacing: 2) {
                            RiskBadge(risk: risk)
                            Text(all.filter { $0.risk == risk && $0.action != .informationOnly }
                                .reduce(UInt64(0)) { $0 + $1.totalSize }.formattedBytes)
                                .font(.title3.bold())
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let quick = analysis.quickscanProfiles {
                    Label("Quickscan: \(quick.map { $0.title.resolved() }.formatted(.list(type: .and)))", systemImage: "bolt")
                        .font(.callout.bold())
                }
                Text("Nothing is removed automatically. Suggestions are collected and confirmed in a later step. Last analysed \(date, format: .relative(presentation: .named)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.tree == nil {
                    Label("Without a scan, only known locations are measured. Scan the startup disk to also find old node_modules folders, large media and duplicates.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Analyse Everything", systemImage: "arrow.clockwise") { model.analyze() }
                    .disabled(analysis.isAnalyzing || model.isScanning)
                if !model.profiles.selected.isEmpty {
                    Button("Quickscan", systemImage: "bolt") { model.quickscan() }
                        .disabled(analysis.isAnalyzing || model.isScanning)
                }
                Button("Change Activities…") { model.profiles.isOnboardingPresented = true }
                if model.fullDiskAccess != .granted {
                    Button("Allow Full Disk Access…") { FullDiskAccess.openSystemSettings() }
                }
            }
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Label(risk.title, systemImage: risk.systemImage)
            .font(.caption.bold())
            .foregroundStyle(risk.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(risk.tint.opacity(0.12), in: .capsule)
    }
}

struct RecommendationCard: View {
    @Environment(AppModel.self) private var model
    let recommendation: Recommendation
    @State private var showsExplanation = false
    @State private var showsItems = false
    private static let visibleItemLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DisclosureGroup("What is this?", isExpanded: $showsExplanation) {
                explanation
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                if recommendation.kind == .localSnapshots, let volume = model.volume {
                    Text("macOS currently estimates \(volume.purgeableBytes.formattedBytes) as removable on demand; snapshots are part of this. Their individual size is not reported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            if recommendation.availability == .needsFullDiskAccess {
                HStack {
                    Label("Needs Full Disk Access to be measured.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                }
                .font(.callout)
            } else if !recommendation.items.isEmpty {
                DisclosureGroup(isExpanded: $showsItems) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(recommendation.items.prefix(Self.visibleItemLimit)) { item in
                            ItemRow(item: item,
                                    candidate: recommendation.allowsItemSelection ? recommendation.candidate(for: item) : nil)
                        }
                        if recommendation.items.count > Self.visibleItemLimit {
                            Text("and \((recommendation.items.count - Self.visibleItemLimit).formattedCount) more")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(recommendation.items.count.formattedCount) items")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) { footer }
                Spacer()
                let candidates = recommendation.cleanupCandidates
                if !candidates.isEmpty && recommendation.availability == .available {
                    AddToSelectionButton(candidates: candidates)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stofiGlass(cornerRadius: 16)
    }

    private var title: Text {
        if let definition = recommendation.definition { return Text(verbatim: definition.title.resolved()) }
        return Text(recommendation.kind.title)
    }

    private var explanation: Text {
        if let definition = recommendation.definition { return Text(verbatim: definition.explanation.resolved()) }
        return Text(recommendation.kind.explanation)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: recommendation.definition?.symbol ?? recommendation.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.headline)
                HStack(spacing: 8) {
                    RiskBadge(risk: recommendation.risk)
                    if let regeneration = recommendation.regeneration.title {
                        Text(regeneration).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if recommendation.kind == .localSnapshots {
                Text("\(recommendation.items.count.formattedCount) snapshots").font(.headline)
            } else if recommendation.availability == .available {
                Text(recommendation.totalSize.formattedBytes)
                    .font(.title3.bold())
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch recommendation.action {
        case .moveToTrash:
            Label("Suggested: move to the Trash (restorable)", systemImage: "trash")
                .font(.caption).foregroundStyle(.secondary)
        case .emptyTrash:
            Label("Suggested: empty the Trash (permanent, asks twice)", systemImage: "trash.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .command(let command):
            Label {
                Text("Suggested command: \(Text(command.displayString).font(.caption.monospaced()))")
            } icon: {
                Image(systemName: "terminal")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .informationOnly:
            Label("For information only", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !recommendation.sourceCommands.isEmpty {
            Text("Determined with: \(recommendation.sourceCommands.map(\.displayString).joined(separator: ", "))")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}

private struct ItemRow: View {
    let item: RecommendationItem
    let candidate: CleanupCandidate?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.detail ?? (item.path as NSString).lastPathComponent)
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let command = item.command {
                    Text(command.displayString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let date = item.modificationDate {
                Text(date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.allocatedSize > 0 {
                Text(item.allocatedSize.formattedBytes)
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)
            }
            if item.path.hasPrefix("/") {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            if let candidate {
                AddToSelectionButton(candidates: [candidate], compact: true)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct DuplicatesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.analysis.duplicates {
        case .finished:
            if let recommendation = model.analysis.duplicateRecommendation, !recommendation.items.isEmpty {
                RecommendationCard(recommendation: recommendation)
            } else {
                GlassCard(title: "Duplicate Files", systemImage: "doc.on.doc") {
                    Text("No duplicates of 1 MB or more found among your own files.")
                        .foregroundStyle(.secondary)
                    searchButton(title: "Search Again")
                }
            }
        case .searching(let progress):
            GlassCard(title: "Duplicate Files", systemImage: "doc.on.doc") {
                if let progress, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.hashedBytes), total: Double(progress.totalBytes)) {
                        Text("Comparing file contents…")
                    } currentValueLabel: {
                        Text("\(progress.hashedBytes.formattedBytes) of \(progress.totalBytes.formattedBytes)")
                    }
                } else {
                    ProgressView("Comparing file contents…")
                }
                Button("Cancel", systemImage: "xmark") { model.analysis.cancelDuplicateSearch() }
            }
        case .idle, .failed:
            GlassCard(title: "Duplicate Files", systemImage: "doc.on.doc") {
                Text("Finds files with identical content among your own files (1 MB or larger). It reads the files, which can take a while for large folders. iCloud placeholders are skipped so nothing is downloaded.")
                    .foregroundStyle(.secondary)
                if case .failed(let message) = model.analysis.duplicates {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if model.tree == nil {
                    Text("Scan first to search for duplicates.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    searchButton(title: "Search for Duplicates")
                }
            }
        }
    }

    private func searchButton(title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "magnifyingglass") { model.findDuplicates() }
            .disabled(model.tree == nil || model.isScanning)
    }
}

extension Recommendation {
    /// The recommendation without items removed in this session (their numbers are outdated).
    func removing(_ paths: Set<String>) -> Recommendation {
        guard !paths.isEmpty else { return self }
        let remaining = items.filter { !paths.contains($0.path) }
        guard remaining.count != items.count else { return self }
        return Recommendation(kind: kind, items: remaining, risk: risk, regeneration: regeneration, action: action,
                              availability: availability, sourceCommands: sourceCommands, definition: definition)
    }
}

import AppKit
import CleanupKit
import SwiftUI

/// Shows exactly what will happen and is the only place that confirms a plan.
/// Cancel is the default (Return/Esc); the action button has no keyboard shortcut on purpose.
struct ConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(plan.isPermanent ? "Delete permanently?" : "Move to the Trash?")
                    .font(.title2.bold())
            } icon: {
                Image(systemName: plan.isPermanent ? "exclamationmark.octagon.fill" : "trash")
                    .foregroundStyle(plan.isPermanent ? .red : .accentColor)
            }
            .accessibilityAddTraits(.isHeader)

            Text(plan.isPermanent
                 ? "These items will be removed permanently and cannot be restored."
                 : "These items will be moved to the Trash. You can put them back until the Trash is emptied; only then is the space freed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(plan.accepted.count.formattedCount) items · \(plan.totalSize.formattedBytes)")
                .font(.headline)
                .monospacedDigit()

            List {
                Section("Will be processed") {
                    ForEach(plan.accepted) { item in
                        CandidateRow(candidate: item.candidate) { EmptyView() }
                    }
                }
                if !plan.rejected.isEmpty {
                    Section("Left out") {
                        ForEach(plan.rejected) { item in
                            CandidateRow(candidate: item.candidate) {
                                Text(item.reason.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Label("Quit apps whose data you remove. Stofi checks open files of your own apps, but cannot see everything.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            if plan.accepted.contains(where: { if case .command = $0.candidate.target { true } else { false } }) {
                Label("Commands run exactly as shown, without a shell. Their output is shown afterwards.",
                      systemImage: "terminal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if plan.isPermanent {
                Toggle("I understand that this cannot be undone.", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cleanup.cancelPlan() }
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive) {
                    model.cleanup.execute(planID: plan.id, acknowledgingPermanentDeletion: acknowledged,
                                          fullDiskAccess: model.fullDiskAccess) { _ in model.refreshVolume() }
                } label: {
                    Text(plan.isPermanent ? "Delete Permanently" : "Move to Trash")
                }
                .disabled(plan.accepted.isEmpty || (plan.isPermanent && !acknowledged))
            }
        }
        .padding(22)
        .frame(width: 680, height: 600)
    }
}

/// What happened, with the honest distinction between “in the Trash” and “freed”.
struct ResultSheet: View {
    @Environment(AppModel.self) private var model
    let report: CleanupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Done").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ReportSummary(report: report)
            List {
                ForEach(report.results) { ResultRow(result: $0) }
            }
            .frame(minHeight: 220)
            HStack {
                if !report.trashedURLs.isEmpty {
                    Button("Show in Trash", systemImage: "trash") {
                        NSWorkspace.shared.activateFileViewerSelecting(report.trashedURLs)
                    }
                }
                Spacer()
                Button("Close") { model.cleanup.dismissResult() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 680, height: 560)
    }
}

struct ReportSummary: View {
    let report: CleanupReport

    var body: some View {
        let succeeded = report.results.filter(\.succeeded).count
        VStack(alignment: .leading, spacing: 4) {
            Text("\(succeeded.formattedCount) of \(report.results.count.formattedCount) items processed")
                .font(.headline)
            if report.bytesInTrash > 0 {
                Text("\(report.bytesInTrash.formattedBytes) moved to the Trash. The space is freed when the Trash is emptied.")
            }
            if let freed = report.measuredFreedBytes {
                Text("Measured change of free space: \(freed >= 0 ? "+" : "−")\(UInt64(freed.magnitude).formattedBytes)")
                    .foregroundStyle(.secondary)
                    .help("Other apps and Time Machine snapshots can affect this measurement.")
            }
        }
        .font(.callout)
    }
}

private struct ResultRow: View {
    let result: CleanupItemResult
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CandidateRow(candidate: result.candidate) {
                Label {
                    outcomeText
                } icon: {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                }
                .font(.caption)
            }
            if case .commandFinished(_, let output) = result.outcome, !output.isEmpty {
                DisclosureGroup("Output", isExpanded: $showsOutput) {
                    ScrollView {
                        Text(verbatim: output)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
        }
    }

    private var outcomeText: Text {
        switch result.outcome {
        case .movedToTrash: Text("In the Trash")
        case .deleted: Text("Deleted")
        case .commandFinished(let code, _): code == 0 ? Text("Command finished") : Text("Command failed (\(code))")
        case .skipped(let reason): Text("Skipped: \(Text(reason.explanation))")
        case .failed(let message): Text("Failed: \(message)")
        }
    }
}

extension CleanupReport {
    /// Locations in the Trash that still exist (the user may have emptied it since).
    var trashedURLs: [URL] {
        results.compactMap { result -> URL? in
            guard case .movedToTrash(let path?) = result.outcome, FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

/// History of all clean-ups (stored in Application Support).
struct CleanupLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.cleanup.log
        if log.isEmpty {
            ContentUnavailableView("No Clean-ups Yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Every confirmed clean-up is recorded here: what was removed, how, and how much space it freed."))
        } else {
            List {
                ForEach(log) { report in
                    Section {
                        ReportSummary(report: report)
                        ForEach(report.results) { ResultRow(result: $0) }
                        if !report.trashedURLs.isEmpty {
                            Button("Show in Trash", systemImage: "trash") {
                                NSWorkspace.shared.activateFileViewerSelecting(report.trashedURLs)
                            }
                        }
                    } header: {
                        Text("\(report.date, format: .dateTime.day().month().year().hour().minute()) · \(report.method == .moveToTrash ? String(localized: "Moved to the Trash") : String(localized: "Deleted permanently"))")
                    }
                }
            }
        }
    }
}

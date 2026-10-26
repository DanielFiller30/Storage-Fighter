import AppKit
import CleanupKit
import SwiftUI

/// The selection (“basket”): everything the user wants to remove, collected before one confirmation.
struct SelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        VStack(spacing: 0) {
            if cleanup.basket.isEmpty {
                ContentUnavailableView("Nothing Selected", systemImage: "cart",
                                       description: Text("Add recommendations, items from the list or areas of the storage map. Nothing is removed until you confirm."))
            } else {
                List {
                    ForEach(cleanup.basket) { candidate in
                        CandidateRow(candidate: candidate) {
                            Button {
                                cleanup.remove(candidate)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from the selection")
                            .accessibilityLabel("Remove from the selection")
                        }
                    }
                }
                actionBar
                    .padding(16)
            }
        }
        .overlay {
            if case .running(let current, let output) = cleanup.execution {
                RunningOverlay(current: current, output: output)
            }
        }
        .sheet(isPresented: Bindable(cleanup).isConfirmationPresented, onDismiss: { cleanup.cancelPlan() }) {
            if let plan = cleanup.plan { ConfirmationSheet(plan: plan) }
        }
        .sheet(isPresented: Bindable(cleanup).isResultPresented, onDismiss: { cleanup.dismissResult() }) {
            if case .finished(let report) = cleanup.execution { ResultSheet(report: report) }
        }
    }

    private var actionBar: some View {
        let cleanup = model.cleanup
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cleanup.basket.count.formattedCount) items · \(cleanup.totalSize.formattedBytes)")
                    .font(.headline)
                    .monospacedDigit()
                Text("Sizes are estimates from the analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Method", selection: Bindable(cleanup).method) {
                Text("Move to Trash").tag(CleanupMethod.moveToTrash)
                Text("Delete Permanently").tag(CleanupMethod.deletePermanently)
                    .selectionDisabled(!cleanup.canDeletePermanently)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(cleanup.canDeletePermanently
                  ? "Permanent deletion cannot be undone"
                  : "Permanent deletion is only available when every item can be recreated (caches, build data)")
            Button("Clear Selection") { cleanup.clear() }
            Button {
                cleanup.preparePlan(fullDiskAccess: model.fullDiskAccess)
            } label: {
                if cleanup.isPlanning { ProgressView().controlSize(.small) } else { Text("Remove…") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(cleanup.isPlanning || cleanup.isRunning)
        }
        .padding(14)
        .stofiGlass(cornerRadius: 14)
    }
}

struct CandidateRow<Accessory: View>: View {
    let candidate: CleanupCandidate
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: candidate.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: candidate.title)
                    Text(verbatim: candidate.origin).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: candidate.detailText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if candidate.expectedSize > 0 {
                Text(candidate.expectedSize.formattedBytes).monospacedDigit()
            }
            accessory
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct RunningOverlay: View {
    let current: String
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView { Text("Removing… \(current)") }
            if !output.isEmpty {
                ScrollView {
                    Text(verbatim: output)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
            }
        }
        .padding(18)
        .frame(width: 520)
        .stofiGlass(cornerRadius: 16)
    }
}

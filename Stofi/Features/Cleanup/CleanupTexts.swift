import AnalysisKit
import CleanupKit
import SwiftUI

extension ProtectionReason {
    nonisolated var explanation: LocalizedStringResource {
        switch self {
        case .invalidPath: "The path is not valid."
        case .systemLocation: "Part of macOS or shared system data."
        case .applications: "Apps are not removed by Stofi."
        case .homeFolder: "A main folder of your home folder."
        case .libraryStructure: "A main folder of your Library, needed by apps."
        case .iCloud: "iCloud Drive or cloud storage; removing it would delete it everywhere."
        case .photosLibrary: "Part of a Photos library."
        case .keychains: "Your keychains with passwords."
        case .messages: "Messages data; manage it in Messages."
        case .mail: "Mail's database; manage it in Mail."
        case .appContainer: "An app's container itself."
        case .timeMachine: "Time Machine backup data."
        case .otherUser: "Belongs to another user."
        case .volumeRoot: "A whole disk or the disks folder."
        }
    }
}

extension RejectionReason {
    nonisolated var explanation: LocalizedStringResource {
        switch self {
        case .protected(let reason): reason.explanation
        case .inUse(let user): "In use by \(user). Quit it and try again."
        case .missing: "No longer exists."
        case .commandNotAllowed: "This command is not on Stofi's list of allowed clean-up commands."
        case .permanentNotAllowed: "Personal or not recreatable data can only be moved to the Trash."
        case .needsFullDiskAccess: "Needs Full Disk Access."
        case .changedSincePlanning: "Changed after confirmation and was therefore skipped."
        }
    }
}

extension CleanupCandidate {
    var systemImage: String {
        switch target {
        case .path: "doc"
        case .command: "terminal"
        case .emptyTrash: "trash.slash"
        }
    }

    /// Path or command as shown in lists and in the confirmation.
    var detailText: String {
        switch target {
        case .path(let path): path
        case .command(let command): command.displayString
        case .emptyTrash: String(localized: "Removes all items in the Trash permanently")
        }
    }
}

/// Adds candidates to the selection; disabled with the reason when the protection list forbids it.
struct AddToSelectionButton: View {
    @Environment(AppModel.self) private var model
    let candidates: [CleanupCandidate]
    var compact = false

    var body: some View {
        let cleanup = model.cleanup
        let allowed = candidates.filter { cleanup.verdict(for: $0).isAllowed }
        let added = !allowed.isEmpty && allowed.allSatisfy(cleanup.contains)
        let firstReason: ProtectionReason? = candidates.lazy.compactMap {
            if case .denied(let reason) = cleanup.verdict(for: $0) { reason } else { nil }
        }.first

        Button {
            cleanup.add(allowed)
        } label: {
            if compact {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
            } else {
                Label(added ? "In Selection" : "Add to Selection", systemImage: added ? "checkmark.circle.fill" : "plus.circle")
            }
        }
        .buttonStyle(.borderless)
        .disabled(allowed.isEmpty || added)
        .help(allowed.isEmpty
              ? (firstReason.map { Text($0.explanation) } ?? Text("Nothing to add"))
              : added ? Text("Already in the selection") : Text("Add to the selection; nothing is removed yet"))
        .accessibilityLabel(added ? Text("In Selection") : Text("Add to Selection"))
    }
}

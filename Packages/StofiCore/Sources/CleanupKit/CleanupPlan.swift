import AnalysisKit
import Darwin
import Foundation
import ScannerKit

/// Something the user put into the selection.
public struct CleanupCandidate: Sendable, Hashable, Identifiable, Codable {
    public enum Target: Sendable, Hashable, Codable {
        case path(String)
        /// A tool's own clean-up command (assumption C3), e.g. deleting a simulator runtime.
        case command(ExternalCommand)
        /// Permanently removes the contents of the Trash.
        case emptyTrash
    }

    public var id: String {
        switch target {
        case .path(let path): "path:" + path
        case .command(let command): "command:" + command.displayString
        case .emptyTrash: "emptyTrash"
        }
    }

    public let target: Target
    /// Short name for lists, e.g. the folder name or "iOS 18.3".
    public let title: String
    /// Where it came from, e.g. the recommendation title.
    public let origin: String
    public let expectedSize: UInt64
    /// Decides whether permanent deletion may be offered (only for data that can be recreated).
    public let regeneration: Regeneration

    public init(target: Target, title: String, origin: String, expectedSize: UInt64, regeneration: Regeneration) {
        self.target = target
        self.title = title
        self.origin = origin
        self.expectedSize = expectedSize
        self.regeneration = regeneration
    }

    /// Permanent deletion is only offered for data that comes back by itself or by download/rebuild.
    public var allowsPermanentDeletion: Bool {
        switch target {
        case .path: [.automatic, .download, .rebuild].contains(regeneration)
        case .command, .emptyTrash: false
        }
    }
}

public enum CleanupMethod: String, Sendable, Codable {
    /// Default: restorable from the Trash.
    case moveToTrash
    /// Only for recreatable data; needs a second confirmation.
    case deletePermanently
}

public enum RejectionReason: Error, Sendable, Hashable, Codable {
    case protected(ProtectionReason)
    case inUse(String)
    case missing
    case commandNotAllowed
    case permanentNotAllowed
    case needsFullDiskAccess
    /// The item was replaced or changed into something else after planning (checked before acting).
    case changedSincePlanning
}

/// Identity of a file system object at planning time. The executor compares it right before acting,
/// so a path that now points to a different object (e.g. replaced by a link) is skipped.
struct Fingerprint: Sendable, Hashable, Codable {
    let device: Int32
    let inode: UInt64
    let type: UInt16

    static func of(_ path: String) -> Fingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Fingerprint(device: info.st_dev, inode: info.st_ino, type: info.st_mode & S_IFMT)
    }
}

public struct PlannedItem: Sendable, Hashable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: CleanupCandidate
    let fingerprint: Fingerprint?
}

public struct RejectedItem: Sendable, Hashable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: CleanupCandidate
    public let reason: RejectionReason
}

public enum ConfirmationError: Error, Sendable, Equatable {
    case planMismatch
    case permanentDeletionNotAcknowledged
    case nothingToDo
}

/// The checked list of what would happen. Shown in the confirmation dialog; executes nothing.
public struct CleanupPlan: Sendable, Identifiable {
    public let id: UUID
    public let method: CleanupMethod
    public let accepted: [PlannedItem]
    public let rejected: [RejectedItem]

    public var totalSize: UInt64 { accepted.reduce(0) { $0 &+ $1.candidate.expectedSize } }

    /// Whether the plan removes something permanently (permanent method or emptying the Trash).
    public var isPermanent: Bool {
        method == .deletePermanently || accepted.contains { $0.candidate.target == .emptyTrash }
    }

    /// The only way to a ``ConfirmedCleanup``. Called by the confirmation dialog's own button.
    /// Permanent removal additionally needs the explicit acknowledgement from the second step.
    public func confirm(planID: UUID, acknowledgingPermanentDeletion: Bool = false) throws(ConfirmationError) -> ConfirmedCleanup {
        guard planID == id else { throw .planMismatch }
        guard !accepted.isEmpty else { throw .nothingToDo }
        if isPermanent && !acknowledgingPermanentDeletion { throw .permanentDeletionNotAcknowledged }
        return ConfirmedCleanup(plan: self)
    }
}

/// A plan the user confirmed. Cannot be created outside CleanupKit except through ``CleanupPlan/confirm(planID:acknowledgingPermanentDeletion:)``.
public struct ConfirmedCleanup: Sendable {
    public let plan: CleanupPlan
    fileprivate init(plan: CleanupPlan) { self.plan = plan }
}

/// Checks the selection and builds a plan.
public struct CleanupPlanner: Sendable {
    public let policy: ProtectionPolicy
    public let usage: UsageSnapshot
    public let hasFullDiskAccess: Bool

    public init(policy: ProtectionPolicy, usage: UsageSnapshot, hasFullDiskAccess: Bool) {
        self.policy = policy
        self.usage = usage
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public func plan(_ candidates: [CleanupCandidate], method: CleanupMethod) -> CleanupPlan {
        var accepted: [PlannedItem] = []
        var rejected: [RejectedItem] = []
        for candidate in candidates {
            switch check(candidate, method: method) {
            case .success(let fingerprint):
                accepted.append(PlannedItem(candidate: candidate, fingerprint: fingerprint))
            case .failure(let reason):
                rejected.append(RejectedItem(candidate: candidate, reason: reason))
            }
        }
        return CleanupPlan(id: UUID(), method: method, accepted: accepted, rejected: rejected)
    }

    /// The checks for one candidate. The executor runs them again right before acting.
    func check(_ candidate: CleanupCandidate, method: CleanupMethod) -> Result<Fingerprint?, RejectionReason> {
        switch candidate.target {
        case .path(let path):
            if method == .deletePermanently && !candidate.allowsPermanentDeletion { return .failure(.permanentNotAllowed) }
            if case .denied(let reason) = policy.evaluate(path) { return .failure(.protected(reason)) }
            guard let fingerprint = Fingerprint.of(path) else { return .failure(.missing) }
            // Open files are reported with resolved paths (e.g. /private/var/…), so compare both forms.
            if let user = usage.user(of: path) ?? policy.normalize(path).flatMap(usage.user(of:)) {
                return .failure(.inUse(user))
            }
            return .success(fingerprint)
        case .command(let command):
            return CommandAllowlist.isAllowed(command, homeDirectory: policy.homeDirectory)
                ? .success(nil) : .failure(.commandNotAllowed)
        case .emptyTrash:
            return hasFullDiskAccess ? .success(nil) : .failure(.needsFullDiskAccess)
        }
    }
}

import AnalysisKit
import Foundation
import os
import ScannerKit

/// Moves to the Trash or deletes. Injected so tests never touch the user's real Trash.
public protocol TrashHandling: Sendable {
    /// Returns the item's new location in the Trash.
    func moveToTrash(_ url: URL) throws -> URL?
    func removePermanently(_ url: URL) throws
    /// Contents of the user's Trash (for emptying it).
    func trashContents() throws -> [URL]
}

public struct SystemTrash: TrashHandling {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public func removePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func trashContents() throws -> [URL] {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [])
    }
}

public struct CleanupItemResult: Sendable, Hashable, Codable, Identifiable {
    public enum Outcome: Sendable, Hashable, Codable {
        case movedToTrash(trashPath: String?)
        case deleted
        case commandFinished(exitCode: Int32, output: String)
        case skipped(RejectionReason)
        case failed(String)
    }

    public var id: String { candidate.id }
    public let candidate: CleanupCandidate
    public let outcome: Outcome

    public var succeeded: Bool {
        switch outcome {
        case .movedToTrash, .deleted: true
        case .commandFinished(let code, _): code == 0
        case .skipped, .failed: false
        }
    }
}

/// What happened, for the result sheet and the log.
public struct CleanupReport: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let method: CleanupMethod
    public let results: [CleanupItemResult]
    /// Measured free space of the volume before and after (assumption C5: other activity and
    /// snapshots can distort the difference).
    public let availableBefore: UInt64?
    public let availableAfter: UInt64?

    /// Expected sizes of what was moved to the Trash: freed only when the Trash is emptied.
    public var bytesInTrash: UInt64 {
        results.filter { if case .movedToTrash = $0.outcome { true } else { false } }
            .reduce(0) { $0 + $1.candidate.expectedSize }
    }

    public var measuredFreedBytes: Int64? {
        guard let availableBefore, let availableAfter else { return nil }
        return Int64(clamping: availableAfter) - Int64(clamping: availableBefore)
    }
}

/// Progress events while a confirmed cleanup runs.
public enum CleanupEvent: Sendable {
    case started(CleanupCandidate)
    case output(String)
    case finished(CleanupItemResult)
}

/// Executes a confirmed plan. Every path is checked again right before the action (protection list,
/// usage, identity); anything that changed since planning is skipped.
public struct CleanupExecutor: Sendable {
    public let planner: CleanupPlanner
    public let trash: any TrashHandling
    public let commands: any CommandRunning
    public let volumeURL: URL
    public static let commandTimeout: Duration = .seconds(30 * 60)
    private static let logger = Logger(subsystem: "de.df.Stofi", category: "Cleanup")

    public init(planner: CleanupPlanner, trash: any TrashHandling = SystemTrash(),
                commands: any CommandRunning = ProcessCommandRunner(), volumeURL: URL = URL(fileURLWithPath: "/")) {
        self.planner = planner
        self.trash = trash
        self.commands = commands
        self.volumeURL = volumeURL
    }

    public func execute(_ confirmed: ConfirmedCleanup,
                        events: @escaping @Sendable (CleanupEvent) -> Void = { _ in }) async -> CleanupReport {
        let plan = confirmed.plan
        // Apps may have been started since planning: take a fresh look at what is in use.
        let current = CleanupPlanner(policy: planner.policy,
                                     usage: planner.usage.refreshed(),
                                     hasFullDiskAccess: planner.hasFullDiskAccess)
        let before = try? VolumeInfo.read(for: volumeURL).availableCapacity
        var results: [CleanupItemResult] = []
        for item in plan.accepted {
            events(.started(item.candidate))
            let result: CleanupItemResult
            if Task.isCancelled {
                result = CleanupItemResult(candidate: item.candidate, outcome: .failed("Cancelled"))
            } else {
                result = await perform(item, method: plan.method, planner: current, events: events)
            }
            Self.logger.notice("Cleanup \(item.candidate.id, privacy: .public): \(String(describing: result.outcome), privacy: .public)")
            events(.finished(result))
            results.append(result)
        }
        let after = try? VolumeInfo.read(for: volumeURL).availableCapacity
        return CleanupReport(id: plan.id, date: .now, method: plan.method, results: results,
                             availableBefore: before, availableAfter: after)
    }

    private func perform(_ item: PlannedItem, method: CleanupMethod, planner: CleanupPlanner,
                         events: @escaping @Sendable (CleanupEvent) -> Void) async -> CleanupItemResult {
        let candidate = item.candidate
        // Second check, immediately before acting.
        switch planner.check(candidate, method: method) {
        case .failure(let reason):
            return CleanupItemResult(candidate: candidate, outcome: .skipped(reason))
        case .success(let fingerprint):
            if fingerprint != item.fingerprint {
                return CleanupItemResult(candidate: candidate, outcome: .skipped(.changedSincePlanning))
            }
        }

        do {
            switch candidate.target {
            case .path(let path):
                let url = URL(fileURLWithPath: path)
                switch method {
                case .moveToTrash:
                    let location = try trash.moveToTrash(url)
                    return CleanupItemResult(candidate: candidate, outcome: .movedToTrash(trashPath: location?.path))
                case .deletePermanently:
                    try trash.removePermanently(url)
                    return CleanupItemResult(candidate: candidate, outcome: .deleted)
                }
            case .command(let command):
                let result = await commands.run(command, timeout: Self.commandTimeout) { events(.output($0)) }
                let output = (result.standardOutput + result.standardError).suffix(20_000)
                return CleanupItemResult(candidate: candidate,
                                         outcome: .commandFinished(exitCode: result.timedOut ? -2 : result.exitCode,
                                                                   output: String(output)))
            case .emptyTrash:
                for url in try trash.trashContents() {
                    try trash.removePermanently(url)
                }
                return CleanupItemResult(candidate: candidate, outcome: .deleted)
            }
        } catch {
            return CleanupItemResult(candidate: candidate, outcome: .failed(error.localizedDescription))
        }
    }
}

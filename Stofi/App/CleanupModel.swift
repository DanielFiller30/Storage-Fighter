import AnalysisKit
import AppKit
import CleanupKit
import Foundation
import Observation
import os
import ScannerKit

/// UI state of the selection (“basket”) and the confirmed cleanup flow.
///
/// Nothing is removed here directly: the model builds a plan with CleanupKit, the confirmation sheet
/// confirms it, and only then the executor acts. The selection lives in memory only (decision for M4).
@Observable
final class CleanupModel {
    enum Execution {
        case idle
        case running(current: String, output: String)
        case finished(CleanupReport)
    }

    private(set) var basket: [CleanupCandidate] = []
    var method: CleanupMethod = .moveToTrash
    private(set) var plan: CleanupPlan?
    private(set) var isPlanning = false
    private(set) var execution: Execution = .idle
    private(set) var log: [CleanupReport] = []
    var isConfirmationPresented = false
    var isResultPresented = false
    /// Paths removed in this session; their old numbers in recommendations are hidden.
    private(set) var removedPaths: Set<String> = []

    let policy: ProtectionPolicy
    private let logStore: CleanupLogStore?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "Cleanup")

    private let trash: any TrashHandling

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        policy = ProtectionPolicy(homeDirectory: homeDirectory)
        var trash: any TrashHandling = SystemTrash()
        var logStore = try? CleanupLogStore.standard()
        #if DEBUG
        // Test hooks: `-StofiFakeTrash <folder>` and `-StofiLogPath <file>` keep test runs away from the
        // user's real Trash and log.
        if let folder = UserDefaults.standard.string(forKey: "StofiFakeTrash") { trash = FolderTrash(directory: folder) }
        if let file = UserDefaults.standard.string(forKey: "StofiLogPath") {
            logStore = CleanupLogStore(fileURL: URL(fileURLWithPath: file))
        }
        #endif
        self.trash = trash
        self.logStore = logStore
        do {
            log = try logStore?.load() ?? []
        } catch {
            logger.error("Cleanup log could not be read: \(error.localizedDescription, privacy: .public)")
        }
    }

    var totalSize: UInt64 { basket.reduce(0) { $0 + $1.expectedSize } }

    /// Permanent deletion is only offered when every entry may be deleted permanently.
    var canDeletePermanently: Bool {
        !basket.isEmpty && basket.allSatisfy { candidate in
            if case .path = candidate.target { return candidate.allowsPermanentDeletion }
            return true
        } && basket.contains { if case .path = $0.target { true } else { false } }
    }

    var isRunning: Bool { if case .running = execution { true } else { false } }

    // MARK: Selection

    func contains(_ candidate: CleanupCandidate) -> Bool { basket.contains { $0.id == candidate.id } }

    /// Quick check for buttons: the protection list only (usage is checked when planning).
    func verdict(for candidate: CleanupCandidate) -> ProtectionVerdict {
        if case .path(let path) = candidate.target { return policy.evaluate(path) }
        return .allowed
    }

    func add(_ candidates: [CleanupCandidate]) {
        for candidate in candidates where !contains(candidate) && verdict(for: candidate).isAllowed {
            basket.append(candidate)
        }
        if !canDeletePermanently { method = .moveToTrash }
    }

    func remove(_ candidate: CleanupCandidate) {
        basket.removeAll { $0.id == candidate.id }
        if !canDeletePermanently { method = .moveToTrash }
    }

    func clear() {
        basket = []
        method = .moveToTrash
    }

    // MARK: Plan, confirmation, execution

    /// Checks the selection (protection list, usage, existence) and opens the confirmation sheet.
    func preparePlan(fullDiskAccess: FullDiskAccess.Status) {
        guard !basket.isEmpty, !isPlanning, !isRunning else { return }
        isPlanning = true
        let candidates = basket, method = method, policy = policy
        let hasAccess = fullDiskAccess == .granted
        let apps = Self.runningApps()
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                CleanupPlanner(policy: policy, usage: .capture(runningApps: apps), hasFullDiskAccess: hasAccess)
                    .plan(candidates, method: method)
            }.value
            guard let self else { return }
            self.plan = plan
            self.isPlanning = false
            self.isConfirmationPresented = true
        }
    }

    func cancelPlan() {
        plan = nil
        isConfirmationPresented = false
    }

    /// Called only by the confirmation sheet's action button.
    func execute(planID: UUID, acknowledgingPermanentDeletion: Bool, fullDiskAccess: FullDiskAccess.Status,
                 completion: @escaping (CleanupReport) -> Void) {
        guard let plan else { return }
        let confirmed: ConfirmedCleanup
        do {
            confirmed = try plan.confirm(planID: planID, acknowledgingPermanentDeletion: acknowledgingPermanentDeletion)
        } catch {
            logger.error("Confirmation refused: \(String(describing: error), privacy: .public)")
            return
        }
        isConfirmationPresented = false
        execution = .running(current: "", output: "")
        // Usage is looked at again with the apps running now.
        let planner = CleanupPlanner(policy: policy, usage: .capture(runningApps: Self.runningApps()),
                                     hasFullDiskAccess: fullDiskAccess == .granted)
        let executor = CleanupExecutor(planner: planner, trash: trash)
        let (events, continuation) = AsyncStream.makeStream(of: CleanupEvent.self)
        let run = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return await executor.execute(confirmed) { continuation.yield($0) }
        }
        Task { [weak self] in
            for await event in events {
                guard let self, case .running(let current, let output) = self.execution else { continue }
                switch event {
                case .started(let candidate):
                    self.execution = .running(current: candidate.title, output: output)
                case .output(let text):
                    // Keep the tail only; tools can be chatty.
                    self.execution = .running(current: current, output: String((output + text).suffix(8_000)))
                case .finished:
                    break
                }
            }
            let report = await run.value
            self?.finish(report)
            completion(report)
        }
    }

    private func finish(_ report: CleanupReport) {
        execution = .finished(report)
        plan = nil
        for result in report.results where result.succeeded {
            basket.removeAll { $0.id == result.candidate.id }
            if case .path(let path) = result.candidate.target { removedPaths.insert(path) }
        }
        log.insert(report, at: 0)
        do {
            try logStore?.append(report)
        } catch {
            logger.error("Cleanup log could not be written: \(error.localizedDescription, privacy: .public)")
        }
        isResultPresented = true
    }

    func dismissResult() {
        isResultPresented = false
        execution = .idle
    }

    private static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleIdentifier: $0.bundleIdentifier,
                       bundlePath: $0.bundleURL?.path)
        }
    }
}

// MARK: - Candidates from the analysis and the scan

extension Recommendation {
    /// Display title as plain text (built-in kinds are localised through the string catalog).
    var titleText: String {
        definition?.title.resolved() ?? String(localized: kind.title)
    }

    /// What adding the whole recommendation puts into the selection.
    var cleanupCandidates: [CleanupCandidate] {
        switch action {
        case .moveToTrash:
            return items.filter { $0.path.hasPrefix("/") }.map { candidate(for: $0) }
        case .emptyTrash:
            return [CleanupCandidate(target: .emptyTrash, title: titleText, origin: titleText,
                                     expectedSize: totalSize, regeneration: .none)]
        case .command(let command):
            return [CleanupCandidate(target: .command(command), title: command.displayString, origin: titleText,
                                     expectedSize: totalSize, regeneration: regeneration)]
        case .informationOnly:
            // Items may still carry their own command (e.g. one simulator runtime each).
            return items.compactMap { $0.command == nil ? nil : candidate(for: $0) }
        }
    }

    func candidate(for item: RecommendationItem) -> CleanupCandidate {
        if let command = item.command {
            return CleanupCandidate(target: .command(command), title: item.detail ?? command.displayString,
                                    origin: titleText, expectedSize: item.allocatedSize, regeneration: regeneration)
        }
        return CleanupCandidate(target: .path(item.path), title: (item.path as NSString).lastPathComponent,
                                origin: titleText, expectedSize: item.allocatedSize, regeneration: regeneration)
    }

    /// Whether single items can be added (only for path-based or per-item command recommendations).
    var allowsItemSelection: Bool {
        switch action {
        case .moveToTrash: true
        case .informationOnly: items.contains { $0.command != nil }
        case .emptyTrash, .command: false
        }
    }
}

extension CleanupCandidate {
    /// A path picked freely in the list or the map: unknown content, so only the Trash is offered.
    static func freelyChosen(path: String, size: UInt64) -> CleanupCandidate {
        CleanupCandidate(target: .path(path), title: (path as NSString).lastPathComponent,
                         origin: String(localized: "Chosen manually"), expectedSize: size, regeneration: .none)
    }
}

#if DEBUG
/// Test-only “Trash”: a plain folder. Moves items there; never deletes on its own.
struct FolderTrash: TrashHandling {
    let directory: String

    func moveToTrash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    func removePermanently(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    func trashContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
    }
}
#endif

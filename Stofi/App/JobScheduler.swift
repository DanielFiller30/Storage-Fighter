import AnalysisKit
import CleanupKit
import Foundation
import Observation
import os
import ScannerKit
import UserNotifications

/// Runs scheduled clean-ups while Stofi is running. A due job only *prepares*: it measures its
/// categories, applies the age filter and offers the result for review. Removing still needs the
/// confirmation dialog (safety rule 1). Without enabled jobs, no timer runs.
@Observable
final class JobScheduler {
    struct ReadyJob: Identifiable {
        var id: UUID { jobID }
        let jobID: UUID
        let jobName: String
        let candidates: [CleanupCandidate]
        let preparedAt: Date
        let trigger: CleanupJob.Trigger

        var totalSize: UInt64 { candidates.reduce(0) { $0 + $1.expectedSize } }
    }

    private(set) var jobs: [CleanupJob] = []
    private(set) var ready: [ReadyJob] = []
    private(set) var preparing: Set<UUID> = []

    /// Measures a job's categories and returns what would be selected. Provided by the app model.
    var prepare: ((CleanupJob) async -> [CleanupCandidate])?
    /// Current level of the startup disk for low-space triggers.
    var currentLevel: (() -> CapacityLevel?)?

    private var loop: Task<Void, Never>?
    private let store: CleanupJobStore?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "Jobs")

    init() {
        var store = try? CleanupJobStore.standard()
        #if DEBUG
        // Test hook: `-StofiJobsPath <file>` keeps test runs away from the user's real jobs.
        if let path = UserDefaults.standard.string(forKey: "StofiJobsPath") {
            store = CleanupJobStore(fileURL: URL(fileURLWithPath: path))
        }
        #endif
        self.store = store
        do {
            jobs = try store?.load() ?? []
        } catch {
            logger.error("Jobs could not be read: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Editing

    func save(_ job: CleanupJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
        persist()
        updateLoop()
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }

    func delete(_ job: CleanupJob) {
        jobs.removeAll { $0.id == job.id }
        ready.removeAll { $0.jobID == job.id }
        persist()
        updateLoop()
    }

    func setEnabled(_ enabled: Bool, for job: CleanupJob) {
        var changed = job
        changed.isEnabled = enabled
        save(changed)
    }

    func dismiss(_ readyJob: ReadyJob) {
        ready.removeAll { $0.id == readyJob.id }
    }

    // MARK: Running

    /// Starts the check loop when at least one job is enabled, stops it otherwise.
    func updateLoop() {
        let needsLoop = jobs.contains(where: \.isEnabled)
        if needsLoop && loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.checkDueJobs()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            logger.notice("Job checks started")
        } else if !needsLoop, let running = loop {
            running.cancel()
            loop = nil
            logger.notice("Job checks stopped")
        }
    }

    private func checkDueJobs() async {
        let now = Date.now
        let level = currentLevel?()
        for job in jobs where !preparing.contains(job.id) {
            guard let trigger = job.dueTrigger(now: now, currentLevel: level) else { continue }
            await run(job, trigger: trigger)
        }
    }

    /// Prepares a job now (button “Prepare Now” or a due trigger).
    func prepareNow(_ job: CleanupJob) {
        Task { await run(job, trigger: .schedule(.now)) }
    }

    private func run(_ job: CleanupJob, trigger: CleanupJob.Trigger) async {
        guard let prepare, !preparing.contains(job.id) else { return }
        preparing.insert(job.id)
        defer { preparing.remove(job.id) }
        logger.notice("Preparing job \(job.name, privacy: .public)")
        let candidates = await prepare(job)

        var updated = job
        updated.lastPrepared = .now
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = updated }
        persist()

        ready.removeAll { $0.jobID == job.id }
        guard !candidates.isEmpty else {
            logger.notice("Job \(job.name, privacy: .public) found nothing to remove")
            return
        }
        let result = ReadyJob(jobID: job.id, jobName: job.name, candidates: candidates, preparedAt: .now, trigger: trigger)
        ready.append(result)
        notify(result)
    }

    private func notify(_ result: ReadyJob) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Scheduled clean-up “\(result.jobName)” is ready")
        content.body = String(localized: "\(result.candidates.count.formattedCount) items, \(result.totalSize.formattedBytes). Nothing has been removed; open Stofi to review and confirm.")
        let request = UNNotificationRequest(identifier: "job-" + result.jobID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func persist() {
        do {
            try store?.save(jobs)
        } catch {
            logger.error("Jobs could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Categories a job can contain: everything with a removal action that can be measured without a full scan.
enum JobCategories {
    static let builtIns: [RecommendationKind] = [
        .userCaches, .userLogs, .trash, .downloads, .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport,
        .simulatorRuntimes, .simulatorUnavailableDevices, .androidVirtualDevices, .gradleCache, .npmCache,
        .pnpmStore, .yarnCache, .pipCache, .homebrewCache, .cocoaPodsCache, .dockerData, .iosBackups, .mailDownloads,
    ]

    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static func all(profiles: [ActivityProfile]) -> [Entry] {
        var seen = Set<String>()
        let builtIn = builtIns.map { Entry(id: $0.rawValue, title: String(localized: $0.title)) }
        let fromProfiles = profiles.flatMap(\.locations)
            .filter { $0.action.type != .info && seen.insert($0.id).inserted }
            .map { Entry(id: "profile." + $0.id, title: $0.title.resolved()) }
        return builtIn + fromProfiles
    }
}

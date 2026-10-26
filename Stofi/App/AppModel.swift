import AnalysisKit
import AppKit
import CleanupKit
import Observation
import os
import ScannerKit

/// What the user wants to scan.
enum ScanTarget: Hashable {
    /// The data volume of the startup disk; paths are shown via firmlinks (`/Users`, `/Applications`, …).
    case startupVolume
    case folder(URL)

    var rootPath: String {
        switch self {
        case .startupVolume: StartupVolume.dataVolumePath
        case .folder(let url): url.path
        }
    }

    /// A URL on the volume whose capacity is shown in the overview.
    var volumeURL: URL {
        switch self {
        case .startupVolume: URL(fileURLWithPath: "/")
        case .folder(let url): url
        }
    }
}

/// Central UI state. Owns the running scan and its result. Strictly read-only: nothing here modifies files.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, paused, finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var target: ScanTarget = .startupVolume
    /// Live progress while scanning; the last snapshot stays available afterwards.
    private(set) var snapshot: ScanSnapshot?
    private(set) var tree: FileTree?
    private(set) var volume: VolumeInfo?
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown

    let startupVolume = StartupVolume.current()
    let analysis = AnalysisModel()
    let profiles = ProfileSettings()
    let cleanup: CleanupModel
    let settings = AppSettings()
    let loginItem = LoginItem()
    let menuBarStatus = MenuBarStatus()
    let jobs = JobScheduler()
    /// Categories of the last startup-disk scan, also after a restart (for the menu bar).
    private(set) var lastSummary: ScanSummary?
    private let summaryStore = ScanSummaryStore()
    /// Set to switch the sidebar from outside the view, e.g. after starting a quickscan.
    var requestedSection: SidebarItem?
    /// Storage categories of the last startup-disk scan; empty for folder scans.
    private(set) var storageCategories: [StorageCategory] = []
    /// Increases with every finished scan, so views can react to a new result.
    private(set) var scanGeneration = 0

    init() {
        cleanup = CleanupModel(homeDirectory: analysis.homeDirectory)
        lastSummary = summaryStore.load()
        jobs.prepare = { [weak self] job in await self?.prepareJob(job) ?? [] }
        jobs.currentLevel = { [weak self] in
            guard let self, let info = try? VolumeInfo.read(for: URL(fileURLWithPath: "/")) else { return nil }
            return info.level(lowPercent: self.settings.lowPercent, criticalPercent: self.settings.criticalPercent)
        }
        jobs.updateLoop()
    }

    /// Measures a job's categories freshly (without the possibly outdated scan tree) and returns the
    /// candidates after the age filter. Nothing is removed here.
    private func prepareJob(_ job: CleanupJob) async -> [CleanupCandidate] {
        refreshEnvironment()
        let scope = AnalysisScope.categories(job.categories, profiles: profiles.available)
        let context = AnalysisContext(homeDirectory: analysis.homeDirectory, tree: nil, startupVolume: startupVolume,
                                      hasFullDiskAccess: fullDiskAccess == .granted,
                                      thresholds: settings.analysisThresholds)
        let recommendations = await Task.detached(priority: .utility) {
            await RecommendationEngine(context: context).analyze(scope: scope)
        }.value
        let now = Date.now
        return recommendations.map { job.filtered($0, now: now) }.flatMap(\.cleanupCandidates)
    }

    /// Puts a prepared job into the selection and opens the confirmation dialog.
    func review(_ readyJob: JobScheduler.ReadyJob) {
        cleanup.add(readyJob.candidates)
        jobs.dismiss(readyJob)
        requestedSection = .selection
        cleanup.preparePlan(fullDiskAccess: fullDiskAccess)
    }

    private var scanTask: Task<Void, Never>?
    private var controller: ScanController?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "App")

    var isScanning: Bool { phase == .scanning || phase == .paused }

    /// Name shown for the scan root, e.g. "Macintosh HD" or a folder name.
    var targetName: String {
        switch target {
        case .startupVolume: volume?.name ?? String(localized: "Startup Disk")
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        }
    }

    /// Largest direct children of the scan root, live during the scan and final afterwards.
    var topItems: [ScanSnapshot.Item] {
        if let tree {
            return tree.children(of: tree.root)
                .map { ScanSnapshot.Item(name: tree.name(of: $0), allocatedSize: tree.allocatedSize(of: $0),
                                         isDirectory: tree.isDirectory($0)) }
                .sorted { $0.allocatedSize > $1.allocatedSize }
        }
        return snapshot?.topItems ?? []
    }

    /// Display name of a direct child of the root, e.g. `Users` → `/Users` on the startup disk.
    func displayName(ofTopItem name: String) -> String {
        guard target == .startupVolume else { return name }
        return startupVolume.displayPath(forDataVolumePath: StartupVolume.dataVolumePath + "/" + name)
    }

    // MARK: - Environment

    func refreshEnvironment() {
        fullDiskAccess = FullDiskAccess.check()
        refreshVolume()
    }

    func refreshVolume() {
        do {
            volume = try VolumeInfo.read(for: target.volumeURL)
        } catch {
            logger.error("Reading volume capacity failed: \(error.localizedDescription, privacy: .public)")
            volume = nil
        }
    }

    // MARK: - Scanning

    func select(_ newTarget: ScanTarget) {
        guard !isScanning, newTarget != target else { return }
        target = newTarget
        tree = nil
        snapshot = nil
        storageCategories = []
        analysis.reset()
        phase = .idle
        refreshVolume()
    }

    func chooseFolder() {
        guard !isScanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan")
        panel.message = String(localized: "Choose a folder to analyse. Stofi only reads it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(.folder(url))
        startScan()
    }

    func startScan() {
        cancelScan()
        refreshEnvironment()
        let controller = ScanController()
        self.controller = controller
        tree = nil
        snapshot = nil
        storageCategories = []
        analysis.reset()
        phase = .scanning

        let stream = DiskScanner().scan(rootPath: target.rootPath, controller: controller)
        scanTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .progress(let snapshot):
                        self.snapshot = snapshot
                    case .finished(let tree):
                        self.logger.notice("Scan result: \(tree.nodeCount) nodes, \(tree.statistics.allocatedBytes) bytes")
                        self.tree = tree
                        self.scanGeneration += 1
                        self.phase = .finished
                        self.refreshVolume()
                        self.updateStorageCategories()
                    }
                }
                // The stream also ends without a result when the scan was cancelled.
                if let self, self.phase == .scanning || self.phase == .paused {
                    self.logger.notice("Scan stream ended without result")
                    self.phase = .idle
                }
            } catch let failure as ScanFailure {
                self?.logger.error("Scan failed: \(failure.localizedMessage, privacy: .public)")
                self?.phase = .failed(failure.localizedMessage)
            } catch {
                self?.logger.error("Scan failed: \(error.localizedDescription, privacy: .public)")
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func updateStorageCategories() {
        guard target == .startupVolume, let tree, let volume else {
            storageCategories = []
            return
        }
        storageCategories = StorageCategories.compute(
            tree: tree, startupVolume: startupVolume, volumeUsedBytes: volume.usedBytes,
            systemVolumeUsedBytes: FileMetadata.volumeUsedBytes(atPath: "/") ?? 0
        )
        let summary = ScanSummary(date: .now, categories: storageCategories)
        lastSummary = summary
        summaryStore.save(summary)
    }

    /// Analyses everything: all built-in rules and the locations of every profile.
    func analyze() {
        analysis.analyze(scope: .full(profiles: profiles.available), tree: tree, startupVolume: startupVolume,
                         fullDiskAccess: fullDiskAccess, thresholds: settings.analysisThresholds)
    }

    /// Measures only the locations of the user's activities; fast, no full scan needed.
    func quickscan() {
        guard !profiles.selected.isEmpty, !isScanning else { return }
        refreshEnvironment()
        analysis.analyze(scope: .quick(profiles: profiles.selected), tree: tree, startupVolume: startupVolume,
                         fullDiskAccess: fullDiskAccess, thresholds: settings.analysisThresholds)
        requestedSection = .recommendations
    }

    func findDuplicates() {
        guard let tree else { return }
        analysis.findDuplicates(tree: tree, startupVolume: startupVolume)
    }

    /// “Analyse again” from the menu bar: a quickscan when activities are chosen, otherwise a full scan
    /// of the startup disk.
    func analyzeFromMenuBar() {
        guard !isScanning else { return }
        if profiles.selected.isEmpty {
            select(.startupVolume)
            startScan()
            requestedSection = .overview
        } else {
            quickscan()
        }
    }

    func togglePause() {
        switch phase {
        case .scanning:
            controller?.pause()
            phase = .paused
        case .paused:
            controller?.resume()
            phase = .scanning
        default:
            break
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        controller = nil
        if isScanning { phase = .idle }
    }
}

extension ScanFailure {
    var localizedMessage: String {
        switch self {
        case .rootUnreadable(let path, let code):
            String(localized: "“\(path)” could not be read: \(String(cString: strerror(code)))")
        }
    }
}

import AnalysisKit
import Foundation
import Observation
import os
import ScannerKit

/// UI state of the recommendations and the duplicate search. Read-only: it only collects suggestions.
@Observable
final class AnalysisModel {
    enum DuplicateState {
        case idle
        case searching(DuplicateProgress?)
        case finished([DuplicateGroup])
        case failed(String)
    }

    private(set) var recommendations: [Recommendation] = []
    private(set) var isAnalyzing = false
    private(set) var analysisDate: Date?
    private(set) var duplicates: DuplicateState = .idle
    /// Profiles of the last quickscan; `nil` when the last analysis covered everything.
    private(set) var quickscanProfiles: [ActivityProfile]?

    private var analysisTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "Analysis")

    var homeDirectory: String {
        #if DEBUG
        // Test hook: `-StofiHomeOverride <folder>` analyses a fake home instead of the real one.
        if let override = UserDefaults.standard.string(forKey: "StofiHomeOverride") { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Discards results that belong to an older scan.
    func reset() {
        analysisTask?.cancel()
        duplicateTask?.cancel()
        recommendations = []
        analysisDate = nil
        isAnalyzing = false
        quickscanProfiles = nil
        duplicates = .idle
    }

    func analyze(scope: AnalysisScope, tree: FileTree?, startupVolume: StartupVolume,
                 fullDiskAccess: FullDiskAccess.Status, thresholds: AnalysisThresholds) {
        analysisTask?.cancel()
        isAnalyzing = true
        if case .quick(let profiles) = scope { quickscanProfiles = profiles } else { quickscanProfiles = nil }
        let context = AnalysisContext(homeDirectory: homeDirectory, tree: tree, startupVolume: startupVolume,
                                      hasFullDiskAccess: fullDiskAccess == .granted, thresholds: thresholds)
        analysisTask = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                await RecommendationEngine(context: context).analyze(scope: scope)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recommendations = results
            self.analysisDate = .now
            self.isAnalyzing = false
            self.logger.notice("Recommendations: \(results.map { "\($0.id)=\($0.totalSize)" }.joined(separator: ", "), privacy: .public)")
        }
    }

    func findDuplicates(tree: FileTree, startupVolume: StartupVolume) {
        duplicateTask?.cancel()
        duplicates = .searching(nil)
        let finder = DuplicateFinder(tree: tree, homeDirectory: homeDirectory, startupVolume: startupVolume)
        let (progressStream, progress) = AsyncStream.makeStream(of: DuplicateProgress.self,
                                                                bufferingPolicy: .bufferingNewest(1))
        let search = Task.detached(priority: .utility) {
            defer { progress.finish() }
            return try await finder.find { progress.yield($0) }
        }
        duplicateTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await update in progressStream {
                    guard let self else { return }
                    if case .searching = self.duplicates { self.duplicates = .searching(update) }
                }
                do {
                    let groups = try await search.value
                    self?.duplicates = .finished(groups)
                } catch is CancellationError {
                    self?.duplicates = .idle
                } catch {
                    self?.logger.error("Duplicate search failed: \(error.localizedDescription, privacy: .public)")
                    self?.duplicates = .failed(error.localizedDescription)
                }
            } onCancel: {
                search.cancel()
            }
        }
    }

    func cancelDuplicateSearch() {
        duplicateTask?.cancel()
        duplicates = .idle
    }

    var duplicateRecommendation: Recommendation? {
        guard case .finished(let groups) = duplicates else { return nil }
        return DuplicateFinder.recommendation(for: groups)
    }
}

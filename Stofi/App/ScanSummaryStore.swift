import AnalysisKit
import Foundation
import os

/// The few numbers the menu bar shows from the last scan of the startup disk: categories and date.
/// Stored as a small JSON in Application Support; the full scan cache follows separately (M5).
struct ScanSummary: Codable, Equatable {
    let date: Date
    let categories: [StorageCategory]
}

struct ScanSummaryStore {
    let fileURL: URL?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "Summary")

    init() {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        fileURL = support?.appendingPathComponent("Stofi/last-scan-summary.json")
    }

    func load() -> ScanSummary? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanSummary.self, from: data)
    }

    func save(_ summary: ScanSummary) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(summary).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Summary could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

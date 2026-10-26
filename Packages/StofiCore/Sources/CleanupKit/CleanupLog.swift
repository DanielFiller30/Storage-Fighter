import Foundation

/// Persistent log of what was removed (`~/Library/Application Support/Stofi/cleanup-log.json`).
public struct CleanupLogStore: Sendable {
    public let fileURL: URL
    public static let maximumEntries = 200

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func standard() throws -> CleanupLogStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return CleanupLogStore(fileURL: support.appendingPathComponent("Stofi/cleanup-log.json"))
    }

    /// Entries, newest first. A missing file is an empty log.
    public func load() throws -> [CleanupReport] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CleanupReport].self, from: Data(contentsOf: fileURL))
    }

    public func append(_ report: CleanupReport) throws {
        var entries = try load()
        entries.insert(report, at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}

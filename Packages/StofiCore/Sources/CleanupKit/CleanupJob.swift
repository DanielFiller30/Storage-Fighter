import AnalysisKit
import Foundation
import ScannerKit

/// A scheduled clean-up (“job”). It never removes anything by itself: when it is due, the app gathers the
/// matching items and asks the user, who confirms in the usual confirmation dialog (safety rule 1).
public struct CleanupJob: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Recommendation IDs (``Recommendation/id``), e.g. `xcodeDerivedData` or `profile.swiftPMCache`.
    public var categories: [String]
    public var schedule: Schedule?
    /// Prepare the job when the startup disk reaches this level (in addition to the schedule).
    public var lowSpaceLevel: CapacityLevel?
    /// Only items whose last modification (or use) is older than this many days.
    public var minimumAgeDays: Int?
    public var lastPrepared: Date?
    /// Scheduled times before this date are ignored (a new job does not fire for the past).
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, categories: [String],
                schedule: Schedule? = nil, lowSpaceLevel: CapacityLevel? = nil, minimumAgeDays: Int? = nil,
                lastPrepared: Date? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.categories = categories
        self.schedule = schedule
        self.lowSpaceLevel = lowSpaceLevel
        self.minimumAgeDays = minimumAgeDays
        self.lastPrepared = lastPrepared
        self.createdAt = createdAt
    }

    public struct Schedule: Codable, Sendable, Hashable {
        public enum Frequency: String, Codable, Sendable, CaseIterable { case daily, weekly, monthly }

        public var frequency: Frequency
        public var hour: Int
        public var minute: Int
        /// 1 = Sunday … 7 = Saturday (`Calendar` convention), for weekly schedules.
        public var weekday: Int
        /// 1…28, for monthly schedules (limited to 28 so every month has the day).
        public var dayOfMonth: Int

        public init(frequency: Frequency, hour: Int = 9, minute: Int = 0, weekday: Int = 2, dayOfMonth: Int = 1) {
            self.frequency = frequency
            self.hour = min(max(hour, 0), 23)
            self.minute = min(max(minute, 0), 59)
            self.weekday = min(max(weekday, 1), 7)
            self.dayOfMonth = min(max(dayOfMonth, 1), 28)
        }

        /// The first scheduled time strictly after `date`.
        public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
            var components = DateComponents(hour: hour, minute: minute, second: 0)
            switch frequency {
            case .daily: break
            case .weekly: components.weekday = weekday
            case .monthly: components.day = dayOfMonth
            }
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
        }

        /// The most recent scheduled time at or before `date` (used to catch up on missed runs).
        public func previousOccurrence(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
            var components = DateComponents(hour: hour, minute: minute, second: 0)
            switch frequency {
            case .daily: break
            case .weekly: components.weekday = weekday
            case .monthly: components.day = dayOfMonth
            }
            return calendar.nextDate(after: date.addingTimeInterval(1), matching: components,
                                     matchingPolicy: .nextTime, direction: .backward)
        }
    }

    /// Why a job is due now, if it is.
    public enum Trigger: Sendable, Equatable {
        case schedule(Date)
        case lowSpace(CapacityLevel)
    }

    /// Minimum time between two low-space preparations, so a full disk does not nag constantly.
    public static let lowSpaceCooldown: TimeInterval = 24 * 3600

    /// Whether the job should be prepared now. A missed scheduled time (app was not running) counts once.
    public func dueTrigger(now: Date, currentLevel: CapacityLevel?, calendar: Calendar = .current) -> Trigger? {
        guard isEnabled, !categories.isEmpty else { return nil }
        if let schedule, let last = schedule.previousOccurrence(atOrBefore: now, calendar: calendar),
           last > max(lastPrepared ?? .distantPast, createdAt) {
            return .schedule(last)
        }
        if let threshold = lowSpaceLevel, let currentLevel, currentLevel >= threshold,
           lastPrepared.map({ now.timeIntervalSince($0) >= Self.lowSpaceCooldown }) ?? true {
            return .lowSpace(currentLevel)
        }
        return nil
    }

    public func nextScheduledRun(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return schedule?.nextOccurrence(after: date, calendar: calendar)
    }

    /// Applies the job's age filter to a recommendation. Items without a date are left out when a
    /// minimum age is set, because their age is unknown.
    public func filtered(_ recommendation: Recommendation, now: Date) -> Recommendation {
        guard let minimumAgeDays, minimumAgeDays > 0 else { return recommendation }
        let cutoff = now.addingTimeInterval(-TimeInterval(minimumAgeDays) * 86_400)
        let items = recommendation.items.filter { ($0.modificationDate ?? .distantFuture) < cutoff }
        return Recommendation(kind: recommendation.kind, items: items, risk: recommendation.risk,
                              regeneration: recommendation.regeneration, action: recommendation.action,
                              availability: recommendation.availability, sourceCommands: recommendation.sourceCommands,
                              definition: recommendation.definition)
    }
}

extension CapacityLevel: Codable {}

/// Jobs in `~/Library/Application Support/Stofi/cleanup-jobs.json`.
public struct CleanupJobStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func standard() throws -> CleanupJobStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return CleanupJobStore(fileURL: support.appendingPathComponent("Stofi/cleanup-jobs.json"))
    }

    public func load() throws -> [CleanupJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CleanupJob].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ jobs: [CleanupJob]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}

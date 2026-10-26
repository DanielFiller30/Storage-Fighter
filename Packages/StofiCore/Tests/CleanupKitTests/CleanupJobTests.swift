import AnalysisKit
import Foundation
import ScannerKit
import Testing
@testable import CleanupKit

@Suite("Scheduled clean-ups")
struct CleanupJobTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return calendar
    }

    func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string) ?? .distantPast
    }

    @Test func nextOccurrences() {
        let daily = CleanupJob.Schedule(frequency: .daily, hour: 9, minute: 30)
        #expect(daily.nextOccurrence(after: date("2026-10-26 08:00"), calendar: calendar) == date("2026-10-26 09:30"))
        #expect(daily.nextOccurrence(after: date("2026-10-26 09:30"), calendar: calendar) == date("2026-10-27 09:30"))

        // 2026-10-26 is a Monday; weekday 2 = Monday.
        let weekly = CleanupJob.Schedule(frequency: .weekly, hour: 18, weekday: 6) // Friday
        #expect(weekly.nextOccurrence(after: date("2026-10-26 12:00"), calendar: calendar) == date("2026-10-30 18:00"))

        let monthly = CleanupJob.Schedule(frequency: .monthly, hour: 7, dayOfMonth: 1)
        #expect(monthly.nextOccurrence(after: date("2026-10-26 12:00"), calendar: calendar) == date("2026-11-01 07:00"))
        #expect(CleanupJob.Schedule(frequency: .monthly, dayOfMonth: 31).dayOfMonth == 28)
    }

    @Test func scheduledJobIsDueOnceAndCatchesUpMissedRuns() {
        let created = date("2026-10-20 12:00")
        var job = CleanupJob(name: "Weekly", categories: ["xcodeDerivedData"],
                             schedule: .init(frequency: .daily, hour: 9), createdAt: created)
        // Before the first scheduled time after creation: not due.
        #expect(job.dueTrigger(now: date("2026-10-21 08:59"), currentLevel: .normal, calendar: calendar) == nil)
        // App was not running at 09:00; at 15:00 the missed run is caught up once.
        #expect(job.dueTrigger(now: date("2026-10-21 15:00"), currentLevel: .normal, calendar: calendar)
                == .schedule(date("2026-10-21 09:00")))
        job.lastPrepared = date("2026-10-21 15:00")
        #expect(job.dueTrigger(now: date("2026-10-21 23:00"), currentLevel: .normal, calendar: calendar) == nil)
        // Several missed days still give a single preparation.
        #expect(job.dueTrigger(now: date("2026-10-25 10:00"), currentLevel: .normal, calendar: calendar)
                == .schedule(date("2026-10-25 09:00")))
    }

    @Test func newJobDoesNotFireForThePast() {
        let job = CleanupJob(name: "New", categories: ["userCaches"], schedule: .init(frequency: .daily, hour: 9),
                             createdAt: date("2026-10-26 10:00"))
        #expect(job.dueTrigger(now: date("2026-10-26 10:01"), currentLevel: .normal, calendar: calendar) == nil)
    }

    @Test func lowSpaceTriggerWithCooldown() {
        var job = CleanupJob(name: "Low", categories: ["userCaches"], lowSpaceLevel: .low, createdAt: date("2026-10-01 00:00"))
        #expect(job.dueTrigger(now: date("2026-10-26 10:00"), currentLevel: .normal, calendar: calendar) == nil)
        #expect(job.dueTrigger(now: date("2026-10-26 10:00"), currentLevel: .critical, calendar: calendar) == .lowSpace(.critical))
        job.lastPrepared = date("2026-10-26 10:00")
        #expect(job.dueTrigger(now: date("2026-10-26 20:00"), currentLevel: .critical, calendar: calendar) == nil)
        #expect(job.dueTrigger(now: date("2026-10-27 10:00"), currentLevel: .low, calendar: calendar) == .lowSpace(.low))
    }

    @Test func disabledOrEmptyJobsNeverFire() {
        var job = CleanupJob(name: "Off", categories: ["userCaches"], lowSpaceLevel: .low, createdAt: date("2026-10-01 00:00"))
        job.isEnabled = false
        #expect(job.dueTrigger(now: date("2026-10-26 10:00"), currentLevel: .critical, calendar: calendar) == nil)
        job.isEnabled = true
        job.categories = []
        #expect(job.dueTrigger(now: date("2026-10-26 10:00"), currentLevel: .critical, calendar: calendar) == nil)
    }

    @Test func ageFilterKeepsOnlyOldItemsWithKnownDate() {
        let now = date("2026-10-26 12:00")
        let recommendation = Recommendation(kind: .xcodeDerivedData, items: [
            RecommendationItem(path: "/old", allocatedSize: 1, modificationDate: date("2026-08-01 12:00")),
            RecommendationItem(path: "/new", allocatedSize: 1, modificationDate: date("2026-10-20 12:00")),
            RecommendationItem(path: "/unknown", allocatedSize: 1, modificationDate: nil),
        ], risk: .safe, regeneration: .rebuild, action: .moveToTrash)
        let job = CleanupJob(name: "Old", categories: ["xcodeDerivedData"], minimumAgeDays: 30)
        #expect(job.filtered(recommendation, now: now).items.map(\.path) == ["/old"])
        let noFilter = CleanupJob(name: "All", categories: ["xcodeDerivedData"])
        #expect(noFilter.filtered(recommendation, now: now).items.count == 3)
    }

    @Test func categoryScopeSelectsBuiltInsAndProfileLocations() throws {
        let profiles = try ActivityProfiles.bundled()
        let scope = AnalysisScope.categories(["xcodeDerivedData", "profile.swiftPMCache", "unknown"], profiles: profiles)
        guard case .selected(let builtIns, let locations) = scope else {
            Issue.record("unexpected scope")
            return
        }
        #expect(builtIns == [.xcodeDerivedData])
        #expect(locations.map(\.id) == ["swiftPMCache"])
    }

    @Test func storeRoundTrip() throws {
        let home = try TestHome()
        let store = CleanupJobStore(fileURL: URL(fileURLWithPath: home.path + "/jobs.json"))
        #expect(try store.load().isEmpty)
        let jobs = [CleanupJob(name: "A", categories: ["userCaches"], schedule: .init(frequency: .weekly),
                               lowSpaceLevel: .critical, minimumAgeDays: 14, createdAt: date("2026-10-01 00:00"))]
        try store.save(jobs)
        #expect(try store.load() == jobs)
    }
}

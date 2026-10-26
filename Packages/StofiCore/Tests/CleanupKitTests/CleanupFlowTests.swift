import AnalysisKit
import Darwin
import Foundation
import ScannerKit
import Synchronization
import Testing
@testable import CleanupKit

/// Temporary home folder; never the real one.
final class TestHome {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("StofiCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath gives /private/var/…, like the open-file table of the kernel.
        path = ProtectionPolicy.realpath(base.path) ?? base.path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000) throws -> String {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: full))
        return full
    }
}

/// A Trash inside the test folder, so tests never put anything into the user's real Trash.
final class FakeTrash: TrashHandling, Sendable {
    let directory: String
    private let log = Mutex<[String]>([])

    init(in home: TestHome) throws {
        directory = home.path + "/FakeTrash"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    var actions: [String] { log.withLock { $0 } }

    func moveToTrash(_ url: URL) throws -> URL? {
        let target = URL(fileURLWithPath: directory).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        log.withLock { $0.append("trash " + url.path) }
        return target
    }

    func removePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        log.withLock { $0.append("delete " + url.path) }
    }

    func trashContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory).map { URL(fileURLWithPath: directory + "/" + $0) }
    }
}

final class RecordingCommands: CommandRunning, Sendable {
    private let calls = Mutex<[String]>([])
    var ran: [String] { calls.withLock { $0 } }
    func isExecutable(_ path: String) -> Bool { true }
    func run(_ command: ExternalCommand, timeout: Duration) async -> CommandResult {
        calls.withLock { $0.append(command.displayString) }
        return CommandResult(exitCode: 0, standardOutput: "done\n")
    }
}

func candidate(_ path: String, regeneration: Regeneration = .automatic) -> CleanupCandidate {
    CleanupCandidate(target: .path(path), title: (path as NSString).lastPathComponent, origin: "Test",
                     expectedSize: 10_000, regeneration: regeneration)
}

func planner(_ home: TestHome, usage: UsageSnapshot = UsageSnapshot(openFiles: [], runningApps: []),
             fullDiskAccess: Bool = true) -> CleanupPlanner {
    CleanupPlanner(policy: ProtectionPolicy(homeDirectory: home.path), usage: usage, hasFullDiskAccess: fullDiskAccess)
}

@Suite("Confirmation flow")
struct ConfirmationFlowTests {
    @Test func planRejectsProtectedMissingAndInUseItems() throws {
        let home = try TestHome()
        let cache = try home.file("Library/Caches/com.example.App/blob")
        let open = try home.file("Library/Caches/com.busy.App/blob")
        let usage = UsageSnapshot(openFiles: [(open, "BusyApp")], runningApps: [])

        let plan = planner(home, usage: usage).plan([
            candidate(home.path + "/Library/Caches/com.example.App"),
            candidate(home.path + "/Library/Caches/com.busy.App"),
            candidate(home.path + "/Library/Keychains/login.keychain-db"),
            candidate(home.path + "/Library/Caches/gone"),
        ], method: .moveToTrash)

        #expect(plan.accepted.map(\.candidate.target) == [.path(home.path + "/Library/Caches/com.example.App")])
        #expect(Set(plan.rejected.map(\.reason)) == [.inUse("BusyApp"), .protected(.keychains), .missing])
        #expect(FileManager.default.fileExists(atPath: cache)) // planning removes nothing
    }

    @Test func runningAppsProtectTheirCachesAndBundles() throws {
        let home = try TestHome()
        try home.file("Library/Caches/com.running.App/blob")
        try home.file("Tools/Running.app/Contents/MacOS/Running")
        let usage = UsageSnapshot(openFiles: [], runningApps: [
            RunningApp(name: "Running", bundleIdentifier: "com.running.App", bundlePath: home.path + "/Tools/Running.app"),
        ])
        let plan = planner(home, usage: usage).plan([
            candidate(home.path + "/Library/Caches/com.running.App"), candidate(home.path + "/Tools"),
        ], method: .moveToTrash)
        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.allSatisfy { $0.reason == .inUse("Running") })
    }

    @Test func openFilesOfThisMachineAreDetected() throws {
        let home = try TestHome()
        let path = try home.file("Projects/data.bin")
        // A child process keeps the file open (the inspector ignores the own process).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let usage = UsageSnapshot.capture(runningApps: [])
        #expect(usage.user(of: home.path + "/Projects") == "sleep")
        #expect(usage.user(of: home.path + "/Other") == nil)
    }

    @Test func confirmationNeedsTheRightPlanAndPermanentAcknowledgement() throws {
        let home = try TestHome()
        try home.file("Library/Caches/a/blob")
        let trashPlan = planner(home).plan([candidate(home.path + "/Library/Caches/a")], method: .moveToTrash)
        #expect(throws: ConfirmationError.planMismatch) { try trashPlan.confirm(planID: UUID()) }
        #expect(throws: Never.self) { try trashPlan.confirm(planID: trashPlan.id) }

        let permanentPlan = planner(home).plan([candidate(home.path + "/Library/Caches/a")], method: .deletePermanently)
        #expect(permanentPlan.isPermanent)
        #expect(throws: ConfirmationError.permanentDeletionNotAcknowledged) { try permanentPlan.confirm(planID: permanentPlan.id) }
        #expect(throws: Never.self) { try permanentPlan.confirm(planID: permanentPlan.id, acknowledgingPermanentDeletion: true) }

        let empty = planner(home).plan([], method: .moveToTrash)
        #expect(throws: ConfirmationError.nothingToDo) { try empty.confirm(planID: empty.id) }
    }

    @Test func personalFilesCanOnlyGoToTheTrash() throws {
        let home = try TestHome()
        try home.file("Downloads/movie.mov")
        let plan = planner(home).plan([candidate(home.path + "/Downloads/movie.mov", regeneration: .none)],
                                      method: .deletePermanently)
        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.first?.reason == .permanentNotAllowed)
    }

    @Test func onlyAllowlistedCommandsAreAccepted() throws {
        let home = try TestHome()
        let allowed = ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        let runtime = ExternalCommand(executable: "/usr/bin/xcrun",
                                      arguments: ["simctl", "runtime", "delete", "0E53F36D-753B-44C0-9EEF-8C6E58F32D88"])
        let conda = ExternalCommand(executable: home.path + "/miniconda3/bin/conda", arguments: ["clean", "--all", "--yes"])
        let sneaky = [
            ExternalCommand(executable: "/bin/rm", arguments: ["-rf", home.path]),
            ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", "all"]),
            ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "all"]),
            ExternalCommand(executable: "/tmp/brew", arguments: ["cleanup", "--prune=all"]),
            ExternalCommand(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--force", "git"]),
        ]
        let candidates = ([allowed, runtime, conda] + sneaky).map {
            CleanupCandidate(target: .command($0), title: $0.displayString, origin: "Test", expectedSize: 0, regeneration: .download)
        }
        let plan = planner(home).plan(candidates, method: .moveToTrash)
        #expect(plan.accepted.count == 3)
        #expect(plan.rejected.count == sneaky.count)
        #expect(plan.rejected.allSatisfy { $0.reason == .commandNotAllowed })
    }

    @Test func emptyingTheTrashNeedsFullDiskAccessAndIsPermanent() throws {
        let home = try TestHome()
        let target = CleanupCandidate(target: .emptyTrash, title: "Trash", origin: "Test", expectedSize: 0, regeneration: .none)
        #expect(planner(home, fullDiskAccess: false).plan([target], method: .moveToTrash).rejected.first?.reason == .needsFullDiskAccess)
        let plan = planner(home).plan([target], method: .moveToTrash)
        #expect(plan.isPermanent)
        #expect(throws: ConfirmationError.permanentDeletionNotAcknowledged) { try plan.confirm(planID: plan.id) }
    }
}

@Suite("Execution")
struct ExecutionTests {
    @Test func movesToTheTrashAndReportsTheNewLocation() async throws {
        let home = try TestHome()
        try home.file("Library/Caches/a/blob")
        let trash = try FakeTrash(in: home)
        let planner = planner(home)
        let plan = planner.plan([candidate(home.path + "/Library/Caches/a")], method: .moveToTrash)
        let report = await CleanupExecutor(planner: planner, trash: trash, commands: RecordingCommands(),
                                           volumeURL: URL(fileURLWithPath: home.path))
            .execute(try plan.confirm(planID: plan.id))

        #expect(report.results.first?.outcome == .movedToTrash(trashPath: trash.directory + "/a"))
        #expect(!FileManager.default.fileExists(atPath: home.path + "/Library/Caches/a"))
        #expect(FileManager.default.fileExists(atPath: trash.directory + "/a/blob"))
        #expect(report.bytesInTrash == 10_000)
        #expect(report.availableBefore != nil && report.availableAfter != nil)
    }

    @Test func itemsChangedAfterPlanningAreSkipped() async throws {
        let home = try TestHome()
        try home.file("Library/Caches/a/blob")
        try home.file("Library/Caches/b/blob")
        let trash = try FakeTrash(in: home)
        let planner = planner(home)
        let plan = planner.plan([candidate(home.path + "/Library/Caches/a"), candidate(home.path + "/Library/Caches/b")],
                                method: .moveToTrash)
        let confirmed = try plan.confirm(planID: plan.id)

        // After confirmation: "a" is replaced by a link to the keychain folder, "b" by a different folder.
        try FileManager.default.createDirectory(atPath: home.path + "/Library/Keychains", withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: home.path + "/Library/Caches/a")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Library/Caches/a", withDestinationPath: home.path + "/Library/Keychains")
        try FileManager.default.removeItem(atPath: home.path + "/Library/Caches/b")
        try home.file("Library/Caches/b/other")

        let report = await CleanupExecutor(planner: planner, trash: trash, commands: RecordingCommands(),
                                           volumeURL: URL(fileURLWithPath: home.path)).execute(confirmed)
        #expect(report.results.allSatisfy { $0.outcome == .skipped(.changedSincePlanning) })
        #expect(trash.actions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.path + "/Library/Keychains"))
    }

    @Test func permanentDeletionAndCommands() async throws {
        let home = try TestHome()
        try home.file("Library/Caches/a/blob")
        let trash = try FakeTrash(in: home)
        let commands = RecordingCommands()
        let planner = planner(home)
        let command = ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        let plan = planner.plan([
            candidate(home.path + "/Library/Caches/a"),
            CleanupCandidate(target: .command(command), title: "Simulators", origin: "Test", expectedSize: 0, regeneration: .notApplicable),
        ], method: .deletePermanently)
        // The command is not a path, so it is allowed with the permanent method as well.
        #expect(plan.accepted.count == 2)
        let report = await CleanupExecutor(planner: planner, trash: trash, commands: commands,
                                           volumeURL: URL(fileURLWithPath: home.path))
            .execute(try plan.confirm(planID: plan.id, acknowledgingPermanentDeletion: true))
        #expect(report.results.map(\.succeeded) == [true, true])
        #expect(trash.actions == ["delete " + home.path + "/Library/Caches/a"])
        #expect(commands.ran == ["xcrun simctl delete unavailable"])
    }

    @Test func logRoundTrip() throws {
        let home = try TestHome()
        let store = CleanupLogStore(fileURL: URL(fileURLWithPath: home.path + "/Log/cleanup-log.json"))
        #expect(try store.load().isEmpty)
        let report = CleanupReport(id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000), method: .moveToTrash,
                                   results: [CleanupItemResult(candidate: candidate("/x"), outcome: .movedToTrash(trashPath: "/t/x"))],
                                   availableBefore: 100, availableAfter: 150)
        try store.append(report)
        try store.append(report)
        let loaded = try store.load()
        #expect(loaded.count == 2)
        #expect(loaded.first == report)
        #expect(loaded.first?.measuredFreedBytes == 50)
    }
}

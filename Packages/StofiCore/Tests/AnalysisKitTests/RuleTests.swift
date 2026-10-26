import Foundation
import ScannerKit
import Testing
@testable import AnalysisKit

@Suite("Location rules")
struct LocationRuleTests {
    @Test(arguments: [true, false])
    func cachesArePerAppAndExcludeFoldersWithOwnRecommendation(useFullScan: Bool) async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.App/data.bin", bytes: 3_000_000)
        try home.file("Library/Caches/com.other.App/data.bin", bytes: 1_000_000)
        try home.file("Library/Caches/Homebrew/bottle.tar.gz", bytes: 2_000_000)
        try home.file("Library/Logs/App/log.txt", bytes: 500_000)
        // Hybrid lookup: with a full scan, or with targeted scans of only these locations.
        let tree = useFullScan ? try await home.scan() : nil

        let results = await RecommendationEngine(context: context(home, tree: tree)).analyze()
        let caches = try #require(results[.userCaches])
        #expect(Set(caches.items.map { ($0.path as NSString).lastPathComponent }) == ["com.example.App", "com.other.App"])
        #expect(caches.items.first?.path == home.path + "/Library/Caches/com.example.App")
        #expect(caches.risk == .safe && caches.regeneration == .automatic && caches.action == .moveToTrash)
        #expect(results[.homebrewCache]?.totalSize ?? 0 >= 2_000_000)
        #expect(results[.userLogs]?.items.count == 1)
    }

    @Test func missingLocationsProduceNoRecommendation() async throws {
        let home = try FakeHome()
        try home.directory("Documents")
        let results = await RecommendationEngine(context: context(home, tree: try await home.scan())).analyze()
        #expect(results.isEmpty)
    }

    @Test func downloadsOnlyListsLargeOrOldItems() async throws {
        let home = try FakeHome()
        try home.file("Downloads/installer.dmg", bytes: 3_000_000)
        try home.file("Downloads/old.pdf", bytes: 10_000, ageInDays: 400)
        try home.file("Downloads/recent-small.pdf", bytes: 10_000)
        var thresholds = AnalysisThresholds()
        thresholds.largeDownload = 2_000_000

        let results = await RecommendationEngine(context: context(home, tree: try await home.scan(),
                                                                  thresholds: thresholds)).analyze()
        let downloads = try #require(results[.downloads])
        #expect(Set(downloads.items.map { ($0.path as NSString).lastPathComponent }) == ["installer.dmg", "old.pdf"])
        #expect(downloads.risk == .caution && downloads.regeneration == .none)
    }

    @Test func otherAppsContainersNeedFullDiskAccess() async throws {
        let home = try FakeHome()
        try home.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf", bytes: 1_500_000)
        try home.file("Library/Application Support/MobileSync/Backup/0000-1111/Manifest.db", bytes: 1_500_000)

        // Without a full scan and without access, nothing below the containers is touched.
        let withoutAccess = await RecommendationEngine(context: context(home, tree: nil, fullDiskAccess: false)).analyze()
        #expect(withoutAccess[.mailDownloads]?.availability == .needsFullDiskAccess)
        #expect(withoutAccess[.mailDownloads]?.items.isEmpty == true)
        #expect(withoutAccess[.iosBackups]?.availability == .needsFullDiskAccess)

        // Docker is not installed, so its container is not even mentioned.
        #expect(withoutAccess[.dockerData] == nil)
        let withDocker = await RecommendationEngine(context: context(home, tree: nil, fullDiskAccess: false,
                                                                     installedApps: ["com.docker.docker"])).analyze()
        #expect(withDocker[.dockerData]?.availability == .needsFullDiskAccess)

        let withAccess = await RecommendationEngine(context: context(home, tree: nil, fullDiskAccess: true)).analyze()
        #expect(withAccess[.mailDownloads]?.totalSize ?? 0 >= 1_500_000)
        #expect(withAccess[.iosBackups]?.items.map(\.path) == [home.path + "/Library/Application Support/MobileSync/Backup/0000-1111"])
        #expect(withAccess[.iosBackups]?.risk == .expert)
    }

    @Test func trashIsEmptiedNotMovedToTrash() async throws {
        let home = try FakeHome()
        try home.file(".Trash/old.zip", bytes: 1_200_000)
        let results = await RecommendationEngine(context: context(home, tree: try await home.scan())).analyze()
        #expect(results[.trash]?.action == .emptyTrash)
    }

    @Test func xcodeLocations() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 2_000_000)
        try home.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 1_100_000)
        try home.file("Library/Developer/Xcode/iOS DeviceSupport/18.3 (22D63)/Symbols/dyld", bytes: 1_300_000)
        try home.file("Library/Developer/Xcode/watchOS DeviceSupport/11.0/Symbols/dyld", bytes: 1_100_000)

        let results = await RecommendationEngine(context: context(home, tree: try await home.scan())).analyze()
        #expect(results[.xcodeDerivedData]?.regeneration == .rebuild)
        #expect(results[.xcodeArchives]?.risk == .caution)
        #expect(results[.xcodeDeviceSupport]?.items.count == 2)
    }

    @Test func homebrewUsesCleanupCommandWhenInstalled() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 1_100_000)
        let commands = FakeCommands(executables: ["/opt/homebrew/bin/brew"])
        let results = await RecommendationEngine(context: context(home, tree: nil, commands: commands)).analyze()
        #expect(results[.homebrewCache]?.action
                == .command(ExternalCommand(executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all"])))
        // Nothing was executed: the command is only proposed.
        #expect(!commands.ranCommands.contains { $0.contains("brew") })
    }

    @Test func dockerWithoutCLIIsInformationOnly() async throws {
        let home = try FakeHome()
        try home.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 1_500_000)
        let results = await RecommendationEngine(context: context(home, tree: nil)).analyze()
        let docker = try #require(results[.dockerData])
        #expect(docker.action == .informationOnly && docker.risk == .expert)
        #expect(docker.items.first?.path.hasSuffix("Docker.raw") == true)
    }
}

@Suite("Heuristics")
struct HeuristicTests {
    @Test func inactiveNodeModulesOnlyInOldProjectsWithPackageJSON() async throws {
        let home = try FakeHome()
        // Old project.
        try home.file("Projects/old/node_modules/lib/index.js", bytes: 1_500_000)
        try home.file("Projects/old/package.json", bytes: 100)
        try home.directory("Projects/old/src")
        for path in ["Projects/old/src", "Projects/old/package.json", "Projects/old"] { try home.age(path, days: 200) }
        // Recently changed project.
        try home.file("Projects/new/node_modules/lib/index.js", bytes: 1_500_000)
        try home.file("Projects/new/package.json", bytes: 100)
        // Old, but no package.json → not a project we understand.
        try home.file("Projects/odd/node_modules/x.js", bytes: 1_500_000)
        try home.age("Projects/odd", days: 200)
        // Tool data in hidden or Library folders must never be suggested.
        try home.file(".vscode/extensions/ext/node_modules/x.js", bytes: 1_500_000)
        try home.file(".vscode/extensions/ext/package.json", bytes: 100)
        try home.age(".vscode/extensions/ext", days: 200)
        try home.file("Library/Application Support/App/node_modules/x.js", bytes: 1_500_000)
        try home.file("Library/Application Support/App/package.json", bytes: 100)
        try home.age("Library/Application Support/App", days: 200)

        let results = await RecommendationEngine(context: context(home, tree: try await home.scan())).analyze()
        let modules = try #require(results[.inactiveNodeModules])
        #expect(modules.items.map(\.path) == [home.path + "/Projects/old/node_modules"])
        #expect(modules.items.first?.detail == "old")
    }

    @Test func largeMediaExcludesManagedLibrariesAndAppData() async throws {
        let home = try FakeHome()
        try home.file("Movies/holiday.mov", bytes: 2_000_000)
        try home.file("Movies/small.mov", bytes: 100_000)
        try home.file("Documents/report.pdf", bytes: 2_000_000)
        try home.file("Pictures/Photos Library.photoslibrary/originals/IMG_1.mov", bytes: 2_000_000)
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/clip.mp4", bytes: 2_000_000)
        try home.file("Movies/Project.fcpbundle/Media/clip.mov", bytes: 2_000_000)
        var thresholds = AnalysisThresholds()
        thresholds.largeMedia = 1_000_000

        let results = await RecommendationEngine(context: context(home, tree: try await home.scan(),
                                                                  thresholds: thresholds)).analyze()
        #expect(results[.largeMedia]?.items.map(\.path) == [home.path + "/Movies/holiday.mov"])
    }

    @Test func personalFileFilter() {
        let home = "/Users/me"
        #expect(PersonalFiles.isPersonal("/Users/me/Movies/a.mov", home: home))
        #expect(!PersonalFiles.isPersonal("/Users/me/Library/a.mov", home: home))
        #expect(!PersonalFiles.isPersonal("/Users/me/.cache/a.mov", home: home))
        #expect(!PersonalFiles.isPersonal("/Users/me/Music/Music Library.musiclibrary/a.m4a", home: home))
        #expect(!PersonalFiles.isPersonal("/Users/other/a.mov", home: home))
        #expect(!PersonalFiles.isPersonal("/Users/meX/a.mov", home: home))
    }
}

@Suite("Tool rules")
struct ToolRuleTests {
    static let runtimesJSON = """
        {
          "0E53F36D-753B-44C0-9EEF-8C6E58F32D88" : {
            "build" : "22D8075", "deletable" : true, "identifier" : "0E53F36D-753B-44C0-9EEF-8C6E58F32D88",
            "lastUsedAt" : "2026-01-15T14:51:21Z",
            "path" : "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-ACF1/Restore/044.dmg",
            "platformIdentifier" : "com.apple.platform.iphonesimulator",
            "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-3",
            "sizeBytes" : 8708125252, "state" : "Ready", "version" : "18.3.1"
          },
          "1FB6DD32-1403-4726-9C54-35B7D327F71E" : {
            "build" : "23F77", "deletable" : false, "identifier" : "1FB6DD32-1403-4726-9C54-35B7D327F71E",
            "path" : "/System/Library/AssetsV2/x.dmg", "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "sizeBytes" : 8494282293, "version" : "26.5"
          }
        }
        """
    static let devicesJSON = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"udid": "A", "name": "iPhone 15", "isAvailable": false, "dataPathSize": 123456789,
             "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/A/data"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "B", "name": "iPhone 18", "isAvailable": true, "dataPathSize": 5,
             "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/B/data"}
          ]
        }}
        """

    static func commands(xcodeInstalled: Bool = true, snapshots: String = "Snapshots for disk /:\n") -> FakeCommands {
        var outputs: [String: CommandResult] = [
            "/usr/bin/tmutil listlocalsnapshots /": CommandResult(exitCode: 0, standardOutput: snapshots),
        ]
        if xcodeInstalled {
            outputs["/usr/bin/xcode-select -p"] = CommandResult(exitCode: 0, standardOutput: "/Applications/Xcode.app/Contents/Developer\n")
            outputs["/usr/bin/xcrun simctl runtime list -j"] = CommandResult(exitCode: 0, standardOutput: runtimesJSON)
            outputs["/usr/bin/xcrun simctl list -j devices"] = CommandResult(exitCode: 0, standardOutput: devicesJSON)
        } else {
            outputs["/usr/bin/xcode-select -p"] = CommandResult(exitCode: 2, standardOutput: "", standardError: "no developer tools")
        }
        return FakeCommands(outputs: outputs)
    }

    @Test func simulatorRuntimesAndUnavailableDevices() async throws {
        let home = try FakeHome()
        let commands = Self.commands()
        let results = await RecommendationEngine(context: context(home, tree: nil, commands: commands)).analyze()

        let runtimes = try #require(results[.simulatorRuntimes])
        #expect(runtimes.items.count == 1) // the non-deletable runtime is left out
        #expect(runtimes.items[0].allocatedSize == 8_708_125_252)
        #expect(runtimes.items[0].detail == "iOS 18.3.1 (22D8075)")
        #expect(runtimes.items[0].command?.displayString == "xcrun simctl runtime delete 0E53F36D-753B-44C0-9EEF-8C6E58F32D88")
        #expect(runtimes.regeneration == .download)

        let devices = try #require(results[.simulatorUnavailableDevices])
        #expect(devices.items.map(\.detail) == ["iPhone 15"])
        #expect(devices.items[0].path == "/Users/me/Library/Developer/CoreSimulator/Devices/A")
        #expect(devices.action == .command(RecommendationEngine.deleteUnavailable))
        // Only listing commands ran; the delete command is just proposed.
        #expect(!commands.ranCommands.contains { $0.contains("delete") })
    }

    @Test func withoutDeveloperToolsXcrunIsNeverCalled() async throws {
        let home = try FakeHome()
        let commands = Self.commands(xcodeInstalled: false)
        let results = await RecommendationEngine(context: context(home, tree: nil, commands: commands)).analyze()
        #expect(results[.simulatorRuntimes] == nil)
        #expect(!commands.ranCommands.contains { $0.hasPrefix("/usr/bin/xcrun") })
    }

    @Test func localSnapshotsAreListedButNotActionable() async throws {
        let home = try FakeHome()
        let output = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-26-101010.local\ncom.apple.TimeMachine.2026-10-25-091500.local\n"
        let results = await RecommendationEngine(context: context(home, tree: nil, commands: Self.commands(snapshots: output))).analyze()
        let snapshots = try #require(results[.localSnapshots])
        #expect(snapshots.items.count == 2)
        #expect(snapshots.action == .informationOnly)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                         from: try #require(snapshots.items.first { $0.path.contains("10-26") }?.modificationDate))
        #expect(components.year == 2026 && components.month == 10 && components.day == 26 && components.hour == 10 && components.minute == 10)
    }

    @Test func noSnapshotsMeansNoRecommendation() async throws {
        let home = try FakeHome()
        let results = await RecommendationEngine(context: context(home, tree: nil, commands: Self.commands())).analyze()
        #expect(results[.localSnapshots] == nil)
    }

    @Test func parsersTolerateGarbage() {
        #expect(SimctlParser.runtimes(from: "not json").isEmpty)
        #expect(SimctlParser.unavailableDevices(from: "{}").isEmpty)
        #expect(TmutilParser.snapshots(from: "").isEmpty)
    }

    @Test func realCommandRunnerRunsWithoutShellAndTimesOut() async {
        let runner = ProcessCommandRunner()
        let echo = await runner.run(ExternalCommand(executable: "/bin/echo", arguments: ["a b", "$HOME"]), timeout: .seconds(5))
        // No shell: the argument is passed literally, `$HOME` is not expanded.
        #expect(echo.standardOutput == "a b $HOME\n")
        let sleep = await runner.run(ExternalCommand(executable: "/bin/sleep", arguments: ["10"]), timeout: .milliseconds(300))
        #expect(sleep.timedOut)
        let missing = await runner.run(ExternalCommand(executable: "/nonexistent", arguments: []), timeout: .seconds(1))
        #expect(!missing.succeeded)
    }
}

@Suite("LaunchServices")
struct LaunchServicesTests {
    @Test func knowsSystemAppsAndRejectsUnknownIdentifiers() {
        #expect(AnalysisContext.launchServicesKnowsApp("com.apple.finder"))
        #expect(!AnalysisContext.launchServicesKnowsApp("de.df.stofi.does-not-exist"))
    }
}

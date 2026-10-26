import Foundation
import ScannerKit
import Testing
@testable import AnalysisKit

@Suite("Bundled profile files")
struct BundledProfileTests {
    let profiles: [ActivityProfile]

    init() throws {
        profiles = try ActivityProfiles.bundled()
    }

    @Test func allEightProfilesLoadInOrder() {
        #expect(profiles.map(\.id) == ActivityProfiles.order)
    }

    @Test func idsAreUniqueAndTextsExistInGermanAndEnglish() {
        let locationIDs = profiles.flatMap(\.locations).map(\.id)
        #expect(Set(locationIDs).count == locationIDs.count)
        for profile in profiles {
            #expect(profile.title.values["en"]?.isEmpty == false && profile.title.values["de"]?.isEmpty == false)
            #expect(profile.summary.values.keys.sorted() == ["de", "en"])
            #expect(!profile.builtIns.isEmpty || !profile.locations.isEmpty)
        }
        for location in profiles.flatMap(\.locations) {
            #expect(location.title.values.keys.sorted() == ["de", "en"], "\(location.id)")
            #expect(location.explanation.values.keys.sorted() == ["de", "en"], "\(location.id)")
        }
    }

    /// Profile files are data, so they get checked like code: no location may point at a folder that is
    /// far too broad to ever be suggested, and commands must never be generic deletion tools.
    @Test func locationsNeverPointAtProtectedRoots() {
        let forbidden: Set<String> = ["~", "~/", "~/Library", "~/Documents", "~/Desktop", "~/Pictures", "~/Movies",
                                      "~/Music", "~/Downloads", "~/Library/Mobile Documents", "/", "/System",
                                      "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/Users"]
        for location in profiles.flatMap(\.locations) {
            for path in location.paths {
                #expect(path.hasPrefix("~/") || path.hasPrefix("/"), "\(location.id): \(path)")
                #expect(!path.contains(".."), "\(location.id): \(path)")
                if location.mode != .search && location.action.type != .info {
                    #expect(!forbidden.contains(path), "\(location.id) suggests removing \(path)")
                    #expect(!path.hasPrefix("/System") && !path.hasPrefix("/usr"), "\(location.id): \(path)")
                }
            }
            if location.mode == .search { #expect(location.match?.isEmpty == false, "\(location.id)") }
            if location.action.type == .command {
                let executables = location.action.executables ?? []
                #expect(!executables.isEmpty, "\(location.id)")
                for executable in executables {
                    let name = (executable as NSString).lastPathComponent
                    #expect(!["rm", "sh", "bash", "zsh", "sudo", "find"].contains(name), "\(location.id): \(executable)")
                }
            }
        }
    }

    @Test func localizedTextFallsBackToEnglish() {
        let text = LocalizedText(["en": "Cache", "de": "Zwischenspeicher"])
        #expect(text.resolved(preferredLanguages: ["de-DE"]) == "Zwischenspeicher")
        #expect(text.resolved(preferredLanguages: ["fr-FR", "en-US"]) == "Cache")
        #expect(text.resolved(preferredLanguages: ["ja"]) == "Cache")
    }
}

@Suite("Quickscan")
struct QuickscanTests {
    static func profile(_ id: String) throws -> ActivityProfile {
        try #require(try ActivityProfiles.bundled().first { $0.id == id })
    }

    @Test func quickscanOnlyMeasuresTheSelectedProfiles() async throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/Steam/steamapps/common/Game A/data.pak", bytes: 3_000_000)
        try home.file("Library/Application Support/Steam/steamapps/common/Game B/data.pak", bytes: 1_500_000)
        try home.file("Library/Application Support/Steam/steamapps/shadercache/123/cache.bin", bytes: 1_200_000)
        try home.file("Library/Caches/com.example.App/blob", bytes: 2_000_000)
        try home.file("Library/Developer/Xcode/DerivedData/App/x.o", bytes: 2_000_000)

        let engine = RecommendationEngine(context: context(home, tree: nil))
        let results = await engine.analyze(scope: .quick(profiles: [try Self.profile("gaming")]))
        #expect(Set(results.map(\.id)) == ["profile.steamGames", "profile.steamShaderCache"])
        let games = try #require(results.first { $0.id == "profile.steamGames" })
        #expect(games.items.map { ($0.path as NSString).lastPathComponent } == ["Game A", "Game B"])
        #expect(games.action == .informationOnly) // uninstall in Steam, not in the Finder
        #expect(games.group == .gaming)
    }

    @Test func fullScopeIncludesBuiltInsAndProfileLocations() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.App/blob", bytes: 2_000_000)
        try home.file(".cache/huggingface/hub/models--org--model/blobs/abc", bytes: 2_500_000)
        let engine = RecommendationEngine(context: context(home, tree: try await home.scan()))
        let results = await engine.analyze(scope: .full(profiles: try ActivityProfiles.bundled()))
        #expect(results[.userCaches] != nil)
        let models = try #require(results.first { $0.id == "profile.huggingFaceCache" })
        #expect(models.items.map { ($0.path as NSString).lastPathComponent } == ["models--org--model"])
    }

    @Test func cacheFoldersOfProfilesAreNotCountedTwice() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/org.swift.swiftpm/repositories/x.pack", bytes: 2_000_000)
        try home.file("Library/Caches/com.example.App/blob", bytes: 1_000_000)
        let engine = RecommendationEngine(context: context(home, tree: nil))
        let results = await engine.analyze(scope: .quick(profiles: [try Self.profile("everyday"), try Self.profile("appleDevelopment")]))
        let caches = try #require(results[.userCaches])
        #expect(caches.items.map { ($0.path as NSString).lastPathComponent } == ["com.example.App"])
        #expect(results.contains { $0.id == "profile.swiftPMCache" })
    }

    @Test func searchModeFindsMatchingFolders() async throws {
        let home = try FakeHome()
        try home.file("Pictures/Lightroom/Catalog Previews.lrdata/a/b.lrprev", bytes: 1_500_000)
        try home.file("Pictures/Lightroom/Catalog.lrcat", bytes: 1_500_000)
        try home.file("Movies/My.fcpbundle/Event 1/Render Files/High Quality Media/x.mov", bytes: 2_000_000)
        let engine = RecommendationEngine(context: context(home, tree: try await home.scan()))
        let results = await engine.analyze(scope: .quick(profiles: [try Self.profile("videoPhoto")]))
        let previews = try #require(results.first { $0.id == "profile.lightroomPreviews" })
        #expect(previews.items.map { ($0.path as NSString).lastPathComponent } == ["Catalog Previews.lrdata"])
        let renders = try #require(results.first { $0.id == "profile.finalCutRenderFiles" })
        #expect(renders.items.first?.path == home.path + "/Movies/My.fcpbundle/Event 1/Render Files")
        #expect(renders.action == .informationOnly)
    }

    @Test func commandsAreOnlyOfferedWhenTheProgramExists() async throws {
        let home = try FakeHome()
        try home.file("miniconda3/pkgs/numpy-1.0.tar.bz2", bytes: 1_200_000)
        let missing = await RecommendationEngine(context: context(home, tree: nil))
            .analyze(scope: .quick(profiles: [try Self.profile("aiData")]))
        #expect(missing.first { $0.id == "profile.condaPackages" }?.action == .informationOnly)

        let conda = home.path + "/miniconda3/bin/conda"
        let installed = await RecommendationEngine(context: context(home, tree: nil, commands: FakeCommands(executables: [conda])))
            .analyze(scope: .quick(profiles: [try Self.profile("aiData")]))
        #expect(installed.first { $0.id == "profile.condaPackages" }?.action
                == .command(ExternalCommand(executable: conda, arguments: ["clean", "--all", "--yes"])))
    }

    @Test func containersOfMissingAppsAreSkippedWithoutAccess() async throws {
        let home = try FakeHome()
        let engine = RecommendationEngine(context: context(home, tree: nil, fullDiskAccess: false, installedApps: []))
        let results = await engine.analyze(scope: .quick(profiles: [try Self.profile("everyday")]))
        // Teams is not installed: no hint. Messages is a system location: needs access.
        #expect(!results.contains { $0.id == "profile.teamsCache" })
        #expect(results.first { $0.id == "profile.messagesAttachments" }?.availability == .needsFullDiskAccess)
    }
}

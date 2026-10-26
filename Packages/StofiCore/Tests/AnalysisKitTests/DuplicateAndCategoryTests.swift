import Darwin
import Foundation
import ScannerKit
import Testing
@testable import AnalysisKit

@Suite("Duplicates")
struct DuplicateTests {
    @Test func findsIdenticalFilesOnly() async throws {
        let home = try FakeHome()
        let original = try home.file("Documents/a.bin", bytes: 300_000)
        let copy = home.path + "/Documents/Backup/a copy.bin"
        try FileManager.default.createDirectory(atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Write the bytes again: `FileManager.copyItem` would create an APFS clone that shares its blocks.
        try Data(contentsOf: URL(fileURLWithPath: original)).write(to: URL(fileURLWithPath: copy))
        // Same size, different content (differs only after the first 64 KiB).
        var data = try Data(contentsOf: URL(fileURLWithPath: original))
        data[200_000] ^= 0xFF
        try data.write(to: URL(fileURLWithPath: home.path + "/Documents/almost.bin"))
        // Hard link: same inode, counted once by the scan, so not a duplicate.
        #expect(link(original, home.path + "/Documents/hardlink.bin") == 0)
        // Duplicates in app data are not suggested.
        try FileManager.default.createDirectory(atPath: home.path + "/Library/App", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: original, toPath: home.path + "/Library/App/a.bin")

        let groups = try await DuplicateFinder(tree: try await home.scan(), homeDirectory: home.path).find()
        #expect(groups.count == 1)
        #expect(Set(groups[0].files.map(\.path)).count == 2)
        #expect(groups[0].files.allSatisfy { !$0.path.contains("almost") && !$0.path.contains("Library") })
        #expect(groups[0].reclaimableSize >= 300_000)
    }

    @Test func clonesFreeNothing() async throws {
        let home = try FakeHome()
        let original = try home.file("Documents/movie.bin", bytes: 2_000_000)
        try #require(clonefile(original, home.path + "/Documents/movie clone.bin", 0) == 0)

        let groups = try await DuplicateFinder(tree: try await home.scan(), homeDirectory: home.path).find()
        #expect(groups.count == 1)
        // The two copies share their blocks, so removing one frees (almost) nothing.
        #expect(groups[0].reclaimableSize < 100_000)
    }

    @Test func recommendationKeepsOneCopyPerGroup() async throws {
        let home = try FakeHome()
        let original = try home.file("Documents/x.bin", bytes: 200_000)
        for index in 1...2 {
            try FileManager.default.copyItem(atPath: original, toPath: home.path + "/Documents/x\(index).bin")
        }
        let groups = try await DuplicateFinder(tree: try await home.scan(), homeDirectory: home.path).find()
        let recommendation = DuplicateFinder.recommendation(for: groups)
        #expect(recommendation.items.count == 2)
        #expect(recommendation.kind == .duplicates && recommendation.risk == .caution)
    }

    @Test func cancellationStopsTheSearch() async throws {
        let home = try FakeHome()
        let original = try home.file("Documents/x.bin", bytes: 200_000)
        try FileManager.default.copyItem(atPath: original, toPath: home.path + "/Documents/y.bin")
        let finder = DuplicateFinder(tree: try await home.scan(), homeDirectory: home.path)
        let task = Task { try await finder.find() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func privateSizeIsReadable() throws {
        let home = try FakeHome()
        let path = try home.file("a.bin", bytes: 1_000_000)
        let size = try #require(FileMetadata.privateSize(atPath: path))
        #expect(size >= 1_000_000)
    }
}

@Suite("Storage categories")
struct StorageCategoryTests {
    @Test func everyByteLandsInOneCategory() async throws {
        let root = try FakeHome()
        try root.file("Applications/App.app/Contents/MacOS/App", bytes: 3_000_000)
        try root.file("Users/me/Documents/doc.bin", bytes: 2_000_000)
        try root.file("Users/me/Library/Caches/x/cache.bin", bytes: 1_000_000)
        try root.file("Users/me/Library/Application Support/App/data.bin", bytes: 1_500_000)
        try root.file("Users/me/Library/Developer/Xcode/DerivedData/x.bin", bytes: 2_500_000)
        try root.file("Users/me/.gradle/caches/x.bin", bytes: 500_000)
        try root.file("Library/Caches/system.bin", bytes: 700_000)
        try root.file("Library/Preferences/pref.bin", bytes: 300_000)
        let tree = try await root.scan()
        let scanned = tree.allocatedSize(of: tree.root)

        let categories = StorageCategories.compute(tree: tree, startupVolume: .current(),
                                                   volumeUsedBytes: scanned + 10_000_000,
                                                   systemVolumeUsedBytes: 4_000_000, pathPrefix: root.path)
        func bytes(_ kind: StorageCategoryKind) -> UInt64 { categories.first { $0.kind == kind }?.bytes ?? 0 }

        #expect(bytes(.applications) >= 3_000_000)
        #expect(bytes(.userData) >= 2_000_000 && bytes(.userData) < 2_200_000)
        #expect(bytes(.developer) >= 3_000_000) // DerivedData + .gradle
        #expect(bytes(.appData) >= 1_500_000 && bytes(.appData) < 1_700_000)
        #expect(bytes(.cachesAndLogs) >= 1_700_000)
        #expect(bytes(.notCaptured) == 6_000_000)
        // Nothing is counted twice: the sum equals the used space of the volume.
        #expect(categories.reduce(0) { $0 + $1.bytes } == scanned + 10_000_000)
    }
}

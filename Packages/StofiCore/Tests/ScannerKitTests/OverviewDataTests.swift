import Foundation
import Testing
@testable import ScannerKit

@Suite("Volume info")
struct VolumeInfoTests {
    @Test func partsAddUpToTheTotal() {
        let info = VolumeInfo(name: "Test", totalCapacity: 1000, availableCapacity: 200,
                              availableForImportantUsage: 350, availableForOpportunisticUsage: 150)
        #expect(info.freeBytes == 200)
        #expect(info.purgeableBytes == 150)
        #expect(info.usedBytes == 650)
        #expect(info.usedBytes + info.purgeableBytes + info.freeBytes == info.totalCapacity)
        #expect(abs(info.availableFraction - 0.35) < 0.0001)
    }

    @Test func importantBelowFreeMeansNothingPurgeable() {
        let info = VolumeInfo(name: "Test", totalCapacity: 1000, availableCapacity: 300,
                              availableForImportantUsage: 250, availableForOpportunisticUsage: 100)
        #expect(info.purgeableBytes == 0)
        #expect(info.usedBytes == 700)
    }

    @Test func clampsInconsistentValues() {
        let info = VolumeInfo(name: "Test", totalCapacity: 100, availableCapacity: 500,
                              availableForImportantUsage: 900, availableForOpportunisticUsage: 0)
        #expect(info.usedBytes + info.purgeableBytes + info.freeBytes == 100)
    }

    @Test func readsTheStartupVolume() throws {
        let info = try VolumeInfo.read()
        #expect(info.totalCapacity > 0)
        #expect(info.usedBytes + info.purgeableBytes + info.freeBytes == info.totalCapacity)
    }
}

@Suite("Largest items")
struct LargestItemsTests {
    @Test func listsLargestFilesAndDirectoriesSeparately() async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("big/huge.bin", bytes: 3_000_000)
        try dir.makeFile("big/medium.bin", bytes: 2_000_000)
        try dir.makeFile("small/tiny.bin", bytes: 1_000)
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/link", withDestinationPath: dir.path + "/big/huge.bin")
        let tree = try await detailedScanner.scanTree(rootPath: dir.path)
        let volume = StartupVolume.current()

        let files = tree.largestItems(.files, limit: 2, startupVolume: volume)
        #expect(files.map(\.name) == ["huge.bin", "medium.bin"])
        #expect(files[0].path == dir.path + "/big/huge.bin")
        #expect(!files[0].isDirectory)

        let directories = tree.largestItems(.directories, limit: 10, startupVolume: volume)
        #expect(directories.map(\.name) == ["big", "small"])
        #expect(directories[0].fileCount == 2)
    }

    @Test(arguments: [1, 5, 50, 999, 1000, 5000])
    func thresholdMatchesSorting(keep: Int) {
        var generator = SystemRandomNumberGenerator()
        let sizes = (0..<1000).map { _ in UInt64.random(in: 0...500, using: &generator) }
        let expected = sizes.sorted(by: >)[min(keep, sizes.count) - 1]
        #expect(FileTree.sizeThreshold(for: sizes, keeping: keep) == expected)
    }
}

@Suite("Capacity level")
struct CapacityLevelTests {
    func volume(availablePercent: Double) -> VolumeInfo {
        let total: UInt64 = 1_000_000
        let free = UInt64(Double(total) * availablePercent / 100)
        return VolumeInfo(name: "T", totalCapacity: total, availableCapacity: free / 2,
                          availableForImportantUsage: free, availableForOpportunisticUsage: 0)
    }

    @Test(arguments: [(50.0, CapacityLevel.normal), (15.0, .normal), (14.9, .low), (5.0, .low), (4.9, .critical), (0, .critical)])
    func levelsFollowTheThresholds(percent: Double, expected: CapacityLevel) {
        #expect(volume(availablePercent: percent).level(lowPercent: 15, criticalPercent: 5) == expected)
    }

    @Test func purgeableSpaceCountsAsUsable() {
        let info = VolumeInfo(name: "T", totalCapacity: 100, availableCapacity: 2, availableForImportantUsage: 30,
                              availableForOpportunisticUsage: 0)
        #expect(info.usableBytes == 30)
        #expect(info.level(lowPercent: 15, criticalPercent: 5) == .normal)
    }
}

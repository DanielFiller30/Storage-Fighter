import Darwin
import Foundation
import Testing
@testable import ScannerKit

/// A throw-away directory below the system temp directory. Tests never touch real user data.
final class TemporaryDirectory {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StofiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths compare predictably.
        path = base.resolvingSymlinksInPath().path
    }

    deinit {
        // Restore permissions changed by tests so cleanup succeeds.
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                chmod(path + "/" + relative, 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func url(_ relative: String) -> URL { URL(fileURLWithPath: path + "/" + relative) }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random content so APFS cannot compress or deduplicate it.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
        return url
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    /// Allocated size as reported by Foundation, used as the reference value.
    func allocatedSize(_ relative: String) throws -> UInt64 {
        let values = try url(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? 0)
    }
}

/// Scanner with every file as its own node, which makes assertions easy.
let detailedScanner = DiskScanner(options: ScanOptions(maxConcurrency: 4, minimumFileNodeSize: 0))

func detailedScanner(_ api: ScanOptions.DirectoryAPI) -> DiskScanner {
    DiskScanner(options: ScanOptions(maxConcurrency: 4, minimumFileNodeSize: 0, directoryAPI: api))
}

@Suite("Size calculation")
struct SizeCalculationTests {
    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func countsAllocatedNotLogicalSize(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("tiny.txt", bytes: 10)
        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)

        let node = try #require(tree.node(atRelativePath: "tiny.txt"))
        #expect(tree.logicalSize(of: node) == 10)
        #expect(tree.allocatedSize(of: node) == (try dir.allocatedSize("tiny.txt")))
        #expect(tree.allocatedSize(of: node) >= 4096)
    }

    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func aggregatesDirectorySizes(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("a/one.bin", bytes: 100_000)
        try dir.makeFile("a/b/two.bin", bytes: 200_000)
        try dir.makeFile("c/three.bin", bytes: 300_000)
        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)

        let expectedA = try dir.allocatedSize("a/one.bin") + dir.allocatedSize("a/b/two.bin")
        let expectedTotal = try expectedA + dir.allocatedSize("c/three.bin")
        let a = try #require(tree.node(atRelativePath: "a"))
        #expect(tree.allocatedSize(of: a) == expectedA)
        #expect(tree.fileCount(of: a) == 2)
        #expect(tree.allocatedSize(of: tree.root) == expectedTotal)
        #expect(tree.fileCount(of: tree.root) == 3)
        #expect(tree.statistics.regularFiles == 3)
        #expect(tree.statistics.directories == 4) // root, a, a/b, c
    }

    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func sparseFileCountsOnlyAllocatedBlocks(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        let path = dir.path + "/sparse.img"
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        try #require(fd >= 0)
        let logical: off_t = 512 * 1024 * 1024
        #expect(ftruncate(fd, logical) == 0)
        var byte: UInt8 = 1
        #expect(pwrite(fd, &byte, 1, logical - 1) == 1)
        close(fd)

        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)
        let node = try #require(tree.node(atRelativePath: "sparse.img"))
        #expect(tree.logicalSize(of: node) == UInt64(logical))
        #expect(tree.allocatedSize(of: node) < 1024 * 1024)
        #expect(tree.allocatedSize(of: node) == (try dir.allocatedSize("sparse.img")))
    }

    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func hardLinksAreCountedOnce(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("original.bin", bytes: 1_000_000)
        try dir.makeDirectory("other")
        #expect(link(dir.path + "/original.bin", dir.path + "/other/link.bin") == 0)
        #expect(link(dir.path + "/original.bin", dir.path + "/link2.bin") == 0)

        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)
        let single = try dir.allocatedSize("original.bin")
        #expect(tree.allocatedSize(of: tree.root) == single)
        #expect(tree.fileCount(of: tree.root) == 1)
        #expect(tree.statistics.skippedHardLinks == 2)
    }

    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func symlinksAreNotFollowed(api: ScanOptions.DirectoryAPI) async throws {
        let outside = try TemporaryDirectory()
        try outside.makeFile("big.bin", bytes: 2_000_000)
        let dir = try TemporaryDirectory()
        try dir.makeDirectory("inner")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/inner/file-link", withDestinationPath: outside.path + "/big.bin")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/dir-link", withDestinationPath: outside.path)
        // A cycle must not hang the scan.
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/inner/loop", withDestinationPath: dir.path)

        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)
        #expect(tree.allocatedSize(of: tree.root) < 100_000)
        #expect(tree.statistics.symlinks == 3)
        #expect(tree.statistics.regularFiles == 0)
        let dirLink = try #require(tree.node(atRelativePath: "dir-link"))
        #expect(tree.flags(of: dirLink).contains(.symlink))
        #expect(!tree.isDirectory(dirLink))
    }

    @Test func clonesAreReportedAsShared() async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("source.bin", bytes: 4_000_000)
        let cloned = clonefile(dir.path + "/source.bin", dir.path + "/clone.bin", 0)
        try #require(cloned == 0, "clonefile needs APFS for the temp directory")

        let scanner = DiskScanner(options: ScanOptions(minimumFileNodeSize: 0, measurePrivateSize: true))
        let tree = try await scanner.scanTree(rootPath: dir.path)
        let clone = try #require(tree.node(atRelativePath: "clone.bin"))
        // Allocated size counts the clone in full (documented limitation) …
        #expect(tree.allocatedSize(of: clone) >= 4_000_000)
        // … but the shared part is visible, so the UI can tell how much deletion really frees.
        #expect(tree.statistics.sharedBytes >= 4_000_000)
        #expect(tree.privateSize(of: clone) < tree.allocatedSize(of: clone))
    }

    @Test func smallFilesAreFoldedIntoTheirDirectory() async throws {
        let dir = try TemporaryDirectory()
        for index in 0..<20 { try dir.makeFile("many/small-\(index).txt", bytes: 1_000) }
        try dir.makeFile("many/large.bin", bytes: 3_000_000)

        let scanner = DiskScanner(options: ScanOptions(maxConcurrency: 2, minimumFileNodeSize: 1 << 20))
        let tree = try await scanner.scanTree(rootPath: dir.path)
        let many = try #require(tree.node(atRelativePath: "many"))
        #expect(Array(tree.children(of: many)).map { tree.name(of: $0) } == ["large.bin"])
        #expect(tree.fileCount(of: many) == 21)
        #expect(tree.directFileBytes(of: many) >= 20 * 4096)
    }
}

@Suite("Robustness")
struct RobustnessTests {
    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func parsesUnusualNames(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        let names = ["Leerzeichen im Namen.txt", "Ümläute-äöü.txt", "emoji-📦.bin", ".hidden", String(repeating: "x", count: 255)]
        for name in names { try dir.makeFile(name, bytes: 1) }
        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)
        let found = Set(tree.children(of: tree.root).map { tree.name(of: $0) })
        // APFS stores names as given; compare normalised to be independent of NFC/NFD.
        #expect(Set(found.map { $0.precomposedStringWithCanonicalMapping }) ==
                Set(names.map { $0.precomposedStringWithCanonicalMapping }))
    }

    @Test(arguments: ScanOptions.DirectoryAPI.allCases)
    func unreadableDirectoryIsRecordedAndScanContinues(api: ScanOptions.DirectoryAPI) async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("locked/secret.bin", bytes: 10_000)
        try dir.makeFile("open/visible.bin", bytes: 10_000)
        #expect(chmod(dir.path + "/locked", 0) == 0)

        let tree = try await detailedScanner(api).scanTree(rootPath: dir.path)
        let locked = try #require(tree.node(atRelativePath: "locked"))
        #expect(tree.flags(of: locked).contains(.unreadable))
        #expect(tree.statistics.unreadableDirectories == 1)
        #expect(tree.node(atRelativePath: "open/visible.bin") != nil)
        #expect(tree.statistics.sampleErrors.contains { $0.path.hasSuffix("/locked") && $0.code == EACCES })
    }

    @Test func missingRootThrows() async throws {
        let dir = try TemporaryDirectory()
        await #expect(throws: ScanFailure.rootUnreadable(path: dir.path + "/nope", code: ENOENT)) {
            try await detailedScanner.scanTree(rootPath: dir.path + "/nope")
        }
    }

    @Test func pathsAreRebuiltFromTheTree() async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("x/y/z.bin", bytes: 1)
        let tree = try await detailedScanner.scanTree(rootPath: dir.path)
        let node = try #require(tree.node(atRelativePath: "x/y/z.bin"))
        #expect(tree.path(of: node) == dir.path + "/x/y/z.bin")
        #expect(tree.path(of: tree.root) == dir.path)
    }

    @Test func manyDirectoriesInParallelMatchSequentialResult() async throws {
        let dir = try TemporaryDirectory()
        for a in 0..<10 { for b in 0..<10 { try dir.makeFile("d\(a)/e\(b)/f.bin", bytes: 5_000 + a * 100 + b) } }
        let parallel = try await DiskScanner(options: ScanOptions(maxConcurrency: 16, minimumFileNodeSize: 0)).scanTree(rootPath: dir.path)
        let sequential = try await DiskScanner(options: ScanOptions(maxConcurrency: 1, minimumFileNodeSize: 0)).scanTree(rootPath: dir.path)
        #expect(parallel.allocatedSize(of: parallel.root) == sequential.allocatedSize(of: sequential.root))
        #expect(parallel.nodeCount == sequential.nodeCount)
        #expect(parallel.statistics.regularFiles == 100)
    }
}

@Suite("Streaming, pause and cancellation")
struct StreamingTests {
    static func makeWideTree() throws -> TemporaryDirectory {
        let dir = try TemporaryDirectory()
        for a in 0..<40 { for b in 0..<25 { try dir.makeDirectory("d\(a)/e\(b)") } }
        return dir
    }

    @Test func streamEndsWithFinishedTree() async throws {
        let dir = try TemporaryDirectory()
        try dir.makeFile("a/file.bin", bytes: 10_000)
        var finished: FileTree?
        for try await event in detailedScanner.scan(rootPath: dir.path) {
            if case .finished(let tree) = event { finished = tree }
        }
        #expect(try #require(finished).statistics.regularFiles == 1)
    }

    @Test func pausedScanMakesNoProgressUntilResumed() async throws {
        let dir = try Self.makeWideTree()
        let controller = ScanController()
        controller.pause()
        let scanner = DiskScanner(options: ScanOptions(maxConcurrency: 2, progressInterval: .milliseconds(20)))
        let stream = scanner.scan(rootPath: dir.path, controller: controller)

        let consumer = Task { () -> (directoriesWhilePaused: Int, total: Int) in
            var whilePaused = 0
            var total = 0
            for try await event in stream {
                switch event {
                case .progress(let snapshot) where controller.isPaused:
                    whilePaused = max(whilePaused, snapshot.statistics.directories)
                case .finished(let tree):
                    total = tree.statistics.directories
                default: break
                }
            }
            return (whilePaused, total)
        }
        try await Task.sleep(for: .milliseconds(200))
        controller.resume()
        let result = try await consumer.value
        // While paused only the root listing (the 40 top-level directories) may have been read.
        #expect(result.directoriesWhilePaused <= 41)
        #expect(result.total == 1 + 40 + 40 * 25)
    }

    @Test func cancellingAPausedScanThrows() async throws {
        let dir = try Self.makeWideTree()
        let controller = ScanController()
        controller.pause()
        let task = Task {
            try await DiskScanner().scanTree(rootPath: dir.path, controller: controller)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellingTheConsumerEndsTheStream() async throws {
        let dir = try Self.makeWideTree()
        let controller = ScanController()
        controller.pause()
        let stream = DiskScanner().scan(rootPath: dir.path, controller: controller)
        let consumer = Task { () -> Bool in
            var finished = false
            for try await event in stream { if case .finished = event { finished = true } }
            return finished
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        // The stream ends without a finished tree instead of hanging in the paused state.
        #expect(try await consumer.value == false)
    }
}

@Suite("Startup volume")
struct StartupVolumeTests {
    let volume = StartupVolume(firmlinksFileContents: "/Users\tUsers\n/Applications\tApplications\n/usr/local\tusr/local\n")

    @Test func mapsFirmlinkedDataVolumePaths() {
        #expect(volume.displayPath(forDataVolumePath: "/System/Volumes/Data/Users/me/Library") == "/Users/me/Library")
        #expect(volume.displayPath(forDataVolumePath: "/System/Volumes/Data/usr/local/bin") == "/usr/local/bin")
        #expect(volume.displayPath(forDataVolumePath: "/System/Volumes/Data/Applications") == "/Applications")
    }

    @Test func keepsPathsWithoutFirmlink() {
        #expect(volume.displayPath(forDataVolumePath: "/System/Volumes/Data/.Spotlight-V100") == "/System/Volumes/Data/.Spotlight-V100")
        #expect(volume.displayPath(forDataVolumePath: "/System/Volumes/Data/UsersX") == "/System/Volumes/Data/UsersX")
        #expect(volume.displayPath(forDataVolumePath: "/tmp/x") == "/tmp/x")
    }

    @Test func mapsBack() {
        #expect(volume.dataVolumePath(forDisplayPath: "/Users/me") == "/System/Volumes/Data/Users/me")
        #expect(volume.dataVolumePath(forDisplayPath: "/System/Library") == nil)
    }

    @Test func fallsBackWhenFileIsMissing() {
        #expect(StartupVolume(firmlinksFileContents: nil).firmlinkedPaths.contains("Users"))
    }
}

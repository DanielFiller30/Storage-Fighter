import Darwin
import Foundation
import os
import Synchronization

public struct ScanOptions: Sendable {
    /// Maximum number of directories read in parallel.
    ///
    /// Default is half the active cores (at least 2): in StofiBench (M4 Pro, 14 cores) throughput peaked at
    /// 7 workers and dropped by up to 15 % at 14–56 workers due to kernel contention. See `Docs/Benchmark.md`.
    public var maxConcurrency: Int
    /// Files smaller than this get no node of their own; their sizes are folded into the parent directory.
    public var minimumFileNodeSize: UInt64
    /// Interval for ``ScanEvent/progress(_:)`` events.
    public var progressInterval: Duration
    /// Number of root children included in each progress snapshot.
    public var progressTopCount: Int
    /// Also read `ATTR_CMNEXT_PRIVATESIZE` (bytes not shared with clones or snapshots). Costs up to ~55 %
    /// scan time in the benchmark, so it is off by default; cleanup computes it for selected items only.
    public var measurePrivateSize: Bool
    /// Directory-listing API. ``DirectoryAPI/bulk`` is the default; the other exists for the benchmark.
    public var directoryAPI: DirectoryAPI

    public enum DirectoryAPI: Sendable, CaseIterable {
        /// `getattrlistbulk(2)`: metadata of many entries per syscall.
        case bulk
        /// `readdir(3)` + `fstatat(2)`: one stat per entry.
        case posix
    }

    public init(
        maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        minimumFileNodeSize: UInt64 = 1 << 20,
        progressInterval: Duration = .milliseconds(250),
        progressTopCount: Int = 30,
        measurePrivateSize: Bool = false,
        directoryAPI: DirectoryAPI = .bulk
    ) {
        self.maxConcurrency = max(1, maxConcurrency)
        self.minimumFileNodeSize = minimumFileNodeSize
        self.progressInterval = progressInterval
        self.progressTopCount = progressTopCount
        self.measurePrivateSize = measurePrivateSize
        self.directoryAPI = directoryAPI
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanSnapshot)
    case finished(FileTree)
}

public enum ScanFailure: Error, Sendable, Equatable {
    /// The root directory could not be opened (errno).
    case rootUnreadable(path: String, code: Int32)
}

/// Lets the UI pause and resume a running scan. Pausing stops new directories from being started;
/// directories already being read finish first.
public final class ScanController: Sendable {
    private struct State {
        var isPaused = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var isPaused: Bool { state.withLock { $0.isPaused } }

    public func pause() {
        state.withLock { $0.isPaused = true }
    }

    public func resume() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isPaused = false
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Suspends while paused. Returns early when the calling task is cancelled.
    func waitWhilePaused() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.isPaused, !Task.isCancelled else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiters = state.withLock { state in
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
}

/// Strictly read-only scanner for a directory tree. It never follows symbolic links, does not cross
/// into other mounted volumes, counts allocated (not logical) sizes and counts hard-linked files once.
public struct DiskScanner: Sendable {
    public let options: ScanOptions
    private static let logger = Logger(subsystem: "de.df.Stofi", category: "Scanner")

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans `rootPath` and streams progress followed by the finished tree.
    ///
    /// Cancel by cancelling the consuming task or dropping the stream; the stream then simply ends
    /// without a ``ScanEvent/finished(_:)`` event.
    public func scan(
        rootPath: String,
        displayPath: String? = nil,
        controller: ScanController = ScanController()
    ) -> AsyncThrowingStream<ScanEvent, any Error> {
        let options = options
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let task = Task {
                do {
                    let tree = try await Self.run(
                        rootPath: rootPath, displayPath: displayPath ?? rootPath,
                        options: options, controller: controller,
                        onProgress: { continuation.yield(.progress($0)) }
                    )
                    continuation.yield(.finished(tree))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scans without progress events; convenient for tests and the benchmark.
    /// Throws `CancellationError` when the calling task is cancelled.
    public func scanTree(
        rootPath: String,
        displayPath: String? = nil,
        controller: ScanController = ScanController()
    ) async throws -> FileTree {
        try await Self.run(rootPath: rootPath, displayPath: displayPath ?? rootPath,
                           options: options, controller: controller, onProgress: { _ in })
    }

    private static func run(
        rootPath: String,
        displayPath: String,
        options: ScanOptions,
        controller: ScanController,
        onProgress: @escaping @Sendable (ScanSnapshot) -> Void
    ) async throws -> FileTree {
        let clock = ContinuousClock()
        let start = clock.now

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            throw ScanFailure.rootUnreadable(path: rootPath, code: errno)
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw ScanFailure.rootUnreadable(path: rootPath, code: ENOTDIR)
        }

        let builder = TreeBuilder(rootName: displayPath, minimumFileNodeSize: options.minimumFileNodeSize)
        builder.setRootModificationTime(Int64(rootStat.st_mtimespec.tv_sec))
        logger.notice("Scan started: \(rootPath, privacy: .public), concurrency \(options.maxConcurrency)")

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: options.progressInterval)
                guard !Task.isCancelled else { break }
                onProgress(builder.snapshot(topCount: options.progressTopCount))
            }
        }
        defer { progressTask.cancel() }

        switch options.directoryAPI {
        case .bulk:
            try await traverse(BulkDirectoryReader.self, rootPath: rootPath, builder: builder,
                               options: options, controller: controller)
        case .posix:
            try await traverse(PosixDirectoryReader.self, rootPath: rootPath, builder: builder,
                               options: options, controller: controller)
        }

        let tree = builder.finish(rootDisplayPath: displayPath, duration: clock.now - start)
        let stats = tree.statistics
        logger.notice("""
            Scan finished: \(stats.regularFiles) files, \(stats.directories) dirs, \
            \(stats.allocatedBytes) bytes in \(stats.duration)
            """)
        return tree
    }

    private static func traverse<Reader: DirectoryReading & ~Copyable>(
        _: Reader.Type,
        rootPath: String,
        builder: TreeBuilder,
        options: ScanOptions,
        controller: ScanController
    ) async throws {
        // The root is read up front so that an unreadable root fails the scan instead of yielding an empty tree.
        var rootReader = Reader(includePrivateSize: options.measurePrivateSize)
        let rootCode = rootReader.read(path: rootPath)
        guard rootCode == 0 else { throw ScanFailure.rootUnreadable(path: rootPath, code: rootCode) }
        let queue = WorkQueue(initial: builder.add(listing: rootReader, to: builder.rootNode, path: rootPath))
        builder.addBulkCalls(rootReader.bulkCalls)

        // A fixed number of long-lived workers, each with its own reusable buffer, pull directories from
        // a shared depth-first queue. Concurrency is bounded by the number of workers.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<options.maxConcurrency {
                group.addTask {
                    var reader = Reader(includePrivateSize: options.measurePrivateSize)
                    while let item = await queue.take(controller: controller) {
                        let code = reader.read(path: item.path)
                        if code == 0 {
                            queue.complete(adding: builder.add(listing: reader, to: item.node, path: item.path))
                        } else {
                            // Directories that vanished during the scan are not worth reporting.
                            if code != ENOENT { builder.markUnreadable(item.node, path: item.path, code: code) }
                            queue.complete(adding: [])
                        }
                    }
                    builder.addBulkCalls(reader.bulkCalls)
                }
            }
        }
        try Task.checkCancellation()
    }
}

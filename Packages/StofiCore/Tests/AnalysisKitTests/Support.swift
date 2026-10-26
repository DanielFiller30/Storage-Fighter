import Darwin
import Foundation
import ScannerKit
import Synchronization
@testable import AnalysisKit

/// A fake home directory below the system temp directory. Tests never touch real user data.
final class FakeHome {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StofiAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = base.resolvingSymlinksInPath().path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 2_000_000, ageInDays: Double? = nil) throws -> String {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: full))
        if let ageInDays { try age(relative, days: ageInDays) }
        return full
    }

    func directory(_ relative: String, ageInDays: Double? = nil) throws {
        try FileManager.default.createDirectory(atPath: path + "/" + relative, withIntermediateDirectories: true)
        if let ageInDays { try age(relative, days: ageInDays) }
    }

    func age(_ relative: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path + "/" + relative)
    }

    func scan() async throws -> FileTree {
        try await DiskScanner(options: ScanOptions(maxConcurrency: 4, minimumFileNodeSize: 0)).scanTree(rootPath: path)
    }
}

/// Command runner with recorded outputs; records which commands were run.
final class FakeCommands: CommandRunning, Sendable {
    let outputs: [String: CommandResult]
    let executables: Set<String>
    private let calls = Mutex<[String]>([])

    init(outputs: [String: CommandResult] = [:], executables: Set<String> = []) {
        self.outputs = outputs
        self.executables = executables.union(outputs.keys.compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    var ranCommands: [String] { calls.withLock { $0 } }

    func isExecutable(_ path: String) -> Bool { executables.contains(path) }

    func run(_ command: ExternalCommand, timeout: Duration) async -> CommandResult {
        let key = ([command.executable] + command.arguments).joined(separator: " ")
        calls.withLock { $0.append(key) }
        return outputs[key] ?? CommandResult(exitCode: 1, standardOutput: "", standardError: "not recorded")
    }
}

func context(_ home: FakeHome, tree: FileTree?, fullDiskAccess: Bool = true,
             commands: FakeCommands = FakeCommands(), thresholds: AnalysisThresholds = AnalysisThresholds(),
             installedApps: Set<String> = ["com.apple.mail"]) -> AnalysisContext {
    AnalysisContext(homeDirectory: home.path, tree: tree, hasFullDiskAccess: fullDiskAccess,
                    commands: commands, thresholds: thresholds, isAppInstalled: { installedApps.contains($0) })
}

extension Array where Element == Recommendation {
    subscript(kind: RecommendationKind) -> Recommendation? { first { $0.kind == kind } }
}

import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs external programs. Injected so tests can use recorded outputs.
public protocol CommandRunning: Sendable {
    func run(_ command: ExternalCommand, timeout: Duration) async -> CommandResult
    /// Whether an executable exists at the path (no execution).
    func isExecutable(_ path: String) -> Bool
    /// Like ``run(_:timeout:)`` but reports output while the program runs. Cancelling the task stops it.
    func run(_ command: ExternalCommand, timeout: Duration,
             onOutput: @escaping @Sendable (String) -> Void) async -> CommandResult
}

extension CommandRunning {
    public func run(_ command: ExternalCommand, timeout: Duration,
                    onOutput: @escaping @Sendable (String) -> Void) async -> CommandResult {
        let result = await run(command, timeout: timeout)
        onOutput(result.standardOutput + result.standardError)
        return result
    }
}

/// Runs programs with `Process`, without a shell, and kills them after the timeout.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func run(_ command: ExternalCommand, timeout: Duration) async -> CommandResult {
        await run(command, timeout: timeout, onOutput: { _ in })
    }

    public func run(_ command: ExternalCommand, timeout: Duration,
                    onOutput: @escaping @Sendable (String) -> Void) async -> CommandResult {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.runBlocking(command, timeout: timeout, handle: handle,
                                                                    onOutput: onOutput))
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Shares the running process with the cancellation handler.
    private final class ProcessHandle: Sendable {
        private let process = Mutex<Process?>(nil)
        private let cancelled = Mutex(false)

        func set(_ newProcess: Process) -> Bool {
            process.withLock { $0 = newProcess }
            return !cancelled.withLock { $0 }
        }

        func terminate() {
            cancelled.withLock { $0 = true }
            process.withLock { $0?.terminate() }
        }
    }

    private static func runBlocking(_ command: ExternalCommand, timeout: Duration, handle: ProcessHandle,
                                    onOutput: @escaping @Sendable (String) -> Void) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }

        guard handle.set(process) else {
            process.terminate()
            return CommandResult(exitCode: -1, standardOutput: "", standardError: "Cancelled")
        }
        let group = DispatchGroup()
        let collected = Mutex((output: Data(), error: Data()))
        // Read both pipes concurrently in chunks, so output can be shown live and a full buffer never blocks.
        for (pipe, isError) in [(output, false), (error, true)] {
            group.enter()
            DispatchQueue.global().async {
                let reader = pipe.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    collected.withLock { if isError { $0.error.append(chunk) } else { $0.output.append(chunk) } }
                    onOutput(String(decoding: chunk, as: UTF8.self))
                }
                group.leave()
            }
        }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timedOut = group.wait(timeout: .now() + seconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        let (outputData, errorData) = collected.withLock { ($0.output, $0.error) }
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

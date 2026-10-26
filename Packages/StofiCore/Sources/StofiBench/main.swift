import Foundation
import ScannerKit

// Usage: swift run -c release StofiBench [--runs N] <path> [<path> …]
// Every variant is read-only. The first run of each path warms the file-system cache and is discarded,
// so the numbers describe warm-cache throughput (cold-cache runs would need `sudo purge`).

var arguments = Array(CommandLine.arguments.dropFirst())
let runs: Int
if let index = arguments.firstIndex(of: "--runs"), index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
    runs = max(1, value)
    arguments.removeSubrange(index...index + 1)
} else {
    runs = 3
}
let paths = arguments.isEmpty ? ["/System/Library", "/Applications"] : arguments
let cores = ProcessInfo.processInfo.activeProcessorCount

struct Measurement {
    let name: String
    let seconds: Double
    let files: Int
    let directories: Int
    let bytes: UInt64
    let listingCalls: Int?
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

func measure(_ name: String, _ body: () async throws -> TraversalBenchmark.Result) async rethrows -> Measurement {
    var times: [Double] = []
    var last = TraversalBenchmark.Result()
    for _ in 0..<runs {
        let start = ContinuousClock.now
        last = try await body()
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    return Measurement(name: name, seconds: median(times), files: last.files, directories: last.directories,
                       bytes: last.allocatedBytes, listingCalls: last.listingCalls)
}

func scannerVariant(_ options: ScanOptions, path: String) async throws -> TraversalBenchmark.Result {
    let tree = try await DiskScanner(options: options).scanTree(rootPath: path)
    let stats = tree.statistics
    var result = TraversalBenchmark.Result()
    result.files = stats.regularFiles - stats.skippedHardLinks
    result.directories = stats.directories
    result.allocatedBytes = stats.allocatedBytes
    result.listingCalls = stats.bulkCalls
    return result
}

/// Reference value from `du -skx` (allocated KiB, hard links once, stays on the device).
func duKilobytes(_ path: String) -> UInt64? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-skx", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\t").first.flatMap { UInt64($0) }
}

func format(_ m: Measurement) -> String {
    let filesPerSecond = Double(m.files) / m.seconds
    let calls = m.listingCalls.map { String(format: "%.3f", Double($0) / Double(max(1, m.files + m.directories))) } ?? "–"
    return [
        m.name.padding(toLength: 34, withPad: " ", startingAt: 0),
        String(format: "%8.3f s", m.seconds),
        String(format: "%12.0f files/s", filesPerSecond),
        String(format: "%9d files", m.files),
        String(format: "%8d dirs", m.directories),
        String(format: "%9.2f GB", Double(m.bytes) / 1e9),
        "syscalls/entry: \(calls)",
    ].joined(separator: "  ")
}

// `--scan-only <path>`: one DiskScanner run with default options, for memory measurements (`/usr/bin/time -l`).
if arguments.first == "--scan-only", arguments.count == 2 {
    let tree = try await DiskScanner().scanTree(rootPath: arguments[1])
    let s = tree.statistics
    print("nodes \(tree.nodeCount), files \(s.regularFiles), dirs \(s.directories), \(s.allocatedBytes.formatted()) bytes, \(s.duration)")
    exit(0)
}

print("StofiBench – \(runs) runs per variant (median), \(cores) active cores, warm cache")
for path in paths {
    print("\n== \(path)")
    _ = TraversalBenchmark.bulk(path) // warm-up
    var results: [Measurement] = []
    results.append(await measure("fts (1 thread)") { TraversalBenchmark.fts(path) })
    results.append(await measure("FileManager.enumerator") { TraversalBenchmark.fileManager(path) })
    results.append(await measure("getattrlistbulk (1 thread)") { TraversalBenchmark.bulk(path) })
    results.append(await measure("getattrlistbulk, no privsize") { TraversalBenchmark.bulk(path, includePrivateSize: false) })
    let levels = Array(Set([1, 4, cores / 2, cores, cores * 2])).filter { $0 >= 1 }.sorted()
    for api in ScanOptions.DirectoryAPI.allCases {
        for concurrency in levels {
            let options = ScanOptions(maxConcurrency: concurrency, directoryAPI: api)
            results.append(try await measure("DiskScanner \(api) ×\(concurrency)") {
                try await scannerVariant(options, path: path)
            })
        }
    }
    let withPrivateSize = ScanOptions(maxConcurrency: cores / 2, measurePrivateSize: true)
    results.append(try await measure("DiskScanner bulk+privsize ×\(cores / 2)") {
        try await scannerVariant(withPrivateSize, path: path)
    })
    results.forEach { print(format($0)) }
    if let kilobytes = duKilobytes(path) {
        print(String(format: "du -skx reference: %.2f GB", Double(kilobytes) * 1024 / 1e9))
    }
}

import Foundation
import ScannerKit

/// Rules that ask developer tools or the system for data, using read-only commands only (decision for M3).
extension RecommendationEngine {
    static let xcodeSelect = ExternalCommand(executable: "/usr/bin/xcode-select", arguments: ["-p"])
    static let listRuntimes = ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "list", "-j"])
    static let listDevices = ExternalCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "-j", "devices"])
    static let deleteUnavailable = ExternalCommand(executable: "/usr/bin/xcrun",
                                                   arguments: ["simctl", "delete", "unavailable"])
    static let listSnapshots = ExternalCommand(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])

    func simulators() async -> [Recommendation] {
        // Without developer tools `xcrun` would open an installation dialog, so check first.
        guard let select = await run(Self.xcodeSelect), select.succeeded else { return [] }
        async let runtimesOutput = run(Self.listRuntimes)
        async let devicesOutput = run(Self.listDevices)
        var results: [Recommendation] = []

        if let output = await runtimesOutput, output.succeeded {
            let items = SimctlParser.runtimes(from: output.standardOutput).filter(\.deletable).map { runtime in
                RecommendationItem(
                    path: runtime.path, allocatedSize: runtime.sizeBytes, modificationDate: runtime.lastUsed,
                    detail: "\(runtime.platformName) \(runtime.version) (\(runtime.build))",
                    command: ExternalCommand(executable: "/usr/bin/xcrun",
                                             arguments: ["simctl", "runtime", "delete", runtime.identifier])
                )
            }
            results.append(Recommendation(kind: .simulatorRuntimes, items: items, risk: .caution,
                                          regeneration: .download, action: .informationOnly,
                                          sourceCommands: [Self.listRuntimes]))
        }
        if let output = await devicesOutput, output.succeeded {
            let items = SimctlParser.unavailableDevices(from: output.standardOutput).map { device in
                RecommendationItem(path: device.directory, allocatedSize: device.dataSize, detail: device.name)
            }
            results.append(Recommendation(kind: .simulatorUnavailableDevices, items: items, risk: .safe,
                                          regeneration: .notApplicable, action: .command(Self.deleteUnavailable),
                                          sourceCommands: [Self.listDevices]))
        }
        return results
    }

    /// Local Time Machine snapshots: shown and explained only. `tmutil` reports no per-snapshot size
    /// (assumption B4), so items have size 0 and the UI refers to the volume's purgeable estimate.
    func localSnapshots() async -> [Recommendation] {
        guard let output = await run(Self.listSnapshots), output.succeeded else { return [] }
        let items = TmutilParser.snapshots(from: output.standardOutput).map { snapshot in
            RecommendationItem(path: snapshot.name, allocatedSize: 0, modificationDate: snapshot.date, detail: nil)
        }
        return [Recommendation(kind: .localSnapshots, items: items, risk: .expert, regeneration: .notApplicable,
                               action: .informationOnly, sourceCommands: [Self.listSnapshots])]
    }
}

enum SimctlParser {
    struct Runtime: Equatable {
        let identifier: String
        let platformName: String
        let version: String
        let build: String
        let path: String
        let sizeBytes: UInt64
        let lastUsed: Date?
        let deletable: Bool
    }

    struct Device: Equatable {
        let name: String
        let directory: String
        let dataSize: UInt64
    }

    /// Parses `xcrun simctl runtime list -j` (a dictionary keyed by runtime identifier).
    static func runtimes(from json: String) -> [Runtime] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] else {
            return []
        }
        let dateFormatter = ISO8601DateFormatter()
        return object.compactMap { key, value in
            let runtimeID = value["runtimeIdentifier"] as? String ?? ""
            return Runtime(
                identifier: value["identifier"] as? String ?? key,
                platformName: platformName(runtimeIdentifier: runtimeID, platform: value["platformIdentifier"] as? String),
                version: value["version"] as? String ?? "?",
                build: value["build"] as? String ?? "?",
                path: value["path"] as? String ?? "",
                sizeBytes: (value["sizeBytes"] as? NSNumber)?.uint64Value ?? 0,
                lastUsed: (value["lastUsedAt"] as? String).flatMap(dateFormatter.date(from:)),
                deletable: value["deletable"] as? Bool ?? false
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Parses `xcrun simctl list -j devices` and returns devices that are no longer available.
    static func unavailableDevices(from json: String) -> [Device] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let byRuntime = object["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.values.joined().compactMap { device in
            guard device["isAvailable"] as? Bool == false, let dataPath = device["dataPath"] as? String else { return nil }
            return Device(name: device["name"] as? String ?? "?",
                          directory: (dataPath as NSString).deletingLastPathComponent,
                          dataSize: (device["dataPathSize"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    static func platformName(runtimeIdentifier: String, platform: String?) -> String {
        // "com.apple.CoreSimulator.SimRuntime.iOS-18-3" → "iOS"
        if let last = runtimeIdentifier.split(separator: ".").last, let name = last.split(separator: "-").first {
            return String(name)
        }
        return platform ?? "?"
    }
}

enum TmutilParser {
    struct Snapshot: Equatable {
        let name: String
        let date: Date?
    }

    /// Parses `tmutil listlocalsnapshots /`: a header line followed by names such as
    /// `com.apple.TimeMachine.2026-10-26-101010.local`.
    static func snapshots(from output: String) -> [Snapshot] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
            .map { Snapshot(name: $0, date: date(in: $0)) }
    }

    static func date(in name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name[range]))
    }
}

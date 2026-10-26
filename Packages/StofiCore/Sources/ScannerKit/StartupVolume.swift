import Foundation

/// Knowledge about the split startup volume on macOS 10.15 and later.
///
/// The read-only, sealed system volume is mounted at `/`, the writable data volume at
/// `/System/Volumes/Data`. Firmlinks (listed in `/usr/share/firmlinks`) make directories of the data
/// volume, e.g. `/Users`, appear inside `/`. Scanning `/` would therefore visit those directories through
/// the firmlinks while the data volume itself is a separate mount. To count everything exactly once, the
/// scanner reads the data volume directly and shows its paths the way users know them.
public struct StartupVolume: Sendable {
    public static let dataVolumePath = "/System/Volumes/Data"
    public static let firmlinksFile = "/usr/share/firmlinks"

    /// Top-level paths on the data volume (relative, without leading slash) that are firmlinked into `/`.
    public let firmlinkedPaths: [String]

    public init(firmlinksFileContents: String?) {
        let parsed = firmlinksFileContents.map(Self.parse) ?? []
        firmlinkedPaths = parsed.isEmpty ? Self.fallbackFirmlinks : parsed
    }

    /// Reads `/usr/share/firmlinks`; falls back to a built-in list if the file is unavailable.
    public static func current() -> StartupVolume {
        StartupVolume(firmlinksFileContents: try? String(contentsOfFile: firmlinksFile, encoding: .utf8))
    }

    /// Maps a path below the data volume to the path users see, e.g.
    /// `/System/Volumes/Data/Users/me` → `/Users/me`. Paths without a firmlink stay unchanged.
    public func displayPath(forDataVolumePath path: String) -> String {
        let prefix = Self.dataVolumePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        let relative = String(path.dropFirst(prefix.count))
        for target in firmlinkedPaths where relative == target || relative.hasPrefix(target + "/") {
            return "/" + relative
        }
        return path
    }

    /// Inverse of ``displayPath(forDataVolumePath:)`` for firmlinked paths, e.g. `/Users/me` → data volume path.
    public func dataVolumePath(forDisplayPath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let relative = String(path.dropFirst())
        for target in firmlinkedPaths where relative == target || relative.hasPrefix(target + "/") {
            return Self.dataVolumePath + path
        }
        return nil
    }

    /// Parses lines of the form `/Users<TAB>Users`. The second column is the path on the data volume.
    static func parse(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard columns.count == 2, columns[0] == "/" + columns[1] else { return nil }
            return String(columns[1])
        }
    }

    static let fallbackFirmlinks = [
        "AppleInternal", "Applications", "Library", "System/Library/Caches", "System/Library/Assets",
        "System/Library/PreinstalledAssets", "System/Library/AssetsV2", "System/Library/PreinstalledAssetsV2",
        "System/Library/CoreServices/CoreTypes.bundle/Contents/Library", "System/Library/Speech",
        "Users", "Volumes", "cores", "opt", "pkg", "private", "usr/local", "usr/libexec/cups", "usr/share/snmp",
    ]
}

extension FileTree {
    /// Path of a node as shown to users. For scans of the data volume, firmlinked paths are mapped to `/`.
    public func displayPath(of id: NodeID, startupVolume: StartupVolume) -> String {
        let raw = path(of: id)
        return rootDisplayPath == StartupVolume.dataVolumePath
            ? startupVolume.displayPath(forDataVolumePath: raw)
            : raw
    }
}

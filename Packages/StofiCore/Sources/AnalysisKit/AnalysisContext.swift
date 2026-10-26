import CoreServices
import Darwin
import Foundation
import ScannerKit

/// Thresholds of the heuristics (fixed for now, configurable later).
public struct AnalysisThresholds: Sendable {
    public var largeDownload: UInt64 = 100_000_000
    public var oldDownload: TimeInterval = 365 * 24 * 3600
    public var largeMedia: UInt64 = 500_000_000
    public var inactiveProject: TimeInterval = 90 * 24 * 3600

    public init() {}
}

/// Everything the analysis needs. All inputs are injectable so tests run against temporary directories.
public struct AnalysisContext: Sendable {
    /// The user's home directory as an absolute display path, e.g. `/Users/me`.
    public var homeDirectory: String
    /// Result of the last full scan, if any. Locations inside it are not scanned again.
    public var tree: FileTree?
    public var startupVolume: StartupVolume
    /// Without Full Disk Access, locations in other apps' containers are not touched (macOS would ask
    /// the user for permission, see assumption B2).
    public var hasFullDiskAccess: Bool
    public var commands: any CommandRunning
    public var thresholds: AnalysisThresholds
    public var now: Date
    /// Whether an app with the bundle identifier is installed (LaunchServices; no file access).
    public var isAppInstalled: @Sendable (String) -> Bool

    public init(homeDirectory: String, tree: FileTree?, startupVolume: StartupVolume = .current(),
                hasFullDiskAccess: Bool, commands: any CommandRunning = ProcessCommandRunner(),
                thresholds: AnalysisThresholds = AnalysisThresholds(), now: Date = .now,
                isAppInstalled: @escaping @Sendable (String) -> Bool = AnalysisContext.launchServicesKnowsApp) {
        self.homeDirectory = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        self.tree = tree
        self.startupVolume = startupVolume
        self.hasFullDiskAccess = hasFullDiskAccess
        self.commands = commands
        self.thresholds = thresholds
        self.now = now
        self.isAppInstalled = isAppInstalled
    }

    func home(_ relative: String) -> String { homeDirectory + "/" + relative }

    public static let launchServicesKnowsApp: @Sendable (String) -> Bool = { bundleIdentifier in
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL] else { return false }
        return !urls.isEmpty
    }
}

/// A directory (or file) located in a scan tree: either the full scan or a targeted scan of just that place.
public struct TreeLocation: Sendable {
    public let tree: FileTree
    public let node: NodeID
    /// Absolute display path of ``node``.
    public let path: String

    public var allocatedSize: UInt64 { tree.allocatedSize(of: node) }
    public var modificationDate: Date { tree.modificationDate(of: node) }

    /// Child locations (directories and files with their own node).
    public var children: [TreeLocation] {
        tree.children(of: node).map { child in
            TreeLocation(tree: tree, node: child, path: path + "/" + tree.name(of: child))
        }
    }

    public var name: String { tree.name(of: node) }
}

enum LocationLookup: Sendable {
    case found(TreeLocation)
    case missing
    case needsFullDiskAccess
}

/// Hybrid lookup (decision for M3): use the full scan when it contains the location, otherwise scan
/// only that location. Strictly read-only.
struct LocationResolver: Sendable {
    let context: AnalysisContext

    /// Home-relative prefixes whose access triggers a TCC prompt or needs Full Disk Access.
    static let protectedPrefixes = [
        "Library/Containers/", "Library/Group Containers/", "Library/Mail",
        "Library/Application Support/MobileSync", ".Trash", "Library/Safari", "Library/Messages",
    ]

    func requiresFullDiskAccess(_ path: String) -> Bool {
        guard path.hasPrefix(context.homeDirectory + "/") else { return false }
        let relative = String(path.dropFirst(context.homeDirectory.count + 1))
        return Self.protectedPrefixes.contains { relative == $0 || relative.hasPrefix($0) }
    }

    /// App owning a protected location, if known: `Library/Containers/<bundle id>/…`, or Mail's store.
    func owningApp(of path: String) -> String? {
        guard path.hasPrefix(context.homeDirectory + "/") else { return nil }
        let relative = path.dropFirst(context.homeDirectory.count + 1)
        if relative.hasPrefix("Library/Mail") { return "com.apple.mail" }
        let components = relative.split(separator: "/")
        if components.count >= 3, components[0] == "Library", components[1] == "Containers" {
            return String(components[2])
        }
        return nil
    }

    func locate(_ path: String) async -> LocationLookup {
        if let tree = context.tree, let node = tree.node(atAbsolutePath: path, startupVolume: context.startupVolume) {
            // An unreadable directory in the full scan may be readable now (e.g. Full Disk Access granted since).
            if !tree.flags(of: node).contains(.unreadable) {
                return .found(TreeLocation(tree: tree, node: node, path: path))
            }
        }
        if requiresFullDiskAccess(path) && !context.hasFullDiskAccess {
            // Checking the location itself could trigger a privacy prompt, so ask LaunchServices whether
            // the owning app exists at all; without it there is nothing to measure.
            if let owner = owningApp(of: path), !context.isAppInstalled(owner) { return .missing }
            return .needsFullDiskAccess
        }

        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == EPERM || errno == EACCES ? .needsFullDiskAccess : .missing
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        // Files are measured through their parent directory, so the result is a regular tree node.
        let scanRoot = isDirectory ? path : (path as NSString).deletingLastPathComponent
        let scanner = DiskScanner(options: ScanOptions(maxConcurrency: 4, minimumFileNodeSize: isDirectory ? 1 << 20 : 0))
        do {
            let tree = try await scanner.scanTree(rootPath: scanRoot)
            if isDirectory { return .found(TreeLocation(tree: tree, node: tree.root, path: path)) }
            let name = (path as NSString).lastPathComponent
            guard let node = tree.children(of: tree.root).first(where: { tree.name(of: $0) == name }) else { return .missing }
            return .found(TreeLocation(tree: tree, node: node, path: path))
        } catch ScanFailure.rootUnreadable(_, let code) where code == EPERM || code == EACCES {
            return .needsFullDiskAccess
        } catch {
            return .missing
        }
    }
}

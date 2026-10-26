import Darwin
import Foundation
import ScannerKit

/// Why a path may not be removed.
public enum ProtectionReason: String, Sendable, Hashable, Codable {
    case invalidPath
    case systemLocation
    case applications
    case homeFolder
    case libraryStructure
    case iCloud
    case photosLibrary
    case keychains
    case messages
    case mail
    case appContainer
    case timeMachine
    case otherUser
    case volumeRoot
}

public enum ProtectionVerdict: Sendable, Equatable {
    case allowed
    case denied(ProtectionReason)

    public var isAllowed: Bool { self == .allowed }
}

/// The central protection list. Every removal goes through it, twice: when the plan is built and
/// right before the action. It has no switches; changing it means changing (and testing) this code.
///
/// Paths are normalised first (absolute, no `..`, symbolic links in parent folders resolved, data volume
/// paths mapped to their firmlinked form) and compared case-insensitively, because APFS volumes are
/// case-insensitive by default.
public struct ProtectionPolicy: Sendable {
    public let homeDirectory: String
    public let startupVolume: StartupVolume
    /// The home as given and with resolved links (e.g. `/var/…` and `/private/var/…`), lowercased.
    private let homeAliases: [String]

    public init(homeDirectory: String, startupVolume: StartupVolume = .current()) {
        self.homeDirectory = Self.trimmed(homeDirectory)
        self.startupVolume = startupVolume
        var aliases = [Self.trimmed(homeDirectory).lowercased()]
        if let resolved = Self.realpath(homeDirectory)?.lowercased(), !aliases.contains(resolved) { aliases.append(resolved) }
        homeAliases = aliases
    }

    static func realpath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Checks a path on disk (follows symbolic links in parent folders, not the last component).
    public func evaluate(_ path: String) -> ProtectionVerdict {
        guard let normalized = normalize(path) else { return .denied(.invalidPath) }
        // Check both the path as given and its resolved form: a link inside the home that points into
        // /System must not make /System removable, and vice versa.
        let given = rules(for: Self.trimmed(startupVolume.displayPath(forDataVolumePath: path)))
        let resolved = rules(for: normalized)
        if case .denied = given { return given }
        return resolved
    }

    /// Absolute path with resolved parents, or `nil` for relative paths or `.`/`..` components.
    func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        guard let last = components.last else { return "/" }

        let parent = "/" + components.dropLast().joined(separator: "/")
        // Resolve the nearest existing ancestor; the rest is appended unchanged.
        var existing = parent
        var suffix: [Substring] = []
        while existing != "/" && !FileMetadata.exists(atPath: existing) {
            suffix.insert(Substring((existing as NSString).lastPathComponent), at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolvedParent = Self.realpath(existing) else { return nil }
        let joined = ([resolvedParent == "/" ? "" : resolvedParent] + suffix.map(String.init) + [String(last)])
            .joined(separator: "/")
        return Self.trimmed(startupVolume.displayPath(forDataVolumePath: joined))
    }

    /// The rules on an already normalised path. Internal so tests can check them without a file system.
    func rules(for path: String) -> ProtectionVerdict {
        let p = path.lowercased()
        if p.isEmpty || p == "/" { return .denied(.systemLocation) }

        let components = p.split(separator: "/").map(String.init)
        if components.contains(where: { $0.hasSuffix(".photoslibrary") }) { return .denied(.photosLibrary) }
        if components.contains(where: { $0 == "backups.backupdb" || $0.hasSuffix(".backupbundle")
            || $0.hasSuffix(".sparsebundle") || $0 == ".timemachine" }) {
            return .denied(.timeMachine)
        }

        if let home = homeAliases.first(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            return homeRules(String(p.dropFirst(home.count)).split(separator: "/").map(String.init))
        }

        switch components[0] {
        case "system", "usr", "bin", "sbin", "private", "cores", "opt", "etc", "var", "tmp", "dev", "home", "net":
            return .denied(.systemLocation)
        case "applications":
            return .denied(.applications)
        case "library":
            // Only the contents of the shared caches and logs folders.
            if components.count >= 3 && (components[1] == "caches" || components[1] == "logs") { return .allowed }
            return .denied(.systemLocation)
        case "users":
            if components.count >= 3 && components[1] == "shared" { return .allowed }
            return .denied(components.count <= 1 ? .systemLocation : .otherUser)
        case "volumes":
            return components.count <= 2 ? .denied(.volumeRoot) : .allowed
        default:
            // Anything else at the root of the startup disk belongs to the system.
            return .denied(.systemLocation)
        }
    }

    private static let homeFolders: Set<String> = [
        "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public", "applications",
        ".trash",
    ]

    private func homeRules(_ relative: [String]) -> ProtectionVerdict {
        guard let first = relative.first else { return .denied(.homeFolder) }
        if relative.count == 1 && Self.homeFolders.contains(first) { return .denied(.homeFolder) }
        guard first == "library", relative.count >= 2 else { return .allowed }

        let second = relative[1]
        if relative.count == 2 { return .denied(.libraryStructure) }
        switch second {
        case "mobile documents", "cloudstorage": return .denied(.iCloud)
        case "keychains": return .denied(.keychains)
        case "messages": return .denied(.messages)
        case "mail": return .denied(.mail)
        case "containers", "group containers":
            // The container itself, its Data folder and Data/Library are the app's structure.
            if relative.count <= 3 { return .denied(.appContainer) }
            if relative.count == 4 && relative[3] == "data" { return .denied(.appContainer) }
            if relative.count == 5 && relative[3] == "data" && relative[4] == "library" { return .denied(.appContainer) }
            return .allowed
        default:
            return .allowed
        }
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

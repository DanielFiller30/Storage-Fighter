import Foundation

/// What a recommendation is about. The app maps each kind to a title and an explanation, so all
/// user-facing text lives in the app's string catalog.
public enum RecommendationKind: String, Sendable, CaseIterable, Codable {
    case userCaches, userLogs, trash, downloads
    case xcodeDerivedData, xcodeArchives, xcodeDeviceSupport
    case simulatorRuntimes, simulatorUnavailableDevices, androidVirtualDevices
    case gradleCache, npmCache, pnpmStore, yarnCache, pipCache, homebrewCache, cocoaPodsCache
    case inactiveNodeModules, dockerData
    case iosBackups, mailDownloads, mailAttachments, largeMedia
    case duplicates, localSnapshots
    /// A location defined in an activity profile (JSON); its texts come from the definition.
    case profileLocation

    public var group: RecommendationGroup {
        switch self {
        case .userCaches, .userLogs, .trash: .system
        case .downloads, .iosBackups, .mailDownloads, .mailAttachments, .largeMedia: .personal
        case .duplicates: .duplicates
        case .localSnapshots: .snapshots
        case .profileLocation: .other
        default: .developer
        }
    }
}

public enum RecommendationGroup: String, Sendable, CaseIterable, Codable {
    case system, developer, personal, creative, gaming, duplicates, snapshots, other
}

public enum RiskLevel: String, Sendable, Comparable, Codable, CaseIterable {
    /// Safe to remove: regenerated automatically or not needed.
    case safe
    /// Check before removing: personal data or a noticeable cost to get back.
    case caution
    /// Only remove if you know what it is.
    case expert

    private var order: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .expert: 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

public enum Regeneration: String, Sendable, Codable {
    /// Recreated automatically when needed.
    case automatic
    /// Can be downloaded again (needs network and time).
    case download
    /// Recreated by a command or by setting it up again.
    case rebuild
    /// Cannot be recreated.
    case none
    /// Not applicable (information only).
    case notApplicable
}

/// A command shown to the user and only run after confirmation (cleanup, milestone 4).
/// Executed without a shell: `executable` with `arguments` exactly as listed.
public struct ExternalCommand: Sendable, Hashable, Codable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Display form, e.g. `xcrun simctl delete unavailable`.
    public var displayString: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
            ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : argument
    }
}

/// How the cleanup (milestone 4) would handle a recommendation. Nothing is executed by AnalysisKit.
public enum RecommendedAction: Sendable, Hashable, Codable {
    case moveToTrash
    /// Emptying the Trash is permanent and needs an extra confirmation.
    case emptyTrash
    case command(ExternalCommand)
    case informationOnly
}

public enum Availability: Sendable, Hashable, Codable {
    case available
    /// The location exists but cannot be measured without Full Disk Access.
    case needsFullDiskAccess
}

public struct RecommendationItem: Sendable, Hashable, Identifiable, Codable {
    public var id: String { path + (detail ?? "") }
    /// Absolute path as users see it.
    public let path: String
    public let allocatedSize: UInt64
    public let modificationDate: Date?
    /// Additional description, e.g. "iOS 18.3.1 (22D8075)".
    public let detail: String?
    /// An item-specific command, e.g. deleting one simulator runtime.
    public let command: ExternalCommand?

    public init(path: String, allocatedSize: UInt64, modificationDate: Date? = nil,
                detail: String? = nil, command: ExternalCommand? = nil) {
        self.path = path
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.detail = detail
        self.command = command
    }
}

public struct Recommendation: Sendable, Hashable, Identifiable, Codable {
    public var id: String { definition.map { "profile." + $0.id } ?? kind.rawValue }
    public let kind: RecommendationKind
    /// Set for ``RecommendationKind/profileLocation``: the definition with title and explanation.
    public let definition: LocationDefinition?
    public let items: [RecommendationItem]
    public let risk: RiskLevel
    public let regeneration: Regeneration
    public let action: RecommendedAction
    public let availability: Availability
    /// Commands that were run (read-only) to gather the data, shown for transparency.
    public let sourceCommands: [ExternalCommand]

    public var group: RecommendationGroup { definition?.group ?? kind.group }
    public var totalSize: UInt64 { items.reduce(0) { $0 &+ $1.allocatedSize } }

    public init(kind: RecommendationKind, items: [RecommendationItem], risk: RiskLevel, regeneration: Regeneration,
                action: RecommendedAction, availability: Availability = .available,
                sourceCommands: [ExternalCommand] = [], definition: LocationDefinition? = nil) {
        self.kind = kind
        self.definition = definition
        self.items = items.sorted { $0.allocatedSize > $1.allocatedSize }
        self.risk = risk
        self.regeneration = regeneration
        self.action = action
        self.availability = availability
        self.sourceCommands = sourceCommands
    }
}

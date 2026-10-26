import Foundation

/// A text in several languages, e.g. `{"en": "Steam Games", "de": "Steam-Spiele"}`.
public struct LocalizedText: Codable, Sendable, Hashable {
    public let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// The best match for the user's preferred languages, falling back to English.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for language in preferredLanguages {
            let code = Locale(identifier: language).language.languageCode?.identifier ?? language
            if let value = values[code] { return value }
        }
        return values["en"] ?? values.values.first ?? ""
    }
}

/// What a quickscan of an activity measures: built-in rules plus locations defined in the profile file.
public struct ActivityProfile: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let symbol: String
    public let title: LocalizedText
    public let summary: LocalizedText
    /// Built-in rules (see ``RecommendationKind``) that belong to this activity.
    public let builtIns: [RecommendationKind]
    /// Additional locations, typically found through research on what fills up Macs for this activity.
    public let locations: [LocationDefinition]
}

/// A location described in a profile file. Strictly descriptive: it says where to measure and what
/// cleanup *would* do; executing anything is up to the confirmed cleanup flow (milestone 4).
public struct LocationDefinition: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        /// Each path is one item.
        case whole
        /// Every child of each path is an item (e.g. one entry per model or game).
        case children
        /// Directories named ``LocationDefinition/match`` (or ending with it if it starts with `*`)
        /// below each path, up to ``LocationDefinition/maxDepth`` levels.
        case search
    }

    public struct Action: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case trash, info, command }
        public let type: Kind
        /// Candidate locations of the program; the first existing one is used. `~` means the home folder.
        public let executables: [String]?
        public let arguments: [String]?
    }

    public let id: String
    public let group: RecommendationGroup
    public let symbol: String
    public let title: LocalizedText
    public let explanation: LocalizedText
    /// Absolute paths or paths starting with `~/`.
    public let paths: [String]
    public let mode: Mode
    public let match: String?
    public let maxDepth: Int?
    public let risk: RiskLevel
    public let regeneration: Regeneration
    public let action: Action
}

extension AnalysisScope {
    /// Scope for recommendation IDs such as `xcodeDerivedData` or `profile.swiftPMCache`.
    public static func categories(_ ids: [String], profiles: [ActivityProfile]) -> AnalysisScope {
        let kinds = Set(ids.compactMap(RecommendationKind.init(rawValue:)))
        let wanted = Set(ids.filter { $0.hasPrefix("profile.") }.map { String($0.dropFirst("profile.".count)) })
        var seen = Set<String>()
        let locations = profiles.flatMap(\.locations).filter { wanted.contains($0.id) && seen.insert($0.id).inserted }
        return .selected(builtIns: kinds, locations: locations)
    }
}

public enum ActivityProfiles {
    /// All profiles shipped as JSON files in the module's `Profiles` folder, in a fixed order.
    public static func bundled() throws -> [ActivityProfile] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Profiles") else {
            return []
        }
        let decoder = JSONDecoder()
        let profiles = try urls.map { try decoder.decode(ActivityProfile.self, from: Data(contentsOf: $0)) }
        return profiles.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    static let order = ["everyday", "appleDevelopment", "webBackend", "android", "aiData", "videoPhoto",
                        "musicAudio", "gaming"]
}

/// What an analysis covers.
public enum AnalysisScope: Sendable, Hashable {
    /// Every built-in rule and every location of all profiles (after a full scan).
    case full(profiles: [ActivityProfile])
    /// Only what the selected profiles name; measured in a targeted way, typically within seconds.
    case quick(profiles: [ActivityProfile])
    /// Exactly these categories (used by scheduled clean-ups).
    case selected(builtIns: Set<RecommendationKind>, locations: [LocationDefinition])

    var builtIns: Set<RecommendationKind>? {
        switch self {
        case .full: nil
        case .quick(let profiles): Set(profiles.flatMap(\.builtIns))
        case .selected(let builtIns, _): builtIns
        }
    }

    var locations: [LocationDefinition] {
        let profiles: [ActivityProfile]
        switch self {
        case .full(let all), .quick(let all): profiles = all
        case .selected(_, let locations): return locations
        }
        var seen = Set<String>()
        return profiles.flatMap(\.locations).filter { seen.insert($0.id).inserted }
    }
}

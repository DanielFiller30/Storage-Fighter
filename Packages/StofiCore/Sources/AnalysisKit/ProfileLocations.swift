import Foundation
import ScannerKit

extension RecommendationEngine {
    /// A copy that leaves cache folders measured by `definitions` out of the generic cache rule.
    func claiming(_ definitions: [LocationDefinition]) -> RecommendationEngine {
        var copy = self
        let cachesPrefix = "~/" + KnownLocations.caches + "/"
        for path in definitions.flatMap(\.paths) where path.hasPrefix(cachesPrefix) {
            if let folder = path.dropFirst(cachesPrefix.count).split(separator: "/").first {
                copy.claimedCacheFolders.insert(String(folder))
            }
        }
        return copy
    }

    func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? context.homeDirectory + path.dropFirst(1) : path
    }

    /// Measures a location described in a profile file. Read-only.
    func evaluate(_ definition: LocationDefinition) async -> Recommendation? {
        var items: [RecommendationItem] = []
        var needsAccess = false
        for path in definition.paths.map(expand) {
            switch await resolver.locate(path) {
            case .missing:
                continue
            case .needsFullDiskAccess:
                needsAccess = true
            case .found(let location):
                switch definition.mode {
                case .whole:
                    if location.allocatedSize > 0 { items.append(item(location)) }
                case .children:
                    let children = location.children.filter { $0.allocatedSize > 0 }
                    items += children.map { item($0) }
                    if children.isEmpty && location.allocatedSize > 0 { items.append(item(location)) }
                case .search:
                    items += search(in: location, match: definition.match ?? "", maxDepth: definition.maxDepth ?? 3)
                }
            }
        }
        if items.isEmpty && !needsAccess { return nil }
        return Recommendation(kind: .profileLocation, items: items, risk: definition.risk,
                              regeneration: definition.regeneration, action: action(for: definition.action),
                              availability: items.isEmpty ? .needsFullDiskAccess : .available,
                              definition: definition)
    }

    /// Directories whose name equals `match`, or ends with it when `match` starts with `*`.
    private func search(in root: TreeLocation, match: String, maxDepth: Int) -> [RecommendationItem] {
        let suffix = match.hasPrefix("*") ? String(match.dropFirst()) : nil
        var results: [RecommendationItem] = []
        var stack = [(root, 0)]
        while let (location, depth) = stack.popLast() {
            for child in location.children where location.tree.isDirectory(child.node) {
                let matches = suffix.map { child.name.hasSuffix($0) } ?? (child.name == match)
                if matches {
                    if child.allocatedSize > 0 { results.append(item(child)) }
                } else if depth + 1 < maxDepth {
                    stack.append((child, depth + 1))
                }
            }
        }
        return results
    }

    private func action(for action: LocationDefinition.Action) -> RecommendedAction {
        switch action.type {
        case .trash:
            return .moveToTrash
        case .info:
            return .informationOnly
        case .command:
            // Only offered when the program is installed; otherwise the location is shown for information.
            guard let executable = (action.executables ?? []).map(expand).first(where: context.commands.isExecutable)
            else { return .informationOnly }
            return .command(ExternalCommand(executable: executable, arguments: action.arguments ?? []))
        }
    }
}

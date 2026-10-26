import Foundation
import os
import ScannerKit

/// Produces clean-up recommendations. Strictly read-only: it measures and lists, it never removes anything.
public struct RecommendationEngine: Sendable {
    public let context: AnalysisContext
    let resolver: LocationResolver
    /// Cache folders measured by a profile location, left out of “App Caches” to avoid counting twice.
    var claimedCacheFolders: Set<String> = KnownLocations.claimedCacheFolders
    private static let logger = Logger(subsystem: "de.df.Stofi", category: "Analysis")
    static let commandTimeout: Duration = .seconds(20)

    public init(context: AnalysisContext) {
        self.context = context
        self.resolver = LocationResolver(context: context)
    }

    /// Runs the rules of `scope` concurrently. Recommendations without content are left out.
    public func analyze(scope: AnalysisScope = .full(profiles: [])) async -> [Recommendation] {
        typealias Rule = @Sendable (RecommendationEngine) async -> [Recommendation]
        // Each rule with the kinds it can produce, so a quickscan only runs what the profiles name.
        let rules: [(kinds: Set<RecommendationKind>, run: Rule)] = [
            ([.userCaches, .userLogs], { await $0.cachesAndLogs() }),
            ([.trash], { await $0.trash() }),
            ([.downloads], { await $0.downloads() }),
            ([.xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport], { await $0.xcode() }),
            ([.simulatorRuntimes, .simulatorUnavailableDevices], { await $0.simulators() }),
            ([.gradleCache, .npmCache, .pnpmStore, .yarnCache, .pipCache, .homebrewCache, .cocoaPodsCache,
              .androidVirtualDevices], { await $0.packageCaches() }),
            ([.inactiveNodeModules], { await $0.inactiveNodeModules() }),
            ([.dockerData], { await $0.docker() }),
            ([.iosBackups, .mailDownloads, .mailAttachments], { await $0.backupsAndMail() }),
            ([.largeMedia], { await $0.largeMedia() }),
            ([.localSnapshots], { await $0.localSnapshots() }),
        ]
        let wanted = scope.builtIns
        let selected = rules.filter { wanted == nil || !$0.kinds.isDisjoint(with: wanted ?? []) }
        let engine = self.claiming(scope.locations)
        let results = await withTaskGroup(of: [Recommendation].self) { group in
            for rule in selected { group.addTask { await rule.run(engine) } }
            for definition in scope.locations {
                group.addTask { await engine.evaluate(definition).map { [$0] } ?? [] }
            }
            var all: [Recommendation] = []
            for await result in group { all += result }
            return all
        }
        Self.logger.notice("Analysis produced \(results.count) recommendations")
        return results
            .filter { $0.kind == .profileLocation || wanted == nil || wanted?.contains($0.kind) == true }
            .filter { !$0.items.isEmpty || $0.availability == .needsFullDiskAccess }
            .sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: - Helpers

    /// A whole location as one item.
    func single(_ kind: RecommendationKind, _ relative: String, risk: RiskLevel, regeneration: Regeneration,
                action: RecommendedAction = .moveToTrash) async -> Recommendation? {
        switch await resolver.locate(context.home(relative)) {
        case .missing:
            return nil
        case .needsFullDiskAccess:
            return Recommendation(kind: kind, items: [], risk: risk, regeneration: regeneration,
                                  action: action, availability: .needsFullDiskAccess)
        case .found(let location):
            guard location.allocatedSize > 0 else { return nil }
            return Recommendation(kind: kind, items: [item(location)], risk: risk,
                                  regeneration: regeneration, action: action)
        }
    }

    /// Every child of a location as its own item (e.g. one entry per app cache).
    func perChild(_ kind: RecommendationKind, _ relatives: [String], risk: RiskLevel, regeneration: Regeneration,
                  action: RecommendedAction = .moveToTrash,
                  include: (TreeLocation) -> Bool = { _ in true }) async -> Recommendation? {
        var items: [RecommendationItem] = []
        var needsAccess = false
        for relative in relatives {
            switch await resolver.locate(context.home(relative)) {
            case .missing: continue
            case .needsFullDiskAccess: needsAccess = true
            case .found(let location):
                items += location.children.filter { $0.allocatedSize > 0 && include($0) }.map { item($0) }
                // A folder that only contains small files (no child nodes) becomes one item itself.
                if location.children.isEmpty && location.allocatedSize > 0 {
                    items.append(item(location))
                }
            }
        }
        if items.isEmpty && !needsAccess { return nil }
        return Recommendation(kind: kind, items: items, risk: risk, regeneration: regeneration, action: action,
                              availability: items.isEmpty ? .needsFullDiskAccess : .available)
    }

    func item(_ location: TreeLocation, detail: String? = nil, command: ExternalCommand? = nil) -> RecommendationItem {
        RecommendationItem(path: location.path, allocatedSize: location.allocatedSize,
                           modificationDate: location.modificationDate, detail: detail, command: command)
    }

    /// Path of a node of the full scan as users see it.
    func displayPath(_ tree: FileTree, _ node: NodeID) -> String {
        tree.displayPath(of: node, startupVolume: context.startupVolume)
    }

    /// The home directory as a location in the full scan, if the scan covers it.
    var homeInTree: TreeLocation? {
        guard let tree = context.tree,
              let node = tree.node(atAbsolutePath: context.homeDirectory, startupVolume: context.startupVolume)
        else { return nil }
        return TreeLocation(tree: tree, node: node, path: context.homeDirectory)
    }

    func run(_ command: ExternalCommand) async -> CommandResult? {
        guard context.commands.isExecutable(command.executable) else { return nil }
        let result = await context.commands.run(command, timeout: Self.commandTimeout)
        if !result.succeeded {
            Self.logger.notice("\(command.displayString, privacy: .public) failed: \(result.exitCode)")
        }
        return result
    }
}

// MARK: - Rules

extension RecommendationEngine {
    func cachesAndLogs() async -> [Recommendation] {
        let caches = await perChild(.userCaches, [KnownLocations.caches], risk: .safe, regeneration: .automatic) {
            !claimedCacheFolders.contains($0.name)
        }
        let logs = await perChild(.userLogs, [KnownLocations.logs], risk: .safe, regeneration: .notApplicable)
        return [caches, logs].compactMap { $0 }
    }

    func trash() async -> [Recommendation] {
        let result = await single(.trash, KnownLocations.trash, risk: .safe, regeneration: .none, action: .emptyTrash)
        return [result].compactMap { $0 }
    }

    func downloads() async -> [Recommendation] {
        guard case .found(let location) = await resolver.locate(context.home(KnownLocations.downloads)) else { return [] }
        let cutoff = context.now.addingTimeInterval(-context.thresholds.oldDownload)
        let items = location.children
            .filter { $0.allocatedSize >= context.thresholds.largeDownload || $0.modificationDate < cutoff }
            .filter { $0.allocatedSize > 0 }
            .map { item($0) }
        return [Recommendation(kind: .downloads, items: items, risk: .caution, regeneration: .none, action: .moveToTrash)]
    }

    func xcode() async -> [Recommendation] {
        async let derived = single(.xcodeDerivedData, KnownLocations.derivedData, risk: .safe, regeneration: .rebuild)
        async let archives = perChild(.xcodeArchives, [KnownLocations.archives], risk: .caution, regeneration: .none)
        async let support = perChild(.xcodeDeviceSupport, KnownLocations.deviceSupport, risk: .safe,
                                     regeneration: .automatic)
        return await [derived, archives, support].compactMap { $0 }
    }

    func packageCaches() async -> [Recommendation] {
        var homebrewAction = RecommendedAction.moveToTrash
        if let brew = KnownLocations.homebrewExecutables.first(where: context.commands.isExecutable) {
            homebrewAction = .command(ExternalCommand(executable: brew, arguments: ["cleanup", "--prune=all"]))
        }
        async let gradle = single(.gradleCache, KnownLocations.gradle, risk: .safe, regeneration: .download)
        async let npm = single(.npmCache, KnownLocations.npm, risk: .safe, regeneration: .download)
        async let pnpm = single(.pnpmStore, KnownLocations.pnpm, risk: .safe, regeneration: .download)
        async let yarn = single(.yarnCache, KnownLocations.yarn, risk: .safe, regeneration: .download)
        async let pip = single(.pipCache, KnownLocations.pip, risk: .safe, regeneration: .download)
        async let brew = single(.homebrewCache, KnownLocations.homebrew, risk: .safe, regeneration: .download,
                                action: homebrewAction)
        async let pods = single(.cocoaPodsCache, KnownLocations.cocoaPods, risk: .safe, regeneration: .download)
        async let avds = perChild(.androidVirtualDevices, [KnownLocations.androidAVDs], risk: .caution,
                                  regeneration: .rebuild) { $0.name.hasSuffix(".avd") }
        return await [gradle, npm, pnpm, yarn, pip, brew, pods, avds].compactMap { $0 }
    }

    func docker() async -> [Recommendation] {
        let prune = KnownLocations.dockerExecutables.first(where: context.commands.isExecutable)
            .map { RecommendedAction.command(ExternalCommand(executable: $0, arguments: ["system", "prune", "--force"])) }
        let result = await single(.dockerData, KnownLocations.dockerImage, risk: .expert, regeneration: .none,
                                  action: prune ?? .informationOnly)
        return [result].compactMap { $0 }
    }

    func backupsAndMail() async -> [Recommendation] {
        async let backups = perChild(.iosBackups, [KnownLocations.iosBackups], risk: .expert, regeneration: .none)
        async let downloads = single(.mailDownloads, KnownLocations.mailDownloads, risk: .safe,
                                     regeneration: .automatic)
        async let attachments = mailAttachments()
        return await [backups, downloads, attachments].compactMap { $0 }
    }

    /// Attachment folders inside the Mail store. Shown only: removing files from the store can damage Mail.
    func mailAttachments() async -> Recommendation? {
        switch await resolver.locate(context.home(KnownLocations.mailStore)) {
        case .missing: return nil
        case .needsFullDiskAccess:
            return Recommendation(kind: .mailAttachments, items: [], risk: .expert, regeneration: .notApplicable,
                                  action: .informationOnly, availability: .needsFullDiskAccess)
        case .found(let store):
            var items: [RecommendationItem] = []
            var stack = [(store, 0)]
            while let (location, depth) = stack.popLast() {
                for child in location.children where location.tree.isDirectory(child.node) {
                    if child.name == "Attachments" {
                        if child.allocatedSize > 0 { items.append(item(child)) }
                    } else if depth < 6 {
                        stack.append((child, depth + 1))
                    }
                }
            }
            return Recommendation(kind: .mailAttachments, items: items, risk: .expert,
                                  regeneration: .notApplicable, action: .informationOnly)
        }
    }

    /// Large media files among the user's own files (full scan only: needs the whole home).
    func largeMedia() async -> [Recommendation] {
        guard let home = homeInTree else { return [] }
        var items: [RecommendationItem] = []
        var stack = [home]
        while let location = stack.popLast() {
            for child in location.children {
                if location.tree.isDirectory(child.node) {
                    if PersonalFiles.isPersonalDirectory(child.path, home: context.homeDirectory) { stack.append(child) }
                } else if child.allocatedSize >= context.thresholds.largeMedia,
                          !location.tree.flags(of: child.node).contains(.symlink),
                          PersonalFiles.isMedia(child.name),
                          PersonalFiles.isPersonal(child.path, home: context.homeDirectory) {
                    items.append(item(child))
                }
            }
        }
        return [Recommendation(kind: .largeMedia, items: items, risk: .caution, regeneration: .none, action: .moveToTrash)]
    }

    /// `node_modules` folders of JavaScript projects that were not changed for a while (assumption B3:
    /// judged by the modification dates of the project folder and its direct subfolders, not of every file).
    func inactiveNodeModules() async -> [Recommendation] {
        guard let home = homeInTree else { return [] }
        let cutoff = context.now.addingTimeInterval(-context.thresholds.inactiveProject)
        var items: [RecommendationItem] = []
        var stack = [home]
        while let location = stack.popLast() {
            let children = location.children
            if let modules = children.first(where: { $0.name == "node_modules" && location.tree.isDirectory($0.node) }),
               FileMetadata.exists(atPath: location.path + "/package.json") {
                let lastChange = ([location] + children.filter { $0.name != "node_modules" })
                    .map(\.modificationDate).max() ?? location.modificationDate
                if lastChange < cutoff && modules.allocatedSize > 0 {
                    items.append(item(modules, detail: (location.path as NSString).lastPathComponent))
                }
            }
            for child in children where location.tree.isDirectory(child.node) && child.name != "node_modules" {
                if PersonalFiles.isPersonalDirectory(child.path, home: context.homeDirectory) { stack.append(child) }
            }
        }
        return [Recommendation(kind: .inactiveNodeModules, items: items, risk: .safe, regeneration: .rebuild,
                               action: .moveToTrash)]
    }
}

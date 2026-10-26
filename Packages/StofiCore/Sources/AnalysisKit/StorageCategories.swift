import ScannerKit

public enum StorageCategoryKind: String, Sendable, CaseIterable, Codable {
    case applications, userData, appData, developer, cachesAndLogs, system, notCaptured
}

public struct StorageCategory: Sendable, Hashable, Identifiable, Codable {
    public var id: StorageCategoryKind { kind }
    public let kind: StorageCategoryKind
    public let bytes: UInt64

    public init(kind: StorageCategoryKind, bytes: UInt64) {
        self.kind = kind
        self.bytes = bytes
    }
}

/// Splits a scan of the startup data volume into categories similar to System Settings → Storage.
///
/// Sizes come from a handful of known folders and simple subtraction, so every scanned byte lands in
/// exactly one category. “Not captured” is what the volume reports as used but the scan did not see:
/// unreadable folders, snapshots and the other volumes of the container (VM, Preboot …).
public enum StorageCategories {
    public static func compute(
        tree: FileTree,
        startupVolume: StartupVolume,
        volumeUsedBytes: UInt64,
        systemVolumeUsedBytes: UInt64,
        pathPrefix: String = ""
    ) -> [StorageCategory] {
        // `pathPrefix` lets tests use a temporary directory that mimics the data volume.
        func node(_ path: String) -> NodeID? {
            tree.node(atAbsolutePath: pathPrefix + path, startupVolume: startupVolume)
        }
        func size(_ path: String) -> UInt64 { node(path).map { tree.allocatedSize(of: $0) } ?? 0 }
        var totals: [StorageCategoryKind: UInt64] = [:]
        func add(_ kind: StorageCategoryKind, _ bytes: UInt64) { totals[kind, default: 0] &+= bytes }

        let scanned = tree.allocatedSize(of: tree.root)
        let applications = size("/Applications")
        add(.applications, applications)

        let users = size("/Users")
        var userAccounted: UInt64 = 0
        if let usersNode = node("/Users") {
            for user in tree.children(of: usersNode) where tree.isDirectory(user) {
                let home = "/Users/" + tree.name(of: user)
                let homeSize = tree.allocatedSize(of: user)
                let library = size(home + "/Library")
                let caches = size(home + "/Library/Caches") &+ size(home + "/Library/Logs")
                let developer = size(home + "/Library/Developer")
                let toolData = [".gradle", ".npm", ".android", ".cocoapods", ".m2", ".cargo", ".rustup", ".docker"]
                    .reduce(UInt64(0)) { $0 &+ size(home + "/" + $1) }
                let ownApps = size(home + "/Applications")
                add(.cachesAndLogs, caches)
                add(.developer, developer &+ toolData)
                add(.applications, ownApps)
                add(.appData, subtract(library, caches &+ developer))
                add(.userData, subtract(homeSize, library &+ toolData &+ ownApps))
                userAccounted &+= homeSize
            }
        }
        // Shared folders such as /Users/Shared.
        add(.userData, subtract(users, userAccounted))

        let systemCaches = size("/Library/Caches") &+ size("/Library/Logs") &+ size("/private/var/folders")
            &+ size("/System/Library/Caches")
        add(.cachesAndLogs, systemCaches)
        add(.system, subtract(scanned, applications &+ users &+ systemCaches) &+ systemVolumeUsedBytes)

        let captured = scanned &+ systemVolumeUsedBytes
        add(.notCaptured, subtract(volumeUsedBytes, captured))

        return StorageCategoryKind.allCases
            .compactMap { kind in totals[kind].flatMap { $0 > 0 ? StorageCategory(kind: kind, bytes: $0) : nil } }
            .sorted { $0.bytes > $1.bytes }
    }

    static func subtract(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }
}

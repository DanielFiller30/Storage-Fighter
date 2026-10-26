import CryptoKit
import Darwin
import Foundation
import ScannerKit

public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let modificationDate: Date
    /// Bytes that deleting this copy would free now. Lower than the size when the copy shares
    /// blocks with an APFS clone or a snapshot.
    public let reclaimableSize: UInt64
}

public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public var id: String { digest }
    public let digest: String
    /// Allocated size of one copy.
    public let allocatedSize: UInt64
    public let files: [DuplicateFile]

    /// Space freed by keeping one copy (the one that frees the least is assumed to stay).
    public var reclaimableSize: UInt64 {
        let sizes = files.map(\.reclaimableSize).sorted()
        return sizes.dropFirst().reduce(0, +)
    }
}

public struct DuplicateProgress: Sendable {
    public let hashedBytes: UInt64
    public let totalBytes: UInt64
    public let groupsFound: Int
}

/// Finds identical files among the user's own files (see ``PersonalFiles``).
///
/// Steps: group by exact size → hash of the first 64 KiB → full SHA-256. Files are only read, with
/// `F_NOCACHE` to avoid flooding the file cache. Skipped: symbolic links, dataless placeholders (reading
/// them would download them from iCloud), and files below the scan's minimum node size (1 MiB).
/// Hard links never show up twice because the scan already counts every inode once.
public struct DuplicateFinder: Sendable {
    public let tree: FileTree
    public let homeDirectory: String
    public let startupVolume: StartupVolume
    static let headerLength = 64 * 1024
    static let chunkLength = 1 << 20

    public init(tree: FileTree, homeDirectory: String, startupVolume: StartupVolume = .current()) {
        self.tree = tree
        self.homeDirectory = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        self.startupVolume = startupVolume
    }

    /// Throws `CancellationError` when the task is cancelled.
    public func find(progress: @Sendable (DuplicateProgress) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        // 1. Candidates grouped by logical size; only sizes that occur more than once matter.
        var bySize: [UInt64: [NodeID]] = [:]
        for index in 1..<max(1, tree.nodeCount) {
            let node = NodeID(index)
            let flags = tree.flags(of: node)
            guard !flags.contains(.directory), !flags.contains(.symlink), !flags.contains(.dataless),
                  tree.logicalSize(of: node) > 0 else { continue }
            bySize[tree.logicalSize(of: node), default: []].append(node)
        }
        let sizeGroups = bySize.values.compactMap { nodes -> [(NodeID, String)]? in
            guard nodes.count > 1 else { return nil }
            let personal = nodes.map { ($0, tree.displayPath(of: $0, startupVolume: startupVolume)) }
                .filter { PersonalFiles.isPersonal($0.1, home: homeDirectory) }
            return personal.count > 1 ? personal : nil
        }
        let totalBytes = sizeGroups.reduce(UInt64(0)) { sum, group in
            sum + UInt64(group.count) * tree.logicalSize(of: group[0].0)
        }
        var hashedBytes: UInt64 = 0
        var groups: [DuplicateGroup] = []

        for group in sizeGroups {
            try Task.checkCancellation()
            let size = tree.logicalSize(of: group[0].0)
            // 2. Cheap pre-filter on the first bytes.
            var byHeader: [Data: [(NodeID, String)]] = [:]
            for candidate in group {
                if let header = Self.digest(of: candidate.1, limit: Self.headerLength) {
                    byHeader[header, default: []].append(candidate)
                }
            }
            hashedBytes += UInt64(group.count) * min(size, UInt64(Self.headerLength))
            // 3. Full hash only where the headers match.
            for candidates in byHeader.values where candidates.count > 1 {
                var byDigest: [Data: [(NodeID, String)]] = [:]
                for candidate in candidates {
                    try Task.checkCancellation()
                    if size <= UInt64(Self.headerLength) {
                        byDigest[Data(), default: []].append(candidate)
                    } else if let digest = Self.digest(of: candidate.1, limit: nil) {
                        byDigest[digest, default: []].append(candidate)
                    }
                    hashedBytes += size
                    progress(DuplicateProgress(hashedBytes: min(hashedBytes, totalBytes), totalBytes: totalBytes,
                                               groupsFound: groups.count))
                }
                for (digest, files) in byDigest where files.count > 1 {
                    let duplicateFiles = files.map { node, path in
                        DuplicateFile(path: path, modificationDate: tree.modificationDate(of: node),
                                      reclaimableSize: FileMetadata.privateSize(atPath: path)
                                        ?? tree.allocatedSize(of: node))
                    }
                    let key = digest.isEmpty ? Self.digest(of: files[0].1, limit: nil) ?? Data() : digest
                    groups.append(DuplicateGroup(digest: key.map { String(format: "%02x", $0) }.joined(),
                                                 allocatedSize: tree.allocatedSize(of: files[0].0),
                                                 files: duplicateFiles.sorted { $0.path < $1.path }))
                }
            }
        }
        progress(DuplicateProgress(hashedBytes: totalBytes, totalBytes: totalBytes, groupsFound: groups.count))
        return groups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    /// The duplicate groups as a recommendation (one item per redundant copy).
    public static func recommendation(for groups: [DuplicateGroup]) -> Recommendation {
        let items = groups.flatMap { group in
            group.files.sorted { $0.reclaimableSize < $1.reclaimableSize }.dropFirst().map { file in
                RecommendationItem(path: file.path, allocatedSize: file.reclaimableSize,
                                   modificationDate: file.modificationDate,
                                   detail: group.files.first.map { ($0.path as NSString).lastPathComponent })
            }
        }
        return Recommendation(kind: .duplicates, items: items, risk: .caution, regeneration: .none, action: .moveToTrash)
    }

    /// SHA-256 of the first `limit` bytes (or the whole file). `nil` if the file cannot be read or is a
    /// dataless placeholder.
    static func digest(of path: String, limit: Int?) -> Data? {
        guard !FileMetadata.isDataless(atPath: path) else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkLength, alignment: 16)
        defer { buffer.deallocate() }
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let count = read(fd, buffer.baseAddress, min(chunkLength, remaining))
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            remaining -= count
        }
        return Data(hasher.finalize())
    }
}

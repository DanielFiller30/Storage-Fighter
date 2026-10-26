import Darwin
import Foundation

/// Read-only, single-threaded reference traversals used by the `StofiBench` target to compare APIs.
/// They only count; they build no tree. Not used by the app.
public enum TraversalBenchmark {
    public struct Result: Sendable {
        public var files = 0
        public var directories = 0
        public var allocatedBytes: UInt64 = 0
        /// Directory-listing syscalls (`getattrlistbulk`), when known.
        public var listingCalls: Int?

        public init() {}
    }

    /// Recursive traversal with `getattrlistbulk`, one reader buffer, no parallelism.
    public static func bulk(_ root: String, includePrivateSize: Bool = true) -> Result {
        var result = Result()
        var reader = BulkDirectoryReader(includePrivateSize: includePrivateSize)
        var seen = Set<UInt64>()
        var pending = [root]
        result.directories = 1
        while let path = pending.popLast() {
            guard reader.read(path: path) == 0 else { continue }
            for entry in reader.entries where entry.errorCode == 0 {
                switch entry.kind {
                case .directory:
                    result.directories += 1
                    if !entry.isMountPoint {
                        let name = String(decoding: reader.nameBytes[entry.nameOffset..<entry.nameOffset + entry.nameLength], as: UTF8.self)
                        pending.append(path + "/" + name)
                    }
                default:
                    if entry.kind == .file {
                        if entry.linkCount > 1 && !seen.insert(entry.fileID).inserted { continue }
                        result.files += 1
                    }
                    result.allocatedBytes += entry.allocatedSize
                }
            }
        }
        result.listingCalls = reader.bulkCalls
        return result
    }

    /// `fts(3)` with `FTS_PHYSICAL | FTS_XDEV`: one `lstat` per entry plus directory reads.
    public static func fts(_ root: String) -> Result {
        var result = Result()
        var seen = Set<UInt64>()
        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let handle = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(handle) }
        while let entry = fts_read(handle) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                result.directories += 1
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let stat = entry.pointee.fts_statp?.pointee else { continue }
                if info == FTS_F {
                    if stat.st_nlink > 1 && !seen.insert(UInt64(stat.st_ino)).inserted { continue }
                    result.files += 1
                }
                result.allocatedBytes += UInt64(stat.st_blocks) * 512
            default:
                break
            }
        }
        return result
    }

    /// `FileManager.enumerator(at:includingPropertiesForKeys:)` with prefetched resource keys.
    public static func fileManager(_ root: String) -> Result {
        var result = Result()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .linkCountKey, .fileResourceIdentifierKey, .isVolumeKey]
        let keySet = Set(keys)
        var seen = Set<AnyHashable>()
        result.directories = 1
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true }
        ) else { return result }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                result.directories += 1
                // The enumerator would cross into other volumes; skip mount points like the other variants.
                if values.isVolume == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                if (values.linkCount ?? 1) > 1, let id = values.fileResourceIdentifier as? AnyHashable,
                   !seen.insert(id).inserted { continue }
                result.files += 1
            }
            result.allocatedBytes += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return result
    }
}

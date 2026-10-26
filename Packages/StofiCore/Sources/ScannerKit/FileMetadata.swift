import Darwin
import Foundation

/// Read-only metadata lookups for single paths (used where no scan tree entry exists).
public enum FileMetadata {
    /// Bytes of a file that are not shared with APFS clones or snapshots, i.e. what deleting it would free
    /// right now. `nil` if the file system does not report it.
    public static func privateSize(atPath path: String) -> UInt64? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(truncatingIfNeeded: Int64(ATTR_CMN_RETURNED_ATTRS))
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        struct Buffer {
            var length: UInt32 = 0
            var returned = attribute_set_t()
            var privateSize: Int64 = 0
        }
        var buffer = Buffer()
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        let result = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlist(path, &attributes, raw.baseAddress, raw.count, options)
        }
        guard result == 0, buffer.returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
        // The struct layout matches the packed buffer: length, returned attrs, then the off_t value.
        return UInt64(max(0, buffer.privateSize))
    }

    /// Whether the path is a dataless placeholder (e.g. an evicted iCloud Drive file). Reading such a file
    /// would trigger a download, so content-reading features must skip it.
    public static func isDataless(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public static func exists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Used bytes of the single volume mounted at `path` (not the whole APFS container), e.g. the sealed
    /// system volume at `/`.
    public static func volumeUsedBytes(atPath path: String) -> UInt64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let blocks = UInt64(info.f_blocks), free = UInt64(info.f_bfree)
        return blocks >= free ? (blocks - free) * UInt64(info.f_bsize) : nil
    }
}

extension FileTree {
    /// Finds the node for an absolute path as users see it (e.g. `/Users/me/Library/Caches`).
    /// For scans of the startup data volume, firmlinked paths are mapped onto the data volume.
    public func node(atAbsolutePath path: String, startupVolume: StartupVolume) -> NodeID? {
        var candidate = path
        if rootDisplayPath == StartupVolume.dataVolumePath,
           let mapped = startupVolume.dataVolumePath(forDisplayPath: path) {
            candidate = mapped
        }
        let rootPath = rootDisplayPath.hasSuffix("/") ? String(rootDisplayPath.dropLast()) : rootDisplayPath
        if candidate == rootPath { return root }
        guard candidate.hasPrefix(rootPath + "/") else { return nil }
        return node(atRelativePath: String(candidate.dropFirst(rootPath.count + 1)))
    }
}

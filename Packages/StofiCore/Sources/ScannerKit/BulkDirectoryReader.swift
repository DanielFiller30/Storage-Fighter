import Darwin

/// One entry of a directory as returned by ``BulkDirectoryReader``. Read-only metadata, never follows links.
struct RawEntry {
    enum Kind: UInt8 { case file, directory, symlink, other }

    var nameOffset: Int
    var nameLength: Int
    var kind: Kind
    var allocatedSize: UInt64
    var logicalSize: UInt64
    var privateSize: UInt64
    var modificationTime: Int64
    var fileID: UInt64
    var linkCount: UInt32
    var bsdFlags: UInt32
    var isMountPoint: Bool
    var errorCode: Int32
}

/// Reads a directory with `getattrlistbulk(2)`: one syscall returns the metadata of many entries.
///
/// The reader is strictly read-only: it opens directories with `O_RDONLY | O_NOFOLLOW` and never
/// resolves symbolic links. One reader owns a reusable buffer and must only be used by one thread at a time.
struct BulkDirectoryReader: ~Copyable {
    private let buffer: UnsafeMutableRawBufferPointer
    private var attributes: attrlist
    /// UTF-8 bytes of all entry names of the last read; ``RawEntry/nameOffset`` points in here.
    private(set) var nameBytes: [UInt8] = []
    private(set) var entries: [RawEntry] = []
    private(set) var bulkCalls = 0

    init(bufferSize: Int = 256 * 1024, includePrivateSize: Bool = true) {
        buffer = .allocate(byteCount: bufferSize, alignment: 16)
        attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The header macros import with mixed integer types, so convert each one explicitly.
        let common: [Int64] = [Int64(ATTR_CMN_RETURNED_ATTRS), Int64(ATTR_CMN_NAME), Int64(ATTR_CMN_ERROR),
                               Int64(ATTR_CMN_OBJTYPE), Int64(ATTR_CMN_MODTIME), Int64(ATTR_CMN_FLAGS),
                               Int64(ATTR_CMN_FILEID)]
        attributes.commonattr = common.reduce(0) { $0 | attrgroup_t(truncatingIfNeeded: $1) }
        attributes.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        attributes.forkattr = includePrivateSize ? attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) : 0
    }

    deinit { buffer.deallocate() }

    /// Reads all entries of the directory at `path`. Returns `0` on success or an `errno` value.
    mutating func read(path: String) -> Int32 {
        entries.removeAll(keepingCapacity: true)
        nameBytes.removeAll(keepingCapacity: true)

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer.baseAddress, buffer.count, options)
            bulkCalls += 1
            if count < 0 {
                // A directory that vanishes or changes while it is read is not fatal; keep what we have.
                return entries.isEmpty ? errno : 0
            }
            if count == 0 { return 0 }
            parse(count: Int(count))
        }
    }

    private mutating func parse(count: Int) {
        guard var entryStart = buffer.baseAddress else { return }
        for _ in 0..<count {
            let length = Int(entryStart.loadUnaligned(as: UInt32.self))
            var field = entryStart + MemoryLayout<UInt32>.size

            // Layout (verified by hex dump on APFS): returned attrs, error, name ref, objtype, modtime, flags,
            // fileid; then the dir group only for directories, the file group only for files and symlinks,
            // then the cmnext group. FSOPT_PACK_INVAL_ATTRS only fills invalid values *within* a group that
            // applies to the object type, so presence of a group is decided by its `returned` bits.
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size

            let errorCode = Int32(bitPattern: field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size

            let nameRef = field.loadUnaligned(as: attrreference_t.self)
            let namePointer = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
            // attr_length includes the terminating NUL.
            let nameLength = max(0, Int(nameRef.attr_length) - 1)
            field += MemoryLayout<attrreference_t>.size

            let objectType = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size

            let modTime = field.loadUnaligned(as: timespec.self)
            field += MemoryLayout<timespec>.size

            let bsdFlags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size

            let fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size

            var mountStatus: UInt32 = 0
            if returned.dirattr != 0 {
                mountStatus = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }

            var linkCount: UInt32 = 1, totalSize: Int64 = 0, allocSize: Int64 = 0
            if returned.fileattr != 0 {
                linkCount = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
                totalSize = field.loadUnaligned(as: Int64.self)
                field += MemoryLayout<Int64>.size
                allocSize = field.loadUnaligned(as: Int64.self)
                field += MemoryLayout<Int64>.size
            }

            let hasPrivateSize = returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0
            let privateSize = returned.forkattr != 0 ? field.loadUnaligned(as: Int64.self) : 0

            let kind: RawEntry.Kind = switch objectType {
            case UInt32(VREG.rawValue): .file
            case UInt32(VDIR.rawValue): .directory
            case UInt32(VLNK.rawValue): .symlink
            default: .other
            }

            let offset = nameBytes.count
            nameBytes.append(contentsOf: UnsafeBufferPointer(start: namePointer, count: nameLength))

            let allocated = UInt64(max(0, allocSize))
            entries.append(RawEntry(
                nameOffset: offset,
                nameLength: nameLength,
                kind: kind,
                allocatedSize: allocated,
                logicalSize: UInt64(max(0, totalSize)),
                privateSize: hasPrivateSize ? min(allocated, UInt64(max(0, privateSize))) : allocated,
                modificationTime: Int64(modTime.tv_sec),
                fileID: fileID,
                linkCount: linkCount,
                bsdFlags: bsdFlags,
                isMountPoint: kind == .directory
                    && mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0,
                errorCode: errorCode
            ))

            entryStart += length
        }
    }
}

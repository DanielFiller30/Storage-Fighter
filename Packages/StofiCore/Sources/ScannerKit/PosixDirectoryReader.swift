import Darwin

/// Common interface of the directory readers so the scanner can be benchmarked with either API.
protocol DirectoryReading: ~Copyable {
    init(includePrivateSize: Bool)
    var entries: [RawEntry] { get }
    var nameBytes: [UInt8] { get }
    /// Syscalls spent on listing and metadata (approximate for readers that use libc buffering).
    var bulkCalls: Int { get }
    mutating func read(path: String) -> Int32
}

extension BulkDirectoryReader: DirectoryReading {
    init(includePrivateSize: Bool) { self.init(bufferSize: 256 * 1024, includePrivateSize: includePrivateSize) }
}

/// Classic `readdir(3)` + `fstatat(2)` reader: one `stat` call per entry. Exists for the benchmark;
/// cannot report the clone-private size.
struct PosixDirectoryReader: ~Copyable, DirectoryReading {
    private(set) var entries: [RawEntry] = []
    private(set) var nameBytes: [UInt8] = []
    private(set) var bulkCalls = 0

    init(includePrivateSize: Bool) {}

    mutating func read(path: String) -> Int32 {
        entries.removeAll(keepingCapacity: true)
        nameBytes.removeAll(keepingCapacity: true)

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        var directoryStat = stat()
        guard fstat(fd, &directoryStat) == 0, let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            return code
        }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            let nameLength = Int(entry.pointee.d_namlen)
            let isDot = withUnsafeBytes(of: entry.pointee.d_name) { raw -> Bool in
                (nameLength == 1 && raw[0] == 0x2E) || (nameLength == 2 && raw[0] == 0x2E && raw[1] == 0x2E)
            }
            if isDot { continue }

            var info = stat()
            let result = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) { name in
                    fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW)
                }
            }
            bulkCalls += 1
            let offset = nameBytes.count
            withUnsafeBytes(of: entry.pointee.d_name) { raw in
                nameBytes.append(contentsOf: raw.prefix(nameLength))
            }
            if result != 0 {
                entries.append(RawEntry(nameOffset: offset, nameLength: nameLength, kind: .other, allocatedSize: 0,
                                        logicalSize: 0, privateSize: 0, modificationTime: 0, fileID: 0,
                                        linkCount: 1, bsdFlags: 0, isMountPoint: false, errorCode: errno))
                continue
            }
            let kind: RawEntry.Kind = switch info.st_mode & S_IFMT {
            case S_IFREG: .file
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
            let allocated = UInt64(max(0, info.st_blocks)) * 512
            entries.append(RawEntry(
                nameOffset: offset, nameLength: nameLength, kind: kind,
                allocatedSize: allocated, logicalSize: UInt64(max(0, info.st_size)), privateSize: allocated,
                modificationTime: Int64(info.st_mtimespec.tv_sec), fileID: UInt64(info.st_ino),
                linkCount: UInt32(info.st_nlink), bsdFlags: info.st_flags,
                isMountPoint: kind == .directory && info.st_dev != directoryStat.st_dev,
                errorCode: 0
            ))
        }
        return 0
    }
}

import Darwin
import Synchronization

/// Thread-safe, append-only builder for a ``FileTree``. Workers hand in whole directory listings, so the
/// lock is taken once per directory, not once per file. Directory sizes are propagated to all ancestors
/// immediately, which lets the UI show growing totals while the scan is still running.
final class TreeBuilder: Sendable {
    struct State: ~Copyable {
        var nodes: [FileTree.Node] = []
        var names: [UInt8] = []
        /// Last child per node, so appending stays O(1). Only needed while building.
        var lastChild: [NodeID] = []
        var seenHardLinks: Set<UInt64> = []
        var statistics = ScanStatistics()
        var currentPath = ""
    }

    struct Subdirectory: Sendable {
        let node: NodeID
        let path: String
    }

    private let state: Mutex<State>
    let rootNode: NodeID = 0
    private let minimumFileNodeSize: UInt64
    private let maximumSampleErrors = 200

    init(rootName: String, minimumFileNodeSize: UInt64) {
        self.minimumFileNodeSize = minimumFileNodeSize
        var initial = State()
        initial.nodes.reserveCapacity(1 << 16)
        initial.names.reserveCapacity(1 << 20)
        let nameBytes = Array(rootName.utf8.prefix(Int(UInt16.max)))
        initial.names.append(contentsOf: nameBytes)
        initial.nodes.append(FileTree.Node(
            parent: FileTree.noNode, firstChild: FileTree.noNode, nextSibling: FileTree.noNode,
            nameOffset: 0, nameLength: UInt16(nameBytes.count), flags: .directory,
            fileCount: 0, allocatedSize: 0, logicalSize: 0, privateSize: 0, modificationTime: 0
        ))
        initial.lastChild.append(FileTree.noNode)
        initial.statistics.directories = 1
        state = Mutex(initial)
    }

    /// Adds the listing of `directory` and returns the subdirectories that still need to be scanned.
    func add<Reader: DirectoryReading & ~Copyable>(
        listing reader: borrowing Reader,
        to directory: NodeID,
        path: String
    ) -> [Subdirectory] {
        var subdirectories: [Subdirectory] = []
        let entries = reader.entries
        let readerNames = reader.nameBytes
        let threshold = minimumFileNodeSize

        state.withLock { state in
            state.currentPath = path
            var bytes: UInt64 = 0, logical: UInt64 = 0, privateBytes: UInt64 = 0, files: UInt32 = 0

            for entry in entries {
                let nameSlice = readerNames[entry.nameOffset..<entry.nameOffset + entry.nameLength]
                if entry.errorCode != 0 {
                    Self.recordError(&state, path: path, name: nameSlice, code: entry.errorCode, cap: maximumSampleErrors)
                    continue
                }
                switch entry.kind {
                case .directory:
                    var flags: NodeFlags = .directory
                    if entry.isMountPoint {
                        flags.insert(.mountPoint)
                        state.statistics.skippedMountPoints.append(Self.join(path, nameSlice))
                    }
                    let id = Self.appendNode(&state, parent: directory, name: nameSlice, flags: flags,
                                             entry: entry, sizes: (0, 0, 0), fileCount: 0)
                    state.statistics.directories += 1
                    if !entry.isMountPoint {
                        subdirectories.append(Subdirectory(node: id, path: Self.join(path, nameSlice)))
                    }

                case .file, .symlink, .other:
                    var flags: NodeFlags = []
                    if entry.kind == .symlink {
                        flags.insert(.symlink)
                        state.statistics.symlinks += 1
                    } else if entry.kind == .file {
                        state.statistics.regularFiles += 1
                    }
                    if entry.bsdFlags & UInt32(SF_DATALESS) != 0 { flags.insert(.dataless) }
                    if entry.bsdFlags & UInt32(UF_COMPRESSED) != 0 { flags.insert(.compressed) }
                    if entry.kind == .file && entry.linkCount > 1 {
                        flags.insert(.hardLinked)
                        // The scan stays on one device, so the file ID alone identifies the inode.
                        if !state.seenHardLinks.insert(entry.fileID).inserted {
                            state.statistics.skippedHardLinks += 1
                            continue
                        }
                    }
                    let count: UInt32 = entry.kind == .file ? 1 : 0
                    bytes &+= entry.allocatedSize
                    logical &+= entry.logicalSize
                    privateBytes &+= entry.privateSize
                    files &+= count
                    if entry.allocatedSize >= threshold {
                        _ = Self.appendNode(&state, parent: directory, name: nameSlice, flags: flags, entry: entry,
                                            sizes: (entry.allocatedSize, entry.logicalSize, entry.privateSize),
                                            fileCount: count)
                    }
                }
            }

            state.statistics.allocatedBytes &+= bytes
            state.statistics.sharedBytes &+= bytes &- privateBytes
            // Propagate the directory's own file sizes to itself and every ancestor.
            var current = directory
            while current != FileTree.noNode {
                state.nodes[Int(current)].allocatedSize &+= bytes
                state.nodes[Int(current)].logicalSize &+= logical
                state.nodes[Int(current)].privateSize &+= privateBytes
                state.nodes[Int(current)].fileCount &+= files
                current = state.nodes[Int(current)].parent
            }
        }
        return subdirectories
    }

    func markUnreadable(_ directory: NodeID, path: String, code: Int32) {
        state.withLock { state in
            state.nodes[Int(directory)].flags.insert(.unreadable)
            state.statistics.unreadableDirectories += 1
            if state.statistics.sampleErrors.count < maximumSampleErrors {
                state.statistics.sampleErrors.append(ScanError(path: path, code: code))
            }
        }
    }

    func addBulkCalls(_ count: Int) {
        state.withLock { $0.statistics.bulkCalls += count }
    }

    func setRootModificationTime(_ seconds: Int64) {
        state.withLock { $0.nodes[0].modificationTime = seconds }
    }

    /// A cheap, consistent view for live progress: totals plus the largest children of the root.
    func snapshot(topCount: Int) -> ScanSnapshot {
        state.withLock { state in
            var top: [ScanSnapshot.Item] = []
            var child = state.nodes[0].firstChild
            while child != FileTree.noNode {
                let node = state.nodes[Int(child)]
                let start = Int(node.nameOffset)
                top.append(ScanSnapshot.Item(
                    name: String(decoding: state.names[start..<start + Int(node.nameLength)], as: UTF8.self),
                    allocatedSize: node.allocatedSize,
                    isDirectory: node.flags.contains(.directory)
                ))
                child = node.nextSibling
            }
            top.sort { $0.allocatedSize > $1.allocatedSize }
            return ScanSnapshot(
                statistics: state.statistics,
                topItems: Array(top.prefix(topCount)),
                currentPath: state.currentPath
            )
        }
    }

    /// Hands the collected data over to an immutable tree. The builder must not be used afterwards.
    func finish(rootDisplayPath: String, duration: Duration) -> FileTree {
        state.withLock { state in
            state.statistics.duration = duration
            let nodes = state.nodes
            let names = state.names
            state.nodes = []
            state.names = []
            state.lastChild = []
            state.seenHardLinks = []
            return FileTree(nodes: nodes, names: names, rootDisplayPath: rootDisplayPath, statistics: state.statistics)
        }
    }

    // MARK: - Helpers

    private static func appendNode(
        _ state: inout State,
        parent: NodeID,
        name: ArraySlice<UInt8>,
        flags: NodeFlags,
        entry: RawEntry,
        sizes: (UInt64, UInt64, UInt64),
        fileCount: UInt32
    ) -> NodeID {
        let id = NodeID(state.nodes.count)
        let nameBytes = name.prefix(Int(UInt16.max))
        let offset = UInt32(state.names.count)
        state.names.append(contentsOf: nameBytes)
        state.nodes.append(FileTree.Node(
            parent: parent, firstChild: FileTree.noNode, nextSibling: FileTree.noNode,
            nameOffset: offset, nameLength: UInt16(nameBytes.count), flags: flags,
            fileCount: fileCount, allocatedSize: sizes.0, logicalSize: sizes.1, privateSize: sizes.2,
            modificationTime: entry.modificationTime
        ))
        state.lastChild.append(FileTree.noNode)

        let previous = state.lastChild[Int(parent)]
        if previous == FileTree.noNode {
            state.nodes[Int(parent)].firstChild = id
        } else {
            state.nodes[Int(previous)].nextSibling = id
        }
        state.lastChild[Int(parent)] = id
        return id
    }

    private static func recordError(_ state: inout State, path: String, name: ArraySlice<UInt8>, code: Int32, cap: Int) {
        if state.statistics.sampleErrors.count < cap {
            state.statistics.sampleErrors.append(ScanError(path: join(path, name), code: code))
        }
    }

    static func join(_ path: String, _ name: ArraySlice<UInt8>) -> String {
        let component = String(decoding: name, as: UTF8.self)
        return path.hasSuffix("/") ? path + component : path + "/" + component
    }
}

/// Live progress of a running scan.
public struct ScanSnapshot: Sendable {
    public struct Item: Sendable, Hashable {
        public let name: String
        public let allocatedSize: UInt64
        public let isDirectory: Bool

        public init(name: String, allocatedSize: UInt64, isDirectory: Bool) {
            self.name = name
            self.allocatedSize = allocatedSize
            self.isDirectory = isDirectory
        }
    }

    public let statistics: ScanStatistics
    /// Largest direct children of the scan root, sorted by allocated size (descending).
    public let topItems: [Item]
    /// The directory most recently processed.
    public let currentPath: String
}

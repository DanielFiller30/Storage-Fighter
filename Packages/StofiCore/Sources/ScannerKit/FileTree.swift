import Foundation

/// Index of a node inside a ``FileTree``.
public typealias NodeID = UInt32

/// Compact, immutable result of a scan.
///
/// All nodes live in one contiguous array of plain structs; names are stored as UTF-8 in a single
/// shared byte buffer. There are no `URL` or `String` objects per file: paths are rebuilt on demand
/// from the parent chain. Directories carry the aggregated size of their whole subtree.
///
/// Files smaller than ``ScanOptions/minimumFileNodeSize`` do not get their own node; their sizes are
/// folded into the parent directory (see ``directFileBytes(of:)``).
public struct FileTree: Sendable {
    public static let noNode: NodeID = .max

    struct Node: Sendable {
        var parent: NodeID
        var firstChild: NodeID
        var nextSibling: NodeID
        var nameOffset: UInt32
        var nameLength: UInt16
        var flags: NodeFlags
        /// Number of regular files in the subtree (including files folded into directories).
        var fileCount: UInt32
        /// Allocated bytes on disk (`totalFileAllocatedSize` semantics), aggregated for directories.
        var allocatedSize: UInt64
        /// Logical bytes (`totalFileSize` semantics), aggregated for directories.
        var logicalSize: UInt64
        /// Bytes that would be freed immediately on deletion (not shared with clones or snapshots).
        var privateSize: UInt64
        /// Modification time in seconds since 1970.
        var modificationTime: Int64
    }

    var nodes: [Node]
    var names: [UInt8]

    /// The path of the scanned root as it should be shown to the user.
    public let rootDisplayPath: String
    public let statistics: ScanStatistics

    public var root: NodeID { 0 }
    public var nodeCount: Int { nodes.count }

    public func name(of id: NodeID) -> String {
        let node = nodes[Int(id)]
        let start = Int(node.nameOffset)
        return String(decoding: names[start..<start + Int(node.nameLength)], as: UTF8.self)
    }

    public func parent(of id: NodeID) -> NodeID? {
        let parent = nodes[Int(id)].parent
        return parent == Self.noNode ? nil : parent
    }

    public func children(of id: NodeID) -> ChildSequence {
        ChildSequence(tree: self, first: nodes[Int(id)].firstChild)
    }

    public func allocatedSize(of id: NodeID) -> UInt64 { nodes[Int(id)].allocatedSize }
    public func logicalSize(of id: NodeID) -> UInt64 { nodes[Int(id)].logicalSize }
    public func privateSize(of id: NodeID) -> UInt64 { nodes[Int(id)].privateSize }
    public func fileCount(of id: NodeID) -> UInt32 { nodes[Int(id)].fileCount }
    public func flags(of id: NodeID) -> NodeFlags { nodes[Int(id)].flags }
    public func isDirectory(_ id: NodeID) -> Bool { nodes[Int(id)].flags.contains(.directory) }

    public func modificationDate(of id: NodeID) -> Date {
        Date(timeIntervalSince1970: TimeInterval(nodes[Int(id)].modificationTime))
    }

    /// Allocated bytes of the files directly inside a directory that have no node of their own.
    public func directFileBytes(of id: NodeID) -> UInt64 {
        var childBytes: UInt64 = 0
        for child in children(of: id) { childBytes &+= nodes[Int(child)].allocatedSize }
        let total = nodes[Int(id)].allocatedSize
        return total >= childBytes ? total - childBytes : 0
    }

    /// Full display path of a node, e.g. `/Users/me/Library/Caches`.
    public func path(of id: NodeID) -> String {
        var components: [NodeID] = []
        var current = id
        while current != root {
            components.append(current)
            current = nodes[Int(current)].parent
        }
        var path = rootDisplayPath
        for component in components.reversed() {
            if !path.hasSuffix("/") { path += "/" }
            path += name(of: component)
        }
        return path
    }

    /// Looks up a node by a path relative to the root (components separated by `/`).
    public func node(atRelativePath relativePath: String) -> NodeID? {
        var current = root
        for component in relativePath.split(separator: "/") {
            guard let next = children(of: current).first(where: { name(of: $0) == component }) else { return nil }
            current = next
        }
        return current
    }

    public struct ChildSequence: Sequence, IteratorProtocol, Sendable {
        let tree: FileTree
        var current: NodeID

        init(tree: FileTree, first: NodeID) {
            self.tree = tree
            self.current = first
        }

        public mutating func next() -> NodeID? {
            guard current != FileTree.noNode else { return nil }
            defer { current = tree.nodes[Int(current)].nextSibling }
            return current
        }
    }
}

public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    /// The file has more than one hard link; it was counted only at its first occurrence.
    public static let hardLinked = NodeFlags(rawValue: 1 << 2)
    /// The directory could not be read (e.g. missing permission); its size is incomplete.
    public static let unreadable = NodeFlags(rawValue: 1 << 3)
    /// A mount point that was not traversed.
    public static let mountPoint = NodeFlags(rawValue: 1 << 4)
    /// Dataless file (e.g. evicted iCloud Drive file), occupies no local space.
    public static let dataless = NodeFlags(rawValue: 1 << 5)
    public static let compressed = NodeFlags(rawValue: 1 << 6)
}

public struct ScanStatistics: Sendable, Equatable {
    public var regularFiles: Int = 0
    public var directories: Int = 0
    public var symlinks: Int = 0
    public var allocatedBytes: UInt64 = 0
    /// Allocated bytes that are shared with clones or snapshots and would not be freed by deletion.
    /// Clones are counted at their full allocated size; this value shows how much of that may be shared.
    public var sharedBytes: UInt64 = 0
    /// Hard links that were skipped because their inode was already counted.
    public var skippedHardLinks: Int = 0
    public var unreadableDirectories: Int = 0
    public var skippedMountPoints: [String] = []
    /// A capped sample of errors (path and errno) for diagnostics.
    public var sampleErrors: [ScanError] = []
    /// Number of `getattrlistbulk` calls; a proxy for the syscall cost.
    public var bulkCalls: Int = 0
    public var duration: Duration = .zero

    public init() {}
}

public struct ScanError: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let code: Int32

    public var description: String { "\(path): \(String(cString: strerror(code)))" }
}

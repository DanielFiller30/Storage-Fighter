import Foundation

/// A row of the “largest items” list, detached from the tree so it can be sorted and filtered freely.
public struct LargestItem: Sendable, Hashable, Identifiable {
    public let id: NodeID
    public let name: String
    public let path: String
    public let allocatedSize: UInt64
    public let modificationDate: Date
    public let isDirectory: Bool
    public let fileCount: UInt32
}

extension FileTree {
    public enum ItemKind: Sendable { case files, directories }

    /// The `limit` largest files or directories (root excluded), largest first.
    ///
    /// Only files that have their own node are considered, i.e. files of at least
    /// ``ScanOptions/minimumFileNodeSize``. Directories overlap by nature: a folder and its subfolder can
    /// both appear.
    public func largestItems(_ kind: ItemKind, limit: Int, startupVolume: StartupVolume) -> [LargestItem] {
        guard limit > 0, nodeCount > 1 else { return [] }
        var candidates: [(size: UInt64, id: NodeID)] = []
        candidates.reserveCapacity(min(nodeCount, 1 << 20))
        for index in 1..<nodeCount {
            let node = nodes[index]
            let isDirectory = node.flags.contains(.directory)
            guard (kind == .directories) == isDirectory, !node.flags.contains(.symlink) else { continue }
            candidates.append((node.allocatedSize, NodeID(index)))
        }
        let top: ArraySlice<(size: UInt64, id: NodeID)>
        if candidates.count > limit * 4 {
            // Partial selection is cheaper than sorting millions of entries.
            let threshold = Self.sizeThreshold(for: candidates.map(\.size), keeping: limit)
            top = candidates.filter { $0.size >= threshold }.sorted { $0.size > $1.size }.prefix(limit)
        } else {
            top = candidates.sorted { $0.size > $1.size }.prefix(limit)
        }
        return top.map { candidate in
            LargestItem(
                id: candidate.id,
                name: name(of: candidate.id),
                path: displayPath(of: candidate.id, startupVolume: startupVolume),
                allocatedSize: candidate.size,
                modificationDate: modificationDate(of: candidate.id),
                isDirectory: isDirectory(candidate.id),
                fileCount: fileCount(of: candidate.id)
            )
        }
    }

    /// Size of the `keeping`-th largest value (quickselect, average O(n)).
    static func sizeThreshold(for sizes: [UInt64], keeping count: Int) -> UInt64 {
        var values = sizes
        let k = min(count, values.count) - 1
        guard k >= 0 else { return 0 }
        var low = 0, high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low, j = high
            while i <= j {
                while values[i] > pivot { i += 1 }
                while values[j] < pivot { j -= 1 }
                if i <= j { values.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { high = j } else if k >= i { low = i } else { break }
        }
        return values[k]
    }
}

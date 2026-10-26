import CoreGraphics

/// One laid-out rectangle of a nested treemap.
public struct TreemapCell<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let rect: CGRect
    /// 1 for direct children of the root, 2 for grandchildren, …
    public let depth: Int
    /// Index of the depth-1 ancestor among the root's children; useful for colouring.
    public let branch: Int
    /// Whether children of this cell were laid out inside it.
    public let hasChildren: Bool
    /// Index of the parent cell in the result array, `nil` for depth 1.
    public let parentIndex: Int?
}

public struct TreemapOptions: Sendable {
    /// Deepest level that is laid out.
    public var maximumDepth: Int = 8
    /// Cells narrower or lower than this are dropped; their area stays part of the parent.
    public var minimumSide: CGFloat = 4
    /// Inset between a container and its children.
    public var padding: CGFloat = 2
    /// Space reserved for a label at the top of containers that are at least ``minimumHeaderContainer``.
    public var headerHeight: CGFloat = 16
    public var minimumHeaderContainer = CGSize(width: 80, height: 48)
    /// Hard cap on the number of cells, keeps drawing and hit-testing cheap for huge trees.
    public var maximumCells: Int = 20_000

    public init() {}
}

public enum Treemap {
    /// Squarified layout (Bruls, Huizing, van Wijk 2000) of `weights` inside `rect`.
    ///
    /// Returns one rectangle per weight in input order. Weights that are zero, negative or not finite
    /// get an empty rectangle. The rectangles do not overlap and exactly cover `rect` when at least one
    /// weight is positive.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: weights.count)
        let order = weights.indices
            .filter { weights[$0] > 0 && weights[$0].isFinite }
            .sorted { weights[$0] > weights[$1] }
        let total = order.reduce(0.0) { $0 + weights[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { weights[$0] * scale }
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = areas[start]
            var currentWorst = worstRatio(sum: rowSum, max: areas[start], min: areas[start], side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                // Areas are sorted descending, so the row maximum is the first and the minimum the new one.
                let candidateWorst = worstRatio(sum: candidateSum, max: areas[start], min: areas[end], side: side)
                if candidateWorst > currentWorst { break }
                rowSum = candidateSum
                currentWorst = candidateWorst
                end += 1
            }

            let isLast = end == areas.count
            if remaining.width >= remaining.height {
                // Vertical strip on the left.
                let width = isLast ? remaining.width : CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for index in start..<end {
                    let height = index == end - 1
                        ? remaining.maxY - y
                        : CGFloat(areas[index] / Double(width))
                    result[order[index]] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Horizontal strip on top.
                let height = isLast ? remaining.height : CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for index in start..<end {
                    let width = index == end - 1
                        ? remaining.maxX - x
                        : CGFloat(areas[index] / Double(height))
                    result[order[index]] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }

    /// Lays out a hierarchy, outermost level first. Cells are returned in pre-order (every parent before
    /// its children), so drawing in array order paints children on top and hit-testing can search backwards.
    ///
    /// - Parameter children: Returns the children of an element with their weights. It is only called for
    ///   elements whose cell is large enough to show children.
    public static func layout<ID: Hashable & Sendable>(
        root: ID,
        in rect: CGRect,
        options: TreemapOptions = TreemapOptions(),
        children: (ID) -> [(id: ID, weight: Double)]
    ) -> [TreemapCell<ID>] {
        var cells: [TreemapCell<ID>] = []
        // Depth-first with an explicit stack; children are pushed in reverse to keep pre-order.
        var stack: [Pending<ID>] = []
        pushChildren(of: root, in: rect, depth: 1, branch: nil, parentIndex: nil,
                     options: options, children: children, onto: &stack)

        while let item = stack.popLast(), cells.count < options.maximumCells {
            let index = cells.count
            let inner = innerRect(of: item.rect, options: options)
            let canNest = item.depth < options.maximumDepth
                && inner.width >= options.minimumSide && inner.height >= options.minimumSide
            let before = stack.count
            if canNest {
                pushChildren(of: item.id, in: inner, depth: item.depth + 1, branch: item.branch,
                             parentIndex: index, options: options, children: children, onto: &stack)
            }
            cells.append(TreemapCell(id: item.id, rect: item.rect, depth: item.depth, branch: item.branch,
                                     hasChildren: stack.count > before, parentIndex: item.parentIndex))
        }
        return cells
    }

    /// Area available for children: padded, and with room for a label if the container is large enough.
    public static func innerRect(of rect: CGRect, options: TreemapOptions) -> CGRect {
        var inner = rect.insetBy(dx: options.padding, dy: options.padding)
        if rect.width >= options.minimumHeaderContainer.width && rect.height >= options.minimumHeaderContainer.height {
            inner.origin.y += options.headerHeight
            inner.size.height -= options.headerHeight
        }
        return inner.width > 0 && inner.height > 0 ? inner : .zero
    }

    private static func pushChildren<ID>(
        of id: ID,
        in rect: CGRect,
        depth: Int,
        branch: Int?,
        parentIndex: Int?,
        options: TreemapOptions,
        children: (ID) -> [(id: ID, weight: Double)],
        onto stack: inout [Pending<ID>]
    ) {
        let items = children(id)
        guard !items.isEmpty else { return }
        let rects = squarify(items.map(\.weight), in: rect)
        for index in items.indices.reversed() {
            let childRect = rects[index]
            guard childRect.width >= options.minimumSide, childRect.height >= options.minimumSide else { continue }
            stack.append(Pending(id: items[index].id, rect: childRect, depth: depth,
                                 branch: branch ?? index, parentIndex: parentIndex))
        }
    }

    private struct Pending<ID> {
        let id: ID
        let rect: CGRect
        let depth: Int
        let branch: Int
        let parentIndex: Int?
    }

    private static func worstRatio(sum: Double, max: Double, min: Double, side: Double) -> Double {
        let sideSquared = side * side
        let sumSquared = sum * sum
        return Swift.max(sideSquared * max / sumSquared, sumSquared / (sideSquared * min))
    }
}

extension Array {
    /// Index of the innermost treemap cell containing `point`, searching from the end (pre-order layout).
    public func innermostCellIndex<ID>(at point: CGPoint) -> Int? where Element == TreemapCell<ID> {
        lastIndex { $0.rect.contains(point) }
    }
}

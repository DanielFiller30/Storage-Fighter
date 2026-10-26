import CoreGraphics
import Testing
@testable import LayoutKit

private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let intersection = a.intersection(b)
    return !intersection.isNull && intersection.width > 0.0001 && intersection.height > 0.0001
}

@Suite("Squarified layout")
struct SquarifyTests {
    let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)

    @Test(arguments: [
        [1.0],
        [6, 6, 4, 3, 2, 2, 1],
        [1000, 1, 1, 1],
        [5, 1, 3, 2, 8, 13, 21, 1, 1, 2],
        Array(repeating: 1.0, count: 100),
    ])
    func areasAreProportionalAndCoverTheBounds(weights: [Double]) {
        let rects = Treemap.squarify(weights, in: bounds)
        let total = weights.reduce(0, +)
        #expect(rects.count == weights.count)
        for (weight, rect) in zip(weights, rects) {
            #expect(abs(area(rect) - weight / total * area(bounds)) < 0.5)
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        }
        #expect(abs(rects.map(area).reduce(0, +) - area(bounds)) < 1)
        for i in rects.indices { for j in rects.indices where j > i { #expect(!overlaps(rects[i], rects[j])) } }
    }

    @Test func keepsInputOrderForUnsortedWeights() {
        let rects = Treemap.squarify([1, 9], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(area(rects[1]) > area(rects[0]) * 8)
    }

    @Test func ignoresZeroNegativeAndInvalidWeights() {
        let rects = Treemap.squarify([0, 4, -1, .nan, .infinity, 4], in: bounds)
        #expect(rects[0] == .zero && rects[2] == .zero && rects[3] == .zero && rects[4] == .zero)
        #expect(abs(area(rects[1]) + area(rects[5]) - area(bounds)) < 1)
    }

    @Test func emptyInputOrEmptyRect() {
        #expect(Treemap.squarify([], in: bounds).isEmpty)
        #expect(Treemap.squarify([1, 2], in: .zero) == [.zero, .zero])
    }

    @Test func producesReasonableAspectRatios() {
        let rects = Treemap.squarify(Array(repeating: 1.0, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 2)
    }
}

@Suite("Nested layout")
struct NestedLayoutTests {
    /// root → a(60: a1 40, a2 20), b(30), c(10)
    let tree: [String: [(id: String, weight: Double)]] = [
        "root": [("a", 60), ("b", 30), ("c", 10)],
        "a": [("a1", 40), ("a2", 20)],
    ]
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func childrenLieInsideTheirParentAndFollowIt() {
        let cells = Treemap.layout(root: "root", in: bounds) { tree[$0] ?? [] }
        #expect(Set(cells.map(\.id)) == ["a", "b", "c", "a1", "a2"])
        for (index, cell) in cells.enumerated() {
            if let parent = cell.parentIndex {
                #expect(parent < index)
                #expect(cells[parent].rect.contains(cell.rect))
                #expect(cell.depth == cells[parent].depth + 1)
                #expect(cell.branch == cells[parent].branch)
            } else {
                #expect(cell.depth == 1)
            }
        }
        let a = cells.first { $0.id == "a" }
        #expect(a?.hasChildren == true)
        #expect(cells.first { $0.id == "b" }?.hasChildren == false)
    }

    @Test func hitTestingFindsTheInnermostCell() throws {
        let cells = Treemap.layout(root: "root", in: bounds) { tree[$0] ?? [] }
        let a1 = try #require(cells.first { $0.id == "a1" })
        let hit = cells.innermostCellIndex(at: CGPoint(x: a1.rect.midX, y: a1.rect.midY))
        #expect(hit.map { cells[$0].id } == "a1")
        #expect(cells.innermostCellIndex(at: CGPoint(x: -5, y: -5)) == nil)
    }

    @Test func respectsDepthAndCellLimits() {
        var options = TreemapOptions()
        options.maximumDepth = 1
        #expect(Treemap.layout(root: "root", in: bounds, options: options) { tree[$0] ?? [] }.count == 3)

        options = TreemapOptions()
        options.maximumCells = 2
        #expect(Treemap.layout(root: "root", in: bounds, options: options) { tree[$0] ?? [] }.count == 2)
    }

    @Test func dropsCellsBelowTheMinimumSide() {
        let many = (0..<10_000).map { (id: "n\($0)", weight: 1.0) }
        let cells = Treemap.layout(root: "root", in: CGRect(x: 0, y: 0, width: 100, height: 100)) { $0 == "root" ? many : [] }
        #expect(cells.allSatisfy { $0.rect.width >= 4 && $0.rect.height >= 4 })
        #expect(cells.count < 1_000)
    }

    @Test func layoutOfAHugeFlatHierarchyIsFast() {
        // 200 000 children must not explode: squarify is O(n log n) and cells are capped.
        let many = (0..<200_000).map { (id: $0 + 1, weight: Double(200_001 - $0)) }
        let start = ContinuousClock.now
        let cells = Treemap.layout(root: 0, in: CGRect(x: 0, y: 0, width: 1600, height: 1000)) { $0 == 0 ? many : [] }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(cells.count <= TreemapOptions().maximumCells)
    }
}

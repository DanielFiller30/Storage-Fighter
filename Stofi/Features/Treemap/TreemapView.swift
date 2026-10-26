import AppKit
import CleanupKit
import LayoutKit
import ScannerKit
import os
import SwiftUI

/// Element of the treemap: a node of the tree, or the files of a directory that have no node of their own.
nonisolated enum TreemapKey: Hashable, Sendable {
    case node(NodeID)
    case looseFiles(of: NodeID)
}

struct TreemapScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree {
            TreemapContainer(tree: tree, rootName: model.targetName, startupVolume: model.startupVolume)
                // A new scan result starts at the root again.
                .id(tree.nodeCount ^ Int(tree.allocatedSize(of: tree.root) & 0xFFFF_FFFF))
        } else {
            ContentUnavailableView(
                "Storage Map",
                systemImage: "square.grid.3x3.square",
                description: Text(model.isScanning
                                  ? "The map appears as soon as the scan has finished."
                                  : "Start a scan to see your disk as a map: the larger the area, the more space.")
            )
        }
    }
}

private struct TreemapContainer: View {
    let tree: FileTree
    let rootName: String
    let startupVolume: StartupVolume

    @State private var focus: NodeID
    @State private var cells: [TreemapCell<TreemapKey>] = []
    @State private var canvasSize: CGSize = .zero
    @State private var hoverIndex: Int?
    @State private var hoverLocation: CGPoint = .zero
    @State private var selectedIndex: Int?
    @State private var generation = 0
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(tree: FileTree, rootName: String, startupVolume: StartupVolume) {
        self.tree = tree
        self.rootName = rootName
        self.startupVolume = startupVolume
        _focus = State(initialValue: tree.root)
    }

    private struct LayoutRequest: Equatable {
        let focus: NodeID
        let size: CGSize
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(tree: tree, focus: focus, rootName: rootName) { navigate(to: $0) }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            GeometryReader { geometry in
                canvas
                    .onAppear { canvasSize = geometry.size }
                    .onChange(of: geometry.size) { _, newSize in canvasSize = newSize }
            }
            .padding([.horizontal, .bottom], 16)
        }
        .task(id: LayoutRequest(focus: focus, size: canvasSize)) {
            await recomputeLayout()
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        Canvas { context, _ in
            let palette = TreemapPalette(colorScheme: colorScheme)
            for cell in cells {
                context.fill(Path(cell.rect), with: .color(palette.fill(for: cell)))
                if cell.hasChildren || cell.depth == 1 {
                    context.stroke(Path(cell.rect), with: .color(palette.border), lineWidth: 0.5)
                }
            }
            for cell in cells where cell.rect.width >= 64 && cell.rect.height >= 18 {
                let label = Text(label(for: cell.id))
                    .font(.system(size: 11, weight: cell.hasChildren ? .semibold : .regular))
                    .foregroundStyle(palette.text)
                let labelRect = CGRect(x: cell.rect.minX + 4, y: cell.rect.minY + 2,
                                       width: cell.rect.width - 8, height: 14)
                context.draw(context.resolve(label), in: labelRect)
            }
            if let selectedIndex, cells.indices.contains(selectedIndex) {
                context.stroke(Path(cells[selectedIndex].rect.insetBy(dx: 1, dy: 1)),
                               with: .color(.accentColor), lineWidth: 3)
            }
            if let hoverIndex, cells.indices.contains(hoverIndex) {
                context.stroke(Path(cells[hoverIndex].rect.insetBy(dx: 0.5, dy: 0.5)),
                               with: .color(palette.highlight), lineWidth: 2)
            }
        }
        .id(generation)
        .transition(.opacity)
        .clipShape(.rect(cornerRadius: 10))
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                hoverIndex = cells.innermostCellIndex(at: location)
            case .ended:
                hoverIndex = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            isFocused = true
            if let index = cells.innermostCellIndex(at: value.location) { drillDown(from: index) }
        })
        .overlay(alignment: .topLeading) { hoverOverlay }
        .contextMenu {
            if let index = hoverIndex ?? selectedIndex, case .node(let node) = cells[index].id {
                Button("Show in Finder", systemImage: "folder") { showInFinder(node) }
                AddToSelectionButton(candidates: [.freelyChosen(path: tree.displayPath(of: node, startupVolume: startupVolume),
                                                                size: tree.allocatedSize(of: node))])
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if press.key == .upArrow && press.modifiers.contains(.command) {
                goUp()
            } else {
                moveSelection(press.key)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if let selectedIndex { drillDown(from: selectedIndex) }
            return .handled
        }
        .onKeyPress(.escape) {
            goUp()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage map of \(label(for: .node(focus)))")
        .accessibilityChildren {
            ForEach(topLevelIndices.prefix(60), id: \.self) { index in
                let cell = cells[index]
                Rectangle()
                    .accessibilityLabel(label(for: cell.id))
                    .accessibilityValue(size(of: cell.id).formattedBytes)
                    .accessibilityAddTraits(isDrillable(cell.id) ? .isButton : [])
                    .accessibilityAction { drillDown(from: index) }
            }
        }
    }

    @ViewBuilder
    private var hoverOverlay: some View {
        if let hoverIndex, cells.indices.contains(hoverIndex) {
            let key = cells[hoverIndex].id
            VStack(alignment: .leading, spacing: 3) {
                Text(label(for: key)).font(.headline).lineLimit(1)
                Text(path(of: key))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detail(for: key)).font(.callout).monospacedDigit()
            }
            .padding(10)
            .frame(maxWidth: 360, alignment: .leading)
            .stofiGlass(cornerRadius: 12)
            .offset(overlayOffset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var overlayOffset: CGSize {
        // Keep the overlay next to the cursor but inside the canvas.
        let width: CGFloat = 360, height: CGFloat = 90
        let x = hoverLocation.x + 16 + width > canvasSize.width ? max(0, hoverLocation.x - width - 16) : hoverLocation.x + 16
        let y = hoverLocation.y + 16 + height > canvasSize.height ? max(0, hoverLocation.y - height - 8) : hoverLocation.y + 16
        return CGSize(width: x, height: y)
    }

    // MARK: Layout

    private static let logger = Logger(subsystem: "de.df.Stofi", category: "Treemap")

    private func recomputeLayout() async {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            Self.logger.debug("Layout skipped, canvas size \(canvasSize.width)×\(canvasSize.height)")
            return
        }
        // Debounce window resizing.
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        let tree = tree, focus = focus, size = canvasSize
        let newCells = await Task.detached(priority: .userInitiated) {
            Self.layout(tree: tree, focus: focus, size: size)
        }.value
        guard !Task.isCancelled else { return }
        Self.logger.notice("Layout: \(newCells.count) cells for \(size.width)×\(size.height), focus \(focus)")
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            cells = newCells
            generation += 1
        }
        hoverIndex = nil
        selectedIndex = nil
    }

    nonisolated private static func layout(tree: FileTree, focus: NodeID, size: CGSize) -> [TreemapCell<TreemapKey>] {
        Treemap.layout(root: .node(focus), in: CGRect(origin: .zero, size: size)) { key in
            guard case .node(let id) = key, tree.isDirectory(id) else { return [] }
            var items: [(id: TreemapKey, weight: Double)] = []
            for child in tree.children(of: id) {
                let bytes = tree.allocatedSize(of: child)
                if bytes > 0 { items.append((.node(child), Double(bytes))) }
            }
            let loose = tree.directFileBytes(of: id)
            if loose > 0 { items.append((.looseFiles(of: id), Double(loose))) }
            return items
        }
    }

    // MARK: Navigation

    private var topLevelIndices: [Int] {
        cells.indices.filter { cells[$0].depth == 1 }
    }

    private func isDrillable(_ key: TreemapKey) -> Bool {
        if case .node(let node) = key { return tree.isDirectory(node) && tree.children(of: node).first(where: { _ in true }) != nil }
        return false
    }

    /// Opens the innermost directory at the clicked cell; a file opens its directory.
    private func drillDown(from index: Int) {
        var current: Int? = index
        while let candidate = current {
            if isDrillable(cells[candidate].id), case .node(let node) = cells[candidate].id {
                navigate(to: node)
                return
            }
            current = cells[candidate].parentIndex
        }
        selectedIndex = index
    }

    private func navigate(to node: NodeID) {
        guard node != focus else { return }
        focus = node
    }

    private func goUp() {
        if let parent = tree.parent(of: focus) { focus = parent }
    }

    private func moveSelection(_ key: KeyEquivalent) {
        let candidates = topLevelIndices
        guard !candidates.isEmpty else { return }
        guard let current = selectedIndex, candidates.contains(current) else {
            selectedIndex = candidates.first
            return
        }
        let origin = CGPoint(x: cells[current].rect.midX, y: cells[current].rect.midY)
        let best = candidates.filter { $0 != current }.compactMap { index -> (Int, CGFloat)? in
            let center = CGPoint(x: cells[index].rect.midX, y: cells[index].rect.midY)
            let dx = center.x - origin.x, dy = center.y - origin.y
            let inDirection = switch key {
            case .leftArrow: dx < -1 && abs(dy) <= abs(dx) * 2
            case .rightArrow: dx > 1 && abs(dy) <= abs(dx) * 2
            case .upArrow: dy < -1 && abs(dx) <= abs(dy) * 2
            default: dy > 1 && abs(dx) <= abs(dy) * 2
            }
            return inDirection ? (index, dx * dx + dy * dy) : nil
        }.min { $0.1 < $1.1 }
        if let best { selectedIndex = best.0 }
    }

    private func showInFinder(_ node: NodeID) {
        let url = URL(fileURLWithPath: tree.displayPath(of: node, startupVolume: startupVolume))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Labels

    private func label(for key: TreemapKey) -> String {
        switch key {
        case .node(let node): node == tree.root ? rootName : tree.name(of: node)
        case .looseFiles: String(localized: "Other files")
        }
    }

    private func path(of key: TreemapKey) -> String {
        switch key {
        case .node(let node): tree.displayPath(of: node, startupVolume: startupVolume)
        case .looseFiles(let node): tree.displayPath(of: node, startupVolume: startupVolume)
        }
    }

    private func size(of key: TreemapKey) -> UInt64 {
        switch key {
        case .node(let node): tree.allocatedSize(of: node)
        case .looseFiles(let node): tree.directFileBytes(of: node)
        }
    }

    private func detail(for key: TreemapKey) -> String {
        let bytes = size(of: key).formattedBytes
        switch key {
        case .node(let node) where tree.isDirectory(node):
            return String(localized: "\(bytes) · \(Int(tree.fileCount(of: node)).formattedCount) files")
        case .node:
            return bytes
        case .looseFiles:
            return String(localized: "\(bytes) · files smaller than 1 MB in this folder")
        }
    }
}

private struct BreadcrumbBar: View {
    let tree: FileTree
    let focus: NodeID
    let rootName: String
    let navigate: (NodeID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let parent = tree.parent(of: focus) { navigate(parent) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(tree.parent(of: focus) == nil)
            .help("Up one level (⌘↑ or Esc)")
            .accessibilityLabel("Up one level")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(chain.enumerated()), id: \.element) { position, node in
                        if position > 0 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button(node == tree.root ? rootName : tree.name(of: node)) { navigate(node) }
                            .buttonStyle(.borderless)
                            .fontWeight(node == focus ? .semibold : .regular)
                            .disabled(node == focus)
                    }
                }
            }
            Spacer()
            Text(tree.allocatedSize(of: focus).formattedBytes)
                .font(.callout.bold())
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .stofiGlass(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private var chain: [NodeID] {
        var nodes: [NodeID] = [focus]
        while let parent = tree.parent(of: nodes[nodes.count - 1]) { nodes.append(parent) }
        return nodes.reversed()
    }
}

/// Colours per top-level branch, darker with depth. Labels carry the information; colour only groups.
private struct TreemapPalette {
    let colorScheme: ColorScheme
    private static let hues: [Double] = [0.58, 0.08, 0.36, 0.76, 0.0, 0.5, 0.14, 0.88, 0.44, 0.66]

    var isDark: Bool { colorScheme == .dark }
    var border: Color { isDark ? .black.opacity(0.45) : .black.opacity(0.18) }
    var text: Color { isDark ? .white.opacity(0.92) : .black.opacity(0.82) }
    var highlight: Color { isDark ? .white : .black }

    func fill(for cell: TreemapCell<TreemapKey>) -> Color {
        let hue = Self.hues[cell.branch % Self.hues.count]
        let depth = Double(min(cell.depth, 8))
        if case .looseFiles = cell.id {
            return Color(hue: hue, saturation: 0.08, brightness: isDark ? 0.38 : 0.86)
        }
        return Color(hue: hue,
                     saturation: max(0.2, 0.5 - depth * 0.03),
                     brightness: isDark ? max(0.25, 0.62 - depth * 0.05) : max(0.55, 0.94 - depth * 0.05))
    }
}

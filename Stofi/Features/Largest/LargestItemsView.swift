import AppKit
import CleanupKit
import CoreServices
import ScannerKit
import SwiftUI

struct LargestItemsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree {
            LargestItemsTable(tree: tree, startupVolume: model.startupVolume)
                .id(tree.nodeCount ^ Int(tree.allocatedSize(of: tree.root) & 0xFFFF_FFFF))
        } else {
            ContentUnavailableView(
                "Largest Items",
                systemImage: "list.number",
                description: Text(model.isScanning
                                  ? "The list appears as soon as the scan has finished."
                                  : "Start a scan to list the largest files and folders.")
            )
        }
    }
}

nonisolated struct LargestItemRow: Identifiable, Hashable, Sendable {
    let item: LargestItem
    var lastOpened: Date?

    var id: NodeID { item.id }
    var name: String { item.name }
    var path: String { item.path }
    var size: UInt64 { item.allocatedSize }
    var modified: Date { item.modificationDate }
    /// Items never opened (or unknown to Spotlight) sort as oldest.
    var lastOpenedSortKey: Date { lastOpened ?? .distantPast }
}

private enum SizeFilter: String, CaseIterable, Identifiable {
    case all, over100MB, over1GB
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "Any size"
        case .over100MB: "Larger than 100 MB"
        case .over1GB: "Larger than 1 GB"
        }
    }

    var minimum: UInt64 {
        switch self {
        case .all: 0
        case .over100MB: 100_000_000
        case .over1GB: 1_000_000_000
        }
    }
}

private struct LargestItemsTable: View {
    let tree: FileTree
    let startupVolume: StartupVolume
    nonisolated static let limit = 5_000

    @State private var kind: FileTree.ItemKind = .files
    @State private var rows: [LargestItemRow] = []
    @State private var isLoading = true
    @State private var isLoadingLastOpened = false
    @State private var search = ""
    @State private var sizeFilter: SizeFilter = .all
    @State private var olderThanOneYear = false
    @State private var sortOrder = [KeyPathComparator(\LargestItemRow.size, order: .reverse)]
    @State private var selection = Set<NodeID>()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    Label(row.name, systemImage: row.item.isDirectory ? "folder" : "doc")
                        .help(row.path)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Size", value: \.size) { row in
                    Text(row.size.formattedBytes).monospacedDigit()
                }
                .width(min: 80, ideal: 100)
                TableColumn("Modified", value: \.modified) { row in
                    Text(row.modified, format: .dateTime.day().month().year())
                }
                .width(min: 90, ideal: 110)
                TableColumn("Last Opened", value: \.lastOpenedSortKey) { row in
                    if let date = row.lastOpened {
                        Text(date, format: .dateTime.day().month().year())
                    } else {
                        Text(isLoadingLastOpened ? "…" : "–")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(isLoadingLastOpened ? "Loading" : "Unknown")
                    }
                }
                .width(min: 90, ideal: 110)
                TableColumn("Path", value: \.path) { row in
                    Text(row.path)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: NodeID.self) { ids in
                Button("Show in Finder", systemImage: "folder") { showInFinder(ids) }
                    .disabled(ids.isEmpty)
                AddToSelectionButton(candidates: rows.filter { ids.contains($0.id) }
                    .map { CleanupCandidate.freelyChosen(path: $0.path, size: $0.size) })
            } primaryAction: { ids in
                showInFinder(ids)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if visibleRows.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name or path")
        .task(id: kind) { await load() }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $kind) {
                Text("Files").tag(FileTree.ItemKind.files)
                Text("Folders").tag(FileTree.ItemKind.directories)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Size", selection: $sizeFilter) {
                ForEach(SizeFilter.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Toggle("Older than 1 year", isOn: $olderThanOneYear)
                .toggleStyle(.checkbox)
                .help("Last modified more than a year ago")

            Spacer()
            Text("\(visibleRows.count.formattedCount) of \(rows.count.formattedCount)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .stofiGlass(cornerRadius: 12)
    }

    private var visibleRows: [LargestItemRow] {
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows
            .filter { row in
                row.size >= sizeFilter.minimum
                    && (!olderThanOneYear || row.modified < cutoff)
                    && (query.isEmpty || row.name.localizedStandardContains(query) || row.path.localizedStandardContains(query))
            }
            .sorted(using: sortOrder)
    }

    private func load() async {
        isLoading = true
        selection = []
        let tree = tree, kind = kind, volume = startupVolume
        let items = await Task.detached(priority: .userInitiated) {
            tree.largestItems(kind, limit: Self.limit, startupVolume: volume)
        }.value
        guard !Task.isCancelled else { return }
        rows = items.map { LargestItemRow(item: $0) }
        isLoading = false

        // “Last opened” comes from Spotlight and costs a lookup per item, so it is loaded afterwards in batches.
        isLoadingLastOpened = true
        defer { isLoadingLastOpened = false }
        let paths = items.map { ($0.id, $0.path) }
        for batch in stride(from: 0, to: paths.count, by: 250).map({ Array(paths[$0..<min($0 + 250, paths.count)]) }) {
            let dates = await Task.detached(priority: .utility) { Self.lastOpenedDates(batch) }.value
            guard !Task.isCancelled else { return }
            for index in rows.indices {
                if let date = dates[rows[index].id] { rows[index].lastOpened = date }
            }
        }
    }

    nonisolated private static func lastOpenedDates(_ items: [(NodeID, String)]) -> [NodeID: Date] {
        var result: [NodeID: Date] = [:]
        for (id, path) in items {
            guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            result[id] = date
        }
        return result
    }

    private func showInFinder(_ ids: Set<NodeID>) {
        let urls = rows.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

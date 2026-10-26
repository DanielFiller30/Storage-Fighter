import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, treemap, largest, recommendations, selection, jobs, log

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .treemap: "Storage Map"
        case .largest: "Largest Items"
        case .recommendations: "Recommendations"
        case .selection: "Selection"
        case .jobs: "Scheduled"
        case .log: "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.pie"
        case .treemap: "square.grid.3x3.square"
        case .largest: "list.number"
        case .recommendations: "sparkles"
        case .selection: "cart"
        case .jobs: "calendar.badge.clock"
        case .log: "list.bullet.rectangle"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = Self.initialSelection

    private static var initialSelection: SidebarItem {
        #if DEBUG
        // Test hook: `-StofiInitialSection treemap` opens that section on launch.
        if let raw = UserDefaults.standard.string(forKey: "StofiInitialSection"), let item = SidebarItem(rawValue: raw) {
            return item
        }
        #endif
        return .overview
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Analysis") {
                    ForEach([SidebarItem.overview, .treemap, .largest]) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section("Clean Up") {
                    ForEach([SidebarItem.recommendations, .selection, .jobs, .log]) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .badge(badge(for: item))
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SettingsButton() }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // An inset, not a VStack sibling: the banner must never define the height of the content.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.fullDiskAccess == .denied {
                        FullDiskAccessBanner()
                            .padding([.horizontal, .top], 16)
                    }
                }
            .navigationTitle(selection?.title ?? "Stofi")
            .navigationSubtitle(model.targetName)
        }
        .toolbar { ScanToolbar() }
        .background(OpenWindowRegistrar())
        .sheet(isPresented: Bindable(model.profiles).isOnboardingPresented) { OnboardingView() }
        .onChange(of: model.requestedSection) { _, section in
            if let section {
                selection = section
                model.requestedSection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have just granted Full Disk Access in System Settings.
            model.refreshEnvironment()
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .selection: model.cleanup.basket.count
        case .jobs: model.jobs.ready.count
        default: 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .treemap: TreemapScreen()
        case .largest: LargestItemsScreen()
        case .recommendations: RecommendationsView()
        case .selection: SelectionView()
        case .jobs: JobsView()
        case .log: CleanupLogView()
        }
    }
}

struct ScanToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Startup Disk", systemImage: "internaldrive") { model.select(.startupVolume) }
                Button("Choose Folder…", systemImage: "folder") { model.chooseFolder() }
            } label: {
                Label(model.targetName, systemImage: model.target == .startupVolume ? "internaldrive" : "folder")
            }
            .disabled(model.isScanning)
            .help("Choose what to scan")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Quickscan", systemImage: "bolt") {
                if model.profiles.selected.isEmpty {
                    model.profiles.isOnboardingPresented = true
                } else {
                    model.quickscan()
                }
            }
            .disabled(model.isScanning || model.analysis.isAnalyzing)
            .help(model.profiles.selected.isEmpty
                  ? "Choose your activities for a quickscan"
                  : "Check the typical space hogs of your activities within seconds")

            if model.isScanning {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.phase == .paused ? "Resume" : "Pause",
                          systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                }
                .help(model.phase == .paused ? "Resume the scan" : "Pause the scan")

                Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                    .help("Stop the scan")
            } else {
                Button(model.tree == nil ? "Scan" : "Scan Again", systemImage: "arrow.clockwise") {
                    model.startScan()
                }
                .help("Analyse the selected disk or folder (read-only)")
            }
        }
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is missing")
                    .font(.headline)
                Text("""
                    Without it, macOS hides some folders (for example Mail, Safari and other apps' data) from Stofi, \
                    so their size cannot be measured. Stofi only reads; it never changes files without asking.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                .help("Privacy & Security → Full Disk Access. Enable Stofi there, then return to the app.")
        }
        .padding(14)
        .stofiGlass(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }
}


/// Lets the app delegate reopen the main window (Dock click, notification).
private struct OpenWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear {
            AppDelegate.openMainWindow = { openWindow(id: StofiApp.mainWindowID) }
            #if DEBUG
            // Test hook: `-StofiOpenSettings YES` opens the settings window on launch.
            if UserDefaults.standard.bool(forKey: "StofiOpenSettings") { openSettings() }
            #endif
        }
    }
}

/// Visible entry to the settings (besides Stofi → Settings… and ⌘,).
private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("Settings (⌘,)")
    }
}

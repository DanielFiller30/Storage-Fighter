import AnalysisKit
import AppKit
import ScannerKit
import SwiftUI

@main
struct StofiApp: App {
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A single main window; closing it keeps the app (and the menu bar item) running.
        Window("Stofi", id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    model.refreshEnvironment()
                    #if DEBUG
                    // Test hook: `-StofiQuickscanProfiles gaming,aiData` runs a quickscan with these profiles.
                    if let ids = UserDefaults.standard.string(forKey: "StofiQuickscanProfiles") {
                        model.profiles.useTemporarily(Set(ids.split(separator: ",").map(String.init)))
                        model.quickscan()
                        let start = ContinuousClock.now
                        while model.analysis.isAnalyzing { try? await Task.sleep(for: .milliseconds(100)) }
                        debugReport("quickscan \(ids) in \(ContinuousClock.now - start): "
                                    + model.analysis.recommendations.map { "\($0.id)=\($0.totalSize)" }.joined(separator: ", "))
                    }
                    // Test hook: `-StofiAutoScanPath <folder>` starts a scan of that folder on launch.
                    if let path = UserDefaults.standard.string(forKey: "StofiAutoScanPath") {
                        model.select(.folder(URL(fileURLWithPath: path)))
                        model.startScan()
                        while model.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
                        if let tree = model.tree {
                            let top = tree.largestItems(.files, limit: 3, startupVolume: model.startupVolume)
                            debugReport("scan finished: \(tree.statistics.regularFiles) files, \(tree.nodeCount) nodes, "
                                        + "\(tree.statistics.allocatedBytes) bytes; largest: \(top.map(\.path))")
                        } else {
                            debugReport("scan ended without result: \(model.phase)")
                        }
                        // `-StofiAutoDuplicates YES` also runs the duplicate search.
                        if UserDefaults.standard.bool(forKey: "StofiAutoDuplicates") {
                            model.findDuplicates()
                            while case .searching = model.analysis.duplicates { try? await Task.sleep(for: .milliseconds(200)) }
                            if case .finished(let groups) = model.analysis.duplicates {
                                debugReport("duplicates: \(groups.count) groups, reclaimable \(groups.reduce(0) { $0 + $1.reclaimableSize }) bytes")
                            }
                        }
                    }
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Stofi") {
                    // The full name appears here; everywhere else the app is called Stofi.
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Stofi – Storage Fighter",
                        .credits: NSAttributedString(string: String(localized: "Shows where your disk space goes and helps you free it safely. No telemetry, no network access.")),
                    ])
                }
            }
            CommandMenu("Scan") {
                Button(model.tree == nil ? "Start Scan" : "Scan Again", systemImage: "arrow.clockwise") {
                    model.startScan()
                }
                .keyboardShortcut("r")
                .disabled(model.isScanning)

                Button(model.phase == .paused ? "Resume Scan" : "Pause Scan",
                       systemImage: model.phase == .paused ? "play.fill" : "pause.fill") {
                    model.togglePause()
                }
                // ⌘P is reserved for printing on macOS, hence ⇧⌘P.
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isScanning)

                Button("Stop Scan", systemImage: "stop.fill") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)

                Divider()

                Button("Choose Folder…", systemImage: "folder") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isScanning)

                Divider()

                Button("Quickscan", systemImage: "bolt") { model.quickscan() }
                    .keyboardShortcut("k")
                    .disabled(model.isScanning || model.profiles.selected.isEmpty)
                Button("Change Activities…", systemImage: "person.crop.circle.badge.questionmark") {
                    model.profiles.isOnboardingPresented = true
                }
            }
        }
        // Always show the main window at launch, even if it was closed when the app was last quit;
        // otherwise state restoration starts Stofi without any window (the app keeps running when the
        // window is closed, so “closed” is a state that gets restored).
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        // Optional, off by default. While not inserted, its label (and thus the monitoring task) does not exist.
        MenuBarExtra(isInserted: Bindable(model.settings).showsMenuBarExtra) {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

#if DEBUG
/// Unbuffered output for the launch-argument test hook (stdout is block-buffered when piped).
private func debugReport(_ message: String) {
    FileHandle.standardError.write(Data("[Stofi] \(message)\n".utf8))
}
#endif

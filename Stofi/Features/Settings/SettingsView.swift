import AnalysisKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Menu Bar", systemImage: "menubar.rectangle") { MenuBarSettings() }
            Tab("Analysis", systemImage: "slider.horizontal.3") { AnalysisSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loginItem = model.loginItem
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.requiresApproval {
                    Text("macOS asks for approval in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = loginItem.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Stofi keeps running when you close its window, so the menu bar item stays available. Quit it with ⌘Q.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

private struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarExtra)
                Toggle("Show available space next to the symbol", isOn: $settings.showsFreeSpaceInMenuBar)
                    .disabled(!settings.showsMenuBarExtra)
                Picker("Update every", selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .disabled(!settings.showsMenuBarExtra)
            } footer: {
                Text("The menu bar only reads the disk's capacity, never scans, and updates when disks are connected or ejected. When it is off, nothing runs for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $settings.lowPercent, in: max(settings.criticalPercent + 1, 2)...50, step: 1) {
                    Text("Low below \(Int(settings.lowPercent)) % available")
                }
                Stepper(value: $settings.criticalPercent, in: 1...max(1, settings.lowPercent - 1), step: 1) {
                    Text("Critical below \(Int(settings.criticalPercent)) % available")
                }
                Toggle("Notify when space gets low", isOn: Binding(
                    get: { settings.notifiesWhenLow },
                    set: { enabled in
                        settings.notifiesWhenLow = enabled
                        if enabled { Task { if await !MenuBarStatus.requestNotificationPermission() { settings.notifiesWhenLow = false } } }
                    }))
                    .disabled(!settings.showsMenuBarExtra)
            } header: {
                Text("Status")
            } footer: {
                Text("Notifications only inform and open Stofi; they never remove anything. They are checked together with the menu bar status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AnalysisSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let profiles = model.profiles
        Form {
            Section("Activities for the quickscan") {
                ForEach(profiles.available) { profile in
                    Toggle(isOn: Binding(
                        get: { profiles.selectedIDs.contains(profile.id) },
                        set: { isOn in
                            var ids = profiles.selectedIDs
                            if isOn { ids.insert(profile.id) } else { ids.remove(profile.id) }
                            profiles.save(ids)
                        })) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(verbatim: profile.title.resolved())
                                Text(verbatim: profile.summary.resolved()).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: profile.symbol)
                        }
                    }
                }
            }
            Section {
                Stepper(value: $settings.largeDownloadMB, in: 10...10_000, step: 10) {
                    Text("Downloads larger than \(settings.largeDownloadMB) MB")
                }
                Stepper(value: $settings.oldDownloadDays, in: 30...3_650, step: 30) {
                    Text("Downloads older than \(settings.oldDownloadDays) days")
                }
                Stepper(value: $settings.largeMediaMB, in: 50...50_000, step: 50) {
                    Text("Media files from \(settings.largeMediaMB) MB")
                }
                Stepper(value: $settings.inactiveProjectDays, in: 7...3_650, step: 7) {
                    Text("Projects inactive after \(settings.inactiveProjectDays) days")
                }
                Button("Restore Defaults") { settings.resetAnalysisThresholds() }
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Used by the next analysis.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Full Disk Access") {
                LabeledContent("Status") {
                    switch model.fullDiskAccess {
                    case .granted: Label("Granted", systemImage: "checkmark.shield").foregroundStyle(.green)
                    case .denied: Label("Not granted", systemImage: "xmark.shield").foregroundStyle(.orange)
                    case .unknown: Label("Unknown", systemImage: "questionmark.diamond").foregroundStyle(.secondary)
                    }
                }
                Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                Text("Needed to measure folders macOS protects, such as Mail, Messages and other apps' data. Stofi only reads them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your data") {
                Label("No telemetry and no network access. All results stay on this Mac.", systemImage: "network.slash")
                Label("Nothing is removed without your confirmation; the default is the Trash.", systemImage: "trash")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshEnvironment() }
    }
}

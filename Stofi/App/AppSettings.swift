import AnalysisKit
import Foundation
import Observation
import os
import ServiceManagement

/// User preferences, stored in UserDefaults. Defaults follow the specification: everything optional is off.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    // MARK: Menu bar

    /// Menu bar status item (default off). While off, no timers or observers run for it.
    var showsMenuBarExtra: Bool { didSet { defaults.set(showsMenuBarExtra, forKey: Keys.menuBar) } }
    /// Free space as a number next to the menu bar symbol.
    var showsFreeSpaceInMenuBar: Bool { didSet { defaults.set(showsFreeSpaceInMenuBar, forKey: Keys.menuBarNumber) } }
    /// Notification when space gets low (default off). Only informs and opens the app; never acts.
    var notifiesWhenLow: Bool { didSet { defaults.set(notifiesWhenLow, forKey: Keys.notifications) } }
    /// Refresh interval of the menu bar status in minutes (1, 5 or 15).
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh) } }
    /// Below this share of usable space the status is “low”.
    var lowPercent: Double { didSet { defaults.set(lowPercent, forKey: Keys.low) } }
    /// Below this share of usable space the status is “critical”.
    var criticalPercent: Double { didSet { defaults.set(criticalPercent, forKey: Keys.critical) } }

    // MARK: Analysis thresholds

    var largeDownloadMB: Int { didSet { defaults.set(largeDownloadMB, forKey: Keys.largeDownload) } }
    var oldDownloadDays: Int { didSet { defaults.set(oldDownloadDays, forKey: Keys.oldDownload) } }
    var largeMediaMB: Int { didSet { defaults.set(largeMediaMB, forKey: Keys.largeMedia) } }
    var inactiveProjectDays: Int { didSet { defaults.set(inactiveProjectDays, forKey: Keys.inactiveProject) } }

    static let refreshChoices = [1, 5, 15]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let analysis = AnalysisThresholds()
        defaults.register(defaults: [
            Keys.menuBar: false, Keys.menuBarNumber: false, Keys.notifications: false, Keys.refresh: 5,
            Keys.low: 15.0, Keys.critical: 5.0,
            Keys.largeDownload: Int(analysis.largeDownload / 1_000_000),
            Keys.oldDownload: Int(analysis.oldDownload / 86_400),
            Keys.largeMedia: Int(analysis.largeMedia / 1_000_000),
            Keys.inactiveProject: Int(analysis.inactiveProject / 86_400),
        ])
        showsMenuBarExtra = defaults.bool(forKey: Keys.menuBar)
        showsFreeSpaceInMenuBar = defaults.bool(forKey: Keys.menuBarNumber)
        notifiesWhenLow = defaults.bool(forKey: Keys.notifications)
        refreshMinutes = Self.refreshChoices.contains(defaults.integer(forKey: Keys.refresh)) ? defaults.integer(forKey: Keys.refresh) : 5
        lowPercent = defaults.double(forKey: Keys.low)
        criticalPercent = defaults.double(forKey: Keys.critical)
        largeDownloadMB = defaults.integer(forKey: Keys.largeDownload)
        oldDownloadDays = defaults.integer(forKey: Keys.oldDownload)
        largeMediaMB = defaults.integer(forKey: Keys.largeMedia)
        inactiveProjectDays = defaults.integer(forKey: Keys.inactiveProject)
    }

    var analysisThresholds: AnalysisThresholds {
        var thresholds = AnalysisThresholds()
        thresholds.largeDownload = UInt64(max(1, largeDownloadMB)) * 1_000_000
        thresholds.oldDownload = TimeInterval(max(1, oldDownloadDays)) * 86_400
        thresholds.largeMedia = UInt64(max(1, largeMediaMB)) * 1_000_000
        thresholds.inactiveProject = TimeInterval(max(1, inactiveProjectDays)) * 86_400
        return thresholds
    }

    func resetAnalysisThresholds() {
        let analysis = AnalysisThresholds()
        largeDownloadMB = Int(analysis.largeDownload / 1_000_000)
        oldDownloadDays = Int(analysis.oldDownload / 86_400)
        largeMediaMB = Int(analysis.largeMedia / 1_000_000)
        inactiveProjectDays = Int(analysis.inactiveProject / 86_400)
    }

    private enum Keys {
        static let menuBar = "showsMenuBarExtra"
        static let menuBarNumber = "showsFreeSpaceInMenuBar"
        static let notifications = "notifiesWhenLow"
        static let refresh = "menuBarRefreshMinutes"
        static let low = "lowSpacePercent"
        static let critical = "criticalSpacePercent"
        static let largeDownload = "largeDownloadMB"
        static let oldDownload = "oldDownloadDays"
        static let largeMedia = "largeMediaMB"
        static let inactiveProject = "inactiveProjectDays"
    }
}

/// “Open at login” through `SMAppService` (default off). The state lives in the system, not in UserDefaults.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?
    private let logger = Logger(subsystem: "de.df.Stofi", category: "LoginItem")

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            // Typically for unsigned development builds; shown in the settings instead of failing silently.
            lastError = error.localizedDescription
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}

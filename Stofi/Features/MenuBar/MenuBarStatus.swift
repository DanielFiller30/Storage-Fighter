import AppKit
import Observation
import os
import ScannerKit
import UserNotifications

/// Capacity of the startup disk for the menu bar. Reads only the cheap volume capacities, never scans.
///
/// The monitoring runs inside ``monitor(settings:)``, which the menu bar label starts with
/// `.task(id:)` only while the setting is on. Switching it off cancels the task; no timer or observer remains.
@Observable
final class MenuBarStatus {
    private(set) var volume: VolumeInfo?
    private(set) var level: CapacityLevel = .normal
    private(set) var updated: Date?
    private var notifiedLevel: CapacityLevel = .normal
    private let logger = Logger(subsystem: "de.df.Stofi", category: "MenuBar")

    func monitor(settings: AppSettings) async {
        logger.notice("Menu bar monitoring started")
        defer { logger.notice("Menu bar monitoring stopped") }
        refresh(settings: settings)

        // Mount and unmount events trigger an update instead of polling more often. Both observers end
        // with this task (menu bar item switched off).
        let observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            Task { [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) {
                    self?.refresh(settings: settings)
                }
            }
        }
        defer { observers.forEach { $0.cancel() } }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60 * max(1, settings.refreshMinutes)))
            guard !Task.isCancelled else { break }
            refresh(settings: settings)
        }
    }

    func refresh(settings: AppSettings) {
        do {
            let info = try VolumeInfo.read(for: URL(fileURLWithPath: "/"))
            volume = info
            updated = .now
            let newLevel = info.level(lowPercent: settings.lowPercent, criticalPercent: settings.criticalPercent)
            level = newLevel
            notifyIfNeeded(info: info, level: newLevel, settings: settings)
        } catch {
            logger.error("Reading capacity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One notification per change to a worse level; it only informs and opens the app.
    private func notifyIfNeeded(info: VolumeInfo, level: CapacityLevel, settings: AppSettings) {
        defer { notifiedLevel = level }
        guard settings.notifiesWhenLow, level > notifiedLevel, level != .normal else { return }
        let content = UNMutableNotificationContent()
        content.title = level == .critical
            ? String(localized: "Startup disk almost full")
            : String(localized: "Startup disk space is getting low")
        content.body = String(localized: "\(info.usableBytes.formattedBytes) available on \(info.name). Open Stofi to see what takes up space.")
        let request = UNNotificationRequest(identifier: "lowSpace", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Asks for permission when the user turns notifications on. Returns whether they are allowed.
    static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }
}

import AppKit
import UserNotifications

/// App-level behaviour SwiftUI scenes do not cover: keep running when the window is closed (Dock icon
/// stays, decision for M6) and open the main window from a notification.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by a scene that has access to `openWindow`.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon without an open window brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMainWindow?() }
        return true
    }

    /// A click on the low-space notification only opens the app; it never triggers an action.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            Self.openMainWindow?()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

import AppKit
import Darwin

/// Detects whether the app has Full Disk Access (TCC "SystemPolicyAllFiles").
///
/// There is no public API for this. The usual approach is used: try to open files that only processes
/// with Full Disk Access may read. Opening is read-only and the file contents are never read.
/// Without access the kernel answers `EPERM` immediately, without showing a prompt.
enum FullDiskAccess {
    enum Status: Equatable {
        case granted, denied, unknown
    }

    static func check() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
        ]
        for probe in probes {
            let fd = open(probe, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .denied }
            // ENOENT and others: inconclusive, try the next probe.
        }
        return .unknown
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

import Darwin
import Foundation

/// A running app as reported by the UI layer (`NSWorkspace.runningApplications`).
public struct RunningApp: Sendable, Hashable {
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?

    public init(name: String, bundleIdentifier: String?, bundlePath: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }
}

/// Finds out whether something below a path is in use (assumption C4: best effort).
///
/// Checks files opened by processes of the current user (libproc) and running apps whose bundle lies
/// below the path or whose bundle identifier names the folder (e.g. `~/Library/Caches/com.example.App`).
/// Not visible: processes of other users or root, and memory-mapped files without an open descriptor.
public struct UsageSnapshot: Sendable {
    /// Open file paths with the name of the process that holds them.
    let openFiles: [(path: String, process: String)]
    let runningApps: [RunningApp]
    /// Whether this snapshot reads the real process table (and can therefore be refreshed).
    let isLive: Bool

    public init(openFiles: [(path: String, process: String)], runningApps: [RunningApp]) {
        self.openFiles = openFiles
        self.runningApps = runningApps
        self.isLive = false
    }

    private init(liveRunningApps: [RunningApp]) {
        openFiles = Self.openFilesOfAllProcesses()
        runningApps = liveRunningApps
        isLive = true
    }

    /// Takes a snapshot of the open files of all inspectable processes. Takes a moment; do it once per plan.
    public static func capture(runningApps: [RunningApp]) -> UsageSnapshot {
        UsageSnapshot(liveRunningApps: runningApps)
    }

    /// A new look at the open files (running apps are kept as given). Fixed snapshots stay unchanged.
    func refreshed() -> UsageSnapshot {
        isLive ? UsageSnapshot(liveRunningApps: runningApps) : self
    }

    /// Name of a process or app using `path` (or something below it), or `nil`.
    public func user(of path: String) -> String? {
        let lowered = path.lowercased()
        let prefix = lowered.hasSuffix("/") ? lowered : lowered + "/"
        for app in runningApps {
            if let bundle = app.bundlePath?.lowercased(), bundle == lowered || bundle.hasPrefix(prefix) { return app.name }
            if let identifier = app.bundleIdentifier?.lowercased(),
               lowered.split(separator: "/").contains(where: { $0 == identifier }) {
                return app.name
            }
        }
        for file in openFiles {
            let open = file.path.lowercased()
            if open == lowered || open.hasPrefix(prefix) { return file.process }
        }
        return nil
    }

    static func openFilesOfAllProcesses() -> [(path: String, process: String)] {
        let ownPID = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var result: [(String, String)] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != ownPID {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue } // other users' processes are not inspectable
            let stride = MemoryLayout<proc_fdinfo>.stride
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
            let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard used > 0 else { continue }
            let name = processName(pid)
            for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                          Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                guard read == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if !path.isEmpty { result.append((path, name)) }
            }
        }
        return result
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0
            ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "PID \(pid)"
    }
}

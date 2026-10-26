/// Home-relative locations the analysis knows about. Kept in one place because Apple and tool vendors
/// move them between versions.
enum KnownLocations {
    static let caches = "Library/Caches"
    static let logs = "Library/Logs"
    static let trash = ".Trash"
    static let downloads = "Downloads"

    static let derivedData = "Library/Developer/Xcode/DerivedData"
    static let archives = "Library/Developer/Xcode/Archives"
    static let deviceSupport = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
                                "visionOS DeviceSupport", "xrOS DeviceSupport"]
        .map { "Library/Developer/Xcode/" + $0 }
    static let simulatorDevices = "Library/Developer/CoreSimulator/Devices"
    static let androidAVDs = ".android/avd"

    static let gradle = ".gradle/caches"
    static let npm = ".npm/_cacache"
    static let pnpm = "Library/pnpm/store"
    static let yarn = "Library/Caches/Yarn"
    static let pip = "Library/Caches/pip"
    static let homebrew = "Library/Caches/Homebrew"
    static let cocoaPods = "Library/Caches/CocoaPods"

    /// Cache subfolders that have their own recommendation and are therefore not part of “Caches”.
    static let claimedCacheFolders: Set<String> = ["Yarn", "pip", "Homebrew", "CocoaPods"]

    static let dockerImage = "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    static let iosBackups = "Library/Application Support/MobileSync/Backup"
    static let mailDownloads = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    static let mailStore = "Library/Mail"

    static let homebrewExecutables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let dockerExecutables = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                    "/Applications/Docker.app/Contents/Resources/bin/docker"]
}

/// Decides which files count as the user's own files for media and duplicate suggestions.
/// Excludes app data, iCloud Drive, libraries managed by apps and anything inside bundles, because
/// removing single files there damages the owning app or library.
enum PersonalFiles {
    static let excludedHomePrefixes = ["Library/", "Applications/"]
    static let managedPackageExtensions: Set<String> = [
        "app", "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "fcpbundle", "imovielibrary",
        "logicx", "band", "aplibrary", "migratedphotolibrary", "bundle", "framework", "xcarchive",
    ]

    /// `path` is an absolute display path below `home`.
    static func isPersonal(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        if excludedHomePrefixes.contains(where: { relative.hasPrefix($0) }) { return false }
        for component in relative.split(separator: "/").dropLast() {
            // Hidden folders hold tool data (.npm, .gradle, .vscode …); packages are managed by apps.
            if component.hasPrefix(".") { return false }
            if let dot = component.lastIndex(of: "."),
               managedPackageExtensions.contains(component[component.index(after: dot)...].lowercased()) {
                return false
            }
        }
        return true
    }

    /// Whether files inside the directory at `path` can be personal files.
    static func isPersonalDirectory(_ path: String, home: String) -> Bool {
        isPersonal(path + "/file", home: home)
    }

    static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "wmv", "mpg", "mpeg", "mts", "m2ts", "webm", "flv", "3gp",
        "wav", "aif", "aiff", "flac", "m4a", "mp3",
        "heic", "jpg", "jpeg", "png", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "psd",
    ]

    static func isMedia(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return mediaExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}

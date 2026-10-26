import Foundation
import ScannerKit
import Testing
@testable import CleanupKit

@Suite("Protection list (rules)")
struct ProtectionRuleTests {
    let policy = ProtectionPolicy(homeDirectory: "/Users/test")

    /// Every protected location from the specification, plus variants.
    @Test(arguments: [
        ("/", ProtectionReason.systemLocation),
        ("/System", .systemLocation),
        ("/System/Library/Caches/com.apple.x", .systemLocation),
        ("/usr", .systemLocation), ("/usr/local/bin/tool", .systemLocation),
        ("/bin/ls", .systemLocation), ("/sbin/mount", .systemLocation),
        ("/private/var/db", .systemLocation), ("/private/etc/hosts", .systemLocation),
        ("/etc", .systemLocation), ("/var/log", .systemLocation), ("/tmp/x", .systemLocation),
        ("/opt/homebrew", .systemLocation), ("/cores", .systemLocation),
        ("/Library", .systemLocation), ("/Library/Preferences/x.plist", .systemLocation),
        ("/Library/Application Support/Logic", .systemLocation), ("/Library/Caches", .systemLocation),
        ("/Applications", .applications), ("/Applications/Xcode.app", .applications),
        ("/Users", .systemLocation), ("/Users/other", .otherUser), ("/Users/other/Library/Caches/x", .otherUser),
        ("/Users/test", .homeFolder), ("/Users/test/", .homeFolder),
        ("/Users/test/Desktop", .homeFolder), ("/Users/test/Documents", .homeFolder),
        ("/Users/test/Downloads", .homeFolder), ("/Users/test/Library", .homeFolder),
        ("/Users/test/Movies", .homeFolder), ("/Users/test/Music", .homeFolder),
        ("/Users/test/Pictures", .homeFolder), ("/Users/test/Public", .homeFolder),
        ("/Users/test/Applications", .homeFolder), ("/Users/test/.Trash", .homeFolder),
        ("/Users/test/Library/Caches", .libraryStructure), ("/Users/test/Library/Application Support", .libraryStructure),
        ("/Users/test/Library/Preferences", .libraryStructure),
        ("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", .iCloud),
        ("/Users/test/Library/CloudStorage/OneDrive/x", .iCloud),
        ("/Users/test/Library/Keychains/login.keychain-db", .keychains),
        ("/Users/test/Library/Messages/chat.db", .messages),
        ("/Users/test/Library/Messages/Attachments/ab", .messages),
        ("/Users/test/Library/Mail/V10/x", .mail),
        ("/Users/test/Library/Containers/com.apple.mail", .appContainer),
        ("/Users/test/Library/Containers/com.apple.mail/Data", .appContainer),
        ("/Users/test/Library/Containers/com.apple.mail/Data/Library", .appContainer),
        ("/Users/test/Library/Group Containers/group.x", .appContainer),
        ("/Users/test/Pictures/Photos Library.photoslibrary", .photosLibrary),
        ("/Users/test/Pictures/Photos Library.photoslibrary/originals/A/x.heic", .photosLibrary),
        ("/Volumes", .volumeRoot), ("/Volumes/External", .volumeRoot),
        ("/Volumes/Backup/Backups.backupdb/Mac", .timeMachine),
        ("/Volumes/NAS/Mac.sparsebundle", .timeMachine), ("/Volumes/X/Mac.backupbundle/y", .timeMachine),
        ("/Volumes/.timemachine/abc", .timeMachine),
        // Case variants must not slip through on case-insensitive volumes.
        ("/system/library", .systemLocation), ("/USERS/TEST/LIBRARY/KEYCHAINS/x", .keychains),
        ("/Users/test/library/MOBILE DOCUMENTS/x", .iCloud),
    ])
    func protectedPathsAreDenied(path: String, reason: ProtectionReason) {
        #expect(policy.rules(for: path) == .denied(reason), "\(path)")
    }

    @Test(arguments: [
        "/Users/test/Library/Caches/com.example.App",
        "/Users/test/Library/Developer/Xcode/DerivedData",
        "/Users/test/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        "/Users/test/Downloads/installer.dmg",
        "/Users/test/Projects/app/node_modules",
        "/Users/test/.npm/_cacache",
        "/Users/test/.Trash/old.zip",
        "/Library/Caches/com.example.Updater",
        "/Library/Logs/DiagnosticReports/x.ips",
        "/Users/Shared/big.iso",
        "/Volumes/External/Movies/clip.mov",
    ])
    func allowedLocations(path: String) {
        #expect(policy.rules(for: path) == .allowed, "\(path)")
    }

    @Test(arguments: ["relative/path", "/Users/test/Library/Caches/../Keychains/x", "/Users/test/./Library/Caches/x", ""])
    func invalidPathsAreDenied(path: String) {
        #expect(policy.evaluate(path) == .denied(.invalidPath))
    }

    @Test func dataVolumePathsAreMappedToTheirFirmlinkedForm() {
        #expect(policy.evaluate("/System/Volumes/Data/Users/test/Library/Keychains/x") == .denied(.keychains))
        #expect(policy.evaluate("/System/Volumes/Data/Users/other/x") == .denied(.otherUser))
    }
}

@Suite("Protection list (file system)")
struct ProtectionFileSystemTests {
    @Test func symlinkedParentsCannotReachProtectedLocations() throws {
        let home = try TestHome()
        // ~/Projects/sneaky → ~/Library/Keychains: removing "~/Projects/sneaky/login.keychain-db" would hit the keychain.
        try FileManager.default.createDirectory(atPath: home.path + "/Library/Keychains", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.path + "/Projects", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/Projects/sneaky",
                                                   withDestinationPath: home.path + "/Library/Keychains")
        let policy = ProtectionPolicy(homeDirectory: home.path)
        #expect(policy.evaluate(home.path + "/Projects/sneaky/login.keychain-db") == .denied(.keychains))
        // The link itself only removes the link, which is harmless.
        #expect(policy.evaluate(home.path + "/Projects/sneaky") == .allowed)

        try FileManager.default.createSymbolicLink(atPath: home.path + "/Projects/system", withDestinationPath: "/System/Library")
        #expect(policy.evaluate(home.path + "/Projects/system/Fonts") == .denied(.systemLocation))
    }
}

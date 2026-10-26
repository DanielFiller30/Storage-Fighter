import AnalysisKit
import SwiftUI

/// User-facing texts for AnalysisKit's values. AnalysisKit itself contains no UI text.
extension RecommendationKind {
    var title: LocalizedStringResource {
        switch self {
        case .userCaches: "App Caches"
        case .userLogs: "Logs"
        case .trash: "Trash"
        case .downloads: "Large or Old Downloads"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode Archives"
        case .xcodeDeviceSupport: "Xcode Device Support"
        case .simulatorRuntimes: "Simulator Runtimes"
        case .simulatorUnavailableDevices: "Unavailable Simulators"
        case .androidVirtualDevices: "Android Emulators (AVD)"
        case .gradleCache: "Gradle Cache"
        case .npmCache: "npm Cache"
        case .pnpmStore: "pnpm Store"
        case .yarnCache: "Yarn Cache"
        case .pipCache: "pip Cache"
        case .homebrewCache: "Homebrew Cache"
        case .cocoaPodsCache: "CocoaPods Cache"
        case .inactiveNodeModules: "node_modules in Inactive Projects"
        case .dockerData: "Docker Data"
        case .iosBackups: "iPhone and iPad Backups"
        case .mailDownloads: "Opened Mail Attachments"
        case .mailAttachments: "Attachments in Mail"
        case .largeMedia: "Large Media Files"
        case .duplicates: "Duplicate Files"
        case .localSnapshots: "Local Time Machine Snapshots"
        case .profileLocation: "Other"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .userCaches:
            "Apps keep temporary copies here to start and load faster. Removing them is safe; apps rebuild what they need, which can make them slower the first time. Quit an app before removing its cache."
        case .userLogs:
            "Diagnostic logs written by apps. They are only needed to investigate problems."
        case .trash:
            "Files you have already moved to the Trash. They still use space until the Trash is emptied. Emptying it is permanent."
        case .downloads:
            "Files in your Downloads folder that are large or have not been changed for over a year, such as installers and archives. Check whether you still need them; they cannot be restored once deleted."
        case .xcodeDerivedData:
            "Build products and indexes of Xcode projects. Xcode recreates them on the next build, which then takes longer."
        case .xcodeArchives:
            "App builds created with Product → Archive. They are needed to symbolicate crash reports or to submit that exact build again."
        case .xcodeDeviceSupport:
            "Debug symbols Xcode copied from connected devices, one folder per OS version. Xcode copies them again when that device is connected."
        case .simulatorRuntimes:
            "iOS, watchOS, tvOS or visionOS versions for the Simulator. Xcode can download them again (several GB each). Removal uses Xcode's own command."
        case .simulatorUnavailableDevices:
            "Simulator devices whose OS version is no longer installed. They cannot be started anymore. Removal uses Xcode's own command."
        case .androidVirtualDevices:
            "Android emulator images including their state (installed apps, data). They can be created again in Android Studio."
        case .gradleCache, .npmCache, .pnpmStore, .yarnCache, .pipCache, .cocoaPodsCache:
            "Downloaded packages kept by a package manager to avoid downloading them again. They are downloaded again when a project needs them."
        case .homebrewCache:
            "Downloaded Homebrew packages and old versions. Homebrew's own clean-up command removes them."
        case .inactiveNodeModules:
            "Installed JavaScript dependencies of projects that have not changed for a while. Running npm install (or pnpm/yarn) in the project restores them."
        case .dockerData:
            "The disk image holding all Docker images, containers and volumes. Only remove data with Docker's own tools; volumes may contain databases or other work."
        case .iosBackups:
            "Local backups of iPhones and iPads made with the Finder. A deleted backup cannot be restored; make sure you have a newer backup (e.g. in iCloud) first."
        case .mailDownloads:
            "Copies of attachments you opened from Mail. The originals stay in the messages."
        case .mailAttachments:
            "Attachments stored inside the Mail database. Shown for information only: removing files there can damage Mail. Delete large messages in Mail instead."
        case .largeMedia:
            "Large video, audio and image files among your own files. Your photo library and iCloud Drive are not included."
        case .duplicates:
            "Files with identical content. One copy of each group is always kept. Copies made with the Finder are often APFS clones that share their storage; removing them frees little or nothing, which the sizes reflect."
        case .profileLocation:
            "A location from an activity profile."
        case .localSnapshots:
            "Time Machine keeps hourly snapshots on the startup disk while the backup disk is away. macOS removes them automatically when space is needed, so they count as available space. Stofi only shows them."
        }
    }

    var systemImage: String {
        switch self {
        case .userCaches: "archivebox"
        case .userLogs: "doc.text"
        case .trash: "trash"
        case .downloads: "arrow.down.circle"
        case .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport: "hammer"
        case .simulatorRuntimes, .simulatorUnavailableDevices: "iphone"
        case .androidVirtualDevices: "smartphone"
        case .gradleCache, .npmCache, .pnpmStore, .yarnCache, .pipCache, .homebrewCache, .cocoaPodsCache: "shippingbox"
        case .inactiveNodeModules: "folder.badge.gearshape"
        case .dockerData: "cube"
        case .iosBackups: "externaldrive.badge.timemachine"
        case .mailDownloads, .mailAttachments: "paperclip"
        case .largeMedia: "film"
        case .duplicates: "doc.on.doc"
        case .localSnapshots: "clock.arrow.circlepath"
        case .profileLocation: "folder"
        }
    }
}

extension RecommendationGroup {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System and Apps"
        case .developer: "Developer"
        case .personal: "Personal Files"
        case .creative: "Video, Photo and Audio"
        case .gaming: "Games"
        case .duplicates: "Duplicates"
        case .snapshots: "Snapshots"
        case .other: "Other"
        }
    }
}

extension RiskLevel {
    var title: LocalizedStringKey {
        switch self {
        case .safe: "Safe"
        case .caution: "Use caution"
        case .expert: "Experts only"
        }
    }

    /// Different shapes, so the level is recognisable without colour.
    var systemImage: String {
        switch self {
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.triangle"
        case .expert: "exclamationmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .expert: .red
        }
    }
}

extension Regeneration {
    var title: LocalizedStringKey? {
        switch self {
        case .automatic: "Recreated automatically"
        case .download: "Can be downloaded again"
        case .rebuild: "Can be rebuilt"
        case .none: "Cannot be restored"
        case .notApplicable: nil
        }
    }
}

extension StorageCategoryKind {
    var title: LocalizedStringKey {
        switch self {
        case .applications: "Applications"
        case .userData: "User Data"
        case .appData: "App Data"
        case .developer: "Developer"
        case .cachesAndLogs: "Caches & Logs"
        case .system: "System"
        case .notCaptured: "Not captured"
        }
    }

    var color: Color {
        switch self {
        case .applications: .blue
        case .userData: .purple
        case .appData: .teal
        case .developer: .orange
        case .cachesAndLogs: .yellow
        case .system: .gray
        case .notCaptured: .secondary.opacity(0.4)
        }
    }
}

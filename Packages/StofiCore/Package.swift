// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StofiCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "LayoutKit", targets: ["LayoutKit"]),
        .library(name: "AnalysisKit", targets: ["AnalysisKit"]),
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
    ],
    targets: [
        .target(name: "ScannerKit"),
        // Pure geometry (treemap layout), no file-system or UI dependency, so it can be tested in isolation.
        .target(name: "LayoutKit"),
        // Categories and heuristics on top of a scan. Read-only; produces suggestions, never acts on them.
        .target(name: "AnalysisKit", dependencies: ["ScannerKit"], resources: [.copy("Profiles")]),
        // The only module that removes anything, and only through a confirmed plan.
        .target(name: "CleanupKit", dependencies: ["ScannerKit", "AnalysisKit"]),
        .executableTarget(name: "StofiBench", dependencies: ["ScannerKit"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"]),
        .testTarget(name: "AnalysisKitTests", dependencies: ["AnalysisKit", "ScannerKit"]),
        .testTarget(name: "CleanupKitTests", dependencies: ["CleanupKit", "AnalysisKit", "ScannerKit"]),
    ]
)

import Foundation

/// Lightweight capacity information of a volume, read from `URLResourceValues` without scanning.
///
/// The three parts used / purgeable / free always add up to ``totalCapacity``:
/// - **free**: really unused space (`volumeAvailableCapacity`).
/// - **purgeable** (“removable”): space macOS can reclaim on demand, e.g. caches, local snapshots,
///   optimised iCloud files. It is an *estimate*: the difference between the capacity available for
///   important usage and the really free space. Apple does not document how it is computed.
/// - **used**: the rest.
public struct VolumeInfo: Sendable, Equatable {
    public let name: String
    public let totalCapacity: UInt64
    /// `volumeAvailableCapacity`: free blocks.
    public let availableCapacity: UInt64
    /// `volumeAvailableCapacityForImportantUsage`: free plus what macOS would purge for important data.
    public let availableForImportantUsage: UInt64
    /// `volumeAvailableCapacityForOpportunisticUsage`: what non-essential work should limit itself to.
    public let availableForOpportunisticUsage: UInt64

    public init(name: String, totalCapacity: UInt64, availableCapacity: UInt64,
                availableForImportantUsage: UInt64, availableForOpportunisticUsage: UInt64) {
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = min(availableCapacity, totalCapacity)
        self.availableForImportantUsage = min(availableForImportantUsage, totalCapacity)
        self.availableForOpportunisticUsage = min(availableForOpportunisticUsage, totalCapacity)
    }

    public var freeBytes: UInt64 { availableCapacity }

    public var purgeableBytes: UInt64 {
        availableForImportantUsage > availableCapacity ? availableForImportantUsage - availableCapacity : 0
    }

    public var usedBytes: UInt64 { totalCapacity - freeBytes - purgeableBytes }

    /// Share of space that is free or purgeable, 0…1 — what users can actually use.
    public var availableFraction: Double {
        totalCapacity == 0 ? 0 : Double(freeBytes + purgeableBytes) / Double(totalCapacity)
    }

    /// Reads the capacities of the volume containing `url`. Cheap; does not touch file contents.
    public static func read(for url: URL = URL(fileURLWithPath: "/")) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey,
        ])
        return VolumeInfo(
            name: values.volumeLocalizedName ?? url.lastPathComponent,
            totalCapacity: UInt64(max(0, values.volumeTotalCapacity ?? 0)),
            availableCapacity: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
            availableForImportantUsage: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)),
            availableForOpportunisticUsage: UInt64(max(0, values.volumeAvailableCapacityForOpportunisticUsage ?? 0))
        )
    }
}

/// How tight the space on a volume is, for the menu bar status.
public enum CapacityLevel: Int, Sendable, Comparable, CaseIterable {
    case normal, low, critical

    public static func < (lhs: CapacityLevel, rhs: CapacityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension VolumeInfo {
    /// Space users can actually use: free plus what macOS frees on demand.
    public var usableBytes: UInt64 { freeBytes + purgeableBytes }

    /// Level for the given thresholds in percent of the total capacity (e.g. low < 15 %, critical < 5 %).
    public func level(lowPercent: Double, criticalPercent: Double) -> CapacityLevel {
        let percent = availableFraction * 100
        if percent < criticalPercent { return .critical }
        if percent < lowPercent { return .low }
        return .normal
    }
}

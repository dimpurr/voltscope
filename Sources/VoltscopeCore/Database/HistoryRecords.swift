import Foundation
import GRDB

// GRDB records for the tiered history store. Property names match column
// names one-for-one; `databaseTableName` is set explicitly for the two
// tables whose Swift type name intentionally differs from the SQL name.

/// Process dictionary row. `groupKey` is the stable identity
/// (`bundleIdentifier ?? processName`, the same rule the legacy store used)
/// and is the only column callers look up by.
public struct AppRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var groupKey: String
    public var bundleIdentifier: String?
    public var displayName: String
    public var path: String?
    /// Unix epoch milliseconds of the first time this group was seen.
    public var firstSeen: Int64
    /// Unix epoch milliseconds of the most recent time this group was seen.
    public var lastSeen: Int64

    public static let databaseTableName = "App"

    public init(
        id: Int64? = nil,
        groupKey: String,
        bundleIdentifier: String?,
        displayName: String,
        path: String?,
        firstSeen: Int64,
        lastSeen: Int64
    ) {
        self.id = id
        self.groupKey = groupKey
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// L0 per-process raw sample. Retained for the raw retention window only.
public struct AppSampleRaw: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var ts: Int64
    public var appId: Int64
    public var pid: Int32
    public var parentPid: Int32?
    public var metricVersion: Int
    public var energyNJ: Int64
    public var cpuNs: Int64
    public var wakeups: Int64
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64

    public static let databaseTableName = "AppSampleRaw"

    public init(
        ts: Int64,
        appId: Int64,
        pid: Int32,
        parentPid: Int32?,
        metricVersion: Int,
        energyNJ: Int64,
        cpuNs: Int64,
        wakeups: Int64,
        diskReadBytes: Int64,
        diskWriteBytes: Int64
    ) {
        self.ts = ts
        self.appId = appId
        self.pid = pid
        self.parentPid = parentPid
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
        self.cpuNs = cpuNs
        self.wakeups = wakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

/// L1 per-app per-minute rollup.
public struct AppUsageMinute: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var minute: Int64
    public var appId: Int64
    public var metricVersion: Int
    public var energyNJ: Int64
    public var cpuNs: Int64
    public var wakeups: Int64
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64
    public var samples: Int64

    public static let databaseTableName = "AppUsageMinute"

    public init(
        minute: Int64,
        appId: Int64,
        metricVersion: Int,
        energyNJ: Int64,
        cpuNs: Int64,
        wakeups: Int64,
        diskReadBytes: Int64,
        diskWriteBytes: Int64,
        samples: Int64
    ) {
        self.minute = minute
        self.appId = appId
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
        self.cpuNs = cpuNs
        self.wakeups = wakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.samples = samples
    }
}

/// L2 per-app per-hour rollup. Retained indefinitely.
public struct AppUsageHour: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var hour: Int64
    public var appId: Int64
    public var metricVersion: Int
    public var energyNJ: Int64
    public var cpuNs: Int64
    public var wakeups: Int64
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64
    public var samples: Int64

    public static let databaseTableName = "AppUsageHour"

    public init(
        hour: Int64,
        appId: Int64,
        metricVersion: Int,
        energyNJ: Int64,
        cpuNs: Int64,
        wakeups: Int64,
        diskReadBytes: Int64,
        diskWriteBytes: Int64,
        samples: Int64
    ) {
        self.hour = hour
        self.appId = appId
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
        self.cpuNs = cpuNs
        self.wakeups = wakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.samples = samples
    }
}

/// Hardware bucket dictionary row.
public struct BucketRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var name: String

    public static let databaseTableName = "Bucket"

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// L0 per-bucket raw sample. Retained for the raw retention window only.
public struct BucketSampleRaw: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var ts: Int64
    public var bucketId: Int64
    public var metricVersion: Int
    public var energyNJ: Int64

    public static let databaseTableName = "BucketSampleRaw"

    public init(ts: Int64, bucketId: Int64, metricVersion: Int, energyNJ: Int64) {
        self.ts = ts
        self.bucketId = bucketId
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
    }
}

/// L1 per-bucket per-minute rollup.
public struct BucketMinute: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var minute: Int64
    public var bucketId: Int64
    public var metricVersion: Int
    public var energyNJ: Int64

    public static let databaseTableName = "BucketMinute"

    public init(minute: Int64, bucketId: Int64, metricVersion: Int, energyNJ: Int64) {
        self.minute = minute
        self.bucketId = bucketId
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
    }
}

/// L2 per-bucket per-hour rollup. Retained indefinitely.
public struct BucketHour: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var hour: Int64
    public var bucketId: Int64
    public var metricVersion: Int
    public var energyNJ: Int64

    public static let databaseTableName = "BucketHour"

    public init(hour: Int64, bucketId: Int64, metricVersion: Int, energyNJ: Int64) {
        self.hour = hour
        self.bucketId = bucketId
        self.metricVersion = metricVersion
        self.energyNJ = energyNJ
    }
}

/// Per-tick sampling coverage, one row per tick. Retained for the raw
/// retention window only.
public struct Coverage: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var ts: Int64
    public var visible: Int64
    public var unreadable: Int64

    public static let databaseTableName = "Coverage"

    public init(ts: Int64, visible: Int64, unreadable: Int64) {
        self.ts = ts
        self.visible = visible
        self.unreadable = unreadable
    }
}

/// Per-hour coverage rollup. Retained indefinitely.
public struct CoverageHour: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var hour: Int64
    public var ticks: Int64
    public var visibleSum: Int64
    public var unreadableSum: Int64

    public static let databaseTableName = "CoverageHour"

    public init(hour: Int64, ticks: Int64, visibleSum: Int64, unreadableSum: Int64) {
        self.hour = hour
        self.ticks = ticks
        self.visibleSum = visibleSum
        self.unreadableSum = unreadableSum
    }
}

/// Key/value store for rollup watermarks, importer state, and settings.
public struct MetaEntry: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var key: String
    public var value: String

    public static let databaseTableName = "Meta"

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

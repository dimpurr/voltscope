import Foundation
import GRDB

public struct EnergySample: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var sampleId: Int64?
    public var timestamp: Int64
    public var pid: Int32
    public var bundleIdentifier: String?
    public var processName: String
    public var path: String?
    public var parentPid: Int32?
    public var cpuUserNs: Int64
    public var cpuSystemNs: Int64
    public var energyNJ: Int64
    public var wakeups: Int64
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public static let databaseTableName = "EnergyHistory"

    public init(
        sampleId: Int64? = nil,
        timestamp: Int64,
        pid: Int32,
        bundleIdentifier: String? = nil,
        processName: String,
        path: String? = nil,
        parentPid: Int32? = nil,
        cpuUserNs: Int64,
        cpuSystemNs: Int64,
        energyNJ: Int64,
        wakeups: Int64,
        diskReadBytes: Int64,
        diskWriteBytes: Int64,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) {
        self.sampleId = sampleId
        self.timestamp = timestamp
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.path = path
        self.parentPid = parentPid
        self.cpuUserNs = cpuUserNs
        self.cpuSystemNs = cpuSystemNs
        self.energyNJ = energyNJ
        self.wakeups = wakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        sampleId = inserted.rowID
    }
}

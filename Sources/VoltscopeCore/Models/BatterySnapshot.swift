import Foundation
import GRDB

public struct BatterySnapshot: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var timestamp: Int64
    public var levelPercent: Double?
    public var capacityMAh: Int?
    public var designMAh: Int?
    public var cycleCount: Int?
    public var voltageMV: Int?
    public var amperageMA: Int?
    public var temperatureC: Double?
    public var timeRemainingMin: Int?
    public var isCharging: Bool
    public var isACPlugged: Bool

    public static let databaseTableName = "BatteryStatus"

    public init(
        timestamp: Int64,
        levelPercent: Double?,
        capacityMAh: Int?,
        designMAh: Int?,
        cycleCount: Int?,
        voltageMV: Int?,
        amperageMA: Int?,
        temperatureC: Double?,
        timeRemainingMin: Int?,
        isCharging: Bool,
        isACPlugged: Bool
    ) {
        self.timestamp = timestamp
        self.levelPercent = levelPercent
        self.capacityMAh = capacityMAh
        self.designMAh = designMAh
        self.cycleCount = cycleCount
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.temperatureC = temperatureC
        self.timeRemainingMin = timeRemainingMin
        self.isCharging = isCharging
        self.isACPlugged = isACPlugged
    }

    /// Instantaneous power in watts derived from V × |I|. macOS reports
    /// amperage as signed (negative = discharging); we surface absolute
    /// magnitude since the UI says "drain" / "charging" via separate state.
    /// Returns nil when either voltage or amperage is unavailable.
    public var instantaneousWatts: Double? {
        guard let mv = voltageMV, let ma = amperageMA else { return nil }
        return Double(mv) * Double(abs(ma)) / 1_000_000.0
    }
}

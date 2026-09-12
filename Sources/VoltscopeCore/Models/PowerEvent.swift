import Foundation
import GRDB

public enum PowerEventType: String, Codable, Sendable {
    case sleep
    case wake
    case plug
    case unplug
    case lowpowerOn = "lowpower_on"
    case lowpowerOff = "lowpower_off"
}

public struct PowerEvent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var timestamp: Int64
    public var eventType: String
    public var durationSeconds: Int?
    public var metadata: String?

    public static let databaseTableName = "PowerEvents"

    public init(timestamp: Int64, eventType: PowerEventType, durationSeconds: Int? = nil, metadata: String? = nil) {
        self.timestamp = timestamp
        self.eventType = eventType.rawValue
        self.durationSeconds = durationSeconds
        self.metadata = metadata
    }

    public var type: PowerEventType? {
        PowerEventType(rawValue: eventType)
    }
}

import Foundation

/// Where a command puts its result. The tool writes to its own file handles;
/// tests capture into memory.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private var captured: Data?

    static let standardOutput = OutputSink(handle: .standardOutput)
    static let standardError = OutputSink(handle: .standardError)

    /// An in-memory sink for tests.
    init() {
        handle = nil
        captured = Data()
    }

    private init(handle: FileHandle?) {
        self.handle = handle
    }

    func write(_ data: Data) {
        lock.lock()
        if captured != nil {
            captured?.append(data)
        } else {
            handle?.write(data)
        }
        lock.unlock()
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    var capturedText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: captured ?? Data(), as: UTF8.self)
    }
}

/// A JSON value that can also say `null` explicitly, which `Optional` cannot
/// through `JSONEncoder` (an absent key is not the same answer as "no value").
enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .array(let value):
            var container = encoder.unkeyedContainer()
            for item in value {
                try container.encode(item)
            }
        case .object(let value):
            var container = encoder.container(keyedBy: JSONKey.self)
            for key in value.keys.sorted() {
                guard let item = value[key] else { continue }
                try container.encode(item, forKey: JSONKey(stringValue: key))
            }
        }
    }

    private struct JSONKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Shared helpers for building the JSON envelope and the plain-text tables.
enum CLIFormat {
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// UTC timestamps, matching the CSV export's representation.
    ///
    /// `ISO8601DateFormatter` is not `Sendable`, so a shared instance would need
    /// a lock. One run prints at most a couple of hundred timestamps.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Pretty JSON with stable key order, terminated by a newline.
    static func encodeJSON(_ value: [String: JSONValue]) throws -> String {
        let data = try jsonEncoder.encode(JSONValue.object(value))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func envelope(command: String, generatedAt: Date, lastSampleAt: Date?,
                         databasePath: String?) -> [String: JSONValue] {
        [
            "schema": .integer(1),
            "command": .string(command),
            "generatedAt": .string(isoString(generatedAt)),
            "lastSampleAt": lastSampleAt.map { .string(isoString($0)) } ?? .null,
            "databasePath": databasePath.map { .string($0) } ?? .null
        ]
    }

    /// Joules at three precisions, so a 0.4 J bucket is not printed as 0.00.
    static func energy(_ joules: Double) -> String {
        let magnitude = abs(joules)
        if magnitude >= 100 { return String(format: "%.0f J", joules) }
        if magnitude >= 1 { return String(format: "%.2f J", joules) }
        return String(format: "%.3f J", joules)
    }

    static func joules(_ nanojoules: Int64) -> Double {
        Double(nanojoules) / 1_000_000_000
    }

    static func cpuSeconds(_ nanoseconds: Int64) -> Double {
        Double(nanoseconds) / 1_000_000_000
    }

    /// Signed power: negative while discharging, positive while charging.
    static func power(_ watts: Double?) -> String {
        guard let watts else { return "-" }
        return String(format: "%+.2f W", watts)
    }

    /// A whole-minute duration such as "3h 12m", or "45s" under a minute.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int64(seconds.rounded())
        let minutes = whole / 60
        let hours = minutes / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes % 60) }
        if minutes > 0 { return "\(minutes)m \(whole % 60)s" }
        return "\(whole)s"
    }

    /// One aligned column row: label, then right-aligned values.
    static func row(_ label: String, _ value: String, labelWidth: Int = 16) -> String {
        let padded = label.count >= labelWidth ? label : label + String(repeating: " ", count: labelWidth - label.count)
        return "  \(padded)  \(value)\n"
    }

    static func rightAligned(_ text: String, width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static let energyCaveat = "Energy is recorded CPU energy only. It is not a share of whole-device battery drain."
}

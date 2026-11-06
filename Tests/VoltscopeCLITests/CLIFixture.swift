import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

/// A history file with samples placed relative to a fixed clock, so the same
/// window can be read through the command line and through the Core queries the
/// History window uses, and the two compared.
struct CLIFixture {
    let database: HistoryDatabase
    let url: URL
    let now: Date

    /// Apps and hardware recorded once in each of the last `hours` hourly
    /// windows, plus two battery snapshots per hour.
    ///
    /// Alpha is the heaviest app by energy, Beta the heaviest by CPU time and by
    /// wakeups, and `com.example.system` is system-classified. Data older than a
    /// day is included so a one-day window has to prove it excludes it.
    ///
    /// - Parameter latestOffsetSeconds: also record one tick this many seconds
    ///   ago, which is what makes `status` report "recording". Pass `nil` when a
    ///   test counts samples inside a window.
    static func make(hours: Int = 26, latestOffsetSeconds: TimeInterval? = 60,
                     rollupMinutes: Bool = true) async throws -> CLIFixture {
        let database = try HistoryDatabase.makeTemporaryFile()
        let url = try XCTUnwrap(database.fileURL)
        // Minute-aligned so window boundaries land on whole bucket edges.
        let now = Date(timeIntervalSince1970: Double(Int64(Date().timeIntervalSince1970 / 60) * 60))
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)

        for hour in 1...hours {
            let timestamp = nowMS - Int64(hour) * 3_600_000
            try await database.writeTick(timestamp: timestamp, apps: fixtureApps(), buckets: fixtureBuckets(),
                                         coverage: SampleCoverage(visible: 3, unreadable: 1))
            try await database.flushPendingWindow()
            for offset in [Int64(20_000), 10_000] {
                try await database.writeBatterySnapshot(BatterySnapshot(
                    timestamp: timestamp + offset, levelPercent: Double(100 - hour),
                    capacityMAh: 5_000, designMAh: 6_000, cycleCount: 100 + hour,
                    voltageMV: 12_000, amperageMA: -300, temperatureC: 30,
                    timeRemainingMin: 200, isCharging: false, isACPlugged: false))
            }
        }
        if let offset = latestOffsetSeconds {
            let timestamp = nowMS - Int64(offset * 1_000)
            try await database.writeTick(timestamp: timestamp, apps: fixtureApps(), buckets: fixtureBuckets(),
                                         coverage: SampleCoverage(visible: 3, unreadable: 1))
            try await database.flushPendingWindow()
            try await database.writeBatterySnapshot(BatterySnapshot(
                timestamp: timestamp, levelPercent: 99, capacityMAh: 5_000, designMAh: 6_000,
                cycleCount: 100, voltageMV: 12_000, amperageMA: -300, temperatureC: 30,
                timeRemainingMin: 200, isCharging: false, isACPlugged: false))
        }
        if rollupMinutes {
            // Mirrors the five-minute maintenance checkpoint: the twenty-four hour
            // view is served by the minute tier, with a raw tail still to roll up.
            try await database.rollupMinutes(now: now)
        }
        return CLIFixture(database: database, url: url, now: now)
    }

    /// The same content, with the writer let go afterwards, which is how the tool
    /// finds the file: committed data on disk and no attached writer.
    static func makeClosed(hours: Int = 3, latestOffsetSeconds: TimeInterval? = 60) async throws -> (url: URL, now: Date) {
        let url: URL
        let now: Date
        do {
            let fixture = try await make(hours: hours, latestOffsetSeconds: latestOffsetSeconds)
            url = fixture.url
            now = fixture.now
        }
        return (url, now)
    }

    var environment: [String: String] { ["VOLTSCOPE_DB_PATH": url.path] }

    /// The battery reading the tool should report when the caller injects one.
    static func liveBattery(at date: Date) -> BatterySnapshot {
        BatterySnapshot(timestamp: Int64(date.timeIntervalSince1970 * 1000), levelPercent: 84,
                        capacityMAh: 5_760, designMAh: 6_000, cycleCount: 143,
                        voltageMV: 12_400, amperageMA: -520, temperatureC: 32,
                        timeRemainingMin: 195, isCharging: false, isACPlugged: false)
    }
}

/// The three apps every fixture window records. Alpha is heaviest by energy,
/// Beta by CPU time and by wakeups, and the third is system-classified.
func fixtureApps() -> [SampledApp] {
    [
        SampledApp(groupKey: "com.example.alpha", bundleIdentifier: "com.example.alpha",
                   displayName: "Alpha", path: "/Apps/Alpha.app", pid: 11,
                   energyNJ: 900, cpuNs: 900_000_000, wakeups: 9),
        SampledApp(groupKey: "com.example.beta", bundleIdentifier: "com.example.beta",
                   displayName: "Beta", path: "/Apps/Beta.app", pid: 12,
                   energyNJ: 400, cpuNs: 1_200_000_000, wakeups: 40),
        SampledApp(groupKey: "com.apple.example-agent", bundleIdentifier: "com.apple.example-agent",
                   displayName: "ExampleAgent", path: "/System/Library/ExampleAgent", pid: 13,
                   energyNJ: 600, cpuNs: 600_000_000, wakeups: 6)
    ]
}

func fixtureBuckets() -> [SampledBucket] {
    [SampledBucket(name: "CPU", energyNJ: 5_000), SampledBucket(name: "GPU", energyNJ: 1_000)]
}

// MARK: - Reading the tool's JSON output

func decodedJSON(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        XCTFail("output is not a JSON object: \(text.prefix(400))", file: file, line: line)
        return [:]
    }
    return object
}

func decodedArray(_ value: Any?) -> [[String: Any]] {
    (value as? [[String: Any]]) ?? []
}

func decodedDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}

/// `XCTAssertEqual(_:accuracy:)` needs a non-optional, and a JSON number that is
/// missing or null is exactly the failure worth naming.
func assertApprox(_ value: Double?, _ expected: Double, _ accuracy: Double, _ message: String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    guard let value else {
        XCTFail("\(message.isEmpty ? "" : message + ": ")expected about \(expected), found no number",
                file: file, line: line)
        return
    }
    XCTAssertEqual(value, expected, accuracy: accuracy, message, file: file, line: line)
}

func decodedInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

func decodedString(_ value: Any?) -> String? {
    value as? String
}

func decodedDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return ISO8601DateFormatter().date(from: text)
}

/// The bucket grid `history` prints: every epoch-aligned bucket that starts
/// inside the window, so the numbers line up with the chart queries' buckets.
/// A window that does not open on a bucket edge therefore gets one row more than
/// `window / bucket`.
func expectedBucketStarts(start: Date, end: Date, bucketSeconds: Int) -> [Int64] {
    let width = Int64(bucketSeconds)
    var starts: [Int64] = []
    var bucket = (Int64(start.timeIntervalSince1970) / width) * width
    while Double(bucket) < end.timeIntervalSince1970 {
        starts.append(bucket)
        bucket += width
    }
    return starts
}

/// The shared envelope keys every command must carry.
func assertEnvelope(_ json: [String: Any], command: String, now: Date,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(decodedInt(json["schema"]), 1, "schema must be 1", file: file, line: line)
    XCTAssertEqual(decodedString(json["command"]), command, file: file, line: line)
    guard let generatedAt = decodedDate(json["generatedAt"]) else {
        XCTFail("generatedAt must be an ISO8601 string", file: file, line: line)
        return
    }
    XCTAssertEqual(generatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1,
                   "generatedAt must be the clock the command ran on", file: file, line: line)
    XCTAssertTrue(json.keys.contains("lastSampleAt"), "lastSampleAt must always be present", file: file, line: line)
}

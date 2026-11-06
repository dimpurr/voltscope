import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

/// The CSV bytes are the export contract: the app's Save panel and the
/// command-line tool must produce the same file. `expectedCSV` below repeats the
/// formatting the app used before the logic moved into Core, so a change to the
/// bytes fails here instead of surprising someone with a different export.
final class CSVExportTests: XCTestCase {
    private var removals: [URL] = []

    override func tearDownWithError() throws {
        for url in removals {
            try? FileManager.default.removeItem(at: url)
        }
        removals.removeAll()
    }

    private func expectedCSV(_ samples: [HistoryDatabase.CSVSample]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var text = HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n"
        for sample in samples {
            let iso = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestampMS) / 1000))
            text += sample.csvLine(iso8601: iso)
        }
        return text
    }

    /// Two apps and two hardware buckets over two windows, with a bundle-less
    /// process whose name contains a comma so the escaping path is exercised.
    private func makePopulatedDatabase() async throws -> HistoryDatabase {
        let database = try HistoryDatabase.makeInMemory()
        let base = Int64(Date().timeIntervalSince1970 * 1000) / 30_000 * 30_000
        for offset in [Int64(0), 30_000] {
            try await database.writeTick(
                timestamp: base + offset,
                apps: [
                    SampledApp(groupKey: "csv.alpha", bundleIdentifier: "csv.alpha", displayName: "Alpha",
                               path: "/Apps/Alpha.app", pid: 11, energyNJ: 1_500, cpuNs: 2_000,
                               wakeups: 3, diskReadBytes: 40, diskWriteBytes: 50),
                    SampledApp(groupKey: "csv,beta", bundleIdentifier: nil, displayName: "Beta, the Second",
                               path: nil, pid: 12, energyNJ: 700, cpuNs: 900, wakeups: 1)
                ],
                buckets: [SampledBucket(name: "CPU", energyNJ: 4_000), SampledBucket(name: "GPU", energyNJ: 250)],
                coverage: SampleCoverage(visible: 2, unreadable: 0))
            try await database.flushPendingWindow()
        }
        return database
    }

    func testStreamedExportMatchesTheRowQueryAndTheAppsFormat() async throws {
        let database = try await makePopulatedDatabase()
        let interval = DateInterval(start: Date().addingTimeInterval(-600), end: Date().addingTimeInterval(60))
        let samples = try await database.historySamplesForCSV(in: interval)
        XCTAssertEqual(samples.count, 4)

        let received = DataBox()
        try await CSVExport.write(database: database, interval: interval) { data in
            received.append(data)
        }
        XCTAssertEqual(String(decoding: received.value, as: UTF8.self), expectedCSV(samples))
        XCTAssertEqual(CSVExport.header, HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n")
    }

    func testFileExportWritesTheSameBytesAsTheStream() async throws {
        let database = try await makePopulatedDatabase()
        let interval = DateInterval(start: Date().addingTimeInterval(-600), end: Date().addingTimeInterval(60))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removals.append(directory)
        let url = directory.appendingPathComponent("energy.csv")

        try await CSVExport.write(database: database, interval: interval, to: url)
        let first = try Data(contentsOf: url)

        let streamed = DataBox()
        try await CSVExport.write(database: database, interval: interval) { data in streamed.append(data) }
        XCTAssertEqual(first, streamed.value)
        XCTAssertFalse(try containsPartialFiles(in: directory))

        // A second export replaces the finished file instead of growing it.
        try await CSVExport.write(database: database, interval: interval, to: url)
        XCTAssertEqual(try Data(contentsOf: url), first)
    }

    func testEmptyWindowStillWritesAHeaderOnlyFile() async throws {
        let database = try HistoryDatabase.makeInMemory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removals.append(directory)
        let url = directory.appendingPathComponent("energy.csv")

        try await CSVExport.write(database: database,
                                  interval: DateInterval(start: Date().addingTimeInterval(-60), end: Date()),
                                  to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, CSVExport.header)
    }

    func testFailedExportLeavesNothingAtTheDestination() async throws {
        let database = try await makePopulatedDatabase()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-csv-absent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("energy.csv")
        removals.append(missing.deletingLastPathComponent())

        do {
            try await CSVExport.write(database: database,
                                      interval: DateInterval(start: Date().addingTimeInterval(-600), end: Date()),
                                      to: missing)
            XCTFail("writing into a directory that does not exist must fail")
        } catch let error as CSVExportError {
            XCTAssertEqual(error, .couldNotOpenOutput)
            XCTAssertEqual(error.localizedDescription, "Could not open output file.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

/// Left-over `.partial` files would mean a failed or cancelled export cleaned up
/// after itself incorrectly.
private func containsPartialFiles(in directory: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial") }
}

/// A stream consumer needs to accumulate outside the caller's scope, and the
/// write closure is `@Sendable`, so the buffer is a lock-guarded class.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

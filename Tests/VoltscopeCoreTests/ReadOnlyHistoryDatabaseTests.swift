import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

/// The read-only open is what lets the command-line tool read the app's own
/// history file without any chance of changing it. These tests pin that promise:
/// no migration, no write to the database file or its WAL content, and a refusal
/// to read a schema this build cannot understand.
final class ReadOnlyHistoryDatabaseTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    /// The WAL peer file is measured in bytes rather than presence: opening a
    /// WAL-mode database read-only may create empty `-wal` and `-shm` peers, and
    /// SQLite cannot write content into them from a read-only connection.
    private struct FileState: Equatable {
        var modificationTime: TimeInterval
        var size: Int64
        var walSize: Int64
    }

    private func state(of url: URL) throws -> FileState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let wal = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return FileState(
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: attributes[.size] as? Int64 ?? 0,
            walSize: wal?[.size] as? Int64 ?? 0
        )
    }

    private func takeOwnership(of url: URL) {
        temporaryDirectories.append(url.deletingLastPathComponent())
    }

    /// A file-backed store holding one sampling tick and one battery snapshot,
    /// closed so the file holds committed data and no live WAL writer.
    private func makeCommittedDatabase() async throws -> URL {
        let database = try HistoryDatabase.makeTemporaryFile()
        let url = try XCTUnwrap(database.fileURL)
        takeOwnership(of: url)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) / 30_000 * 30_000
        try await database.writeTick(
            timestamp: timestamp,
            apps: [SampledApp(groupKey: "readonly.app", bundleIdentifier: "readonly.app",
                              displayName: "ReadOnly", pid: 4242, energyNJ: 5_000, cpuNs: 6_000, wakeups: 7)],
            buckets: [SampledBucket(name: "CPU", energyNJ: 9_000)],
            coverage: SampleCoverage(visible: 3, unreadable: 1))
        try await database.flushPendingWindow()
        try await database.writeBatterySnapshot(BatterySnapshot(
            timestamp: timestamp, levelPercent: 66, capacityMAh: 5_000, designMAh: 6_000,
            cycleCount: 42, voltageMV: 12_000, amperageMA: -400, temperatureC: 30,
            timeRemainingMin: 100, isCharging: false, isACPlugged: false))
        return url
    }

    func testReadOnlyOpenReadsHistoryWithoutChangingTheFile() async throws {
        let url = try await makeCommittedDatabase()
        let before = try state(of: url)

        let database = try HistoryDatabase.openReadOnly(url: url)
        let now = Date()
        let interval = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let totals = try await database.historyAppTotals(in: interval, range: .h1)
        let snapshot = try await database.latestBatterySnapshot()
        let coverage = try await database.latestCoverage()
        let samples = try await database.historySamplesForCSV(in: interval)

        XCTAssertEqual(totals.map(\.processName), ["ReadOnly"])
        XCTAssertEqual(totals.first?.totalWakeups, 7)
        XCTAssertEqual(snapshot?.levelPercent, 66)
        XCTAssertEqual(coverage?.unreadable, 1)
        XCTAssertEqual(samples.count, 1)
        let status = try await database.schemaStatus()
        XCTAssertEqual(status, .upToDate)

        let after = try state(of: url)
        XCTAssertEqual(after.size, before.size, "a read-only open must not grow the database file")
        XCTAssertEqual(after.walSize, before.walSize, "a read-only open must not add WAL content")
        XCTAssertEqual(after.modificationTime, before.modificationTime, accuracy: 0.001,
                       "a read-only open must not touch the database file")
    }

    func testReadOnlyConnectionRefusesWrites() async throws {
        let url = try await makeCommittedDatabase()
        let database = try HistoryDatabase.openReadOnly(url: url)
        do {
            try await database.writeBatterySnapshot(BatterySnapshot(
                timestamp: Int64(Date().timeIntervalSince1970 * 1000), levelPercent: 1, capacityMAh: nil,
                designMAh: nil, cycleCount: nil, voltageMV: nil, amperageMA: nil, temperatureC: nil,
                timeRemainingMin: nil, isCharging: false, isACPlugged: false))
            XCTFail("a read-only open must reject a write")
        } catch {
            // SQLite refused the write, which is the second line of defence
            // behind never running the migrator.
        }
        let snapshot = try await database.latestBatterySnapshot()
        XCTAssertEqual(snapshot?.levelPercent, 66, "the rejected write must not have landed")
    }

    func testReadOnlyOpenRejectsDatabaseFromANewerVoltscope() async throws {
        let database = try HistoryDatabase.makeTemporaryFile()
        let url = try XCTUnwrap(database.fileURL)
        takeOwnership(of: url)
        try await database.dbPool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v2_tiered_rework"])
        }

        do {
            _ = try HistoryDatabase.openReadOnly(url: url)
            XCTFail("an unknown migration must be refused")
        } catch let error as HistoryDatabaseOpenError {
            XCTAssertEqual(error, .migrationsUnrecognized(["v2_tiered_rework"], url))
        }
    }

    func testReadOnlyOpenRejectsDatabaseMissingThisBuildsMigrations() async throws {
        let database = try HistoryDatabase.makeTemporaryFile()
        let url = try XCTUnwrap(database.fileURL)
        takeOwnership(of: url)
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: [HistoryDatabase.registeredMigrationIdentifiers[0]])
        }

        do {
            _ = try HistoryDatabase.openReadOnly(url: url)
            XCTFail("a missing migration must be refused")
        } catch let error as HistoryDatabaseOpenError {
            XCTAssertEqual(error, .migrationsNotApplied(HistoryDatabase.registeredMigrationIdentifiers, url))
        }
    }

    func testReadOnlyOpenRejectsSomeOtherSQLiteFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.sqlite")
        temporaryDirectories.append(directory)
        let foreign = try DatabaseQueue(path: url.path)
        try await foreign.write { db in
            try db.execute(sql: "CREATE TABLE SomethingElse (id INTEGER PRIMARY KEY)")
        }

        do {
            _ = try HistoryDatabase.openReadOnly(url: url)
            XCTFail("a file with no migration record is not a Voltscope history database")
        } catch let error as HistoryDatabaseOpenError {
            XCTAssertEqual(error, .notAHistoryDatabase(url))
        }
    }

    func testReadOnlyOpenNeverCreatesAMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent("history.sqlite")

        do {
            _ = try HistoryDatabase.openReadOnly(url: url)
            XCTFail("a missing database must be refused")
        } catch let error as HistoryDatabaseOpenError {
            XCTAssertEqual(error, .fileMissing(url))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "reading must never create the database file")
    }

    func testSchemaStatusClassifiesEveryCombination() {
        let registered = ["v1_tiered", "v2_next"]
        XCTAssertEqual(HistoryDatabase.schemaStatus(applied: ["v1_tiered", "v2_next"], registered: registered), .upToDate)
        XCTAssertEqual(HistoryDatabase.schemaStatus(applied: ["v1_tiered"], registered: registered),
                       .migrationsNotApplied(["v2_next"]))
        XCTAssertEqual(HistoryDatabase.schemaStatus(applied: ["v1_tiered", "v2_next", "v3_later"], registered: registered),
                       .migrationsUnrecognized(["v3_later"]))
        XCTAssertEqual(HistoryDatabase.schemaStatus(applied: nil, registered: registered), .noMigrationRecord)
        // A newer Voltscope that renamed a migration leaves both an unknown and
        // a missing identifier. Only "update Voltscope" is actionable.
        XCTAssertEqual(HistoryDatabase.schemaStatus(applied: ["v1_tiered", "v3_renamed"], registered: registered),
                       .migrationsUnrecognized(["v3_renamed"]))
    }

    func testRegisteredMigrationIdentifiersComeFromTheMigrator() throws {
        XCTAssertEqual(HistoryDatabase.registeredMigrationIdentifiers, HistoryDatabase.migrator.migrations)
        XCTAssertFalse(HistoryDatabase.registeredMigrationIdentifiers.isEmpty)
    }
}

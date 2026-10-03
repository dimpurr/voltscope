import Foundation
import GRDB

/// The 0.10 tiered history store, backed by its own `history.sqlite` file.
///
/// This store is additive: the legacy `AppDatabase` keeps its file, its
/// schema, and its write path until the sampler is moved over. Nothing here
/// reads or writes `db.sqlite`.
public final class HistoryDatabase: @unchecked Sendable {
    /// GRDB's `DatabasePool` (file-backed, WAL) in production and a
    /// `DatabaseQueue` in tests. Both conform to `DatabaseWriter`, so the
    /// same write/read helpers work for either.
    public let dbPool: any DatabaseWriter

    /// Backing file URL, or `nil` for an in-memory database.
    public let fileURL: URL?

    // Process and hardware samples share one pending UTC-aligned window.
    let windowBuffer = HistoryWindowBuffer()

    public init(dbPool: any DatabaseWriter, fileURL: URL? = nil) throws {
        self.dbPool = dbPool
        self.fileURL = fileURL
        try Self.migrator.migrate(dbPool)
    }

    /// Opens the production database next to the legacy one and brings it up
    /// to date.
    public static func makeDefault() throws -> HistoryDatabase {
        let url = try AppPaths.historyDatabaseURL()
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try HistoryDatabase(dbPool: pool, fileURL: url)
    }

    /// In-memory store for tests. The auto-vacuum pragma is not observable
    /// on an in-memory database; use `makeTemporaryFile()` to assert on it.
    public static func makeInMemory() throws -> HistoryDatabase {
        let queue = try DatabaseQueue(configuration: makeConfiguration())
        return try HistoryDatabase(dbPool: queue)
    }

    /// File-backed store in a unique temporary directory, for tests that need
    /// a real database header (auto-vacuum, WAL). The caller owns the
    /// directory and may remove it via `fileURL`.
    public static func makeTemporaryFile() throws -> HistoryDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.sqlite", isDirectory: false)
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try HistoryDatabase(dbPool: pool, fileURL: url)
    }

    /// Shared connection setup.
    ///
    /// `auto_vacuum` has to be written before the file is switched to WAL and
    /// before the first table is created. Both happen after the connection is
    /// opened, so `prepareDatabase` is the only hook early enough.
    ///
    /// That hook also runs for the read-only connections `DatabasePool` opens
    /// to serve readers. A read-only connection is skipped: the writer has
    /// already stored the mode in the file header, and attempting the pragma
    /// there would only raise `SQLITE_READONLY`. On a writer the pragma is
    /// never swallowed, so a genuine write failure surfaces instead of
    /// silently leaving the file without incremental auto-vacuum.
    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            if db.configuration.readonly { return }
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        return config
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_tiered") { db in
            try db.execute(sql: tieredSchema)

            // Battery and power events keep the exact columns and keys of the
            // legacy file so the importer can copy rows across unchanged.
            try db.create(table: BatterySnapshot.databaseTableName) { t in
                t.column("timestamp", .integer).primaryKey()
                t.column("levelPercent", .double)
                t.column("capacityMAh", .integer)
                t.column("designMAh", .integer)
                t.column("cycleCount", .integer)
                t.column("voltageMV", .integer)
                t.column("amperageMA", .integer)
                t.column("temperatureC", .double)
                t.column("timeRemainingMin", .integer)
                t.column("isCharging", .boolean).notNull().defaults(to: false)
                t.column("isACPlugged", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: PowerEvent.databaseTableName) { t in
                t.column("timestamp", .integer).primaryKey()
                t.column("eventType", .text).notNull()
                t.column("durationSeconds", .integer)
                t.column("metadata", .text)
            }
        }

        return m
    }

    /// Tables and indexes of the tiered schema, created by `v1_tiered`.
    ///
    /// Times: `ts` is Unix epoch milliseconds; `minute` is epoch seconds / 60;
    /// `hour` is epoch seconds / 3600, UTC-aligned.
    private static let tieredSchema = """
        CREATE TABLE App (
            id INTEGER PRIMARY KEY,
            groupKey TEXT NOT NULL UNIQUE,
            bundleIdentifier TEXT,
            displayName TEXT NOT NULL,
            path TEXT,
            firstSeen INTEGER NOT NULL,
            lastSeen INTEGER NOT NULL
        );

        CREATE TABLE AppSampleRaw (
            ts INTEGER NOT NULL,
            appId INTEGER NOT NULL REFERENCES App(id),
            pid INTEGER NOT NULL,
            parentPid INTEGER,
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL,
            cpuNs INTEGER NOT NULL,
            wakeups INTEGER NOT NULL,
            diskReadBytes INTEGER NOT NULL,
            diskWriteBytes INTEGER NOT NULL
        );
        CREATE INDEX AppSampleRaw_ts ON AppSampleRaw(ts);

        CREATE TABLE AppUsageMinute (
            minute INTEGER NOT NULL,
            appId INTEGER NOT NULL,
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL,
            cpuNs INTEGER NOT NULL,
            wakeups INTEGER NOT NULL,
            diskReadBytes INTEGER NOT NULL,
            diskWriteBytes INTEGER NOT NULL,
            samples INTEGER NOT NULL,
            PRIMARY KEY (minute, appId, metricVersion)
        ) WITHOUT ROWID;

        CREATE TABLE AppUsageHour (
            hour INTEGER NOT NULL,
            appId INTEGER NOT NULL,
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL,
            cpuNs INTEGER NOT NULL,
            wakeups INTEGER NOT NULL,
            diskReadBytes INTEGER NOT NULL,
            diskWriteBytes INTEGER NOT NULL,
            samples INTEGER NOT NULL,
            PRIMARY KEY (hour, appId, metricVersion)
        ) WITHOUT ROWID;

        CREATE TABLE Bucket (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE
        );

        CREATE TABLE BucketSampleRaw (
            ts INTEGER NOT NULL,
            bucketId INTEGER NOT NULL REFERENCES Bucket(id),
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL
        );
        CREATE INDEX BucketSampleRaw_ts ON BucketSampleRaw(ts);

        CREATE TABLE BucketMinute (
            minute INTEGER NOT NULL,
            bucketId INTEGER NOT NULL,
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL,
            PRIMARY KEY (minute, bucketId, metricVersion)
        ) WITHOUT ROWID;

        CREATE TABLE BucketHour (
            hour INTEGER NOT NULL,
            bucketId INTEGER NOT NULL,
            metricVersion INTEGER NOT NULL,
            energyNJ INTEGER NOT NULL,
            PRIMARY KEY (hour, bucketId, metricVersion)
        ) WITHOUT ROWID;

        CREATE TABLE Coverage (
            ts INTEGER PRIMARY KEY,
            visible INTEGER NOT NULL,
            unreadable INTEGER NOT NULL
        );

        CREATE TABLE CoverageHour (
            hour INTEGER PRIMARY KEY,
            ticks INTEGER NOT NULL,
            visibleSum INTEGER NOT NULL,
            unreadableSum INTEGER NOT NULL
        );

        CREATE TABLE Meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}

/// Errors raised by `HistoryDatabase` helpers.
public enum HistoryDatabaseError: Error, Equatable {
    /// An upsert that must always produce a row returned none.
    case missingUpsertResult
}

extension HistoryDatabase {
    /// Inserts the group if it is new, otherwise widens the seen interval:
    /// `firstSeen` can only move earlier and `lastSeen` only later. This keeps
    /// the interval correct even when a writer with an older timestamp commits
    /// after a newer one. Returns `App.id`.
    @discardableResult
    public func upsertApp(
        _ db: Database,
        groupKey: String,
        bundleIdentifier: String?,
        displayName: String,
        path: String?,
        ts: Int64
    ) throws -> Int64 {
        let sql = """
            INSERT INTO App (groupKey, bundleIdentifier, displayName, path, firstSeen, lastSeen)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(groupKey) DO UPDATE SET
                firstSeen = MIN(firstSeen, excluded.firstSeen),
                lastSeen = MAX(lastSeen, excluded.lastSeen)
            RETURNING id
            """
        guard let id = try Int64.fetchOne(
            db,
            sql: sql,
            arguments: [groupKey, bundleIdentifier, displayName, path, ts, ts]
        ) else {
            throw HistoryDatabaseError.missingUpsertResult
        }
        return id
    }

    /// Transactional convenience wrapper around `upsertApp(_:...)`.
    @discardableResult
    public func upsertApp(
        groupKey: String,
        bundleIdentifier: String?,
        displayName: String,
        path: String?,
        ts: Int64
    ) async throws -> Int64 {
        try await dbPool.write { db in
            try upsertApp(
                db,
                groupKey: groupKey,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                path: path,
                ts: ts
            )
        }
    }

    /// Inserts the bucket if it is new. Returns `Bucket.id`, which is stable
    /// for a given name.
    @discardableResult
    public func upsertBucket(_ db: Database, name: String) throws -> Int64 {
        // The no-op update is what makes RETURNING yield the existing row on
        // conflict; DO NOTHING would return nothing.
        let sql = """
            INSERT INTO Bucket (name) VALUES (?)
            ON CONFLICT(name) DO UPDATE SET name = excluded.name
            RETURNING id
            """
        guard let id = try Int64.fetchOne(db, sql: sql, arguments: [name]) else {
            throw HistoryDatabaseError.missingUpsertResult
        }
        return id
    }

    /// Transactional convenience wrapper around `upsertBucket(_:name:)`.
    @discardableResult
    public func upsertBucket(name: String) async throws -> Int64 {
        try await dbPool.write { db in
            try upsertBucket(db, name: name)
        }
    }
}

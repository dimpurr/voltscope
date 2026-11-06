import Foundation
import GRDB

/// How the migrations recorded in a database compare with the migrations this
/// build registers.
public enum HistorySchemaStatus: Equatable, Sendable {
    /// This build's migrations are all recorded, and nothing else is.
    case upToDate
    /// This build registers migrations the file has not recorded. The file is
    /// older than the code reading it, and only Voltscope itself may apply
    /// them.
    case migrationsNotApplied([String])
    /// The file records migrations this build has never heard of. It was
    /// written by a newer Voltscope.
    case migrationsUnrecognized([String])
    /// No `grdb_migrations` table: the file is not a Voltscope history store.
    case noMigrationRecord
}

/// Why a history database cannot be read by this build. The command-line tool
/// prints `errorDescription` and maps each case to its documented exit code.
public enum HistoryDatabaseOpenError: LocalizedError, Equatable {
    /// There is no file at that path. Nothing was created.
    case fileMissing(URL)
    /// The file exists but SQLite refused to open it read-only.
    case unreadable(URL, reason: String)
    /// The file has no migration record, so its schema is unknown.
    case notAHistoryDatabase(URL)
    /// The file is older than this build.
    case migrationsNotApplied([String], URL)
    /// The file is newer than this build.
    case migrationsUnrecognized([String], URL)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let url):
            return "No Voltscope history database at \(url.path). Start Voltscope once to create it, or point VOLTSCOPE_DB_PATH at a history.sqlite file."
        case .unreadable(let url, let reason):
            return "Cannot open the Voltscope history database at \(url.path): \(reason)"
        case .notAHistoryDatabase(let url):
            return "The file at \(url.path) has no Voltscope migration record, so its schema is unknown. Point VOLTSCOPE_DB_PATH at a history.sqlite file written by Voltscope 0.10 or later."
        case .migrationsNotApplied(let missing, let url):
            return "The history database at \(url.path) is missing migrations this tool expects: \(missing.joined(separator: ", ")). Start Voltscope to bring it up to date."
        case .migrationsUnrecognized(let unknown, let url):
            return "The history database at \(url.path) was written by a newer Voltscope: it records migrations it does not know about (\(unknown.joined(separator: ", "))). Update Voltscope and run the command line tool it ships."
        }
    }
}

extension HistoryDatabase {
    /// Migration identifiers this build registers, oldest first. Read from the
    /// migrator itself so the compatibility check cannot drift from it.
    static var registeredMigrationIdentifiers: [String] { migrator.migrations }

    /// Opens an existing history database without writing anything.
    ///
    /// This is the path for a process that must not change the store, such as
    /// the command-line tool. Unlike `init(dbPool:fileURL:)` it never runs the
    /// migrator, so it cannot create a table or a `Meta` row; a missing path is
    /// an error, not an invitation to create one. The recorded
    /// migrations are checked instead, and an unreadable schema is refused.
    ///
    /// The database file and its WAL content are not written. SQLite may create
    /// or refresh the empty `-wal` and `-shm` peer files when it opens a
    /// WAL-mode database, even read-only; they carry no stored data.
    ///
    /// - Throws: `HistoryDatabaseOpenError` when the file is missing, cannot be
    ///   opened, or its schema is not readable by this build.
    public static func openReadOnly(url: URL) throws -> HistoryDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HistoryDatabaseOpenError.fileMissing(url)
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5.0)
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path, configuration: configuration)
        } catch {
            throw HistoryDatabaseOpenError.unreadable(url, reason: error.localizedDescription)
        }
        let database = HistoryDatabase(unmigrated: pool, fileURL: url)
        let status = try Self.readSchemaStatus(pool)
        switch status {
        case .upToDate:
            return database
        case .migrationsNotApplied(let missing):
            throw HistoryDatabaseOpenError.migrationsNotApplied(missing, url)
        case .migrationsUnrecognized(let unknown):
            throw HistoryDatabaseOpenError.migrationsUnrecognized(unknown, url)
        case .noMigrationRecord:
            throw HistoryDatabaseOpenError.notAHistoryDatabase(url)
        }
    }

    /// Compares the recorded migrations with this build. Callers that opened the
    /// database some other way can inspect the schema without a thrown error.
    public func schemaStatus() async throws -> HistorySchemaStatus {
        let registered = Self.registeredMigrationIdentifiers
        return try await dbPool.read { db in try Self.schemaStatus(in: db, registered: registered) }
    }

    private static func readSchemaStatus(_ pool: DatabasePool) throws -> HistorySchemaStatus {
        let registered = registeredMigrationIdentifiers
        // A blocking read: GRDB's async overload is not reachable from the
        // synchronous opening path, and this process never writes.
        return try pool.read { db in try schemaStatus(in: db, registered: registered) }
    }

    private static func schemaStatus(in db: Database, registered: [String]) throws -> HistorySchemaStatus {
        guard try db.tableExists("grdb_migrations") else { return .noMigrationRecord }
        return schemaStatus(applied: try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
                            registered: registered)
    }

    /// Unknown migrations win over missing ones: when a newer Voltscope renamed
    /// a migration, "update Voltscope" is the only actionable answer.
    static func schemaStatus(applied: [String]?, registered: [String]) -> HistorySchemaStatus {
        guard let applied else { return .noMigrationRecord }
        let appliedSet = Set(applied)
        let unknown = appliedSet.subtracting(registered).sorted()
        guard unknown.isEmpty else { return .migrationsUnrecognized(unknown) }
        let missing = Set(registered).subtracting(appliedSet).sorted()
        guard missing.isEmpty else { return .migrationsNotApplied(missing) }
        return .upToDate
    }
}

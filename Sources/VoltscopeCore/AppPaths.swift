import Foundation

public enum AppPaths {
    public static let supportDirectoryName = "Voltscope"

    /// - Parameter create: When `false`, nothing is created on disk. A reader
    ///   that must leave the filesystem untouched (the command line tool) uses
    ///   this so a missing folder stays missing instead of being made.
    public static func applicationSupportDirectory(create: Bool = true) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let dir = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func databaseURL(create: Bool = true) throws -> URL {
        try applicationSupportDirectory(create: create).appendingPathComponent("db.sqlite", isDirectory: false)
    }

    /// Tiered history store introduced in 0.10. Lives next to the legacy
    /// database; the two files are independent.
    public static func historyDatabaseURL(create: Bool = true) throws -> URL {
        try applicationSupportDirectory(create: create).appendingPathComponent("history.sqlite", isDirectory: false)
    }
}

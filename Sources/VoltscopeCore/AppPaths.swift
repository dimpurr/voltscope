import Foundation

public enum AppPaths {
    public static let supportDirectoryName = "Voltscope"

    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("db.sqlite", isDirectory: false)
    }
}

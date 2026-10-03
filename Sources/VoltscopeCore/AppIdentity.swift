import Foundation

/// Stable identity for bundle-less CLI processes whose executable is version-named.
public enum AppIdentity {
    public struct Resolved: Equatable, Sendable {
        public let groupKey: String
        public let displayName: String
    }

    private static let containerDirectories: Set<String> = [
        "versions", "version", "bin", "sbin", "lib", "libexec", "contents", "macos", "current"
    ]

    private static let sharedLocationDirectories: Set<String> = [
        "usr", "local", "opt", "homebrew", "share", ".local", "applications", "library",
        "cellar", "helpers", "frameworks", "users", "home", "tmp", "private", "var",
        "etc", "system", "volumes", "resources", "support", "vendor"
    ]

    /// Keeps bundle IDs authoritative and otherwise groups only numeric, dotted
    /// executable filenames under their nearest meaningful ancestor directory.
    public static func resolve(bundleIdentifier: String?, processName: String, path: String?) -> Resolved {
        if let bundleIdentifier {
            return Resolved(groupKey: bundleIdentifier, displayName: processName)
        }
        guard let path, let slug = versionedExecutableSlug(path: path) else {
            return Resolved(groupKey: processName, displayName: processName)
        }
        let displayName = slug == "claude" ? "Claude Code" : titleCased(slug)
        let executableName = URL(fileURLWithPath: path).lastPathComponent
        guard processName == executableName || processName == displayName else {
            return Resolved(groupKey: processName, displayName: processName)
        }
        return Resolved(groupKey: "cli:\(slug)", displayName: displayName)
    }

    /// Returns the normalized meaningful directory for a pure dotted numeric filename.
    /// Shared locations and direct children of user roots are too broad to identify an app.
    public static func versionedExecutableSlug(path: String) -> String? {
        let executable = URL(fileURLWithPath: path).lastPathComponent
        let components = executable.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else {
            return nil
        }

        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<16 {
            let name = directory.lastPathComponent
            guard !name.isEmpty, name != "/" else { return nil }
            if !containerDirectories.contains(name.lowercased()) {
                let normalizedName = name.lowercased()
                let parentName = directory.deletingLastPathComponent().lastPathComponent.lowercased()
                guard !sharedLocationDirectories.contains(normalizedName),
                      parentName != "users", parentName != "home" else {
                    return nil
                }
                return normalizedName
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }

    private static func titleCased(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

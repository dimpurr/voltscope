import Foundation

/// Stable identity for bundle-less CLI processes whose executable is version-named.
public enum AppIdentity {
    public struct Resolved: Equatable, Sendable {
        public let groupKey: String
        public let displayName: String
    }

    private static let sharedLocationDirectories: Set<String> = [
        "usr", "local", "opt", "homebrew", "share", ".local", "applications", "library",
        "application support", "cellar", "helpers", "frameworks", "users", "home", "tmp", "private", "var",
        "etc", "system", "volumes", "resources", "support", "vendor"
    ]

    /// Keeps bundle IDs authoritative and otherwise groups only numeric, dotted
    /// executable filenames in a named `versions` directory.
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

    /// Returns the normalized app directory for a pure dotted numeric filename
    /// directly inside a `versions` directory.
    public static func versionedExecutableSlug(path: String) -> String? {
        let executable = URL(fileURLWithPath: path).lastPathComponent
        guard isDottedNumericVersion(executable) else {
            return nil
        }

        let versionsDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard versionsDirectory.lastPathComponent.lowercased() == "versions" else { return nil }

        let nameDirectory = versionsDirectory.deletingLastPathComponent()
        let name = nameDirectory.lastPathComponent
        let normalizedName = name.lowercased()
        guard !name.isEmpty, name != "/",
              !isDottedNumericVersion(name),
              !sharedLocationDirectories.contains(normalizedName) else { return nil }
        return normalizedName
    }

    private static func isDottedNumericVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
    }

    private static func titleCased(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

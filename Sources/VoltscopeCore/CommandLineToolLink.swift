import Foundation

/// The link the app manages so a shell can find the bundled command line tool.
///
/// The tool ships inside the bundle at `Contents/Helpers/voltscope`. Rather than
/// copy it somewhere, or ask for administrator rights, the app puts a symbolic
/// link at `~/.local/bin/voltscope` that points at the helper in place. A Sparkle
/// update replaces the bundle's contents but keeps the bundle path, so the link
/// stays valid across updates.
///
/// Both paths are inputs, so a test can point the whole thing at a temporary
/// directory and never touch a real `~/.local/bin`.
public struct CommandLineToolLink: Equatable, Sendable {
    /// What the user types, and the name of the link.
    public static let toolName = "voltscope"

    /// `~/.local/bin`, the user-writable directory the default PATH already offers.
    public static let defaultLinkDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)

    /// The helper inside the running bundle: `Voltscope.app/Contents/Helpers/voltscope`.
    public static var defaultHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(toolName)
    }

    public let helperURL: URL
    public let linkDirectoryURL: URL

    /// The link this instance manages: `<linkDirectory>/voltscope`.
    public var linkURL: URL {
        linkDirectoryURL.appendingPathComponent(Self.toolName)
    }

    public init(helperURL: URL = CommandLineToolLink.defaultHelperURL,
                linkDirectoryURL: URL = CommandLineToolLink.defaultLinkDirectoryURL) {
        self.helperURL = helperURL
        self.linkDirectoryURL = linkDirectoryURL
    }

    /// What already sits at the link path.
    public enum State: Equatable, Sendable {
        /// Nothing there. Install can create the link.
        case absent
        /// A link to this bundle's helper, which is the installed state.
        case pointsToHelper
        /// A link to somewhere else, so installing means overwriting it.
        case pointsElsewhere(destinationPath: String)
        /// A plain file or a directory. Not something the app may delete, even
        /// after a confirmation, because it is not a link the app could restore.
        case occupiedByOtherItem
        /// This build has no helper binary, so there is nothing to link to.
        case helperUnavailable
    }

    /// Everything the Settings screen needs to describe the current situation.
    public struct Status: Equatable, Sendable {
        public let state: State
        /// Whether `~/.local/bin` exists yet. Install creates it when it does not.
        public let linkDirectoryExists: Bool
        /// Whether the link directory is on the PATH that was tested. A link is
        /// still usable by its absolute path when this is false; only a bare
        /// `voltscope` fails to resolve.
        public let onPath: Bool

        public init(state: State, linkDirectoryExists: Bool, onPath: Bool) {
            self.state = state
            self.linkDirectoryExists = linkDirectoryExists
            self.onPath = onPath
        }
    }

    /// Reads the link and the PATH without changing anything.
    ///
    /// - Parameter pathValue: the `PATH` to test against. Defaults to this
    ///   process's environment; a test passes its own string.
    public func status(
        pathValue: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> Status {
        Status(
            state: currentState,
            linkDirectoryExists: FileManager.default.fileExists(atPath: linkDirectoryURL.path),
            onPath: Self.pathDirectories(from: pathValue).contains(directoryPath)
        )
    }

    /// Creates the link, and the link directory if it is missing.
    ///
    /// - Parameter overwriteExisting: the caller asked the user first and the
    ///   user agreed to replace the link already there. Without it an existing
    ///   link to somewhere else is an error, never a silent replacement. An item
    ///   that is not a link is always an error.
    @discardableResult
    public func install(overwriteExisting: Bool = false) throws -> Status {
        switch currentState {
        case .helperUnavailable:
            throw CommandLineToolLinkError.helperUnavailable(path: helperURL.path)
        case .occupiedByOtherItem:
            throw CommandLineToolLinkError.itemInWay(path: linkURL.path)
        default:
            break
        }
        if !FileManager.default.fileExists(atPath: linkDirectoryURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: linkDirectoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw CommandLineToolLinkError.cannotCreateDirectory(
                    path: linkDirectoryURL.path, message: error.localizedDescription
                )
            }
        }
        switch currentState {
        case .absent:
            try createLink()
        case .pointsToHelper:
            break  // Already installed: leave the existing link alone.
        case .pointsElsewhere:
            guard overwriteExisting else { throw CommandLineToolLinkError.linkExists(path: linkURL.path) }
            try removeLink()
            try createLink()
        default:
            break  // The switch above rejected everything else.
        }
        return status()
    }

    /// Removes the link, and only the link this app made.
    ///
    /// Nothing at all is not an error, so uninstalling twice is safe. Anything
    /// else at the path is left exactly where it is and reported: a link to
    /// another command may be one the user built by hand, and an item that is not
    /// a link is never the app's to delete. The helper in the bundle and anything
    /// a removed link pointed at stay on disk.
    public func uninstall() throws {
        switch currentState {
        case .absent:
            break  // Nothing to remove.
        case .pointsToHelper:
            try removeLink()
        case .pointsElsewhere(let destination):
            throw CommandLineToolLinkError.linkNotMadeByThisApp(path: linkURL.path,
                                                                destination: destination)
        case .occupiedByOtherItem:
            throw CommandLineToolLinkError.itemInWay(path: linkURL.path)
        case .helperUnavailable:
            break  // This build cannot tell its own link from another one, so it touches nothing.
        }
    }

    /// The shell line that puts the link directory on PATH.
    public var pathExportLine: String {
        "export PATH=\"\(directoryPath):$PATH\""
    }

    /// The link path with the home folder shown as `~`, for prose.
    public var linkDisplayPath: String { Self.displayPath(of: linkURL) }

    /// The link directory with the home folder shown as `~`, for prose.
    public var linkDirectoryDisplayPath: String { Self.displayPath(of: linkDirectoryURL) }

    /// Shortens a path inside the user's home folder to `~`-form for display.
    public static func displayPath(of url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Splits a `PATH` into the absolute directory paths it names, expanding a
    /// leading `~` the way a shell would.
    public static func pathDirectories(from pathValue: String?) -> [String] {
        guard let pathValue else { return [] }
        return pathValue
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { entry in
                let text = String(entry)
                let expanded = text == "~" || text.hasPrefix("~/")
                    ? (text as NSString).expandingTildeInPath
                    : text
                return URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
    }

    // MARK: - Filesystem

    private var directoryPath: String { linkDirectoryURL.standardizedFileURL.path }

    private var helperPath: String { helperURL.standardizedFileURL.path }

    private var currentState: State {
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return .helperUnavailable }
        // Ask about the link before asking about the file, because a link whose
        // destination has disappeared is still a link.
        if let destination = linkDestinationPath {
            return destination == helperPath
                ? .pointsToHelper
                : .pointsElsewhere(destinationPath: destination)
        }
        guard FileManager.default.fileExists(atPath: linkURL.path) else { return .absent }
        return .occupiedByOtherItem
    }

    /// Where the link points, resolved against the directory holding it. Nil when
    /// the path is not a symbolic link.
    private var linkDestinationPath: String? {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: linkURL.path) else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: linkURL.deletingLastPathComponent())
            .standardizedFileURL.path
    }

    private func createLink() throws {
        do {
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: helperURL)
        } catch {
            throw CommandLineToolLinkError.cannotCreateLink(
                path: linkURL.path, message: error.localizedDescription
            )
        }
    }

    /// Unlinks the link path itself. `removeItem` does not follow a symbolic
    /// link, so the destination is never touched.
    private func removeLink() throws {
        do {
            try FileManager.default.removeItem(at: linkURL)
        } catch {
            throw CommandLineToolLinkError.cannotRemove(
                path: linkURL.path, message: error.localizedDescription
            )
        }
    }
}

public enum CommandLineToolLinkError: LocalizedError, Equatable {
    case helperUnavailable(path: String)
    case linkExists(path: String)
    case linkNotMadeByThisApp(path: String, destination: String)
    case itemInWay(path: String)
    case cannotCreateDirectory(path: String, message: String)
    case cannotCreateLink(path: String, message: String)
    case cannotRemove(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable(let path):
            return "This Voltscope build has no command line tool at \(path)."
        case .linkExists(let path):
            return "A link to another command is already at \(path). Replace it, or remove it first."
        case .linkNotMadeByThisApp(let path, let destination):
            return "The link at \(path) points at \(destination), not at this copy of Voltscope, so it was left in place. Remove it yourself if you want it gone."
        case .itemInWay(let path):
            return "There is something at \(path) that is not a link. Move it out of the way first."
        case .cannotCreateDirectory(let path, let message):
            return "Could not create \(path): \(message)"
        case .cannotCreateLink(let path, let message):
            return "Could not create \(path): \(message)"
        case .cannotRemove(let path, let message):
            return "Could not remove \(path): \(message)"
        }
    }
}

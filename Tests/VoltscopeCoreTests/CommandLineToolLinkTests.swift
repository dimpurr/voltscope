import Darwin
import Foundation
import XCTest
@testable import VoltscopeCore

/// The Settings button writes one symbolic link in the user's own home
/// directory. These tests run against a temporary directory instead of a real
/// `~/.local/bin`: the link is created, recognised, replaced only after a
/// confirmation, and removed without ever touching the helper or a file the
/// user put there.
final class CommandLineToolLinkTests: XCTestCase {
    private var root: URL!
    private var helperURL: URL!
    private var linkDirectoryURL: URL!

    override func setUpWithError() throws {
        // A fresh directory per test, so no test can see another test's link.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandLineToolLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
        helperURL = base.appendingPathComponent("Voltscope.app/Contents/Helpers/voltscope")
        linkDirectoryURL = base.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The helper is any file here; the link logic only follows paths.
        try Data("helper".utf8).write(to: helperURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLink() -> CommandLineToolLink {
        CommandLineToolLink(helperURL: helperURL, linkDirectoryURL: linkDirectoryURL)
    }

    // MARK: - Reading the state

    func testNothingInstalledReportsAbsentAndNoDirectory() throws {
        let status = makeLink().status()

        XCTAssertEqual(status.state, .absent)
        XCTAssertFalse(status.linkDirectoryExists)
        XCTAssertFalse(status.onPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkDirectoryURL.path))
    }

    func testInstallCreatesTheDirectoryAndALinkToTheHelper() throws {
        let link = makeLink()

        let status = try link.install()

        XCTAssertTrue(status.linkDirectoryExists)
        XCTAssertEqual(status.state, .pointsToHelper)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path)
        XCTAssertEqual(URL(fileURLWithPath: destination).standardizedFileURL.path, helperURL.path)
        // Reading through the link reaches the helper, so the shell runs the tool.
        XCTAssertEqual(try Data(contentsOf: link.linkURL), try Data(contentsOf: helperURL))
    }

    func testInstallingAgainKeepsTheExistingLink() throws {
        let link = makeLink()
        try link.install()
        let firstDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path)

        let status = try link.install()

        XCTAssertEqual(status.state, .pointsToHelper)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path),
            firstDestination
        )
    }

    func testARelativeLinkToTheSameHelperCountsAsInstalled() throws {
        // Someone hand-made the link with a relative path. It still resolves to
        // this bundle's helper, so the button must say it is already installed.
        let shallowHelper = root.appendingPathComponent("tool")
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: shallowHelper)
        XCTAssertEqual(
            symlink("../../tool", linkDirectoryURL.appendingPathComponent("voltscope").path),
            0,
            "the test needs a relative symbolic link"
        )

        let link = CommandLineToolLink(helperURL: shallowHelper, linkDirectoryURL: linkDirectoryURL)

        XCTAssertEqual(link.status().state, .pointsToHelper)
    }

    func testALinkToAnotherCommandIsReportedAndKept() throws {
        let other = root.appendingPathComponent("other-tool")
        try Data("other".utf8).write(to: other)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: makeLink().linkURL, withDestinationURL: other)

        let link = makeLink()
        XCTAssertThrowsError(try link.install()) { error in
            XCTAssertEqual(error as? CommandLineToolLinkError, .linkExists(path: link.linkURL.path))
        }
        XCTAssertEqual(link.status().state, .pointsElsewhere(destinationPath: other.standardizedFileURL.path))
        // The refusal must not have destroyed the user's link.
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path),
            other.path
        )
    }

    func testConfirmedInstallReplacesALinkToAnotherCommand() throws {
        let other = root.appendingPathComponent("other-tool")
        try Data("other".utf8).write(to: other)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: makeLink().linkURL, withDestinationURL: other)

        let status = try makeLink().install(overwriteExisting: true)

        XCTAssertEqual(status.state, .pointsToHelper)
        // What the old link pointed at is nobody else's business but its own.
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testADanglingLinkIsNotTreatedAsNothingInstalled() throws {
        let gone = root.appendingPathComponent("deleted-tool")
        try Data("other".utf8).write(to: gone)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        let link = makeLink()
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: gone)
        try FileManager.default.removeItem(at: gone)

        guard case .pointsElsewhere = link.status().state else {
            return XCTFail("a broken link must still be reported as a link, not as free space")
        }
        XCTAssertThrowsError(try link.install())
    }

    func testAPlainFileInTheWayIsNeverReplaced() throws {
        let link = makeLink()
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try Data("my own script".utf8).write(to: link.linkURL)

        XCTAssertEqual(link.status().state, .occupiedByOtherItem)
        XCTAssertThrowsError(try link.install()) { error in
            XCTAssertEqual(error as? CommandLineToolLinkError, .itemInWay(path: link.linkURL.path))
        }
        // Not even a confirmed install may delete a file the user wrote.
        XCTAssertThrowsError(try link.install(overwriteExisting: true))
        XCTAssertEqual(try String(contentsOf: link.linkURL, encoding: .utf8), "my own script")
    }

    func testABuildWithoutTheHelperInstallsNothing() throws {
        let missing = root.appendingPathComponent("Voltscope.app/Contents/Helpers/voltscope-next-release")
        let link = CommandLineToolLink(helperURL: missing, linkDirectoryURL: linkDirectoryURL)

        XCTAssertEqual(link.status().state, .helperUnavailable)
        XCTAssertThrowsError(try link.install()) { error in
            XCTAssertEqual(error as? CommandLineToolLinkError, .helperUnavailable(path: missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkDirectoryURL.path))
    }

    // MARK: - Removing the link

    func testUninstallRemovesOnlyTheLink() throws {
        let link = makeLink()
        try link.install()

        try link.uninstall()

        XCTAssertEqual(link.status().state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.linkURL.path))
        // The helper stays in the bundle, and the directory the user owns stays too.
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkDirectoryURL.path))
    }

    func testUninstallIsIdempotentWhenNothingIsInstalled() throws {
        let link = makeLink()

        try link.uninstall()
        try link.uninstall()

        XCTAssertEqual(link.status().state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkDirectoryURL.path),
                       "removing nothing must not create the link directory")
    }

    func testUninstallRefusesALinkThatPointsElsewhere() throws {
        let other = root.appendingPathComponent("other-tool")
        try Data("other".utf8).write(to: other)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        let link = makeLink()
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: other)

        XCTAssertThrowsError(try link.uninstall()) { error in
            XCTAssertEqual(
                error as? CommandLineToolLinkError,
                .linkNotMadeByThisApp(path: link.linkURL.path, destination: other.standardizedFileURL.path)
            )
        }
        // A link the user made by hand stays exactly where it is, and so does the
        // command it points at.
        XCTAssertEqual(link.status().state, .pointsElsewhere(destinationPath: other.standardizedFileURL.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path), other.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testUninstallNeverDeletesAPlainFile() throws {
        let link = makeLink()
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try Data("my own script".utf8).write(to: link.linkURL)

        XCTAssertThrowsError(try link.uninstall()) { error in
            XCTAssertEqual(error as? CommandLineToolLinkError, .itemInWay(path: link.linkURL.path))
        }

        XCTAssertEqual(try String(contentsOf: link.linkURL, encoding: .utf8), "my own script")
    }

    // MARK: - PATH

    private var directoryPath: String { linkDirectoryURL.standardizedFileURL.path }

    func testOnPathFollowsTheDirectoryListedInTheEnvironment() throws {
        let link = makeLink()

        XCTAssertTrue(link.status(pathValue: "/usr/bin:\(directoryPath)").onPath)
        XCTAssertFalse(link.status(pathValue: "/usr/bin:/bin").onPath)
        XCTAssertFalse(link.status(pathValue: "").onPath)
        XCTAssertFalse(link.status(pathValue: nil).onPath)
    }

    func testPATHMatchingIgnoresTrailingSlashesAndExpandsTilde() throws {
        XCTAssertTrue(makeLink().status(pathValue: "\(directoryPath)/").onPath)

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertEqual(
            CommandLineToolLink.pathDirectories(from: "~/bin:/usr/bin:"),
            [home + "/bin", "/usr/bin"]
        )
    }

    func testPathExportLineNamesTheLinkDirectory() throws {
        XCTAssertTrue(makeLink().pathExportLine.contains(directoryPath))
        XCTAssertTrue(makeLink().pathExportLine.hasPrefix("export PATH=\""))
    }

    func testDisplayPathShortensTheHomeFolderButLeavesOthersAlone() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = home.appendingPathComponent(".local/bin/voltscope")
        XCTAssertEqual(CommandLineToolLink.displayPath(of: inside), "~/.local/bin/voltscope")
        XCTAssertEqual(CommandLineToolLink.displayPath(of: URL(fileURLWithPath: "/usr/local/bin/voltscope")),
                       "/usr/local/bin/voltscope")
        XCTAssertEqual(makeLink().linkDisplayPath, makeLink().linkDirectoryDisplayPath + "/voltscope")
    }

    func testTheDefaultLinkDirectoryIsLocalBinInTheHomeFolder() {
        XCTAssertEqual(
            CommandLineToolLink.defaultLinkDirectoryURL.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true).path
        )
        XCTAssertEqual(CommandLineToolLink.toolName, "voltscope")
    }
}

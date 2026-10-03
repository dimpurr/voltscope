import XCTest
@testable import VoltscopeCore

final class AppIdentityTests: XCTestCase {
    func testGroupsVersionedClaudeExecutablesByMeaningfulParent() {
        for version in ["2.1.286", "2.1.287"] {
            let resolved = AppIdentity.resolve(bundleIdentifier: nil, processName: version,
                                               path: "/Users/example/.local/share/claude/versions/\(version)")
            XCTAssertEqual(resolved.groupKey, "cli:claude")
            XCTAssertEqual(resolved.displayName, "Claude Code")
        }
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "Claude Code",
                                           path: "/Users/example/.local/share/claude/versions/2.1.287").groupKey,
                       "cli:claude")
    }

    func testGroupsOnlyVersionedExecutableInsideNamedVersionsDirectory() {
        let claude = AppIdentity.resolve(bundleIdentifier: nil, processName: "2.1.287",
                                         path: "/opt/claude/versions/2.1.287")
        XCTAssertEqual(claude.groupKey, "cli:claude")
        XCTAssertEqual(claude.displayName, "Claude Code")

        let caseInsensitive = AppIdentity.resolve(bundleIdentifier: nil, processName: "3.4.1",
                                                  path: "/opt/acme-tool/VeRsIoNs/3.4.1")
        XCTAssertEqual(caseInsensitive.groupKey, "cli:acme-tool")
        XCTAssertEqual(caseInsensitive.displayName, "Acme Tool")
    }

    func testDoesNotGroupExecutableOutsideVersionsDirectory() {
        let resolved = AppIdentity.resolve(bundleIdentifier: nil, processName: "3.4.1",
                                           path: "/opt/acme-tool/bin/3.4.1")
        XCTAssertEqual(resolved, AppIdentity.Resolved(groupKey: "3.4.1", displayName: "3.4.1"))
    }

    func testRejectsReviewPathsOutsideExactVersionsShape() {
        let paths = [
            "/opt/homebrew/Cellar/ripgrep/14.1.1/bin/14.1.1",
            "/opt/homebrew/Cellar/fd/14.1.1/bin/14.1.1",
            "/opt/2.1.287/bin/1.0.0",
            "/tmp/2.1.287/bin/9.8.7",
            "/Library/Application Support/bin/1.0.0",
            "/Library/Application Support/bin/2.0.0",
            "/usr/local/bin/1.0.0",
            "/usr/local/bin/2.0.0",
            "/usr/bin/1.0.0",
            "/usr/libexec/4.5.6",
            "/Users/claude/bin/1.0.0"
        ]
        for path in paths {
            XCTAssertNil(AppIdentity.versionedExecutableSlug(path: path), "Unexpected CLI group for \(path)")
        }
    }

    func testRejectsVersionShapedAndSharedAppNamesInsideVersionsDirectory() {
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/opt/2.1.287/versions/1.0.0"))
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/opt/Application Support/versions/1.0.0"))
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/opt/application support/versions/1.0.0"))
    }

    func testDoesNotGroupVersionsUnderSharedLocalDirectory() {
        for version in ["1.0.0", "2.0.0"] {
            XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/usr/local/bin/\(version)"))
            XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: version,
                                               path: "/usr/local/bin/\(version)").groupKey, version)
        }
    }

    func testDoesNotGroupVersionsUnderSharedUsrDirectory() {
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/usr/bin/1.0.0"))
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: "/usr/libexec/4.5.6"))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "1.0.0",
                                           path: "/usr/bin/1.0.0").groupKey, "1.0.0")
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "4.5.6",
                                           path: "/usr/libexec/4.5.6").groupKey, "4.5.6")
    }

    func testDoesNotGroupUserDirectoryChildAsClaude() {
        let path = "/Users/claude/bin/1.0.0"
        XCTAssertNil(AppIdentity.versionedExecutableSlug(path: path))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "1.0.0", path: path),
                       AppIdentity.Resolved(groupKey: "1.0.0", displayName: "1.0.0"))
    }

    func testDoesNotInferForOrdinaryOrAmbiguousNamesAndPaths() {
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "claude",
                                           path: "/Users/example/.local/share/claude/bin/claude"),
                       AppIdentity.Resolved(groupKey: "claude", displayName: "claude"))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "v2.1.287",
                                           path: "/opt/tool/v2.1.287"),
                       AppIdentity.Resolved(groupKey: "v2.1.287", displayName: "v2.1.287"))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "2.1-beta",
                                           path: "/opt/tool/2.1-beta"),
                       AppIdentity.Resolved(groupKey: "2.1-beta", displayName: "2.1-beta"))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "2.1.287",
                                           path: "/versions/2.1.287"),
                       AppIdentity.Resolved(groupKey: "2.1.287", displayName: "2.1.287"))
        XCTAssertEqual(AppIdentity.resolve(bundleIdentifier: nil, processName: "worker",
                                           path: "/opt/tool/2.1.287"),
                       AppIdentity.Resolved(groupKey: "worker", displayName: "worker"))
    }

    func testBundleIdentityRemainsAuthoritative() {
        let resolved = AppIdentity.resolve(bundleIdentifier: "com.example.claude", processName: "2.1.287",
                                           path: "/Users/example/.local/share/claude/versions/2.1.287")
        XCTAssertEqual(resolved, AppIdentity.Resolved(groupKey: "com.example.claude", displayName: "2.1.287"))
    }

    func testRecognizedVersionedCLIIsClassifiedAsUserApp() {
        XCTAssertFalse(AppClassification.isSystem(bundleIdentifier: nil, processName: "2.1.287",
                                                  path: "/Users/example/.local/share/claude/versions/2.1.287"))
        XCTAssertTrue(AppClassification.isSystem(bundleIdentifier: nil, processName: "worker",
                                                 path: "/opt/tool/2.1.287"))
        XCTAssertTrue(AppClassification.isSystem(bundleIdentifier: nil, processName: "launchd",
                                                 path: "/sbin/launchd"))
    }
}

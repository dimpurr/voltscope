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

    func testGroupsGenericVersionedExecutableByMeaningfulParent() {
        let resolved = AppIdentity.resolve(bundleIdentifier: nil, processName: "3.4.1",
                                           path: "/opt/acme-tool/bin/3.4.1")
        XCTAssertEqual(resolved.groupKey, "cli:acme-tool")
        XCTAssertEqual(resolved.displayName, "Acme Tool")
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
        XCTAssertTrue(AppClassification.isSystem(bundleIdentifier: nil, processName: "launchd",
                                                 path: "/sbin/launchd"))
    }
}

import XCTest
import VoltscopeCore
@testable import voltscope_cli

/// A window has to land on the bucket width the History window would use, or the
/// tool's numbers stop agreeing with the app.
final class CLIArgumentsTests: XCTestCase {
    private func range(for text: String) throws -> HistoryRange {
        try XCTUnwrap(CLIDuration.parse(text)).historyRange
    }

    func testDocumentedWindowsUseTheRangesTheyMatch() throws {
        XCTAssertEqual(try range(for: "30m"), .live)
        XCTAssertEqual(try range(for: "1h"), .h1)
        XCTAssertEqual(try range(for: "6h"), .h6)
        XCTAssertEqual(try range(for: "1d"), .h24)
        XCTAssertEqual(try range(for: "7d"), .d7)
    }

    func testExactWindowsMatchAHistoryRangeWindow() throws {
        for text in ["30m", "1h", "6h", "1d", "7d"] {
            let duration = try XCTUnwrap(CLIDuration.parse(text))
            XCTAssertTrue(HistoryRange.allCases.contains { $0.minutes == duration.minutes },
                          "\(text) should be a range's own window")
        }
    }

    func testOtherWindowsTakeTheNarrowestRangeAtLeastAsWide() throws {
        XCTAssertEqual(try range(for: "5m"), .live)
        XCTAssertEqual(try range(for: "31m"), .h1)
        XCTAssertEqual(try range(for: "2h"), .h6)
        XCTAssertEqual(try range(for: "90m"), .h6)
        XCTAssertEqual(try range(for: "7h"), .h24)
        // Wider than any range the interface offers: keep the week's buckets.
        XCTAssertEqual(try range(for: "30d"), .d7)
        XCTAssertEqual(try range(for: "8d"), .d7)
    }

    func testWindowLengthsAreCountedInMinutesNotSeconds() throws {
        // `AppUsageHour.hour` and `*Minute.minute` are indices since the epoch,
        // so a window read as seconds would be off by a factor of 60 or 3600.
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("1d")).minutes, 1_440)
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("1d")).seconds, 86_400)
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("30d")).minutes, 43_200)
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("6h")).minutes, 360)
    }

    func testWindowLabelsReadLikeEnglish() throws {
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("1d")).label, "1 day")
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("30d")).label, "30 days")
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("6h")).label, "6 hours")
        XCTAssertEqual(try XCTUnwrap(CLIDuration.parse("30m")).label, "30 minutes")
    }

    func testUnusableWindowsAreRejected() {
        for text in ["", "m", "1", "1y", "0m", "-1h", "1s", "1.5h", "1000d", "abc", "1hm"] {
            XCTAssertNil(CLIDuration.parse(text), "\(text) must not be accepted")
        }
    }

    func testDefaultsAndInlineValues() throws {
        let request = try CLIRequest.parse(["top", "--since=6h"])
        XCTAssertEqual(request.command, .top)
        XCTAssertEqual(request.duration?.minutes, 360)
        XCTAssertEqual(request.sort, .energy)
        XCTAssertEqual(request.limit, 10)
        XCTAssertFalse(request.json)

        let full = try CLIRequest.parse(["top", "--since", "1d", "--by", "wakeups", "--limit", "3", "--json"])
        XCTAssertEqual(full.sort, .wakeups)
        XCTAssertEqual(full.limit, 3)
        XCTAssertTrue(full.json)
    }

    func testOutputFileAliasesAllLandInTheSamePlace() throws {
        XCTAssertEqual(try CLIRequest.parse(["export", "--csv", "-o", "energy.csv"]).outputFilePath, "energy.csv")
        XCTAssertEqual(try CLIRequest.parse(["export", "--out", "energy.csv"]).outputFilePath, "energy.csv")
        XCTAssertEqual(try CLIRequest.parse(["export", "--output", "energy.csv"]).outputFilePath, "energy.csv")
    }

    func testHelpIsAcceptedAnywhere() throws {
        XCTAssertTrue(try CLIRequest.parse(["--help"]).wantsHelp)
        XCTAssertTrue(try CLIRequest.parse(["help"]).wantsHelp)
        XCTAssertTrue(try CLIRequest.parse(["top", "--since", "1d", "--help"]).wantsHelp)
    }

    func testUsageErrors() {
        assertUsageError([], contains: "No command")
        assertUsageError(["dashboard"], contains: "Unknown command")
        assertUsageError(["top"], contains: "--since")
        assertUsageError(["history"], contains: "--since")
        assertUsageError(["top", "--since"], contains: "needs a value")
        assertUsageError(["top", "--since", "1w"], contains: "Cannot read --since")
        assertUsageError(["top", "--by", "memory"], contains: "Cannot read --by")
        assertUsageError(["top", "--limit", "0"], contains: "Cannot read --limit")
        assertUsageError(["top", "--nope"], contains: "Unknown option")
        assertUsageError(["top", "extra"], contains: "Unexpected argument")
        assertUsageError(["status", "--since", "1d"], contains: "does not take --since")
        assertUsageError(["status", "-o", "x"], contains: "does not take -o")
        assertUsageError(["history", "--limit", "5"], contains: "does not take --limit")
        assertUsageError(["export", "--by", "cpu"], contains: "does not take --by")
    }

    func testHelpTextCarriesWhatACallerNeeds() {
        XCTAssertTrue(CLIHelp.text.contains("VOLTSCOPE_DB_PATH"))
        XCTAssertTrue(CLIHelp.text.contains("--json"))
        XCTAssertTrue(CLIHelp.text.contains("30 second buckets"))
        XCTAssertTrue(CLIHelp.text.contains("recorded CPU energy only"))
        XCTAssertTrue(CLIHelp.text.contains("3 database newer than this tool"))
        XCTAssertTrue(CLIHelp.text.contains("begin before --since"),
                      "the help has to say the first history row can start before --since")
    }
}

func assertUsageError(_ arguments: [String], contains fragment: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try CLIRequest.parse(arguments)
        XCTFail("expected a usage error for \(arguments.joined(separator: " "))", file: file, line: line)
    } catch let error as CLIError {
        XCTAssertEqual(error.exitCode, CLIExit.usage, file: file, line: line)
        XCTAssertTrue(error.message.contains(fragment),
                      "message '\(error.message)' does not contain '\(fragment)'", file: file, line: line)
    } catch {
        XCTFail("unexpected error type for \(arguments.joined(separator: " ")): \(error)", file: file, line: line)
    }
}

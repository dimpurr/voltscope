import XCTest
@testable import VoltscopeCore

/// Guards the generated range table in `docs/UI_SPEC.md`.
///
/// `HistoryRange` is the single source of truth for range names, windows,
/// bucket widths, and labels. The matching block in the UI specification is
/// rendered from `HistoryRange.documentationTable`; this test fails when the
/// checked-in table drifts and prints the exact replacement text.
final class HistoryRangeDocsTests: XCTestCase {
    private static let startMarker = "<!-- generated:history-ranges:start -->"
    private static let endMarker = "<!-- generated:history-ranges:end -->"

    func testGeneratedTableMatchesUISpec() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let specURL = repoRoot.appendingPathComponent("docs/UI_SPEC.md")
        let spec = try String(contentsOf: specURL, encoding: .utf8)

        guard let start = spec.range(of: Self.startMarker) else {
            XCTFail("docs/UI_SPEC.md is missing \(Self.startMarker)")
            return
        }
        guard let end = spec.range(of: Self.endMarker, range: start.upperBound..<spec.endIndex) else {
            XCTFail("docs/UI_SPEC.md is missing \(Self.endMarker) after the start marker")
            return
        }

        let checkedIn = spec[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = HistoryRange.documentationTable
        XCTAssertEqual(checkedIn, expected, """
            docs/UI_SPEC.md range table is out of date. Replace the block between \
            \(Self.startMarker) and \(Self.endMarker) with:

            \(expected)
            """)
    }
}

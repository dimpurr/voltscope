#!/usr/bin/env python3
"""Regression tests for the documentation checker edge cases."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("check-docs.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("check_docs", SCRIPT)
check_docs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_docs)


class CheckDocsTests(unittest.TestCase):
    def test_test_method_must_belong_to_cited_class(self):
        source = """
final class CitedSuite: XCTestCase {
}

final class OtherSuite: XCTestCase {
    func testOnlyInOtherSuite() {}
}
"""
        with patch.object(Path, "rglob", return_value=[Path("fixture.swift")]), patch.object(
            Path, "read_text", return_value=source
        ):
            self.assertFalse(check_docs.test_exists(Path("fixture"), "CitedSuite.testOnlyInOtherSuite"))

    def test_test_method_in_extension_and_multiple_classes_is_found(self):
        source = '''
final class FirstSuite: XCTestCase {
    let example = "} { // braces in strings do not close the suite"
    let multiline = """ } { multiline braces """
    let raw = #"} { raw braces"#
}
final class HistoryRangeDocsTests: XCTestCase { }
extension HistoryRangeDocsTests {
    // { a comment brace must not change scope
    func testGeneratedTableMatchesUISpec() {}
}
'''
        with patch.object(Path, "rglob", return_value=[Path("fixture.swift")]), patch.object(
            Path, "read_text", return_value=source
        ):
            self.assertTrue(
                check_docs.test_exists(
                    Path("fixture"), "HistoryRangeDocsTests.testGeneratedTableMatchesUISpec"
                )
            )

    def test_test_reference_may_include_module_prefix(self):
        source = "final class HistoryRangeDocsTests: XCTestCase {\n    func testGeneratedTableMatchesUISpec() {}\n}"
        with patch.object(Path, "rglob", return_value=[Path("fixture.swift")]), patch.object(
            Path, "read_text", return_value=source
        ):
            self.assertTrue(
                check_docs.test_exists(
                    Path("fixture"),
                    "VoltscopeCoreTests.HistoryRangeDocsTests.testGeneratedTableMatchesUISpec",
                )
            )

    def test_range_enumeration_crosses_lines_and_reports_start_line(self):
        text = "Options:\n- Live, 1H, 6H,\n  24H, and 7D.\n"
        self.assertEqual(check_docs.match_line_numbers(text, check_docs.RANGE_ENUMERATION), [2])

    def test_non_owner_prepared_version_claim_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "docs/INDEX.md").write_text("Release status: prepared for v9.8.7 (build 42).\n")
            (root / "CHANGELOG.md").write_text("Prepared for v9.8.7 (build 42).\n")
            problems = []
            check_docs.check_non_owner_version_claims(root, problems)
            self.assertEqual(len(problems), 1)
            self.assertIn("docs/INDEX.md:1", problems[0])

    def test_090_historical_macos_claim_is_preserved(self):
        changelog = SCRIPT.parent.parent / "CHANGELOG.md"
        self.assertIn("reliably on macOS 13 and newer.", changelog.read_text(encoding="utf-8"))

    def test_macos_minimum_claim_is_compared_with_package_number(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "Package.swift").write_text(".macOS(.v13)\n")
            (root / "docs/HLD.md").write_text("minimum target: macOS 13+\n")
            (root / "README.md").write_text("Requires macOS 14 or later.\n")
            problems = []
            check_docs.check_macos_minimum(root, problems)
            self.assertTrue(any("README.md:1" in problem and "says 14" in problem for problem in problems))

    def test_all_hld_sampling_interval_rows_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/VoltscopeCore/Sampling"
            source.mkdir(parents=True)
            (source / "SamplingCoordinator.swift").write_text(
                "processInterval: TimeInterval = 5.0\nbatteryInterval: TimeInterval = 30.0\n"
                "walCheckpointInterval: TimeInterval = 300.0\n"
            )
            (root / "docs").mkdir()
            (root / "docs/HLD.md").write_text(
                "### Process and hardware sampling (every 5s)\n"
                "| `proc_listallpids` + `proc_pid_rusage × 100` | Every 10s | ~3 ms CPU |\n"
                "### Battery Sampling Loop (every 30s)\n"
                "| `IOPMPowerSource` snapshot | Every 30s | <1 ms |\n"
            )
            problems = []
            check_docs.check_code_value_facts(root, problems)
            self.assertTrue(any("process-sampling-interval" in problem for problem in problems))

    def test_code_value_rule_accepts_hours_and_missing_optional_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/VoltscopeCore/Sampling"
            source.mkdir(parents=True)
            (source / "SamplingCoordinator.swift").write_text(
                "processInterval: TimeInterval = 5.0\nbatteryInterval: TimeInterval = 30.0\n"
                "walCheckpointInterval: TimeInterval = 3600.0\n"
            )
            (root / "docs").mkdir()
            (root / "docs/HLD.md").write_text(
                "### Sampling Loop (foreground, every 5s)\n"
                "### Battery Sampling Loop (every 30s)\n"
            )
            (root / "docs/ENERGY_MODEL.md").write_text(
                "SQLite `wal_checkpoint(TRUNCATE)` every 1 hour.\n"
            )
            problems = []
            check_docs.check_code_value_facts(root, problems)
            self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()

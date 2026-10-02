#!/usr/bin/env python3
"""Regression tests for the documentation checker edge cases."""

import importlib.util
import sys
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


if __name__ == "__main__":
    unittest.main()

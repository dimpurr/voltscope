#!/usr/bin/env python3
"""Keep duplicated facts in documentation from drifting.

Two checks run over the checked-in Markdown:

1. Facts with a single owning document must not be repeated in the
   non-owner documents listed in ``RULES``. Today the only such fact is the
   History time-range enumeration.
2. ``[test: Suite.method]`` references in ``docs/`` must name a test that
   actually exists under ``Tests/``.

Exit codes: 0 when everything is consistent, 1 when a problem is found, and
2 for a usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The History toolbar offers one time control. Its names, windows, bucket
# widths, and labels are owned by docs/UI_SPEC.md, which renders them from
# `HistoryRange` in VoltscopeCore. This pattern matches a same-line
# enumeration of the range names; 6H is optional so older drifted lists are
# still caught after the range was added.
RANGE_ENUMERATION = re.compile(
    r"\bLive\b[^\n]{0,120}?\b1H\b[^\n]{0,120}?(?:\b6H\b[^\n]{0,120}?)?"
    r"\b24H\b[^\n]{0,120}?\b7D\b"
)

# One entry per duplicated fact. `files` are the documents that must not
# repeat it; add new rules here rather than ad-hoc checks.
RULES = [
    {
        "id": "history-ranges",
        "fact": "History time-range enumeration (Live / 1H / 6H / 24H / 7D)",
        "owner": "docs/UI_SPEC.md",
        "files": [
            "README.md",
            "CLAUDE.md",
            "AGENTS.md",
            "CONTRIBUTING.md",
            "docs/HLD.md",
            "docs/VISION.md",
        ],
        "pattern": RANGE_ENUMERATION,
    },
]

TEST_REFERENCE = re.compile(
    r"\[test:\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*\]"
)


def line_matches(path: Path, pattern: re.Pattern[str]) -> list[int]:
    """Return 1-based line numbers in `path` that contain `pattern`."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    return [number for number, line in enumerate(text.splitlines(), start=1) if pattern.search(line)]


def find_test_references(path: Path) -> list[tuple[int, str]]:
    """Return (line number, reference) for each [test: ...] in `path`."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    found: list[tuple[int, str]] = []
    for number, line in enumerate(text.splitlines(), start=1):
        for match in TEST_REFERENCE.finditer(line):
            found.append((number, match.group(1)))
    return found


def test_exists(root: Path, reference: str) -> bool:
    """True when a test class and method matching `reference` exist in Tests/."""
    parts = reference.split(".")
    suite, method = parts[0], parts[-1]
    class_pattern = re.compile(rf"\bclass\s+{re.escape(suite)}\b")
    method_pattern = re.compile(rf"\bfunc\s+{re.escape(method)}\b")
    for path in (root / "Tests").rglob("*.swift"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if class_pattern.search(text) and method_pattern.search(text):
            return True
    return False


def check_duplicated_facts(root: Path, problems: list[str]) -> None:
    for rule in RULES:
        for relative in rule["files"]:
            path = root / relative
            if not path.is_file():
                continue
            for number in line_matches(path, rule["pattern"]):
                problems.append(
                    f"{relative}:{number}: {rule['fact']} is owned by "
                    f"{rule['owner']}; remove the duplicate and link to the owner"
                )


def check_test_references(root: Path, problems: list[str]) -> None:
    docs = root / "docs"
    if not docs.is_dir():
        return
    for path in sorted(docs.rglob("*.md")):
        relative = path.relative_to(root)
        for number, reference in find_test_references(path):
            if not test_exists(root, reference):
                problems.append(
                    f"{relative}:{number}: [test: {reference}] does not match any "
                    f"test class and method under Tests/"
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=None,
        help="Repository root (defaults to the parent of this script's directory)",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    if not root.is_dir() or not (root / "Sources").is_dir() or not (root / "Tests").is_dir():
        print(f"usage error: {root} is not a Voltscope repository root", file=sys.stderr)
        return 2

    problems: list[str] = []
    check_duplicated_facts(root, problems)
    check_test_references(root, problems)

    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        print(f"\n{len(problems)} documentation consistency problem(s) found.", file=sys.stderr)
        return 1

    print("Documentation consistency check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

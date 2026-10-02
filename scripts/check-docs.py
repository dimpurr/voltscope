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
import plistlib
import re
import sys
from pathlib import Path

# The History toolbar offers one time control. Its names, windows, bucket
# widths, and labels are owned by docs/UI_SPEC.md, which renders them from
# `HistoryRange` in VoltscopeCore. This pattern matches a bounded
# enumeration of the range names; whitespace includes line breaks so wrapped
# prose and Markdown lists are checked too. 6H is optional so older drifted
# lists are still caught after the range was added.
RANGE_ENUMERATION = re.compile(
    r"\bLive\b[\s\S]{0,120}?\b1H\b[\s\S]{0,120}?(?:\b6H\b[\s\S]{0,120}?)?"
    r"\b24H\b[\s\S]{0,120}?\b7D\b"
)
MACOS_MINIMUM = re.compile(r"\bmacOS\s+13(?:\+| or later| and newer)(?=\W|$)")

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
    {
        "id": "macos-minimum",
        "fact": "Minimum macOS version (macOS 13+)",
        "owner": "docs/HLD.md and Package.swift",
        "files": [
            "README.md",
            "CLAUDE.md",
            "AGENTS.md",
            "CHANGELOG.md",
            "docs/ENERGY_MODEL.md",
            "docs/UI_SPEC.md",
            "docs/VISION.md",
        ],
        "pattern": MACOS_MINIMUM,
    },
]

# These facts intentionally appear in prose and implementation. Keep the prose
# aligned with the owning code constants instead of forbidding useful repeats.
CODE_VALUE_RULES = [
    {
        "id": "process-sampling-interval",
        "owner": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift:processInterval",
        "source": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift",
        "constant": "processInterval",
        "files": ["docs/HLD.md"],
        "pattern": re.compile(
            r"(?:ProcessSampler\s*│\s*\(|Sampling Loop \(foreground, every )"
            r"(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>seconds?|s)\b"
        ),
    },
    {
        "id": "battery-sampling-interval",
        "owner": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift:batteryInterval",
        "source": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift",
        "constant": "batteryInterval",
        "files": ["docs/HLD.md"],
        "pattern": re.compile(
            r"Battery Sampling Loop \(every (?P<value>\d+(?:\.\d+)?)\s*(?P<unit>seconds?|s)\b"
        ),
    },
    {
        "id": "wal-checkpoint-interval",
        "owner": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift:walCheckpointInterval",
        "source": "Sources/VoltscopeCore/Sampling/SamplingCoordinator.swift",
        "constant": "walCheckpointInterval",
        "files": ["docs/ENERGY_MODEL.md"],
        "pattern": re.compile(
            r"wal_checkpoint\(TRUNCATE\)`? every (?P<value>\d+(?:\.\d+)?)\s*(?P<unit>minutes?|min)\b"
        ),
    },
]

TEST_REFERENCE = re.compile(
    r"\[test:\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*\]"
)


def line_matches(path: Path, pattern: re.Pattern[str]) -> list[int]:
    """Return 1-based starting line numbers for matches in `path`."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    return match_line_numbers(text, pattern)


def match_line_numbers(text: str, pattern: re.Pattern[str]) -> list[int]:
    """Return 1-based starting line numbers for matches in `text`."""
    return [text.count("\n", 0, match.start()) + 1 for match in pattern.finditer(text)]


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
    suite, method = parts[-2], parts[-1]
    class_pattern = re.compile(rf"\bclass\s+{re.escape(suite)}\b[^{{]*\{{")
    method_pattern = re.compile(rf"\bfunc\s+{re.escape(method)}\b")
    for path in (root / "Tests").rglob("*.swift"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for match in class_pattern.finditer(text):
            depth = 1
            index = match.end()
            while index < len(text) and depth:
                if text[index] == "{":
                    depth += 1
                elif text[index] == "}":
                    depth -= 1
                index += 1
            if method_pattern.search(text, match.end(), index - 1):
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


def check_code_value_facts(root: Path, problems: list[str]) -> None:
    for rule in CODE_VALUE_RULES:
        source = root / rule["source"]
        try:
            text = source.read_text(encoding="utf-8")
        except OSError:
            problems.append(f"{rule['source']}: cannot read source for {rule['id']}")
            continue
        constant = re.search(
            rf"\b{re.escape(rule['constant'])}\s*:\s*TimeInterval\s*=\s*(\d+(?:\.\d+)?)",
            text,
        )
        if not constant:
            problems.append(f"{rule['source']}: cannot find {rule['constant']} for {rule['id']}")
            continue
        expected_seconds = float(constant.group(1))
        for relative in rule["files"]:
            path = root / relative
            if not path.is_file():
                continue
            try:
                prose = path.read_text(encoding="utf-8")
            except OSError:
                continue
            matches = list(rule["pattern"].finditer(prose))
            if not matches:
                problems.append(f"{relative}: missing documented value for {rule['id']}")
            for match in matches:
                value = float(match.group("value"))
                unit = match.group("unit").lower()
                actual_seconds = value * (60 if unit.startswith(("min",)) else 1)
                if actual_seconds != expected_seconds:
                    line = prose.count("\n", 0, match.start()) + 1
                    problems.append(
                        f"{relative}:{line}: {rule['id']} says {value:g} {unit}, but "
                        f"{rule['owner']} is {expected_seconds:g} seconds"
                    )


def check_macos_minimum(root: Path, problems: list[str]) -> None:
    """Keep the HLD minimum-version statement aligned with Package.swift."""
    package_path = root / "Package.swift"
    hld_path = root / "docs/HLD.md"
    try:
        package = package_path.read_text(encoding="utf-8")
        hld = hld_path.read_text(encoding="utf-8")
    except OSError as error:
        problems.append(f"docs/HLD.md: cannot verify minimum macOS version: {error}")
        return
    package_match = re.search(r"\.macOS\(\.v(\d+)\)", package)
    hld_match = re.search(r"minimum target: macOS (\d+)\+", hld)
    if not package_match or not hld_match:
        problems.append("docs/HLD.md: minimum macOS target could not be checked against Package.swift")
    elif package_match.group(1) != hld_match.group(1):
        problems.append(
            "docs/HLD.md: minimum macOS target disagrees with Package.swift "
            f"({hld_match.group(1)} vs {package_match.group(1)})"
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


def check_documented_version(root: Path, problems: list[str]) -> None:
    """Keep the documentation index status aligned with app bundle metadata."""
    plist_path = root / "Sources/Voltscope/Resources/Info.plist"
    index_path = root / "docs/INDEX.md"
    try:
        with plist_path.open("rb") as source:
            plist = plistlib.load(source)
        index = index_path.read_text(encoding="utf-8")
    except (OSError, plistlib.InvalidFileException) as error:
        problems.append(f"docs/INDEX.md: cannot verify release status against Info.plist: {error}")
        return

    version = plist.get("CFBundleShortVersionString")
    build = plist.get("CFBundleVersion")
    expected = f"Status: prepared for v{version} (build {build});"
    status = next((line for line in index.splitlines() if line.startswith("Status:")), "")
    if status != expected + " publication is maintained by the release owner.":
        problems.append(
            "docs/INDEX.md:3: release status must match Info.plist: "
            f"{expected} publication is maintained by the release owner."
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
    check_code_value_facts(root, problems)
    check_macos_minimum(root, problems)
    check_test_references(root, problems)
    check_documented_version(root, problems)

    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        print(f"\n{len(problems)} documentation consistency problem(s) found.", file=sys.stderr)
        return 1

    print("Documentation consistency check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate the release-critical fields in a Sparkle appcast."""

import argparse
import sys
import urllib.request
import xml.etree.ElementTree as ET
from typing import NoReturn

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fail(message: str) -> NoReturn:
    print(f"appcast validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("feed")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--network", action="store_true")
    args = parser.parse_args()

    try:
        root = ET.parse(args.feed).getroot()
    except (OSError, ET.ParseError) as error:
        fail(str(error))
    item = root.find(".//item")
    if item is None:
        fail("feed has no item")
    def value(name: str) -> str:
        element = item.find(name)
        return (element.text or "").strip() if element is not None else ""

    if value(f"{{{SPARKLE}}}version") != args.build:
        fail(f"sparkle:version is not {args.build}")
    if value(f"{{{SPARKLE}}}shortVersionString") != args.version:
        fail(f"sparkle:shortVersionString is not {args.version}")
    if value(f"{{{SPARKLE}}}minimumSystemVersion") != "13.0":
        fail("sparkle:minimumSystemVersion must be 13.0")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("item has no enclosure")
    url = enclosure.attrib.get("url", "")
    if url != args.url:
        fail(f"enclosure URL is {url!r}, expected {args.url!r}")
    signature = enclosure.attrib.get(f"{{{SPARKLE}}}edSignature", "")
    if not signature:
        fail("enclosure is missing sparkle:edSignature")
    length = enclosure.attrib.get("length", "")
    try:
        if int(length) <= 0:
            raise ValueError
    except ValueError:
        fail("enclosure length must be a positive integer")
    if not value("pubDate"):
        fail("item is missing pubDate")

    if args.network:
        try:
            request = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(request, timeout=20) as response:
                content_length = response.headers.get("Content-Length")
                if content_length and int(content_length) != int(length):
                    fail("network Content-Length does not match enclosure length")
        except Exception as error:
            fail(f"could not fetch enclosure: {error}")
    print(f"appcast valid: {args.version} build {args.build}")


if __name__ == "__main__":
    main()

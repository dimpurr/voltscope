#!/usr/bin/env python3
"""Verify that a published GitHub release can actually serve Sparkle updates.

This is intentionally a post-publication gate. A local appcast can be
syntactically valid while the GitHub Release is missing the appcast or DMG,
which is exactly the failure this check is designed to catch.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import NoReturn


SPARKLE = "http://www.andymac.com/sparkle"
USER_AGENT = "Voltscope-release-verifier/1"


def fail(message: str) -> NoReturn:
    print(f"release verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def request(url: str, *, timeout: float, method: str = "GET") -> tuple[bytes, str, dict[str, str]]:
    req = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            headers = {key.lower(): value for key, value in response.headers.items()}
            return response.read(), response.geturl(), headers
    except urllib.error.HTTPError as error:
        fail(f"{method} {url} returned HTTP {error.code}")
    except (urllib.error.URLError, TimeoutError) as error:
        fail(f"could not fetch {url}: {error}")


def asset_by_name(assets: list[dict], name: str) -> dict:
    for asset in assets:
        if asset.get("name") == name:
            return asset
    fail(f"release is missing asset {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub repository, for example dimpurr/voltscope")
    parser.add_argument("--tag", required=True, help="Published tag, for example v0.9.0")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--feed-url", required=True, help="The SUFeedURL used by the released app")
    parser.add_argument("--dmg-name", required=True, help="Exact universal DMG asset name")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    api_url = f"https://api.github.com/repos/{args.repo}/releases/tags/{args.tag}"
    release_data, _, _ = request(api_url, timeout=args.timeout)
    try:
        release = json.loads(release_data)
    except json.JSONDecodeError as error:
        fail(f"GitHub API returned invalid JSON: {error}")
    if release.get("tag_name") != args.tag:
        fail(f"GitHub release tag is {release.get('tag_name')!r}, expected {args.tag!r}")
    if release.get("draft"):
        fail("GitHub release is still a draft")
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("GitHub release response has no assets list")
    dmg_asset = asset_by_name(assets, args.dmg_name)
    appcast_asset = asset_by_name(assets, "appcast.xml")

    feed_data, feed_final_url, _ = request(args.feed_url, timeout=args.timeout)
    try:
        root = ET.fromstring(feed_data)
    except ET.ParseError as error:
        fail(f"live feed is not valid XML: {error}")
    item = root.find(".//item")
    if item is None:
        fail("live feed contains no item")

    def value(namespace: str, name: str) -> str:
        element = item.find(f"{{{namespace}}}{name}")
        return (element.text or "").strip() if element is not None else ""

    if value(SPARKLE, "shortVersionString") != args.version:
        fail("live feed short version does not match the released app")
    if value(SPARKLE, "version") != args.build:
        fail("live feed build does not match the released app")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("live feed item has no enclosure")
    expected_asset_url = dmg_asset.get("browser_download_url")
    if enclosure.get("url") != expected_asset_url:
        fail("live feed enclosure does not point to the DMG in this release")
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        fail("live feed enclosure has no Sparkle EdDSA signature")
    try:
        feed_length = int(enclosure.get("length", "0"))
    except ValueError:
        fail("live feed enclosure length is not an integer")
    if feed_length <= 0:
        fail("live feed enclosure length is not positive")

    dmg_data, dmg_final_url, dmg_headers = request(expected_asset_url, timeout=args.timeout)
    if len(dmg_data) != feed_length:
        fail(f"downloaded DMG is {len(dmg_data)} bytes, feed says {feed_length}")
    declared_size = dmg_asset.get("size")
    if isinstance(declared_size, int) and declared_size != feed_length:
        fail("GitHub asset size does not match the appcast enclosure length")
    if dmg_final_url != expected_asset_url and not dmg_final_url.startswith(expected_asset_url):
        fail("DMG download redirected somewhere other than the GitHub release asset")
    if not appcast_asset.get("browser_download_url"):
        fail("GitHub appcast asset has no download URL")

    print(f"release verified: {args.repo} {args.tag} {args.version} build {args.build}")
    print(f"feed: {feed_final_url}")
    print(f"DMG: {args.dmg_name} ({feed_length} bytes)")


if __name__ == "__main__":
    main()

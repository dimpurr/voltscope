#!/usr/bin/env bash
# Generate and validate the signed Sparkle appcast for one final DMG.
# The EdDSA private key is supplied either by VOLTSCOPE_SPARKLE_ED_KEY (the
# private maintainer repository's release environment) or by Keychain account
# "voltscope" when the environment variable is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG=""
VERSION=""
BUILD=""
TAG=""
OUTPUT="$ROOT/build/appcast.xml"
NETWORK=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dmg) DMG="${2:?Pass a notarized DMG path}"; shift 2 ;;
        --version) VERSION="${2:?Pass the short version}"; shift 2 ;;
        --build) BUILD="${2:?Pass the bundle build}"; shift 2 ;;
        --tag) TAG="${2:?Pass the exact Git tag}"; shift 2 ;;
        --output) OUTPUT="${2:?Pass an appcast output path}"; shift 2 ;;
        --network) NETWORK=1; shift ;;
        *) echo "Usage: $0 --dmg DMG --version 0.9.0 --build 9 [--tag v0.9.0] [--output build/appcast.xml] [--network]" >&2; exit 2 ;;
    esac
done

[ -n "$DMG" ] && [ -n "$VERSION" ] && [ -n "$BUILD" ] || {
    echo "DMG, version, and build are required." >&2; exit 2;
}
[ -f "$DMG" ] || { echo "Missing DMG: $DMG" >&2; exit 1; }
TAG="${TAG:-v$VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid SemVer: $VERSION" >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "Invalid build: $BUILD" >&2; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release tag: $TAG" >&2; exit 2; }

SPARKLE_BIN="${VOLTSCOPE_SPARKLE_TOOLS:-}"
if [ -z "$SPARKLE_BIN" ]; then
    SPARKLE_BIN="$(command -v generate_appcast || true)"
fi
[ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN" ] || {
    echo "Set VOLTSCOPE_SPARKLE_TOOLS to Sparkle's generate_appcast executable." >&2; exit 1;
}

# Refuse an unsigned or unstapled input before asking Sparkle to sign metadata.
codesign --verify --deep --strict "$DMG"
xcrun stapler validate "$DMG"

ASSET_NAME="${VOLTSCOPE_ASSET_NAME:-Voltscope-$VERSION-universal2.dmg}"
ASSET_URL="https://github.com/dimpurr/voltscope/releases/download/$TAG/$ASSET_NAME"
ASSET_PREFIX="${ASSET_URL%/*}/"
STAGE="$(mktemp -d /tmp/voltscope-appcast.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/$ASSET_NAME"
mkdir -p "$(dirname "$OUTPUT")"

SPARKLE_ARGS=(
    --versions "$BUILD"
    --download-url-prefix "$ASSET_PREFIX"
    --link "https://github.com/dimpurr/voltscope/releases"
    -o "$OUTPUT"
)
if [ -n "${VOLTSCOPE_SPARKLE_ED_KEY:-}" ]; then
    # Pass the secret on stdin so it never appears in argv or process listings.
    printf '%s\n' "$VOLTSCOPE_SPARKLE_ED_KEY" |
        "$SPARKLE_BIN" --ed-key-file - "${SPARKLE_ARGS[@]}" "$STAGE"
else
    "$SPARKLE_BIN" --account voltscope "${SPARKLE_ARGS[@]}" "$STAGE"
fi

VERIFY_ARGS=("$OUTPUT" --version "$VERSION" --build "$BUILD" --url "$ASSET_URL")
if [ "$NETWORK" -eq 1 ]; then VERIFY_ARGS+=(--network); fi
python3 "$ROOT/scripts/verify-appcast.py" "${VERIFY_ARGS[@]}"
echo "Generated: $OUTPUT"

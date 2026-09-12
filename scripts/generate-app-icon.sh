#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Sources/Voltscope/Resources/AppIcon.svg"
OUTPUT="$ROOT/Sources/Voltscope/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v iconutil >/dev/null || { echo "iconutil is required on macOS." >&2; exit 1; }
command -v sips >/dev/null || { echo "sips is required on macOS." >&2; exit 1; }

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

MASTER="$WORK/AppIcon-1024.png"
sips -s format png "$SOURCE" --out "$MASTER" >/dev/null

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Generated $OUTPUT"

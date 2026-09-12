#!/usr/bin/env bash
# Builds Voltscope.app from `swift build` output.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
SIGN_IDENTITY="-"
if [ "${2:-}" = "--developer-id" ]; then
    SIGN_IDENTITY="${3:?Pass the Developer ID certificate identity}"
elif [ "$#" -gt 1 ]; then
    echo "Usage: $0 [release|debug] [--developer-id IDENTITY]" >&2
    exit 2
fi
case "$CONFIG" in release|debug) ;; *) echo "Unknown build configuration: $CONFIG" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

BIN_PATH="$(swift build --configuration "$CONFIG" --show-bin-path)"
APP_DIR="$ROOT/build/Voltscope.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

FRAMEWORKS="$CONTENTS/Frameworks"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp "$BIN_PATH/Voltscope" "$MACOS/Voltscope"
cp "$ROOT/Sources/Voltscope/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/Voltscope/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# Copy any SPM-generated resource bundles (GRDB, etc.) into Resources.
for bundle in "$BIN_PATH"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES/"
    fi
done

# Copy any frameworks (Sparkle ships as a binary .framework) into Contents/Frameworks.
for framework in "$BIN_PATH"/*.framework; do
    if [ -d "$framework" ]; then
        cp -R "$framework" "$FRAMEWORKS/"
    fi
done

# Set the loader path before signing any code.
if ! otool -l "$MACOS/Voltscope" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/Voltscope"
fi

sign_code() {
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - --timestamp=none "$1"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$1"
    fi
}

# Sign nested Mach-O helpers and then their enclosing bundles, inside out.
# Sparkle includes XPC services and an updater app; signing only the DMG does
# not make the application distributable.
while IFS= read -r -d '' file_path; do
    if file -b "$file_path" | grep -q 'Mach-O'; then sign_code "$file_path"; fi
done < <(find "$FRAMEWORKS" -type f -print0)
while IFS= read -r -d '' bundle_path; do
    sign_code "$bundle_path"
done < <(find "$FRAMEWORKS" -depth -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.bundle' \) -print0)
sign_code "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "Run with: open $APP_DIR"

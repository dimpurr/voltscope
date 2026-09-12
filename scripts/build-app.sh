#!/usr/bin/env bash
# Builds Voltscope.app from `swift build` output.
# Usage: scripts/build-app.sh [release|debug] [--universal]
set -euo pipefail

CONFIG="${1:-release}"
SIGN_IDENTITY="-"
UNIVERSAL=0
shift $(( $# > 0 ? 1 : 0 ))
while [ "$#" -gt 0 ]; do
    case "$1" in
        --universal) UNIVERSAL=1 ;;
        --developer-id)
            shift
            SIGN_IDENTITY="${1:?Pass the Developer ID certificate identity}"
            ;;
        *) echo "Usage: $0 [release|debug] [--universal] [--developer-id IDENTITY]" >&2; exit 2 ;;
    esac
    shift
done
case "$CONFIG" in release|debug) ;; *) echo "Unknown build configuration: $CONFIG" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MACOS_TRIPLE_SUFFIX="apple-macosx13.0"
if [ "$UNIVERSAL" -eq 1 ]; then
    echo "==> swift build --configuration $CONFIG --triple arm64-$MACOS_TRIPLE_SUFFIX"
    swift build --configuration "$CONFIG" --triple "arm64-$MACOS_TRIPLE_SUFFIX"
    echo "==> swift build --configuration $CONFIG --triple x86_64-$MACOS_TRIPLE_SUFFIX"
    swift build --configuration "$CONFIG" --triple "x86_64-$MACOS_TRIPLE_SUFFIX"
    ARM_BIN_PATH="$(swift build --configuration "$CONFIG" --triple "arm64-$MACOS_TRIPLE_SUFFIX" --show-bin-path)"
    X86_BIN_PATH="$(swift build --configuration "$CONFIG" --triple "x86_64-$MACOS_TRIPLE_SUFFIX" --show-bin-path)"
else
    echo "==> swift build --configuration $CONFIG"
    swift build --configuration "$CONFIG"
    BIN_PATH="$(swift build --configuration "$CONFIG" --show-bin-path)"
fi
APP_DIR="$ROOT/build/Voltscope.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

FRAMEWORKS="$CONTENTS/Frameworks"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

if [ "$UNIVERSAL" -eq 1 ]; then
    lipo -create "$ARM_BIN_PATH/Voltscope" "$X86_BIN_PATH/Voltscope" -output "$MACOS/Voltscope"
else
    cp "$BIN_PATH/Voltscope" "$MACOS/Voltscope"
fi
cp "$ROOT/Sources/Voltscope/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/Voltscope/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# Copy any SPM-generated resource bundles (GRDB, etc.) into Resources.
RESOURCE_BIN_PATH="${ARM_BIN_PATH:-$BIN_PATH}"
for bundle in "$RESOURCE_BIN_PATH"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES/"
    fi
done

# Copy any frameworks (Sparkle ships as a binary .framework) into Contents/Frameworks.
for framework in "$RESOURCE_BIN_PATH"/*.framework; do
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

if [ "$UNIVERSAL" -eq 1 ]; then
    lipo "$MACOS/Voltscope" -verify_arch arm64 x86_64
fi

echo "==> Done: $APP_DIR"
echo "Run with: open $APP_DIR"

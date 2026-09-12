#!/usr/bin/env bash
# --signed: Developer ID signed, explicitly not notarized.
# --release: Developer ID signed and notarized; requires notarization credentials.
# --no-build: reuse and verify the existing app, including its Developer ID in signed modes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
MODE=dev
NO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --signed) MODE=signed ;;
        --release) MODE=release ;;
        --no-build) NO_BUILD=1 ;;
        *) echo "Usage: $0 [--signed|--release] [--no-build]" >&2; exit 2 ;;
    esac
done
APP_BUNDLE="build/Voltscope.app"
DEV_ID=""
if [ "$MODE" != dev ]; then
    DEV_ID="${VOLTSCOPE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n '/Developer ID Application/s/.*) \([A-F0-9]*\) .*/\1/p')}"
    if [ -z "$DEV_ID" ] || [[ "$DEV_ID" == *$'\n'* ]]; then
        echo "Set VOLTSCOPE_SIGN_IDENTITY to one valid Developer ID identity." >&2; exit 1
    fi
fi
if [ "$NO_BUILD" -eq 0 ]; then
    if [ "$MODE" = dev ]; then "$SCRIPT_DIR/build-app.sh" release
    else "$SCRIPT_DIR/build-app.sh" release --developer-id "$DEV_ID"; fi
fi
[ -d "$APP_BUNDLE" ] || { echo "Missing $APP_BUNDLE" >&2; exit 1; }
codesign --verify --deep --strict "$APP_BUNDLE"
if [ "$MODE" != dev ]; then
    SIGNATURE_DETAILS="$(codesign -dvv "$APP_BUNDLE" 2>&1)"
    [[ "$SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] || {
        echo "Existing app is not Developer ID signed; rebuild without --no-build." >&2; exit 1;
    }
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
LABEL="${VOLTSCOPE_RELEASE_LABEL:-$VERSION}"
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid release label" >&2; exit 2; }
ARCH="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Voltscope" | tr ' ' '-')"
DMG_PATH="build/Voltscope-$LABEL-$ARCH.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_BUNDLE" "$STAGE/Voltscope.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Voltscope -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH"
if [ "$MODE" != dev ]; then
    codesign --force --timestamp --sign "$DEV_ID" "$DMG_PATH"
    codesign --verify --strict "$DMG_PATH"
fi
if [ "$MODE" = release ]; then
    RESULT="$STAGE/notary-result.json"
    if [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -f "${ASC_PRIVATE_KEY_PATH:-}" ]; then
        xcrun notarytool submit "$DMG_PATH" --key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$RESULT"
    else
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "${VOLTSCOPE_NOTARY_PROFILE:-voltscope-notary}" --wait --output-format json > "$RESULT"
    fi
    plutil -extract status raw "$RESULT" | grep -qx Accepted || { cat "$RESULT"; exit 1; }
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl -a -t open --context context:primary-signature "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH"
echo "Built: $DMG_PATH"
case "$MODE" in
    dev) echo 'Ad-hoc development build; not notarized.' ;;
    signed) echo 'Developer ID signed; NOT notarized. Gatekeeper may block downloaded copies.' ;;
    release) echo 'Developer ID signed, notarized and stapled.' ;;
esac

#!/bin/zsh
# Builds, signs, notarizes, and packages Bloom into a shareable DMG.
#
# One-time setup:
#   xcrun notarytool store-credentials bloom-notary \
#       --apple-id <apple-id-email> --team-id HFXABN57R2
#
# Usage: script/release.sh [--skip-notarize]
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Aman Chaudhary (HFXABN57R2)"
PROFILE="bloom-notary"
BUILD_DIR="build/release"
APP="$BUILD_DIR/Build/Products/Release/Bloom.app"
DMG="$HOME/Downloads/Bloom.dmg"

echo "==> Building Release with hardened runtime"
xcodebuild -project Bloom.xcodeproj -scheme Bloom -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM=HFXABN57R2 \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    build | grep -E "error|warning: Signing|BUILD" || true

codesign --verify --deep --strict "$APP"
echo "==> Signed as: $(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1)"

echo "==> Packaging DMG"
STAGE="$(mktemp -d)/Bloom"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Bloom" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "${1:-}" == "--skip-notarize" ]]; then
    echo "==> Skipped notarization. DMG at $DMG (unnotarized)."
    exit 0
fi

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"

echo "==> Done: $DMG"

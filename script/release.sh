#!/bin/zsh
# Builds, signs, notarizes, and packages Bloom into a shareable DMG, then
# generates a Sparkle appcast and publishes everything as a GitHub release.
#
# One-time setup:
#   xcrun notarytool store-credentials bloom-notary \
#       --apple-id <apple-id-email> --team-id HFXABN57R2
#   Sparkle EdDSA private key lives in the login keychain ("Private key for
#   signing Sparkle updates"); generate_appcast reads it automatically.
#
# Usage: script/release.sh <version> [--skip-notarize]
#   e.g. script/release.sh 0.4.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: script/release.sh <version> [--skip-notarize]}"
IDENTITY="Developer ID Application: Aman Chaudhary (HFXABN57R2)"
PROFILE="bloom-notary"
REPO="amanfromsolan/bloom"
BUILD_DIR="build/release"
APP="$BUILD_DIR/Build/Products/Release/Bloom.app"
DMG="$HOME/Downloads/Bloom-$VERSION.dmg"

# Release notes are mandatory and validated before the (slow) build:
# RELEASE_NOTES/<version>.md in the strict '## Section' / '- item' subset.
# They end up embedded in the appcast (What's New sheet) and as the GitHub
# release body.
NOTES_MD="RELEASE_NOTES/$VERSION.md"
if [[ ! -f "$NOTES_MD" ]]; then
    echo "error: $NOTES_MD missing — write the release notes first" >&2
    exit 1
fi
python3 script/release_notes.py "$NOTES_MD" > /dev/null

# Sparkle compares CFBundleVersion, so it must increase monotonically with
# each release: 0.4.0 -> 400, 1.2.3 -> 10203.
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUM=$((MAJOR * 10000 + MINOR * 100 + PATCH))

echo "==> Building Release v$VERSION (build $BUILD_NUM) with hardened runtime"
xcodebuild -project Bloom.xcodeproj -scheme Bloom -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM=HFXABN57R2 \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    build | grep -E "error|warning: Signing|BUILD" || true

# Sparkle's nested helpers ship with upstream signatures; the notary service
# requires every executable be signed by our Developer ID with a secure
# timestamp. Re-sign inside-out (helpers -> framework -> app) so each outer
# seal covers the fixed layer beneath it.
echo "==> Re-signing Sparkle helpers for notarization"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
for HELPER in \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/Autoupdate" \
    "$SPARKLE_FW/Versions/B/Updater.app"; do
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements --sign "$IDENTITY" "$HELPER"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW"
codesign --force --options runtime --timestamp \
    --entitlements Bloom/Bloom.entitlements --sign "$IDENTITY" "$APP"

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

if [[ "${2:-}" == "--skip-notarize" ]]; then
    echo "==> Skipped notarization. DMG at $DMG (unnotarized, not published)."
    exit 0
fi

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"

echo "==> Generating Sparkle appcast"
SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="$(mktemp -d)"
cp "$DMG" "$APPCAST_DIR/"
# generate_appcast embeds an HTML file named like the archive as that
# item's release notes (<description> in the appcast).
python3 script/release_notes.py "$NOTES_MD" > "$APPCAST_DIR/Bloom-$VERSION.html"
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --maximum-deltas 0

echo "==> Publishing GitHub release v$VERSION"
gh release create "v$VERSION" \
    "$DMG" \
    "$APPCAST_DIR/appcast.xml" \
    --repo "$REPO" \
    --title "Bloom v$VERSION" \
    --notes-file "$NOTES_MD"

echo "==> Done: https://github.com/$REPO/releases/tag/v$VERSION"

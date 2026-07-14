#!/bin/zsh
# Builds, signs, notarizes, and packages Enso into a shareable DMG, then
# generates a Sparkle appcast and publishes everything as a GitHub release.
#
# Two release channels, auto-detected from the version string:
#   stable  X.Y.Z          e.g. 0.10.0
#           Release configuration -> Enso.app, Enso-<version>.dmg,
#           enso-appcast.xml. Published as a normal (non-prerelease) GitHub
#           release, so the stable feed
#           https://github.com/<repo>/releases/latest/download/enso-appcast.xml
#           picks it up via GitHub's "latest" redirect (which skips
#           prereleases).
#   next    X.Y.Z-next.N   e.g. 0.10.0-next.1  (1 <= N <= 98)
#           ReleaseNext configuration -> "Enso Next.app"
#           (com.amanchaudhary.enso.next), Enso-Next-<version>.dmg,
#           enso-next-appcast.xml. Published twice:
#             1. a versioned release at tag v<version>, marked --prerelease
#                so it never becomes "latest" and never leaks into the
#                stable feed; the appcast enclosure URLs point here so they
#                keep working for that specific version forever.
#             2. a ROLLING prerelease at the fixed tag "next" ("Enso Next
#                (rolling)"), created once if missing; each next release
#                re-uploads (--clobber) the DMG and enso-next-appcast.xml
#                onto it, so the fixed next feed URL
#                https://github.com/<repo>/releases/download/next/enso-next-appcast.xml
#                always serves the newest appcast.
#
# Build number (CFBundleVersion) formula, both channels:
#   major*1000000 + minor*10000 + patch*100 + n
# where n is the -next.N number and stable uses n=99, so a stable X.Y.Z
# outranks every X.Y.Z-next.N. This replaced the old major*10000+minor*100+
# patch formula and stays monotonic against it (old 0.9.0 -> 900; every new
# number is strictly larger).
#
# One-time setup:
#   xcrun notarytool store-credentials enso-notary \
#       --apple-id <apple-id-email> --team-id HFXABN57R2
#   Sparkle EdDSA private key lives in the login keychain ("Private key for
#   signing Sparkle updates"); generate_appcast reads it automatically.
#
# Usage: script/release.sh <version> [--skip-notarize]
#   e.g. script/release.sh 0.10.0
#        script/release.sh 0.10.0-next.1
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: script/release.sh <version> [--skip-notarize]}"
IDENTITY="Developer ID Application: Aman Chaudhary (HFXABN57R2)"
PROFILE="enso-notary"
REPO="amanfromsolan/enso"
BUILD_DIR="build/release"

# Strict version validation + channel detection: X.Y.Z is stable,
# X.Y.Z-next.N (N >= 1) is next; anything else is rejected. Stable claims
# n=99 in the build-number formula, so next numbers must stay below it.
if [[ "$VERSION" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]]; then
    CHANNEL="stable"
    MAJOR=$match[1] MINOR=$match[2] PATCH=$match[3]
    PRE_N=99
elif [[ "$VERSION" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)-next\.([1-9][0-9]*)$' ]]; then
    CHANNEL="next"
    MAJOR=$match[1] MINOR=$match[2] PATCH=$match[3]
    PRE_N=$match[4]
    if (( PRE_N > 98 )); then
        echo "error: -next.N must be <= 98 (99 is reserved for the stable build)" >&2
        exit 1
    fi
else
    echo "error: version must be X.Y.Z or X.Y.Z-next.N (N >= 1), got '$VERSION'" >&2
    exit 1
fi
BUILD_NUM=$((MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + PRE_N))

# Everything that differs between the channels lives here.
if [[ "$CHANNEL" == "stable" ]]; then
    CONFIGURATION="Release"
    APP_NAME="Enso"
    DMG_BASENAME="Enso-$VERSION.dmg"
    APPCAST_NAME="enso-appcast.xml"
    RELEASE_TITLE="Enso v$VERSION"
    PRERELEASE_FLAGS=()
else
    CONFIGURATION="ReleaseNext"
    APP_NAME="Enso Next"
    DMG_BASENAME="Enso-Next-$VERSION.dmg"
    APPCAST_NAME="enso-next-appcast.xml"
    RELEASE_TITLE="Enso Next v$VERSION"
    PRERELEASE_FLAGS=(--prerelease)
fi
APP="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG="$HOME/Downloads/$DMG_BASENAME"

# Release notes are mandatory and validated before the (slow) build:
# RELEASE_NOTES/<version>.md in the strict '## Section' / '- item' subset.
# They end up embedded in the appcast (What's New sheet) and as the GitHub
# release body. Same requirement for both channels.
NOTES_MD="RELEASE_NOTES/$VERSION.md"
if [[ ! -f "$NOTES_MD" ]]; then
    echo "error: $NOTES_MD missing — write the release notes first" >&2
    exit 1
fi
python3 script/release_notes.py "$NOTES_MD" > /dev/null

# ARCHS=arm64: the locally built GhosttyKit.xcframework has only an arm64
# slice, and Release-family configs default to universal (ONLY_ACTIVE_ARCH
# = NO), which fails at the x86_64 link.
echo "==> Building $CONFIGURATION v$VERSION [$CHANNEL] (build $BUILD_NUM) with hardened runtime"
xcodebuild -project macos/Enso.xcodeproj -scheme Enso -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM=HFXABN57R2 \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    ARCHS=arm64 \
    build | grep -E "error|warning: Signing|BUILD" || true

# Bake this version's notes into the bundle: the command palette's
# "What's New" reads Resources/ReleaseNotes.html so the changelog opens
# on demand, offline. Injected before signing so the seal covers it.
echo "==> Bundling release notes into the app"
python3 script/release_notes.py "$NOTES_MD" > "$APP/Contents/Resources/ReleaseNotes.html"

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
    --entitlements macos/Enso/Enso.entitlements --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"
echo "==> Signed as: $(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1)"

echo "==> Packaging DMG"
STAGE="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
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
# item's release notes (<description> in the appcast). The enclosure URLs
# point at the immutable versioned v<version> release for both channels, so
# a given appcast item keeps downloading the exact build it was signed for.
python3 script/release_notes.py "$NOTES_MD" > "$APPCAST_DIR/${DMG_BASENAME%.dmg}.html"
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --maximum-deltas 0

# The stable asset is named enso-appcast.xml, not appcast.xml: pre-rename
# Bloom installs follow GitHub's repo redirect to this repo's latest
# release, and an asset named appcast.xml would offer them Enso updates
# they can't install (bundle id mismatch). The old name 404s for them
# instead. The next channel gets enso-next-appcast.xml for the same
# separation. generate_appcast names its output after the SUFeedURL baked
# into the app's Info.plist — which is the STABLE feed even in Next builds
# (the next app overrides its feed at runtime via SPUUpdaterDelegate) — or
# plain appcast.xml on some Sparkle versions. Normalize whatever single xml
# it wrote to the channel's asset name.
GENERATED_XML=("$APPCAST_DIR"/*.xml(N))
if (( ${#GENERATED_XML} != 1 )); then
    echo "error: expected exactly one generated appcast xml, got: ${GENERATED_XML[*]:-none}" >&2
    exit 1
fi
if [[ "${GENERATED_XML[1]}" != "$APPCAST_DIR/$APPCAST_NAME" ]]; then
    mv "${GENERATED_XML[1]}" "$APPCAST_DIR/$APPCAST_NAME"
fi

echo "==> Publishing GitHub release v$VERSION"
# --target pins the tag to the commit actually built, not the default
# branch HEAD — next builds ship from the `next` branch before merging.
gh release create "v$VERSION" \
    "$DMG" \
    "$APPCAST_DIR/$APPCAST_NAME" \
    --repo "$REPO" \
    --title "$RELEASE_TITLE" \
    --notes-file "$NOTES_MD" \
    --target "$(git rev-parse HEAD)" \
    "${PRERELEASE_FLAGS[@]}"

# The next channel additionally maintains a rolling release at the fixed
# tag "next" so the app's feed URL never changes. Create it once if
# missing (as a prerelease, so it can never become "latest"), then clobber
# the assets with each new build. The appcast inside still points at the
# versioned release above, so older enclosure URLs stay valid.
if [[ "$CHANNEL" == "next" ]]; then
    echo "==> Updating rolling 'next' release"
    if ! gh release view next --repo "$REPO" > /dev/null 2>&1; then
        gh release create next \
            --repo "$REPO" \
            --title "Enso Next (rolling)" \
            --prerelease \
            --notes "Rolling pointer to the newest next-channel build. The Enso Next feed always reads enso-next-appcast.xml from this release."
    fi
    gh release upload next \
        "$DMG" \
        "$APPCAST_DIR/$APPCAST_NAME" \
        --repo "$REPO" \
        --clobber
    # --clobber only replaces same-named assets, and each DMG's name embeds
    # its version — prune everything except this build's pair so the rolling
    # release doesn't accumulate old DMGs. Their canonical home stays the
    # versioned v<version> prerelease, which the appcast enclosures use.
    gh release view next --repo "$REPO" --json assets --jq '.assets[].name' \
        | while read -r ASSET; do
            if [[ "$ASSET" != "$DMG_BASENAME" && "$ASSET" != "$APPCAST_NAME" ]]; then
                gh release delete-asset next "$ASSET" --repo "$REPO" --yes
            fi
        done
fi

echo "==> Done: https://github.com/$REPO/releases/tag/v$VERSION"

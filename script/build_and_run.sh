#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="cmux-alternative"
BUNDLE_ID="com.amanchaudhary.cmux-alternative"
PROJECT="cmux-alternative.xcodeproj"
TARGET="cmux-alternative"
CONFIGURATION="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -target "$TARGET" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  SDK_STAT_CACHE_ENABLE=NO \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

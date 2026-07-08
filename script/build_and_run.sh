#!/usr/bin/env bash
set -euo pipefail

# Builds and launches the Debug build ("Bloom Dev", bundle id
# com.amanchaudhary.bloom.debug) alongside the installed release Bloom.
# Everything here is scoped to the DerivedData copy by full executable
# path — never by process name, which the installed Bloom shares.

MODE="${1:-run}"
APP_NAME="Bloom"
PROJECT="Bloom.xcodeproj"
SCHEME="Bloom"
CONFIGURATION="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

# Kill only a previously launched dev instance (exact executable path).
pkill -f "^$APP_EXECUTABLE" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  SDK_STAT_CACHE_ENABLE=NO \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

dev_pid() {
  pgrep -f "^$APP_EXECUTABLE" | head -1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    open_app
    sleep 1
    PID="$(dev_pid)"
    /usr/bin/log stream --info --style compact --predicate "processID == $PID"
    ;;
  --verify|verify)
    open_app
    sleep 1
    dev_pid >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac

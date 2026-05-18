#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Local Video Uploader"
SCHEME_NAME="iPhoto2YouTubeNativeApp"
PROJECT_PATH="iPhoto2YouTubeNativeApp.xcodeproj"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-derived"
DIST_DIR="$ROOT_DIR/dist"
SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
STAGED_APP_PATH="$DIST_DIR/$APP_NAME.app"
APP_BINARY_PATH="$STAGED_APP_PATH/Contents/MacOS/$APP_NAME"

build_app() {
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

stage_app() {
  rm -rf "$STAGED_APP_PATH"
  mkdir -p "$DIST_DIR"
  /usr/bin/ditto "$SOURCE_APP_PATH" "$STAGED_APP_PATH"
  /usr/bin/touch "$STAGED_APP_PATH" "$STAGED_APP_PATH/Contents/Info.plist"
}

open_app() {
  /usr/bin/open -n "$STAGED_APP_PATH"
}

stream_logs() {
  /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
}

stream_telemetry() {
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.example.iPhoto2YouTubeNativeApp\""
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

build_app
stage_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY_PATH"
    ;;
  --logs|logs)
    open_app
    stream_logs
    ;;
  --telemetry|telemetry)
    open_app
    stream_telemetry
    ;;
  --verify|verify)
    test -x "$APP_BINARY_PATH"
    ;;
  --build-only|build-only)
    test -d "$STAGED_APP_PATH"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac

#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iPhoto2YouTube.app"
DERIVED_DATA_DIR="$ROOT_DIR/.xcode-derived-data"
BUILD_APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"
ROOT_APP_PATH="$ROOT_DIR/$APP_NAME"
CLI_PATH="$ROOT_DIR/.venv/bin/iphoto2youtube"

if [[ ! -x "$CLI_PATH" ]]; then
  echo "CLI が見つかりません: $CLI_PATH"
  echo "先に README のセットアップ手順どおりに .venv を用意してください。"
  read -r "?Enter を押すと終了します。"
  exit 1
fi

if [[ ! -d "$BUILD_APP_PATH" ]]; then
  echo "初回起動のため macOS アプリをビルドしています..."
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/iPhoto2YouTubeNativeApp.xcodeproj" \
    -scheme iPhoto2YouTubeNativeApp \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
fi

if [[ ! -d "$ROOT_APP_PATH" || "$BUILD_APP_PATH" -nt "$ROOT_APP_PATH" ]]; then
  /usr/bin/ditto "$BUILD_APP_PATH" "$ROOT_APP_PATH"
  /usr/bin/codesign --force --deep --sign - "$ROOT_APP_PATH"
fi

open "$ROOT_APP_PATH"

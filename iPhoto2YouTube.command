#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Local Video Uploader.app"
DERIVED_DATA_DIR="$ROOT_DIR/.xcode-derived-data"
BUILD_APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"
ROOT_APP_PATH="$ROOT_DIR/$APP_NAME"
CLI_PATH="$ROOT_DIR/.venv/bin/iphoto2youtube"

if [[ ! -x "$CLI_PATH" ]]; then
  if [[ ! -d "$ROOT_DIR/src/iphoto2youtube_cli" ]]; then
    echo "CLI ソースが見つかりません: $ROOT_DIR/src/iphoto2youtube_cli"
    read -r "?Enter を押すと終了します。"
    exit 1
  fi

  PYTHON_BIN="$(command -v python3 || true)"
  if [[ -z "$PYTHON_BIN" ]]; then
    echo "python3 が見つかりません。"
    read -r "?Enter を押すと終了します。"
    exit 1
  fi

  echo "仮想環境の CLI は見つかりませんでしたが、src から直接起動できる状態です。"
fi

echo "macOS アプリをビルドしています..."
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/iPhoto2YouTubeNativeApp.xcodeproj" \
  -scheme iPhoto2YouTubeNativeApp \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

if [[ ! -d "$ROOT_APP_PATH" || "$BUILD_APP_PATH" -nt "$ROOT_APP_PATH" ]]; then
  /usr/bin/ditto "$BUILD_APP_PATH" "$ROOT_APP_PATH"
  /usr/bin/codesign --force --deep --sign - "$ROOT_APP_PATH"
fi

open "$ROOT_APP_PATH"

#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="Mix Web 部署工具"
EXECUTABLE_NAME="MixWebDeploy"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/module-cache"

mkdir -p "$MODULE_CACHE_DIR"
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
swift build \
    --disable-sandbox \
    --scratch-path "$PROJECT_DIR/.build" \
    --package-path "$PROJECT_DIR" \
    -c release

mkdir -p "$DIST_DIR"
if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$PROJECT_DIR/.build/release/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

chmod 755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"

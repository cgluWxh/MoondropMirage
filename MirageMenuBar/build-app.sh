#!/bin/sh
set -eu

cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mirage-menubar-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export XDG_CACHE_HOME="${TMPDIR:-/tmp}/mirage-menubar-xdg-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
swift build -c release --scratch-path .build --disable-sandbox

APP_DIR="build/Mirage Menu Bar.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/MirageMenuBar "$CONTENTS/MacOS/MirageMenuBar"
cp Info.plist "$CONTENTS/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"

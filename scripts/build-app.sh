#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

if ! APP_GIT_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null)"; then
    print -u2 "Error: no Git tag is reachable from the current branch. Add a tag before building."
    exit 1
fi
APP_SHORT_VERSION="${APP_GIT_TAG#v}"

mkdir -p /private/tmp/easyview-clang-cache /private/tmp/easyview-swiftpm-cache
CLANG_MODULE_CACHE_PATH=/private/tmp/easyview-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/easyview-swiftpm-cache \
swift build -c release --scratch-path "$ROOT_DIR/.build"

APP_DIR="$ROOT_DIR/dist/简图.app"
CONTENTS_DIR="$APP_DIR/Contents"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/EasyView" "$CONTENTS_DIR/MacOS/EasyView"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_SHORT_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :EasyViewGitTag $APP_GIT_TAG" "$CONTENTS_DIR/Info.plist"
# Swift signs the executable during its build, but the app bundle is assembled
# afterwards. Sign the completed bundle so its Info.plist and resources are
# included in one consistent local signature.
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"

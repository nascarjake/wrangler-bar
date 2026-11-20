#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=13.5
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/module-cache}"
swift build -c release --arch arm64 --arch x86_64 --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
APP="dist/Wrangler Bar.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCHIVE="Wrangler-Bar-$VERSION-universal-macos.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/WranglerBar "$APP/Contents/MacOS/WranglerBar"
strip -S "$APP/Contents/MacOS/WranglerBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# Ad-hoc integrity signature only; no Developer ID or notarization is implied.
codesign --force --sign - --identifier com.jakedoesdev.wranglerbar --timestamp=none "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > SHA256SUMS)

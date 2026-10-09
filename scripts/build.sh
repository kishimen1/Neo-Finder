#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
mkdir -p .build/module-cache .build/swift-module-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build --disable-sandbox --cache-path .build/cache -c "$configuration" --product NeoFinder
binary_dir="$(swift build --disable-sandbox --cache-path .build/cache -c "$configuration" --show-bin-path)"
app="$PWD/dist/Neo-Finder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/NeoFinder" "$app/Contents/MacOS/NeoFinder"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/NeoFinder.entitlements "$app"
codesign --verify --strict "$app"
printf 'Built: %s\n' "$app"

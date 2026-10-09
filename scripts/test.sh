#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/swift-module-cache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
plugin_dir="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugin_dir" ]; then
    swift test --disable-sandbox --cache-path .build/cache -Xswiftc -plugin-path -Xswiftc "$plugin_dir"
else
    swift test --disable-sandbox --cache-path .build/cache
fi

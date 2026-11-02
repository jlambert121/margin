#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
for script in web/src/*.js; do
  node --check "$script"
done
plutil -lint Resources/Info.plist
swiftc -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework WebKit tests/EditorTests.swift -o build/EditorTests
./build/EditorTests "$PWD" "$PWD/build/editor-screenshot.png"

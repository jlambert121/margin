#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
node --check web/src/app.js
plutil -lint Resources/Info.plist
swiftc -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework WebKit tests/EditorTests.swift -o build/EditorTests
./build/EditorTests "$PWD" "$PWD/build/editor-screenshot.png"

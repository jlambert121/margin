#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
node --check web/src/app.js
plutil -lint Resources/Info.plist
swiftc -module-cache-path "$PWD/build/module-cache" -framework Cocoa -framework WebKit tests/EditorTests.swift -o build/EditorTests
./build/EditorTests "$PWD" "$PWD/build/editor-screenshot.png"

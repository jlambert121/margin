#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
node --check web/src/app.js
node --check web/src/diagnostics.js
plutil -lint Resources/Info.plist
./scripts/test-native.sh
swiftc -D TESTING -parse-as-library -module-cache-path "$PWD/build/module-cache" -framework Cocoa -framework WebKit Sources/*.swift tests/DocumentTests.swift -o build/DocumentTests
./build/DocumentTests
node tests/editor-dom.mjs

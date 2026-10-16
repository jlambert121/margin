#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
node --check web/src/app.js
node --check web/src/diagnostics.js
node --check web/src/markdown.js
node --check web/src/live-preview.js
plutil -lint Resources/Info.plist
./scripts/test-native.sh
swiftc -D TESTING -parse-as-library -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework WebKit Sources/*.swift tests/DocumentTests.swift -o build/DocumentTests
./build/DocumentTests
./scripts/test-webkit.sh

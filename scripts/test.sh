#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
node --test tests/planning.test.mjs tests/execution.test.mjs
for script in web/src/*.js; do
  node --check "$script"
done
plutil -lint Resources/Info.plist
./scripts/test-workspace.sh
./scripts/test-native.sh
swiftc -D TESTING -parse-as-library -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework WebKit Sources/*.swift tests/DocumentTests.swift -o build/DocumentTests
./build/DocumentTests
./scripts/test-webkit.sh

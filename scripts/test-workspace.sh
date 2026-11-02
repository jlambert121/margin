#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" Sources/WorkspaceScanner.swift tests/WorkspaceScannerTests.swift -o build/WorkspaceScannerTests
./build/WorkspaceScannerTests

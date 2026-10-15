#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_APP="$PWD/build/NativeIntegrationTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" build/module-cache
mkdir -p "$TEST_APP/Contents/Resources"
cp Resources/Welcome.md "$TEST_APP/Contents/Resources/Welcome.md"
rsync -a --delete web/ "$TEST_APP/Contents/Resources/web/"
python3 - "$TEST_APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open('Resources/Info.plist', 'rb') as source:
    info = plistlib.load(source)
info['CFBundleExecutable'] = 'NativeIntegrationTests'
info['CFBundleIdentifier'] = 'com.infiniteviewtech.margin.native-tests'
with open(sys.argv[1], 'wb') as target:
    plistlib.dump(info, target)
PY
swiftc -D TESTING -parse-as-library -module-name Margin -module-cache-path "$PWD/build/module-cache" -framework Cocoa -framework WebKit Sources/*.swift tests/NativeIntegrationTests.swift -o "$TEST_APP/Contents/MacOS/NativeIntegrationTests"
"$TEST_APP/Contents/MacOS/NativeIntegrationTests" "$@"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Margin.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
swiftc -O -parse-as-library -module-cache-path "$PWD/build/module-cache" -framework Cocoa -framework WebKit -target "$(uname -m)-apple-macosx13.0" Sources/*.swift -o "$APP/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Welcome.md "$APP/Contents/Resources/Welcome.md"
rsync -a --delete web/ "$APP/Contents/Resources/web/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"

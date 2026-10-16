#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/module-cache.sh
APP="$PWD/build/Margin.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -module-cache-path "$MODULE_CACHE" -framework Cocoa -framework WebKit -target "$(uname -m)-apple-macosx13.0" Sources/*.swift -o "$APP/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Welcome.md "$APP/Contents/Resources/Welcome.md"
rsync -a --delete web/ "$APP/Contents/Resources/web/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
rsync -a --delete Resources/Icons/ "$APP/Contents/Resources/Icons/"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swift -module-cache-path build/module-cache scripts/make-icon.swift build/AppIcon.iconset Resources/Icons
python3 - <<'PY'
from pathlib import Path
import struct
chunks = []
for tag, name in [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]:
    data = (Path('build/AppIcon.iconset') / name).read_bytes()
    chunks.append(tag.encode() + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
Path('Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
PY

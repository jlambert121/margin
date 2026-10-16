#!/bin/bash
# Rebuilds the vendored editor bundle from the pinned devDependencies. Only
# needed after changing tools/editor-bundle or a dependency version; the app
# build uses the committed web/vendor files and needs no Node.js.
set -euo pipefail
cd "$(dirname "$0")/.."
npx --no-install rollup --config tools/editor-bundle/rollup.config.mjs

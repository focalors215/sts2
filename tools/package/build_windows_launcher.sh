#!/usr/bin/env bash
# Build the Windows cottage launcher (windows/, Electron). Output: dist/windows/.
# On Linux/macOS this builds the portable zip; the NSIS installer additionally needs Windows (or Wine).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT/windows"

if [[ ! -d node_modules ]]; then
  npm ci
fi
npm test
npm run prepare-assets

TARGETS=(zip)
if [[ "${OS:-}" == "Windows_NT" ]] || command -v wine >/dev/null 2>&1; then
  TARGETS+=(nsis)
fi
npx electron-builder --win "${TARGETS[@]}" --x64

echo "Windows launcher written to $ROOT/dist/windows/"
ls -1 "$ROOT/dist/windows/"*.zip "$ROOT/dist/windows/"*.exe 2>/dev/null || true

#!/usr/bin/env bash
# Build the Windows cottage launcher (windows/, Electron). Output: dist/windows/.
# Builds the portable zip and, on Windows / macOS (or Linux with Wine), the NSIS installer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# 联机小屋：frp 助手（需要 Go）与 PC 联机组件 MOD（需要 .NET 9 + 原版 sts2.dll 引用）。
# 缺工具时跳过并给出提示，启动器的联机小屋会显示“缺少联机组件”。
for step in build-frp-helper build-online-mod; do
  if ! bash "$ROOT/tools/windows/$step.sh"; then
    if [[ "${STS2_REQUIRE_ONLINE:-0}" == "1" ]]; then
      exit 1
    fi
    echo "warning: tools/windows/$step.sh failed; the package will not include it." >&2
  fi
done

cd "$ROOT/windows"

if [[ ! -d node_modules ]]; then
  npm ci
fi
npm test
npm run prepare-assets

TARGETS=(zip)
# electron-builder 在 Windows / macOS 上直接带 makensis；Linux 需要 Wine。
if [[ "${OS:-}" == "Windows_NT" || "$(uname -s)" == "Darwin" ]] || command -v wine >/dev/null 2>&1; then
  TARGETS+=(nsis)
fi
npx electron-builder --win "${TARGETS[@]}" --x64

echo "Windows launcher written to $ROOT/dist/windows/"
ls -1 "$ROOT/dist/windows/"*.zip "$ROOT/dist/windows/"*.exe 2>/dev/null || true

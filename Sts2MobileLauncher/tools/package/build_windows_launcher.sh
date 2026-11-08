#!/usr/bin/env bash
# Build the Windows cottage launcher (windows/, Electron). Output: dist/windows/.
# Builds the portable zip and, on Windows / macOS (or Linux with Wine), the NSIS installer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# 联机小屋：frp 助手（需要 Go）与小屋联机组件 STS2CottageOnline（需要 .NET 9 与原版 v0.107.1 /
# v0.111.0 程序集，按版本分别构建）。缺工具或引用时跳过并给出提示，启动器的联机页会显示缺少联机组件。
# 清掉旧版启动器遗留的 Reforged / BaseLib 构建，避免被 extraResources 打进安装包。
rm -rf "$ROOT/windows/resources/online-mod/SlayTheSpire2.LAN.Multiplayer.Reforged" "$ROOT/windows/resources/online-mod/BaseLib" "$ROOT/windows/resources/online-mod/STS2CottageOnline"
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

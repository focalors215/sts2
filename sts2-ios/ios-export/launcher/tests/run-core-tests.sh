#!/usr/bin/env bash
# 启动器核心逻辑宿主单测（不需要设备/游戏）。在 sts2-ios 根目录运行。
set -euo pipefail
L=ios-export/launcher
OUT=${TMPDIR:-/private/tmp}/sts2-launcher-core-tests
xcrun --sdk macosx clang++ -std=gnu++17 -DSTS2_SECRET_STORE_MEMORY \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -Wno-unused-command-line-argument -framework Foundation -framework Security -lz \
  $L/STS2Log.mm $L/STS2LogCenter.mm $L/STS2LogAnalysis.mm $L/STS2PendingAction.mm \
  $L/STS2RoomService.mm $L/STS2FrpTunnel.mm $L/STS2LauncherConfigStore.mm $L/STS2SecretStore.mm \
  $L/STS2ZipArchive.mm $L/STS2NexusMods.mm $L/STS2UpdateChecker.mm $L/tests/STS2LauncherCoreTests.mm -o "$OUT"
"$OUT"

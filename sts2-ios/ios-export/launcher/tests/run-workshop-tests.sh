#!/usr/bin/env bash
# 创意工坊纯逻辑宿主测试（不联网）。在 sts2-ios 根目录运行。
set -euo pipefail
L=ios-export/launcher
OUT=${TMPDIR:-/private/tmp}/sts2-workshop-tests
LZ=$(mktemp /private/tmp/sts2-vzip.XXXXXX)
python3 -I -c "import lzma,sys; open(sys.argv[1],'wb').write(lzma.compress(('slay the spire 2 '*400)[:4000].encode(), format=lzma.FORMAT_ALONE))" "$LZ"
xcrun --sdk macosx clang++ -std=gnu++17 -fobjc-arc -fblocks -Wall -Werror -Wno-unused-command-line-argument \
  -framework Foundation -lz $L/STS2Log.mm $L/STS2ZipArchive.mm $L/STS2SteamWorkshop.mm $L/tests/STS2WorkshopTests.mm -o "$OUT"
"$OUT" "$LZ"

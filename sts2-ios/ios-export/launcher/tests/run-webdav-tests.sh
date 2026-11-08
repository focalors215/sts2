#!/usr/bin/env bash
# WebDAV 云存档端到端宿主测试（本地临时服务器，不访问外网）。在 sts2-ios 根目录运行。
set -euo pipefail
L=ios-export/launcher
OUT=${TMPDIR:-/private/tmp}/sts2-webdav-tests
ROOT=$(mktemp -d /private/tmp/sts2-dav-server.XXXXXX)
PORT=$((20000 + RANDOM % 20000))
xcrun --sdk macosx clang++ -std=gnu++17 -fobjc-arc -fblocks -Wall -Werror -Wno-unused-command-line-argument \
  -framework Foundation $L/STS2Log.mm $L/STS2WebDavSync.mm $L/tests/STS2WebDavSyncTests.mm -o "$OUT"
python3 -I $L/tests/webdav_test_server.py "$ROOT" "$PORT" & SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
"$OUT" "$PORT" "$ROOT"

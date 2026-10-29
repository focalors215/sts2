#!/usr/bin/env bash
# Build the in-process frp client (android/frp-bridge, official frp library) as an
# Android arm64 shared library for the launcher's online rooms.
# Output: android/libs/frp/arm64-v8a/libsts2frp.so (ignored by git).
# Needs Go (GO_BIN / build.go_bin, else PATH) and the Android NDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
sts2_init_env

GO_BIN="$(sts2_config_path GO_BIN build.go_bin "$(command -v go || true)")"
sts2_require_executable "$GO_BIN" "Go toolchain (set GO_BIN in .env)"
NDK_VERSION="$(sed -n "s/.*ndkVersion *: *'\([^']*\)'.*/\1/p" "$ROOT/android/config.gradle" | head -1)"
NDK_DIR="${ANDROID_NDK_HOME:-${ANDROID_HOME:-}/ndk/${NDK_VERSION:-28.1.13356709}}"
MIN_SDK=24
CC_BIN="$(ls -d "$NDK_DIR"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)/aarch64-linux-android${MIN_SDK}-clang"
sts2_require_executable "$CC_BIN" "Android NDK clang"

OUT="$ROOT/android/libs/frp/arm64-v8a"
mkdir -p "$OUT"
cd "$ROOT/android/frp-bridge"
GOTOOLCHAIN=local GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$CC_BIN" \
  "$GO_BIN" build -trimpath -buildmode=c-shared -ldflags "-s -w" -o "$OUT/libsts2frp.so" .
rm -f "$OUT/libsts2frp.h"
echo "Built $OUT/libsts2frp.so"

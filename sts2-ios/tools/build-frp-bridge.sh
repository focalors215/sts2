#!/usr/bin/env bash
# Build the in-process frp client (src/FrpBridge) as an iOS arm64 static library.
# Output: ios-export/prebuilt/frp/libfrpbridge.a + libfrpbridge.h (ignored by git).
# GO_BIN may point at a Go toolchain; defaults to the workspace toolchain, then PATH.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$REPO/../ipad-tools/toolchain"
GO_BIN="${GO_BIN:-$TOOLCHAIN/go/bin/go}"
[ -x "$GO_BIN" ] || GO_BIN="$(command -v go || true)"
[ -x "$GO_BIN" ] || { echo "Go toolchain not found; set GO_BIN" >&2; exit 1; }
if [ -d "$TOOLCHAIN" ]; then
    export GOPATH="${GOPATH:-$TOOLCHAIN/gopath}" GOCACHE="${GOCACHE:-$TOOLCHAIN/gocache}"
fi
MIN_IOS="${STS2_IOS_MIN_VERSION:-18.0}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$REPO/ios-export/prebuilt/frp"
mkdir -p "$OUT"
cd "$REPO/src/FrpBridge"
GOTOOLCHAIN=local GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
    CC="$(xcrun --sdk iphoneos -f clang) -isysroot $SDK -arch arm64 -miphoneos-version-min=$MIN_IOS" \
    CGO_CFLAGS="-fembed-bitcode=off" \
    "$GO_BIN" build -trimpath -buildmode=c-archive -ldflags "-s -w" -o "$OUT/libfrpbridge.a" .
echo "Built $OUT/libfrpbridge.a"

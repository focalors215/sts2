#!/usr/bin/env bash
# Stage the official frp client (frpc) for the cottage "online rooms" feature.
# The launcher runs it as a child process from nativeLibraryDir, so it is packaged as
# lib/arm64-v8a/libfrpc.so (legacy native-lib packaging extracts it to disk on install).
# Same frp version as the iPad launcher (sts2-ios/src/FrpBridge). Nothing is committed:
# the tarball is cached under .agent/cache/frp and verified against the pinned SHA-256.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
sts2_init_env

FRP_VERSION="0.71.1"
FRP_ARCHIVE="frp_${FRP_VERSION}_android_arm64.tar.gz"
FRP_SHA256="9dce8c10e66bdf1a0cff19bf2cd1a3f4f7389fccee8ca0cda57a7a7c0d87af3a"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_ARCHIVE}"
CACHE_DIR="$(sts2_config_path STS2_FRPC_CACHE_DIR runtime.frpc_cache_dir "$ROOT/.agent/cache/frp")"
# Optional: a locally built/verified android/arm64 frpc instead of downloading.
LOCAL_FRPC="$(sts2_config_path STS2_FRPC_BINARY runtime.frpc_binary "${STS2_FRPC_BINARY:-}")"

frpc=""
if [[ -n "$LOCAL_FRPC" ]]; then
  [[ -f "$LOCAL_FRPC" ]] || { echo "STS2_FRPC_BINARY not found: $LOCAL_FRPC" >&2; exit 1; }
  frpc="$LOCAL_FRPC"
else
  mkdir -p "$CACHE_DIR"
  archive="$CACHE_DIR/$FRP_ARCHIVE"
  if [[ ! -f "$archive" ]] || ! echo "$FRP_SHA256  $archive" | sha256sum -c --status; then
    rm -f "$archive.part"
    curl -fsSL --retry 3 -o "$archive.part" "$FRP_URL"
    mv -f "$archive.part" "$archive"
  fi
  if ! echo "$FRP_SHA256  $archive" | sha256sum -c --status; then
    echo "frp archive SHA-256 mismatch: $archive" >&2
    exit 1
  fi
  extract="$CACHE_DIR/frp_${FRP_VERSION}_android_arm64"
  rm -rf "$extract"
  tar -xzf "$archive" -C "$CACHE_DIR" "frp_${FRP_VERSION}_android_arm64/frpc" "frp_${FRP_VERSION}_android_arm64/LICENSE"
  frpc="$extract/frpc"
fi

for variant in debug dev release; do
  dir="$ROOT/android/libs/$variant/arm64-v8a"
  mkdir -p "$dir"
  install -m 0755 "$frpc" "$dir/libfrpc.so"
done
printf 'Staged frpc %s for online rooms: %s\n' "$FRP_VERSION" "$frpc"

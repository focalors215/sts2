#!/usr/bin/env bash
# Build the Windows launcher's frp client helper (windows/frp-helper, official frp v0.71.1
# library, same as the iPad / Android online rooms) for windows/amd64.
# Output: windows/resources/frp/sts2-frpc.exe (ignored by git; packaged as an extra resource).
# Needs Go (GO_BIN / build.go_bin, else PATH); optional GOPATH / GOCACHE pointing at a
# module cache that already holds frp for offline builds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
sts2_init_env

GO_BIN="$(sts2_config_path GO_BIN build.go_bin "$(command -v go || true)")"
sts2_require_executable "$GO_BIN" "Go toolchain (set GO_BIN in .env)"

OUT="$ROOT/windows/resources/frp"
mkdir -p "$OUT"
cd "$ROOT/windows/frp-helper"
GOTOOLCHAIN=local GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$OUT/sts2-frpc.exe" .
echo "Built $OUT/sts2-frpc.exe"

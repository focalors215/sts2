#!/usr/bin/env bash
# Build the PC multiplayer component MOD (windows/online-mod) that the Windows launcher
# installs into <game>/mods/STS2CottageOnline/ for online rooms and LAN direct connect.
# References: STS2_WINDOWS_MOD_REFERENCE_DIR, else STS2_ORIGINAL_V1110_REFERENCE_DIR (sts2.dll,
# GodotSharp.dll, 0Harmony.dll of the matching PC game version).
# Output: windows/resources/online-mod/STS2CottageOnline/ (ignored by git; packaged as an extra resource).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
sts2_init_env

DOTNET="$(sts2_config_path DOTNET_BIN build.dotnet_bin "$(command -v dotnet || true)")"
sts2_require_executable "$DOTNET" ".NET 9 SDK (set DOTNET_BIN in .env)"
REF_DIR="${STS2_WINDOWS_MOD_REFERENCE_DIR:-${STS2_ORIGINAL_V1110_REFERENCE_DIR:-${STS2_ORIGINAL_V1110_ROOT:-}}}"
for name in sts2.dll GodotSharp.dll 0Harmony.dll; do
  if [[ ! -f "$REF_DIR/$name" ]]; then
    echo "Missing $REF_DIR/$name (set STS2_WINDOWS_MOD_REFERENCE_DIR or STS2_ORIGINAL_V1110_REFERENCE_DIR in .env)" >&2
    exit 1
  fi
done

PROJECT="$ROOT/windows/online-mod"
OUT="$ROOT/windows/resources/online-mod/STS2CottageOnline"
BUILD="$ROOT/windows/online-mod/bin/build"
rm -rf "$OUT" "$BUILD"
mkdir -p "$OUT"
"$DOTNET" build "$PROJECT/STS2CottageOnline.csproj" -c Release -nologo -v:minimal \
  -p:GameReferenceDir="$REF_DIR" -o "$BUILD"
cp "$BUILD/STS2CottageOnline.dll" "$BUILD/STS2CottageOnline.json" "$OUT/"
echo "Built $OUT"

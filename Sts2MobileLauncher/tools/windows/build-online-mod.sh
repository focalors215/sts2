#!/usr/bin/env bash
# Build version-specific Windows multiplayer mods against matching original game assemblies.
# STS2_ONLINE_MOD_VERSION selects one version; otherwise build each version with available references.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
# Keep explicitly supplied references when the config loader cannot resolve paths on Windows.
EXPLICIT_REF_DIR="${STS2_WINDOWS_MOD_REFERENCE_DIR:-}"
if [[ -n "$EXPLICIT_REF_DIR" && -z "${STS2_ONLINE_MOD_VERSION:-}" ]]; then
  echo 'STS2_WINDOWS_MOD_REFERENCE_DIR requires STS2_ONLINE_MOD_VERSION to avoid mixing game versions.' >&2
  exit 1
fi
EXPLICIT_1071_REF_DIR="${STS2_ORIGINAL_V1071_REFERENCE_DIR:-}"
EXPLICIT_1110_REF_DIR="${STS2_ORIGINAL_V1110_REFERENCE_DIR:-}"
sts2_init_env

DOTNET="$(sts2_config_path DOTNET_BIN build.dotnet_bin "$(command -v dotnet || true)")"
DOTNET="${DOTNET:-$(command -v dotnet || true)}"
sts2_require_executable "$DOTNET" ".NET 9 SDK (set DOTNET_BIN in .env)"
PROJECT="$ROOT/windows/online-mod"
BUILT=0
VERSIONS=(v0.107.1 v0.111.0)
if [[ -n "${STS2_ONLINE_MOD_VERSION:-}" ]]; then
  case "$STS2_ONLINE_MOD_VERSION" in
    v0.107.1|v0.111.0) VERSIONS=("$STS2_ONLINE_MOD_VERSION") ;;
    *) echo "Unsupported STS2_ONLINE_MOD_VERSION: $STS2_ONLINE_MOD_VERSION" >&2; exit 1 ;;
  esac
fi

for version in "${VERSIONS[@]}"; do
  case "$version" in
    v0.107.1) REF_DIR="${EXPLICIT_REF_DIR:-${EXPLICIT_1071_REF_DIR:-${STS2_ORIGINAL_V1071_REFERENCE_DIR:-${STS2_ORIGINAL_V1071_ROOT:-}}}}" ;;
    v0.111.0) REF_DIR="${EXPLICIT_REF_DIR:-${EXPLICIT_1110_REF_DIR:-${STS2_ORIGINAL_V1110_REFERENCE_DIR:-${STS2_ORIGINAL_V1110_ROOT:-}}}}" ;;
  esac
  if [[ -z "$REF_DIR" && "$version" == 'v0.107.1' && -n "${ProgramFiles_x86:-}" ]]; then
    REF_DIR="$ProgramFiles_x86/Steam/steamapps/common/Slay the Spire 2/data_sts2_windows_x86_64"
  fi
  for name in sts2.dll GodotSharp.dll 0Harmony.dll; do
    if [[ ! -f "$REF_DIR/$name" ]]; then
      if [[ -n "${STS2_ONLINE_MOD_VERSION:-}" ]]; then
        echo "Missing $REF_DIR/$name (set STS2_ORIGINAL_V1071_REFERENCE_DIR or STS2_ORIGINAL_V1110_REFERENCE_DIR)" >&2
        exit 1
      fi
      echo "Skipping $version: missing $REF_DIR/$name" >&2
      continue 2
    fi
  done
  OUT="$ROOT/windows/resources/online-mod/$version/STS2CottageOnline"
  BUILD="$ROOT/windows/online-mod/bin/$version"
  mkdir -p "$OUT" "$BUILD"
  "$DOTNET" build "$PROJECT/STS2CottageOnline.csproj" -c Release -nologo -v:minimal \
    -p:GameVersion="$version" -p:GameReferenceDir="$REF_DIR" -o "$BUILD"
  cp "$BUILD/STS2CottageOnline.dll" "$BUILD/STS2CottageOnline.json" "$OUT/"
  echo "Built $OUT"
  BUILT=$((BUILT + 1))
done
if [[ "$BUILT" == 0 ]]; then
  echo 'No matching original game reference directories found for online mods.' >&2
  exit 1
fi

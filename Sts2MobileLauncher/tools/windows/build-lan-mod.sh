#!/usr/bin/env bash
# Build the LAN multiplayer mod bundled with the Windows launcher:
# "LAN Multiplayer: Reforged" (built from a pinned upstream commit + launcher patches)
# and its required dependency BaseLib (copied from the game's Workshop install).
#
# Output: windows/resources/online-mod/<mod id>/ (copied into <game>/mods/ by the launcher).
#
# Environment:
#   STS2_ORIGINAL_V1071_REFERENCE_DIR  directory holding sts2.dll/GodotSharp.dll (default: Steam install)
#   STS2_BASELIB_DIR                   folder with BaseLib.dll/BaseLib.json/BaseLib.pck (default: Steam Workshop)
#   STS2_DOTNET / DOTNET_BIN           dotnet executable (default: dotnet on PATH)
#   PYTHON_BIN                         Python 3 used to pack the localization PCK
#   REFORGED_COMMIT                    override the pinned upstream commit
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MOD_ID='SlayTheSpire2.LAN.Multiplayer.Reforged'
BASE_LIB_ID='BaseLib'
UPSTREAM_REPO="${REFORGED_REPO:-https://github.com/PageSecOnd/SlayTheSpire2.LAN.Multiplayer.Reforged.git}"
UPSTREAM_COMMIT="${REFORGED_COMMIT:-6623dcd793ed264ff80a5c5ac384ee94fd293110}"
SRC="$ROOT/.agent/reforged-mod"
OUT_MOD="$ROOT/windows/resources/online-mod/$MOD_ID"
OUT_LIB="$ROOT/windows/resources/online-mod/$BASE_LIB_ID"

DOTNET="${STS2_DOTNET:-${DOTNET_BIN:-$(command -v dotnet || true)}}"
if [[ -z "$DOTNET" || ! -x "$DOTNET" ]]; then
  echo 'Missing .NET 9 SDK (set STS2_DOTNET or DOTNET_BIN).' >&2
  exit 1
fi

PYTHON=''
for candidate in "${PYTHON_BIN:-}" python3 python; do
  [[ -n "$candidate" ]] || continue
  if "$candidate" -I -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo 'Missing Python 3 (set PYTHON_BIN); it packs the mod localization PCK.' >&2
  exit 1
fi

# Steam 可能装在任意盘：先看显式变量，再问注册表，最后试默认路径。
steam_roots() {
  local root
  if [[ -n "${STS2_STEAM_DIR:-}" ]]; then
    printf '%s\n' "$STS2_STEAM_DIR"
  fi
  if command -v reg >/dev/null 2>&1; then
    # Git Bash 会把 /v 当成路径，用 //v 阻止转换。
    root="$(reg query 'HKCU\Software\Valve\Steam' //v SteamPath 2>/dev/null | sed -n 's/.*SteamPath[[:space:]]*REG_SZ[[:space:]]*//p' | tr -d '\r' | head -n 1)"
    if [[ -z "$root" ]]; then
      root="$(reg query 'HKLM\SOFTWARE\WOW6432Node\Valve\Steam' //v InstallPath 2>/dev/null | sed -n 's/.*InstallPath[[:space:]]*REG_SZ[[:space:]]*//p' | tr -d '\r' | head -n 1)"
    fi
    if [[ -n "$root" ]]; then
      printf '%s\n' "$root"
    fi
  fi
  printf '%s\n' '/c/Program Files (x86)/Steam' '/c/Program Files/Steam' '/d/Program Files (x86)/Steam' '/d/Program Files/Steam'
}

# 原版 v0.107.1 程序集：MOD 与游戏版本绑定，只有这一份。
REF_DIR="${STS2_ORIGINAL_V1071_REFERENCE_DIR:-}"
if [[ -z "$REF_DIR" && -n "${STS2_ORIGINAL_V1071_ROOT:-}" ]]; then
  REF_DIR="$STS2_ORIGINAL_V1071_ROOT/.godot/mono/temp/bin/Debug"
fi
if [[ -z "$REF_DIR" ]]; then
  while IFS= read -r steam_root; do
    candidate="$steam_root/steamapps/common/Slay the Spire 2/data_sts2_windows_x86_64"
    if [[ -f "$candidate/sts2.dll" ]]; then
      REF_DIR="$candidate"
      break
    fi
  done < <(steam_roots)
fi
for name in sts2.dll GodotSharp.dll 0Harmony.dll Steamworks.NET.dll; do
  if [[ ! -f "$REF_DIR/$name" ]]; then
    echo "Missing $REF_DIR/$name (set STS2_ORIGINAL_V1071_REFERENCE_DIR to the v0.107.1 game data folder)." >&2
    exit 1
  fi
done

# BaseLib：游戏 MOD 目录里通常已有（Workshop 3737335127），也可以显式指定。
BASELIB_DIR="${STS2_BASELIB_DIR:-}"
if [[ -z "$BASELIB_DIR" ]]; then
  while IFS= read -r steam_root; do
    candidate="$steam_root/steamapps/workshop/content/2868840/3737335127/$BASE_LIB_ID"
    if [[ -f "$candidate/$BASE_LIB_ID.dll" ]]; then
      BASELIB_DIR="$candidate"
      break
    fi
  done < <(steam_roots)
fi
if [[ -z "$BASELIB_DIR" ]]; then
  echo "Missing BaseLib (set STS2_BASELIB_DIR to the folder with $BASE_LIB_ID.dll)." >&2
  echo 'Subscribe to BaseLib in the Steam Workshop (id 3737335127) or copy the folder from another install.' >&2
  exit 1
fi
for name in "$BASE_LIB_ID.dll" "$BASE_LIB_ID.json" "$BASE_LIB_ID.pck"; do
  if [[ ! -f "$BASELIB_DIR/$name" ]]; then
    echo "Missing $BASELIB_DIR/$name (set STS2_BASELIB_DIR)." >&2
    exit 1
  fi
done

# 固定上游 commit，丢弃本地改动后再应用启动器补丁，保证可复现。
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone "$UPSTREAM_REPO" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch origin "$UPSTREAM_COMMIT" || git -C "$SRC" fetch --all --tags
fi
git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
git -C "$SRC" reset -q --hard "$UPSTREAM_COMMIT"
git -C "$SRC" clean -qfdx
for patch in "$ROOT"/tools/windows/patches/*.patch; do
  echo "Applying $(basename "$patch")"
  git -C "$SRC" apply --whitespace=nowarn "$patch"
done

"$DOTNET" build "$SRC/$MOD_ID/$MOD_ID.csproj" -c Release -nologo -v:minimal \
  -p:Sts2Dir="$REF_DIR" -o "$SRC/out"

rm -rf "$OUT_MOD" "$OUT_LIB"
mkdir -p "$OUT_MOD" "$OUT_LIB"
cp "$SRC/out/$MOD_ID.dll" "$OUT_MOD/"
cp "$ROOT/tools/windows/assets/$MOD_ID/mod_manifest.json" "$OUT_MOD/$MOD_ID.json"
cp "$SRC/LICENSE" "$OUT_MOD/LICENSE"
cp "$ROOT/tools/windows/assets/online-mod/NOTICE.md" "$OUT_MOD/"
# 只打包本地化：上游 PCK 里的资源路径还是旧 MOD id，游戏按新 id 找不到键。
"$PYTHON" -I "$ROOT/tools/windows/pack-godot-pck.py" \
  --root "$SRC/localization" \
  --prefix "$MOD_ID/localization" \
  --out "$OUT_MOD/$MOD_ID.pck"

cp "$BASELIB_DIR/$BASE_LIB_ID.dll" "$BASELIB_DIR/$BASE_LIB_ID.json" "$BASELIB_DIR/$BASE_LIB_ID.pck" "$OUT_LIB/"
cp "$ROOT/tools/windows/assets/online-mod/NOTICE.md" "$OUT_LIB/"
cp "$ROOT/tools/windows/assets/online-mod/BaseLib-LICENSE.txt" "$OUT_LIB/LICENSE.txt"

echo "Built $OUT_MOD"
echo "Bundled $BASE_LIB_ID from $BASELIB_DIR into $OUT_LIB"

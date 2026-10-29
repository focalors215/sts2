#!/usr/bin/env bash
# Refresh the device AOT slice without re-exporting personal Xcode signing settings.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export DOTNET_ROOT="$TASK_ROOT/ipad-tools/toolchain/dotnet"
export DOTNET_CLI_HOME="$TASK_ROOT/ipad-tools/toolchain/dotnet-home"
export NUGET_PACKAGES="$TASK_ROOT/ipad-tools/toolchain/nuget"
export PATH="$DOTNET_ROOT:$PATH"
IOS_ROOT="$TASK_ROOT/sts2-ios"
PATCH_OUT="$IOS_ROOT/ios-export/.work/mobilepatch-out"
dotnet build "$IOS_ROOT/src/STS2MobileIos" -c Release -o "$PATCH_OUT" > "$TASK_ROOT/ipad-tools/patch-build-perf.log" 2>&1
dotnet "$IOS_ROOT/ios-export/.work/weaver-build/bin/STS2Weaver/release/STS2Weaver.dll" \
 "$IOS_ROOT/game-refs/sts2.dll" "$PATCH_OUT/STS2MobileIos.dll" \
 "$IOS_ROOT/src/STS2MobileIos/manifest.json" "$IOS_ROOT/ios-export/.work/sts2-v0.111.0-woven.dll" \
 > "$TASK_ROOT/ipad-tools/weave-perf.log" 2>&1
cp "$IOS_ROOT/ios-export/.work/sts2-v0.111.0-woven.dll" "$IOS_ROOT/ios-export/prebuilt/sts2.dll"
cp "$PATCH_OUT/STS2MobileIos.dll" "$IOS_ROOT/ios-export/prebuilt/deps/STS2MobileIos.dll"
dotnet publish "$IOS_ROOT/ios-export/sts2.csproj" -c ExportRelease -r ios-arm64 \
 -p:GodotTargetPlatform=ios --self-contained > "$TASK_ROOT/ipad-tools/aot-publish-perf.log" 2>&1
# Godot's device framework wraps this exact NativeAOT dylib; retain its Info.plist.
cp "$IOS_ROOT/ios-export/.godot/mono/temp/bin/ExportRelease/ios-arm64/publish/sts2.dylib" \
 "$IOS_ROOT/ios-export/build/StS2/dylibs/ExportRelease/sts2_aot.xcframework/ios-arm64/sts2.framework/sts2"
install_name_tool -id '@rpath/sts2.framework/sts2' \
 "$IOS_ROOT/ios-export/build/StS2/dylibs/ExportRelease/sts2_aot.xcframework/ios-arm64/sts2.framework/sts2"
echo 'Updated device AOT slice. Simulator slices are unchanged.'

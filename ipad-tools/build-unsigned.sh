#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXPORT_ROOT="$TASK_ROOT/sts2-ios/ios-export"
if ! grep -q 'sts2_aot.xcframework' "$EXPORT_ROOT/build/StS2.xcodeproj/project.pbxproj"; then
  echo "Missing NativeAOT game framework; export the complete project first." >&2
  exit 1
fi
xcodebuild -project "$EXPORT_ROOT/build/StS2.xcodeproj" \
  -scheme StS2 -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$EXPORT_ROOT/.work/xcode-derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build > "$TASK_ROOT/ipad-tools/xcode-build.log" 2>&1
echo "Unsigned app: $EXPORT_ROOT/.work/xcode-derived/Build/Products/Release-iphoneos/StS2.app"
echo "Developer signing and iPad validation are still required."

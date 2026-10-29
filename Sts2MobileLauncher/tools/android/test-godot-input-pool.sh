#!/usr/bin/env bash
# Exercise original Godot pooled input with an observable buffered-input consumer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT/tools/env/load-local-config.sh"
sts2_init_env

JAVAC="${JAVA_HOME:-}/bin/javac"
ANDROID_JAR="${ANDROID_HOME:-}/platforms/android-35/android.jar"
sts2_require_executable "$JAVAC" "JDK 21 javac"
sts2_require_executable "${JAVA_HOME:-}/bin/java" "JDK 21 java"
sts2_require_file "$ANDROID_JAR" "Android platform jar"

if (($# > 0)); then
  AARS=("$@")
else
  REFERENCE_ROOT="$(sts2_config_path STS2_ANDROID_RUNTIME_REFERENCE_ROOT runtime.android_reference_root "${STS2_ANDROID_RUNTIME_REFERENCE_ROOT:-}")"
  sts2_require_dir "$REFERENCE_ROOT" "Android runtime reference root"
  AARS=()
  for variant in debug release; do
    AARS+=("$REFERENCE_ROOT/libs/$variant/godot-lib.template_$variant.aar")
  done
fi
for source in "${AARS[@]}"; do
  sts2_require_file "$source" "Godot template AAR"
done
python3 "$ROOT/tools/android/test-godot-input-source.py" \
  --javac "$JAVAC" --android-jar "$ANDROID_JAR" "${AARS[@]}"

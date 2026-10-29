#!/usr/bin/env python3
"""Execute consumer-visible source/pool regressions against real Godot template AARs."""

import argparse
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location("input_patch", Path(__file__).with_name("patch-godot-input-pool.py"))
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


def require(value, message):
    if not value:
        raise AssertionError(message)


def replace_classes(aar, destination, classes):
    with zipfile.ZipFile(aar) as source, zipfile.ZipFile(destination, "w") as output:
        for info in source.infolist():
            output.writestr(info, classes if info.filename == "classes.jar" else source.read(info.filename))


def mutate_jar(classes, *, rename_setter=False, remove_manifest=False):
    result = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(classes)) as source, zipfile.ZipFile(result, "w") as output:
        for info in source.infolist():
            if remove_manifest and info.filename == patch.PATCH_ENTRY:
                continue
            value = source.read(info.filename)
            if rename_setter and info.filename == patch.RUNNABLE_ENTRY:
                require(b"setKeyEvent" in value, "fixture runnable has no key setter")
                value = value.replace(b"setKeyEvent", b"badKeyEvent")
            output.writestr(info, value)
    return result.getvalue()


def rejected_without_writing(aar, javac, android_jar):
    before = aar.read_bytes()
    try:
        patch.patch_aar(aar, javac, android_jar, False)
    except (ValueError, RuntimeError):
        pass
    else:
        raise AssertionError("unknown/partial input patch was accepted")
    require(aar.read_bytes() == before, "rejected shape modified its input AAR")


def exercise(source, javac, android_jar, root):
    with tempfile.TemporaryDirectory(prefix="sts2-input-source-test-") as temporary:
        work = Path(temporary)
        aar = work / source.name
        shutil.copy2(source, aar)
        with zipfile.ZipFile(source) as original:
            original_classes = original.read("classes.jar")
        patch.patch_aar(aar, javac, android_jar, False)
        patch.patch_aar(aar, None, None, True)
        snapshot = aar.read_bytes()
        patch.patch_aar(aar, javac, android_jar, False)
        require(aar.read_bytes() == snapshot, "reapplying input patch was not byte-idempotent")
        with zipfile.ZipFile(aar) as staged, zipfile.ZipFile(source) as original:
            for info in original.infolist():
                if info.filename != "classes.jar":
                    require(staged.read(info.filename) == original.read(info.filename), "non-Java AAR content changed")
            patched_classes = staged.read("classes.jar")
        with zipfile.ZipFile(io.BytesIO(original_classes)) as original, zipfile.ZipFile(io.BytesIO(patched_classes)) as staged:
            changed = {patch.HANDLER_ENTRY, patch.GESTURE_ENTRY, patch.RUNNABLE_ENTRY}
            for entry in original.namelist():
                if entry not in changed:
                    require(staged.read(entry) == original.read(entry), f"unrelated/pool bytecode changed: {entry}")
        classes = work / "classes.jar"
        classes.write_bytes(patched_classes)
        fixture_classes = work / "fixtures"
        fixture_classes.mkdir()
        fixtures = sorted((root / "tests/input-source").rglob("*.java"))
        subprocess.run([str(javac), "-source", "17", "-target", "17", "-Xlint:-options",
                        "-cp", os.pathsep.join((str(classes), str(android_jar))), "-d", str(fixture_classes),
                        *(str(path) for path in fixtures)], check=True)
        subprocess.run([str(javac.with_name("java")), "-ea", "-cp",
                        os.pathsep.join((str(fixture_classes), str(classes), str(android_jar))),
                        "org.godotengine.godot.input.InputSourceBridgeRegression"], check=True)
        unknown = work / "unknown.aar"
        replace_classes(source, unknown, mutate_jar(original_classes, rename_setter=True))
        rejected_without_writing(unknown, javac, android_jar)
        partial = work / "partial.aar"
        replace_classes(aar, partial, mutate_jar(patched_classes, remove_manifest=True))
        rejected_without_writing(partial, javac, android_jar)
        print(f"Provenance, pooling, ordering, lifecycle, idempotence and fail-closed shape passed: {source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--javac", type=Path, required=True)
    parser.add_argument("--android-jar", type=Path, required=True)
    parser.add_argument("aars", type=Path, nargs="+")
    args = parser.parse_args()
    for source in args.aars:
        exercise(source.resolve(), args.javac.resolve(), args.android_jar.resolve(), Path(__file__).parent)


if __name__ == "__main__":
    main()

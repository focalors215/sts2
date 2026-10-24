#!/usr/bin/env python3
"""Stage Godot's mouse-pool repair and ordered input-source transport in an AAR.

The original handler, pooled runnable code and JNI remain in the archive. A small
handler overlay filters unsupported mouse actions and scopes event provenance;
JDK 21's bundled ASM instruments three runnable setters and wraps the original
run method. Unknown runnable shapes and partial patches are rejected.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

OLD_INTERNAL = b"org/godotengine/godot/input/GodotInputHandler"
BASE_INTERNAL = b"org/godotengine/godot/input/GodotInputHandlerBase"
HANDLER_ENTRY = "org/godotengine/godot/input/GodotInputHandler.class"
BASE_ENTRY = "org/godotengine/godot/input/GodotInputHandlerBase.class"
GESTURE_ENTRY = "org/godotengine/godot/input/GodotGestureHandler.class"
RUNNABLE_ENTRY = "org/godotengine/godot/input/InputEventRunnable.class"
BRIDGE_ENTRY = "org/godotengine/godot/input/GodotInputSourceBridge.class"
PATCH_ENTRY = "META-INF/sts2-input-source.json"
CLASSES_ENTRY = "classes.jar"
SHIM_ROOT = Path(__file__).with_name("input-shim")
TRANSFORMER_SOURCE = SHIM_ROOT / "PatchGodotInputRunnable.java"
SHIM_SOURCES = (
    SHIM_ROOT / "org/godotengine/godot/input/GodotInputHandler.java",
    SHIM_ROOT / "org/godotengine/godot/input/GodotInputSourceBridge.java",
)
ASM_EXPORT = "java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED"


def _source_sha256() -> str:
    digest = hashlib.sha256()
    for source in (Path(__file__), TRANSFORMER_SOURCE, *SHIM_SOURCES):
        digest.update(source.name.encode("utf-8") + b"\0" + source.read_bytes() + b"\0")
    return digest.hexdigest()


def _u2(data: bytes, offset: int) -> tuple[int, int]:
    if offset + 2 > len(data):
        raise ValueError("truncated class file")
    return struct.unpack_from(">H", data, offset)[0], offset + 2


def _rewrite_class_references(data: bytes) -> bytes:
    """Rewrite internal-name UTF-8 constants while preserving a class file."""
    if len(data) < 10 or data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("expected a JVM class file")
    offset = 8
    constant_pool_count, offset = _u2(data, offset)
    output = bytearray(data[:offset])
    index = 1
    while index < constant_pool_count:
        if offset >= len(data):
            raise ValueError("truncated constant pool")
        tag = data[offset]
        output.append(tag)
        offset += 1
        if tag == 1:
            length, offset = _u2(data, offset)
            end = offset + length
            if end > len(data):
                raise ValueError("truncated UTF-8 constant")
            value = data[offset:end].replace(OLD_INTERNAL, BASE_INTERNAL)
            output.extend(struct.pack(">H", len(value)))
            output.extend(value)
            offset = end
        elif tag in (3, 4):
            output.extend(data[offset:offset + 4])
            offset += 4
        elif tag in (5, 6):
            output.extend(data[offset:offset + 8])
            offset += 8
            index += 1
        elif tag in (7, 8, 16, 19, 20):
            output.extend(data[offset:offset + 2])
            offset += 2
        elif tag in (9, 10, 11, 12, 17, 18):
            output.extend(data[offset:offset + 4])
            offset += 4
        elif tag == 15:
            output.extend(data[offset:offset + 3])
            offset += 3
        else:
            raise ValueError(f"unsupported constant-pool tag {tag}")
        index += 1
    if offset > len(data):
        raise ValueError("truncated class file")
    output.extend(data[offset:])
    return bytes(output)


def _copy_info(info: zipfile.ZipInfo, filename: str | None = None) -> zipfile.ZipInfo:
    copied = copy.copy(info)
    if filename is not None:
        copied.filename = filename
    return copied


def _entries(jar: zipfile.ZipFile) -> set[str]:
    names = jar.namelist()
    if len(names) != len(set(names)):
        raise ValueError("Godot classes.jar contains duplicate entries")
    return set(names)


def _validate_source_shape(handler: bytes, gesture: bytes, renamed: bool) -> None:
    required = (b"InputEventRunnable", b"setMouseEvent", b"dispatchInputEventRunnable", b"handleMouseEvent")
    missing = [token.decode("ascii") for token in required if token not in handler]
    if missing:
        raise ValueError(f"unsupported Godot input handler ABI; missing {', '.join(missing)}")
    if (BASE_INTERNAL if renamed else OLD_INTERNAL) not in gesture:
        raise ValueError("unsupported Godot input ABI; gesture handler has no expected handler reference")


def _run(command: list[str], label: str) -> None:
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(label + ":\n" + (exc.stdout or "") + (exc.stderr or "")) from exc


def _transform_runnable(value: bytes, javac: Path, work: Path) -> bytes:
    tool_classes = work / "transformer"
    tool_classes.mkdir()
    _run([str(javac), "-source", "21", "-target", "21", "--add-exports", ASM_EXPORT,
          "-d", str(tool_classes), str(TRANSFORMER_SOURCE)], "failed to compile Godot input transformer (JDK 21 required)")
    source = work / "original-runnable.class"
    destination = work / "patched-runnable.class"
    source.write_bytes(value)
    _run([str(javac.with_name("java")), "--add-exports", ASM_EXPORT, "-cp", str(tool_classes),
          "PatchGodotInputRunnable", str(source), str(destination)], "failed to instrument Godot input runnable")
    return destination.read_bytes()


def _write_base_jar(source: Path, destination: Path, runnable: bytes, renamed: bool) -> None:
    with zipfile.ZipFile(source, "r") as src, zipfile.ZipFile(destination, "w") as dst:
        for info in src.infolist():
            name = info.filename
            if name == HANDLER_ENTRY and renamed:
                continue
            value = src.read(name)
            if name == HANDLER_ENTRY:
                name = BASE_ENTRY
                value = _rewrite_class_references(value)
            elif name == GESTURE_ENTRY and not renamed:
                value = _rewrite_class_references(value)
            elif name == RUNNABLE_ENTRY:
                value = runnable
            dst.writestr(_copy_info(info, name), value)


def _compile_shims(classes_jar: Path, javac: Path, android_jar: Path, output: Path) -> None:
    output.mkdir()
    _run([str(javac), "-source", "17", "-target", "17", "-Xlint:-options",
          "-cp", os.pathsep.join((str(classes_jar), str(android_jar))), "-d", str(output),
          *(str(source) for source in SHIM_SOURCES)], "failed to compile Godot input shims")
    for entry in (HANDLER_ENTRY, BRIDGE_ENTRY):
        if not (output / entry).is_file():
            raise RuntimeError(f"javac did not produce {entry}")


def _build_patched_jar(source: Path, destination: Path, shims: Path) -> None:
    with zipfile.ZipFile(source, "r") as src, zipfile.ZipFile(destination, "w") as dst:
        hashes: dict[str, str] = {}
        for info in src.infolist():
            value = src.read(info.filename)
            dst.writestr(info, value)
            if info.filename in (BASE_ENTRY, GESTURE_ENTRY, RUNNABLE_ENTRY):
                hashes[info.filename] = hashlib.sha256(value).hexdigest()
        for compiled in sorted(shims.rglob("*.class")):
            entry = compiled.relative_to(shims).as_posix()
            value = compiled.read_bytes()
            dst.writestr(entry, value)
            hashes[entry] = hashlib.sha256(value).hexdigest()
        dst.writestr(PATCH_ENTRY, json.dumps({"abi": 1, "source_sha256": _source_sha256(), "classes": hashes}, sort_keys=True))


def _validate_patched_aar(aar: Path) -> None:
    with zipfile.ZipFile(aar, "r") as src:
        try:
            classes = src.read(CLASSES_ENTRY)
        except KeyError as exc:
            raise ValueError("Godot AAR has no classes.jar") from exc
    with zipfile.ZipFile(io.BytesIO(classes), "r") as jar:
        entries = _entries(jar)
        required = {HANDLER_ENTRY, BASE_ENTRY, GESTURE_ENTRY, RUNNABLE_ENTRY, BRIDGE_ENTRY, PATCH_ENTRY}
        missing = required - entries
        if missing:
            raise ValueError(f"patched classes.jar is missing: {sorted(missing)}")
        try:
            manifest = json.loads(jar.read(PATCH_ENTRY))
            if manifest["abi"] != 1 or manifest["source_sha256"] != _source_sha256():
                raise ValueError("Godot input patch is stale; restage from the reference AAR")
            hashes = manifest["classes"]
            if not isinstance(hashes, dict) or not (required - {PATCH_ENTRY}) <= hashes.keys():
                raise ValueError("Godot input patch integrity manifest is incomplete")
            for entry, expected in hashes.items():
                if hashlib.sha256(jar.read(entry)).hexdigest() != expected:
                    raise ValueError(f"Godot input patch integrity mismatch: {entry}")
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid Godot input patch integrity manifest") from exc
        wrapper, base, gesture = (jar.read(entry) for entry in (HANDLER_ENTRY, BASE_ENTRY, GESTURE_ENTRY))
        if any(OLD_INTERNAL in value.replace(BASE_INTERNAL, b"") for value in (base, gesture)):
            raise ValueError("patched handler base still contains the old handler type reference")
        if BASE_INTERNAL not in wrapper or BASE_INTERNAL not in gesture:
            raise ValueError("patched handler/base type references are incomplete")
        if b"InputEventRunnable" in wrapper or b"InputEventRunnable" in gesture:
            raise ValueError("the filtering wrapper must not obtain pooled input events")


def patch_aar(aar: Path, javac: Path | None, android_jar: Path | None, check: bool) -> None:
    if check:
        _validate_patched_aar(aar)
        return
    with zipfile.ZipFile(aar, "r") as src:
        try:
            classes = src.read(CLASSES_ENTRY)
        except KeyError as exc:
            raise ValueError("Godot AAR has no classes.jar") from exc
        with zipfile.ZipFile(io.BytesIO(classes), "r") as jar:
            entries = _entries(jar)
            if PATCH_ENTRY in entries:
                _validate_patched_aar(aar)
                return
            if BRIDGE_ENTRY in entries:
                raise ValueError("partial Godot input source patch without integrity manifest")
            renamed = BASE_ENTRY in entries
            required = {HANDLER_ENTRY, GESTURE_ENTRY, RUNNABLE_ENTRY}
            if not required <= entries:
                raise ValueError("unsupported Godot AAR: expected input handler, gesture and runnable classes")
            _validate_source_shape(jar.read(BASE_ENTRY if renamed else HANDLER_ENTRY), jar.read(GESTURE_ENTRY), renamed)
            original_runnable = jar.read(RUNNABLE_ENTRY)
    if javac is None or android_jar is None:
        raise ValueError("--javac and --android-jar are required when patching")
    for executable in (javac, javac.with_name("java")):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"JDK executable not found: {executable}")
    if not android_jar.is_file():
        raise ValueError(f"Android platform jar not found: {android_jar}")
    with tempfile.TemporaryDirectory(prefix="sts2-godot-input-patch-", dir=aar.parent) as tmp_name:
        tmp = Path(tmp_name)
        original_classes = tmp / "original-classes.jar"
        base_classes = tmp / "base-classes.jar"
        patched_classes = tmp / "patched-classes.jar"
        shims = tmp / "shim-classes"
        original_classes.write_bytes(classes)
        runnable = _transform_runnable(original_runnable, javac, tmp)
        _write_base_jar(original_classes, base_classes, runnable, renamed)
        _compile_shims(base_classes, javac, android_jar, shims)
        _build_patched_jar(base_classes, patched_classes, shims)
        aar_tmp = tmp / "patched.aar"
        with zipfile.ZipFile(aar, "r") as src, zipfile.ZipFile(aar_tmp, "w") as dst:
            for info in src.infolist():
                value = patched_classes.read_bytes() if info.filename == CLASSES_ENTRY else src.read(info.filename)
                dst.writestr(info, value)
        _validate_patched_aar(aar_tmp)
        os.replace(aar_tmp, aar)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aar", type=Path)
    parser.add_argument("--javac", type=Path)
    parser.add_argument("--android-jar", type=Path)
    parser.add_argument("--check", action="store_true", help="verify an already patched AAR")
    args = parser.parse_args()
    try:
        patch_aar(args.aar, args.javac, args.android_jar, args.check)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

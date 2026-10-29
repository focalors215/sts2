#!/usr/bin/env python3
"""Read-only feasibility inventory; never certifies an iPad port as runnable."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import zipfile


def run(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=20)
        return {"ok": p.returncode == 0, "detail": (p.stdout + p.stderr).strip()[:2000]}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "detail": str(exc)}


def inventory(path):
    with zipfile.ZipFile(path) as archive:
        entries = {}
        for info in archive.infolist():
            name = info.filename.replace("\\", "/")
            parts = PurePosixPath(name).parts
            if name.startswith("/") or ".." in parts or any(":" in x for x in parts):
                raise ValueError("Unsafe ZIP member name")
            key = str(PurePosixPath(name))
            if key in entries:
                raise ValueError("Duplicate normalized ZIP member: " + key)
            entries[key] = info
        def unique(suffix):
            found = [i for n, i in entries.items() if n == suffix or n.endswith("/" + suffix)]
            if len(found) > 1:
                raise ValueError("Ambiguous ZIP member: " + suffix)
            return found[0] if found else None
        def metadata(suffix):
            info = unique(suffix)
            if info is None:
                return None
            if info.file_size > 1024 * 1024:
                raise ValueError("Metadata exceeds 1 MiB: " + suffix)
            value = json.loads(archive.read(info))
            if not isinstance(value, dict):
                raise ValueError("Expected JSON object: " + suffix)
            return value
        pck, dll = unique("SlayTheSpire2.pck"), unique("sts2.dll")
        if not pck or not dll:
            raise ValueError("ZIP must contain SlayTheSpire2.pck and sts2.dll")
        with archive.open(pck) as stream:
            if stream.read(4) != b"GDPC":
                raise ValueError("Invalid Godot PCK magic")
        body = metadata(".android_body_manifest.json")
        # Only select summary fields, never copy private source paths from the manifest.
        return {
            "entries": len(entries), "zip_bytes": Path(path).stat().st_size,
            "uncompressed_bytes": sum(i.file_size for i in entries.values()),
            "pck_bytes": pck.file_size, "sts2_dll_bytes": dll.file_size,
            "release": metadata("release_info.json"),
            "runtime_config": metadata("sts2.runtimeconfig.json"),
            "android_optimized": bool(body and body.get("kind") == "sts2_android_optimized_body_zip"),
            "manifest_godot_version": (body or {}).get("optimized_pck", {}).get("godot_version"),
            "godotsharp_present_in_zip": unique("GodotSharp.dll") is not None,
            "ios_native_candidates_in_zip": [n for n in entries if ".xcframework/" in n or ".framework/" in n or n.endswith(".a")],
            "integrity_scope": "ZIP directory, small metadata CRC and PCK magic only; large PCK/DLL integrity and PCK embedded dependencies not verified",
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if not (args.repo / "android").is_dir() or not (args.repo / "port-mod").is_dir():
            raise ValueError("Expected launcher checkout with android/ and port-mod/")
        payload = inventory(args.payload)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, RuntimeError) as exc:
        print("Invalid input: " + str(exc), file=sys.stderr)
        return 1
    tools = {
        "xcode": run(["xcodebuild", "-version"]),
        "iphoneos_sdk": run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]),
        "dotnet": run([os.environ.get("DOTNET_BIN", "dotnet"), "--info"]),
        "godot": run([os.environ.get("GODOT_BIN") or shutil.which("godot") or shutil.which("godot-mono") or "godot", "--headless", "--version"]),
    }
    report = {
        "status": "blocked", "runnable_on_ipad": False,
        "host": platform.platform(), "payload": payload, "tools": tools,
        "source_commit": run(["git", "-C", str(args.repo), "rev-parse", "HEAD"]),
        "submodules": run(["git", "-C", str(args.repo), "submodule", "status"]),
        "blockers": [
            "Current checkout provides an Android launcher, not an implemented iPad target.",
            "Godot/managed runtime and Harmony dynamic patching require an independently proven iOS execution strategy.",
            "Matching iOS arm64 FMOD and Spine integrations are not supplied or validated by this check.",
            "Device signing and actual iPad cold-start/gameplay/save lifecycle tests remain required.",
        ] + ["Missing/unavailable tool: " + name for name, result in tools.items() if not result["ok"]],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("BLOCKED: inventory saved to " + str(args.output))
    return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Export a local Xcode project. Does not sign for, install on, or validate an iPad."""
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
EXPORT = ROOT / "sts2-ios/ios-export"
TOOLS = ROOT / "ipad-tools/toolchain"


def main():
    godot = TOOLS / "godot/Godot_mono.app/Contents/MacOS/Godot"
    template = TOOLS / "templates/ios.zip"
    payload = EXPORT / ".work/user-input/SlayTheSpire2.pck"
    libs = [
        EXPORT / "addons/fmod/libs/ios/libGodotFmod.ios.template_release.xcframework",
        EXPORT / "addons/fmod/libs/ios/libfmod_iphoneos.a",
        EXPORT / "addons/fmod/libs/ios/libfmodstudio_iphoneos.a",
        EXPORT / "addons/spine/ios/libspine_godot.ios.template_release.framework",
        EXPORT / "prebuilt/sts2.dll",
        EXPORT / "sts2.sln",
    ]
    for path in [godot, template, payload, *libs]:
        if not path.exists():
            raise SystemExit("Missing input: " + str(path))
    preset = EXPORT / "export_presets.cfg"
    project = EXPORT / "project.godot"
    saved_preset, saved_project = preset.read_text(), project.read_text()
    scene = EXPORT / "scenes/game.tscn"
    created_scene = not scene.exists()
    output = EXPORT / "build"
    output.mkdir(exist_ok=True)
    icon = EXPORT / ".work/export-icon.svg"
    icon.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="#18202d"/><path d="M192 768V608h160V448h160V288h160V128h160v640z" fill="#d7b874"/></svg>')
    # Non-personal sentinel required by Godot's exporter. Cleared from the
    # generated Xcode project afterwards; no provisioning is attempted.
    overrides = {
        "custom_template/debug": str(template),
        "custom_template/release": str(template),
        "application/app_store_team_id": "UNSIGNED00",
        "application/bundle_identifier": "local.sts2.ipadmini7",
        "application/short_version": "0.111.0",
        "application/version": "11100",
        "application/min_ios_version": "18.0",
        "application/code_sign_identity_release": "-",
        "application/export_project_only": True,
        "application/targeted_device_family": 1,
        "icons/icon_1024x1024": str(icon),
    }
    modified = saved_preset
    for key, value in overrides.items():
        rendered = str(value).lower() if isinstance(value, bool) else json.dumps(value, ensure_ascii=False)
        line = key + "=" + rendered
        pattern = r"(?m)^" + re.escape(key) + r"=.*$"
        if re.search(pattern, modified):
            modified = re.sub(pattern, lambda _: line, modified)
        else:
            modified += "\n" + line + "\n"
    env = dict(os.environ)
    env.update({
        "DOTNET_ROOT": str(TOOLS / "dotnet"),
        "DOTNET_CLI_HOME": str(TOOLS / "dotnet-home"),
        "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
        "NUGET_PACKAGES": str(TOOLS / "nuget"),
        "PATH": str(TOOLS / "dotnet") + os.pathsep + env.get("PATH", ""),
    })
    try:
        preset.write_text(modified)
        # A minimal scene permits exporting the driver. The exported driver PCK
        # is replaced below with the user's full game PCK before native build.
        if created_scene:
            scene.parent.mkdir(exist_ok=True)
            scene.write_text('[gd_scene format=3]\n\n[node name="ExportDriver" type="Node"]\n')
        project.write_text(re.sub(r'(?m)^config/icon=.*$', 'config/icon="res://.work/export-icon.svg"', saved_project))
        extension_list = EXPORT / ".godot/extension_list.cfg"
        extension_list.parent.mkdir(exist_ok=True)
        extension_list.write_text("res://addons/fmod/fmod.gdextension\nres://addons/spine/spine_godot_extension.gdextension\n")
        log_path = ROOT / "ipad-tools/godot-export.log"
        with log_path.open("w") as log:
            result = subprocess.run([
                str(godot), "--headless", "--path", str(EXPORT),
                "--export-release", "iOS", str(output / "StS2.ipa"),
            ], env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit("Godot export failed; see " + str(log_path))
    finally:
        preset.write_text(saved_preset)
        project.write_text(saved_project)
        if created_scene:
            scene.unlink(missing_ok=True)
            try:
                scene.parent.rmdir()
            except OSError:
                pass
    pbx = output / "StS2.xcodeproj/project.pbxproj"
    if not pbx.exists():
        raise SystemExit("Godot reported success but no Xcode project was generated")
    text = pbx.read_text().replace("UNSIGNED00", "")
    if "sts2_aot.xcframework" not in text:
        raise SystemExit("Export omitted the C# NativeAOT framework; refusing an incomplete project")
    text = re.sub(r'(?i)\b(DEVELOPMENT_TEAM|DevelopmentTeam) =\s*;', r'\1 = "";', text)
    text = text.replace("Apple Distribution", "Apple Development")
    text = text.replace('CODE_SIGN_STYLE = "Manual";', 'CODE_SIGN_STYLE = "Automatic";')
    text = re.sub(r'(CODE_SIGN_IDENTITY(?:\[sdk=iphoneos\*\])?"? = )"-";', r'\1"Apple Development";', text)
    pbx.write_text(text)
    subprocess.run(["plutil", "-lint", str(pbx)], check=True)
    info_path = output / "StS2/StS2-Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    # The generic engine template includes empty permission descriptions. This
    # offline game build does not use camera, microphone or photo-library input.
    for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"]:
        if info.get(key) == "":
            del info[key]
    info_path.write_bytes(plistlib.dumps(info))
    dummy = output / "StS2/dummy.cpp"
    text = dummy.read_text()
    if "load_all_fmod_plugins" not in text:
        text += '''
// No custom FMOD plug-ins are used by this payload.
extern "C" __attribute__((visibility("default"))) __attribute__((used))
unsigned int *load_all_fmod_plugins(void *, unsigned int *count) {
    if (count) { *count = 0; }
    return nullptr;
}
'''
        dummy.write_text(text)
    subprocess.run([sys.executable, str(ROOT / "ipad-tools/apply-scene-bridge.py")], check=True)
    # This Android optimized PCK already has C# resource placeholders and no
    # Sentry autoload/extension. Do not run the older SentryInit-only patcher.
    shutil.copyfile(payload, output / "StS2.pck")
    print("Exported local Xcode project: " + str(pbx.parent))
    print("Unsigned; select your Team in Xcode before device deployment.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Apply the local Godot 4.5.1 UIScene adapter without regenerating signing settings."""
from pathlib import Path
import plistlib
import shutil
import hashlib
import re

ROOT = Path(__file__).resolve().parent.parent
EXPORT = ROOT / 'sts2-ios/ios-export'
APP = EXPORT / 'build/StS2'
source = EXPORT / 'StS2SceneDelegate.mm'
shutil.copyfile(source, APP / source.name)
launcher = APP / 'launcher'
# In-process frp client for remote play; built by sts2-ios/tools/build-frp-bridge.sh.
frp_library = EXPORT / 'prebuilt/frp/libfrpbridge.a'
if not frp_library.is_file():
    raise SystemExit(f'Missing {frp_library}; run: bash sts2-ios/tools/build-frp-bridge.sh')
launcher.mkdir(exist_ok=True)
for item in (EXPORT / 'launcher').iterdir():
    if item.suffix in {'.h', '.mm'} and item.stem != 'STS2WorkshopClient':
        shutil.copyfile(item, launcher / item.name)
dummy = APP / 'dummy.cpp'
text = dummy.read_text()
include = '#include "StS2SceneDelegate.mm"'
if include not in text:
    dummy.write_text(text + '\n' + include + '\n')
project = EXPORT / 'build/StS2.xcodeproj/project.pbxproj'
text = project.read_text()
old = 'lastKnownFileType = sourcecode.cpp.cpp; path = dummy.cpp;'
new = 'lastKnownFileType = sourcecode.cpp.objcpp; path = dummy.cpp;'
if old not in text and new not in text:
    raise SystemExit('Unexpected dummy.cpp project entry')
text = text.replace(old, new)
text = re.sub(r'CLANG_CXX_LANGUAGE_STANDARD = [^;]+;', 'CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";', text)
# Workshop support was cancelled by the user. Keep its research sources outside
# the app and remove old generated build references on repeated application.
for relative in ['launcher/STS2WorkshopClient.mm', 'launcher/steam_lzma/LzmaDec.c']:
    removed_ids = [hashlib.sha256((prefix + relative).encode()).hexdigest()[:24].upper()
                   for prefix in ['sts2-file:', 'sts2-build:']]
    text = '\n'.join(line for line in text.split('\n') if not any(value in line for value in removed_ids))
# Compile each implementation separately: the archive modules contain private static names.
for implementation in sorted(p for p in launcher.glob('*.mm') if p.stem != 'STS2WorkshopClient'):
    relative = 'launcher/' + implementation.relative_to(launcher).as_posix()
    source_type = 'sourcecode.c.c' if implementation.suffix == '.c' else 'sourcecode.cpp.objcpp'
    file_id = hashlib.sha256(('sts2-file:' + relative).encode()).hexdigest()[:24].upper()
    build_id = hashlib.sha256(('sts2-build:' + relative).encode()).hexdigest()[:24].upper()
    if f'{file_id} /*' not in text:
        text = text.replace('/* End PBXFileReference section */', f'\t\t{file_id} /* {implementation.name} */ = {{isa = PBXFileReference; lastKnownFileType = {source_type}; path = "{relative}"; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
        text = text.replace('/* End PBXBuildFile section */', f'\t\t{build_id} /* {implementation.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {implementation.name} */; }};\n/* End PBXBuildFile section */')
        group = r'(isa = PBXGroup;\s*children = \()(.*?)(\);\s*path = StS2;)'
        text, count = re.subn(group, lambda m: m[1] + m[2] + f'\t\t\t\t{file_id} /* {implementation.name} */,\n\t\t\t' + m[3], text, count=1, flags=re.S)
        if count != 1:
            raise SystemExit('Missing StS2 source group')
        phase = r'(isa = PBXSourcesBuildPhase;.*?files = \()'
        text, count = re.subn(phase, lambda m: m[1] + f'\n\t\t\t\t{build_id} /* {implementation.name} in Sources */,', text, count=1, flags=re.S)
        if count != 1:
            raise SystemExit('Missing Sources build phase')
# UIKit document export uses a share sheet; do not expose Documents (including the PCK).
# zlib supplies ZIP inflate/CRC. Keep all existing flags and signing settings.
def add_launcher_flags(match):
    contents = match[2].rstrip()
    # Go c-archive (frp) needs libresolv plus the Security/CoreFoundation frameworks.
    flags = ['"-lz"', '"-framework",\n\t\t\t\t"UniformTypeIdentifiers"',
             '"$(PROJECT_DIR)/../prebuilt/frp/libfrpbridge.a"', '"-lresolv"',
             '"-framework",\n\t\t\t\t"Security"', '"-framework",\n\t\t\t\t"CoreFoundation"']
    for flag in flags:
        marker = flag.split('\n')[-1].strip()
        if marker not in contents:
            contents += '\n\t\t\t\t' + flag + ','
    return match[1] + contents + '\n\t\t\t' + match[3]
text = re.sub(r'(OTHER_LDFLAGS = \()(.*?)(\);)', add_launcher_flags, text, flags=re.S)
project.write_text(text)
info = APP / 'StS2-Info.plist'
data = plistlib.loads(info.read_bytes())
data['UIApplicationSceneManifest'] = {
    'UIApplicationSupportsMultipleScenes': False,
    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
        'UISceneConfigurationName': 'StS2 Main',
        'UISceneDelegateClassName': 'StS2SceneDelegate',
        'UISceneClassName': 'UIWindowScene',
    }]},
}
data['NSLocalNetworkUsageDescription'] = '用于与局域网内的其他玩家直连游戏。'
data['LSSupportsOpeningDocumentsInPlace'] = True
data['UIFileSharingEnabled'] = False
info.write_bytes(plistlib.dumps(data))
print('Applied UIScene bridge; existing signing settings preserved.')

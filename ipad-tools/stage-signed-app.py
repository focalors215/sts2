#!/usr/bin/env python3
"""Sign a private build outside File Provider folders, using its existing profile."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "sts2-ios/ios-export/.work/xcode-derived/Build/Products/Release-iphoneos/StS2.app"
WORK = ROOT / "sts2-ios/ios-export/.work"


def main():
    # The original game reads this next to its executable. Preserve the user's
    # release metadata rather than advertising a fabricated network version.
    body_archive = ROOT / "sts2-v0.111.0-android-body.zip"
    base_game = ROOT / "sts2-ios/game-refs/sts2.dll"
    with zipfile.ZipFile(body_archive) as body:
        assemblies = [name for name in body.namelist() if name == "sts2.dll" or name.endswith("/sts2.dll")]
        if len(assemblies) != 1:
            raise SystemExit("Expected exactly one original game assembly in the owned body archive")
        if hashlib.sha256(body.read(assemblies[0])).digest() != hashlib.sha256(base_game.read_bytes()).digest():
            raise SystemExit("Release metadata archive does not match the original game assembly")
        metadata_entry = body.getinfo("release_info.json")
        if metadata_entry.file_size > 65536:
            raise SystemExit("Unexpectedly large release metadata")
        release_bytes = body.read(metadata_entry)
    release = json.loads(release_bytes)
    if not isinstance(release, dict) or not re.fullmatch(r"v\d+\.\d+\.\d+", release.get("version", "")):
        raise SystemExit("Invalid original release metadata version")
    profile = SOURCE / "embedded.mobileprovision"
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True, check=True)
    data = plistlib.loads(decoded.stdout)
    info = plistlib.loads((SOURCE / "Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    entitlement_id = data["Entitlements"]["application-identifier"]
    if not entitlement_id.endswith("." + bundle):
        raise SystemExit("Provisioning profile does not match the app bundle")
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in data["DeveloperCertificates"]}
    identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, check=True)
    matches = [value for value in re.findall(r'^\s*\d+\)\s+([A-F0-9]{40})\s+"', identities.stdout, re.M) if value in allowed]
    if not matches:
        raise SystemExit("No installed signing identity matches the app provisioning profile")
    stage = Path(tempfile.mkdtemp(prefix="sts2-ipad-signed-", dir="/private/tmp")) / "StS2.app"
    # The source has no quarantine attribute. Omit Finder metadata on this build
    # copy so cloud-backed Documents cannot reapply it between copy and signing.
    subprocess.run(["ditto", "--norsrc", "--noextattr", str(SOURCE), str(stage)], check=True)
    (stage / "release_info.json").write_bytes(release_bytes)
    # Catch a raw NativeAOT @rpath/sts2.dylib copied into a framework before
    # signing/installing. Godot exports normally rewrite this install name.
    linked = subprocess.run(["otool", "-L", str(stage / info["CFBundleExecutable"])], capture_output=True, text=True, check=True)
    for line in linked.stdout.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("@rpath/"):
            target = stage / "Frameworks" / dependency[len("@rpath/"):]
            if not target.is_file():
                raise SystemExit("Missing bundled runtime dependency: " + dependency)
    entitlements = WORK / "device-signing-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps(data["Entitlements"]))
    for framework in sorted((stage / "Frameworks").glob("*.framework")):
        subprocess.run(["codesign", "--force", "--sign", matches[0], "--timestamp=none", "--generate-entitlement-der", str(framework)], check=True)
    subprocess.run(["codesign", "--force", "--sign", matches[0], "--timestamp=none", "--generate-entitlement-der", "--entitlements", str(entitlements), str(stage)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(stage)], check=True)
    report = {"status": "developer_signed_not_installed", "app_path": str(stage), "bundle_identifier": bundle, "profile_expiration": data["ExpirationDate"].isoformat(), "signature_verified": True, "release_info_version": release["version"], "release_info_sha256": hashlib.sha256(release_bytes).hexdigest()}
    (ROOT / "ipad-tools/signed-app-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Signed and verified:", stage)


if __name__ == "__main__":
    main()

# Fixed compiled MOD gate

Research only: the user cancelled Steam MOD support on 2026-10-27. No real capability file or enabled adapter was integrated into the app. Source stubs remain closed.

The iOS runtime gate admits only the statically adapted More Silent Animations
0.1.33 build. It does not inspect downloaded MOD assemblies or load assemblies
from launcher storage. The source-tree adapter stubs remain closed:
`HasMoreSilentSupport()` returns `false`, and `InitializeMoreSilent()` is empty.
The offline signed-app adaptation changes those two methods to the approved
support marker and a direct `adaptedMOD.ModEntry.Initialize()` call.

## Admission contract

`compiled-mods.json` must be next to the app executable. Its schema is version
1, its `buildId` must be `sts2-ios-v0.111.0-more-silent-0.1.33-r1`, and it must
contain exactly one entry for `MoreSilentAnimations` /
`more-silent-animations-v0.1.33`. That entry must match source SHA256
`1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41`, game
version `v0.111.0`, and MOD version `0.1.33`. `files` is an array of objects
with `path`, `sha256`, and `size` fields. The runtime requires safe unique
relative paths, 64-hex hashes, and nonnegative integer sizes; it verifies
listed files exist beside the app and rejects symbolic links in the path chain.

Only after the signed-app capability and patched support marker match does the
gate read `Documents/Launcher/config.json`. The root object must have
`schemaVersion: 1` and a `compiledMods` array. A request has `id` (64 hex
characters), `modId`, `feature`, `sourceSha256`, and `buildId`. Exactly one
request may refer to the fixed MOD by either its MOD ID or feature, and all
fields must match the capability constants. A forged capability placed in
Documents has no effect. Invalid JSON, invalid fields, duplicate requests,
hash/build mismatches, unsafe paths, or symbolic links leave the gate closed.
No matching request means disabled and skips initialization.

`IsMoreSilentEnabled()` freezes the decision on its first call. It initializes
once, returns false during reentry, and returns true only after the direct MOD
initializer returns successfully. An exception is recorded as a failed entry
and does not escape into vanilla startup. `InitializePrefix()` provides an
early startup hook for the weave entry point. `AugmentPeerVersion(ref
PeerVersionInfo)` adds `ios-compiled-mod-v1:<feature>:<sourceSha256>` only while
enabled, preserving the existing gameplay MOD list and all other peer fields.

The gate atomically replaces
`Documents/Launcher/compiled-mod-load-status.json` with:

```json
{
  "schemaVersion": 1,
  "buildId": "sts2-ios-v0.111.0-more-silent-0.1.33-r1",
  "completed": true,
  "entries": [
    {
      "id": "",
      "modId": "MoreSilentAnimations",
      "feature": "more-silent-animations-v0.1.33",
      "sourceSha256": "1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41",
      "requested": false,
      "status": "disabled",
      "error": ""
    }
  ]
}
```

Status is `loaded`, `failed`, or `disabled`; `requested` reflects a valid
launcher request. Status write and path failures are logged and never abort
game startup.

## Private synthetic tests

The isolated console harness under `.work/compiled-mod-gate-test` links the
production gate source and reads the same public synthetic capability fixture
as native tests from `ios-export/launcher/tests/compiled-mod-capability.fixture.json`.
It tests support/capability/config admission, forged Documents capabilities,
mismatched and duplicate requests, malformed IDs and schemas, unsafe and
duplicate file paths and metadata, disabled behavior, initialization exceptions
and reentry, once-only state, and peer fingerprint preservation. Build it and the production library
to `ios-export/.work/runtime-gate-out` with the local .NET 9 SDK; this does not
touch prebuilt/AOT or device output.

# Save archive data layer

`STS2SaveArchiveStore` reads `Documents/default/1`. Run its synchronous operations on the UI's serialized background I/O queue while the game is stopped.

- `exportCurrentSave:` writes a UUID-named portable ZIP below `Documents/.LauncherSaveArchive/`.
- `createSnapshotWithName:error:` creates a named ZIP; `snapshots` returns `name`, `path` (`NSURL`), `date`, and `size` dictionaries.
- `restoreArchiveAtURL:error:` validates the entire ZIP and requires a `.save`. Native account-relative paths are preserved, including `modded/` and root ancillary files. Only explicit `default/<numeric ID>/` or `steam/<numeric ID>/` wrappers are removed. Multiple wrappers and mixed wrapped/native files are rejected as ambiguous.
- Restore stages outside the account, creates an automatic snapshot of the current account, then atomically exchanges existing directories with Darwin `renameatx_np(RENAME_SWAP)`. An absent account is installed with one `rename`. Process termination before/after commit leaves the complete old/new account; there is no missing-account interval. An interrupted cleanup can leave the old directory under `.LauncherSaveArchive/staging/`. Unsupported atomic exchange fails with the original account untouched.
- `currentSaveSummary` returns `exists`, `fileCount`, `saveFileCount`, `totalBytes`, and `accountPath`.

`STS2ZipArchive.h` exposes `STS2ZipCreateData` and `STS2ZipReadData`. The writer uses STORE with CRC32. The reader accepts STORE/raw DEFLATE and Java-style bit-3 data descriptors (signed 16-byte or unsigned 12-byte form). Central sizes/CRC are authoritative, local fields must be zero or consistent, and the descriptor must immediately follow the compressed payload and agree with the directory. Encryption, unsupported flags, multi-disk ZIP, ZIP64, invalid lengths/CRC, unsafe paths, case-insensitive canonical duplicate paths, and symbolic links are rejected. Enumeration, writing, and reading share limits: 4,096 files, 64 MiB/file, 256 MiB total. Enumeration checks `lstat` sizes before reading. Linked save/archive directories and non-regular save files are rejected.

Host-only synthetic tests below use unique `/private/tmp` trees. They do not access a device or real save. Run from `sts2-ios`:

```sh
python3 ios-export/launcher/tests/generate_fixtures.py
xcrun --sdk macosx clang++ -DSTS2_SAVE_ARCHIVE_TESTING \
  -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -Wno-unused-command-line-argument -framework Foundation -lz \
  ios-export/launcher/STS2ZipArchive.mm \
  ios-export/launcher/STS2SaveArchiveStore.mm \
  ios-export/launcher/tests/STS2SaveArchiveStoreTests.mm \
  -o /private/tmp/sts2-save-archive-tests
/private/tmp/sts2-save-archive-tests
```

Coverage includes native/modded/wrapped layouts, ancillary files, multiple-account rejection, exports/snapshots, CRC/truncation/traversal rejection, descriptor integrity, case duplicates, total limits, symbolic trees, and subprocess termination immediately before/after both restore commit forms. The test macro only exposes commit-boundary hooks; production builds omit them.

This host has no Java runtime. The checked-in `java-equivalent-*.zip` fixtures are generated with Python's unseekable DEFLATE writer, matching Java `ZipOutputStream` flags-8/local-zero/descriptor encoding; they are not claimed to be Java-produced. Device iOS integration and filesystem power-loss durability have not been tested. Atomic namespace replacement covers process termination; it does not claim full power-loss durability.

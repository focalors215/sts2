#import "STS2SaveArchiveStore.h"
#import "STS2ZipArchive.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#import <zlib.h>

static NSString *const STS2ArchiveErrorDomain = @"STS2SaveArchiveStore";
static const uint32_t kMaxEntries = 4096;
static const uint64_t kMaxTotal = 256ull * 1024 * 1024;
static const uint64_t kMaxItem = 64ull * 1024 * 1024;
// Multiplayer saves are bound to network.playerId, so portable archives carry it
// in a sidecar entry that is never written into the save tree.
static NSString *const kIdentityEntry = @"__launcher/identity.json";
static const NSUInteger kKeepAutoSnapshots = 10;
static const NSTimeInterval kExportLifetime = 24 * 60 * 60;

static NSError *ArchiveError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:STS2ArchiveErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSString *SnapshotFilename(NSString *name) {
    NSString *clean = [[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"/"
                                  withString:@"-"];
    if (!clean.length)
        clean = @"Snapshot";
    if (clean.length > 60)
        clean = [clean substringToIndex:60];
    return [NSString stringWithFormat:@"Snapshot-%@-%@.zip", clean, NSUUID.UUID.UUIDString];
}

static BOOL HasSaveFile(NSDictionary *files) {
    for (NSString *p in files)
        if ([p.pathExtension.lowercaseString isEqualToString:@"save"])
            return YES;
    return NO;
}

// Validate lexical ancestors, including missing future paths, before any writes.
static BOOL SafeTreeAncestry(NSURL *url, NSURL *documents, NSError **error) {
    for (NSURL *part = url; part.path.length >= documents.path.length;
         part = part.URLByDeletingLastPathComponent) {
        struct stat st;
        if (lstat(part.fileSystemRepresentation, &st) == 0) {
            if (!S_ISDIR(st.st_mode)) {
                if (error)
                    *error =
                        ArchiveError(3, @"Save/archive directory contains a symbolic link or non-directory.");
                return NO;
            }
        } else if (errno != ENOENT) {
            if (error)
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
    }
    return YES;
}

@implementation STS2SaveArchiveStore {
    NSURL *_documentsURL;
    NSURL *_archiveRoot;
    NSURL *_saveURL;
}
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if ((self = [super init])) {
        _documentsURL = [documentsURL copy];
        _archiveRoot = [documentsURL URLByAppendingPathComponent:@".LauncherSaveArchive" isDirectory:YES];
        _saveURL = [[documentsURL URLByAppendingPathComponent:@"default"
                                                  isDirectory:YES] URLByAppendingPathComponent:@"1"
                                                                                   isDirectory:YES];
    }
    return self;
}
- (NSURL *)configURL {
    return [[_documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES]
        URLByAppendingPathComponent:@"config.json"];
}
- (NSString *)currentPlayerID {
    @synchronized(NSFileManager.defaultManager) {
        NSData *data = [NSData dataWithContentsOfURL:[self configURL]];
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id network = [root isKindOfClass:NSDictionary.class] ? root[@"network"] : nil;
        id value = [network isKindOfClass:NSDictionary.class] ? network[@"playerId"] : nil;
        return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
    }
}
// Only fills a missing ID. An existing ID is never replaced, and an unreadable
// config is never overwritten.
- (void)adoptPlayerID:(NSString *)playerID {
    if (!playerID.length || playerID.length > 20 ||
        [playerID rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
        return;
    @synchronized(NSFileManager.defaultManager) {
        NSURL *url = [self configURL];
        NSData *data = [NSData dataWithContentsOfURL:url];
        NSMutableDictionary *root = [NSMutableDictionary dictionary];
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if (![parsed isKindOfClass:NSDictionary.class])
                return;
            root = parsed;
        }
        NSMutableDictionary *network = [root[@"network"] isKindOfClass:NSDictionary.class]
                                           ? [root[@"network"] mutableCopy]
                                           : [NSMutableDictionary dictionary];
        if ([network[@"playerId"] isKindOfClass:NSString.class] && [network[@"playerId"] length])
            return;
        network[@"playerId"] = playerID;
        root[@"network"] = network;
        if (!root[@"schemaVersion"])
            root[@"schemaVersion"] = @1;
        NSData *out = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
        [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        [out writeToURL:url options:NSDataWritingAtomic error:nil];
    }
}
// Exports are throwaway share copies; automatic pre-restore snapshots keep the newest few.
- (void)pruneArchives {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *urls = [fm contentsOfDirectoryAtURL:_archiveRoot
                      includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                           error:nil];
    NSMutableArray *autos = [NSMutableArray array];
    for (NSURL *u in urls) {
        NSString *name = u.lastPathComponent;
        NSDate *date = [u resourceValuesForKeys:@[ NSURLContentModificationDateKey ]
                                          error:nil][NSURLContentModificationDateKey];
        if ([name hasPrefix:@"save-export-"] && date && -date.timeIntervalSinceNow > kExportLifetime)
            [fm removeItemAtURL:u error:nil];
        else if ([name hasPrefix:@"Snapshot-Auto-before-restore-"])
            [autos addObject:@{@"url" : u, @"date" : date ?: NSDate.distantPast}];
    }
    [autos sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    for (NSUInteger i = kKeepAutoSnapshots; i < autos.count; i++)
        [fm removeItemAtURL:autos[i][@"url"] error:nil];
}
- (NSDictionary<NSString *, NSData *> *)filesAtSaveURL:(NSURL *)root error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSMutableSet *folded = [NSMutableSet set];
    uint64_t total = 0;
    if (!SafeTreeAncestry(root, _documentsURL, error))
        return nil;
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator *it = [fm enumeratorAtURL:root
                         includingPropertiesForKeys:nil
                                            options:0
                                       errorHandler:^BOOL(NSURL *url, NSError *e) {
                                           (void)url;
                                           enumerationError = e;
                                           return NO;
                                       }];
    for (NSURL *url in it) {
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) != 0) {
            if (error)
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return nil;
        }
        if (S_ISDIR(st.st_mode))
            continue;
        NSString *relative = [url.path substringFromIndex:root.path.length + 1];
        NSString *fold = [relative.lowercaseString precomposedStringWithCanonicalMapping];
        if (!S_ISREG(st.st_mode) || !STS2ZipSafeRelativePath(relative) || [folded containsObject:fold] ||
            st.st_size < 0 || (uint64_t)st.st_size > kMaxItem || total + (uint64_t)st.st_size > kMaxTotal ||
            files.count >= kMaxEntries) {
            if (error)
                *error = ArchiveError(
                    3, @"Save tree has unsafe files, duplicate paths, or exceeds archive limits.");
            return nil;
        }
        // Reject oversized files before reading or mapping their contents.
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
        if (!data)
            return nil;
        if (data.length != (uint64_t)st.st_size) {
            if (error)
                *error = ArchiveError(3, @"Save changed during archive creation. Please retry.");
            return nil;
        }
        total += data.length;
        [folded addObject:fold];
        files[relative] = data;
    }
    if (enumerationError) {
        if (error)
            *error = enumerationError;
        return nil;
    }
    return files;
}
- (NSURL *)writeArchiveForFiles:(NSDictionary *)files filename:(NSString *)filename error:(NSError **)error {
    if (!SafeTreeAncestry(_archiveRoot, _documentsURL, error))
        return nil;
    NSError *e = nil;
    NSString *playerID = [self currentPlayerID];
    if (playerID) {
        NSMutableDictionary *withIdentity = [files mutableCopy];
        withIdentity[kIdentityEntry] = [NSJSONSerialization dataWithJSONObject:@{@"playerId" : playerID}
                                                                       options:0
                                                                         error:nil];
        files = withIdentity;
    }
    NSData *zip = STS2ZipCreateData(files, &e);
    if (!zip) {
        if (error)
            *error = e;
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:_archiveRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *out = [_archiveRoot URLByAppendingPathComponent:filename];
    NSURL *tmp = [_archiveRoot
        URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.tmp", NSUUID.UUID.UUIDString]];
    if (![zip writeToURL:tmp options:NSDataWritingAtomic error:&e] || ![fm moveItemAtURL:tmp
                                                                                   toURL:out
                                                                                   error:&e]) {
        [fm removeItemAtURL:tmp error:nil];
        if (error)
            *error = e;
        return nil;
    }
    [self pruneArchives];
    return out;
}
- (NSURL *)exportCurrentSave:(NSError **)error {
    NSDictionary *f = [self filesAtSaveURL:_saveURL error:error];
    if (!f)
        return nil;
    if (!HasSaveFile(f)) {
        if (error)
            *error = ArchiveError(4, @"Current save tree contains no .save file.");
        return nil;
    }
    return
        [self writeArchiveForFiles:f
                          filename:[NSString stringWithFormat:@"save-export-%@.zip", NSUUID.UUID.UUIDString]
                             error:error];
}
- (NSURL *)createSnapshotWithName:(NSString *)name error:(NSError **)error {
    NSDictionary *f = [self filesAtSaveURL:_saveURL error:error];
    if (!f)
        return nil;
    if (!HasSaveFile(f)) {
        if (error)
            *error = ArchiveError(4, @"当前没有可快照的存档。");
        return nil;
    }
    return [self writeArchiveForFiles:f filename:SnapshotFilename(name) error:error];
}
- (NSArray<NSDictionary *> *)snapshots {
    NSArray *urls = [NSFileManager.defaultManager
          contentsOfDirectoryAtURL:_archiveRoot
        includingPropertiesForKeys:@[ NSURLFileSizeKey, NSURLContentModificationDateKey ]
                           options:NSDirectoryEnumerationSkipsHiddenFiles
                             error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in urls)
        if ([u.pathExtension.lowercaseString isEqualToString:@"zip"] &&
            [u.lastPathComponent hasPrefix:@"Snapshot-"]) {
            NSDictionary *v = [u resourceValuesForKeys:@[ NSURLFileSizeKey, NSURLContentModificationDateKey ]
                                                 error:nil];
            [out addObject:@{
                @"path" : u,
                @"name" : u.lastPathComponent,
                @"size" : v[NSURLFileSizeKey] ?: @0,
                @"date" : v[NSURLContentModificationDateKey] ?: NSDate.distantPast
            }];
        }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
}
- (BOOL)restoreArchiveAtURL:(NSURL *)archiveURL error:(NSError **)error {
    NSError *e = nil;
    NSData *data = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:&e];
    if (!data) {
        if (error)
            *error = e;
        return NO;
    }
    NSDictionary *entries = STS2ZipReadData(data, &e);
    if (!entries) {
        if (error)
            *error = e;
        return NO;
    }
    // The identity sidecar is launcher metadata, not part of the account tree.
    NSString *archivedPlayerID = nil;
    NSData *identityData = entries[kIdentityEntry];
    if (identityData) {
        id identity = [NSJSONSerialization JSONObjectWithData:identityData options:0 error:nil];
        id value = [identity isKindOfClass:NSDictionary.class] ? identity[@"playerId"] : nil;
        archivedPlayerID = [value isKindOfClass:NSString.class] ? value : nil;
        NSMutableDictionary *trimmed = [entries mutableCopy];
        [trimmed removeObjectForKey:kIdentityEntry];
        entries = trimmed;
    }
    // Only known account wrappers are removed. Native paths (including modded/)
    // are account-relative and must remain byte-for-byte in the same layout.
    NSMutableSet<NSString *> *wrappers = [NSMutableSet set];
    BOOL native = NO, hasSave = NO;
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *path in entries) {
        NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
        NSString *wrapper = nil;
        if (parts.count >= 3 &&
            ([parts[0] isEqualToString:@"default"] || [parts[0] isEqualToString:@"steam"]) &&
            parts[1].length && [parts[1] rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            wrapper = [NSString stringWithFormat:@"%@/%@", parts[0], parts[1]];
        }
        if (wrapper)
            [wrappers addObject:wrapper];
        else
            native = YES;
        if ([path.pathExtension.lowercaseString isEqualToString:@"save"])
            hasSave = YES;
    }
    if (!hasSave || wrappers.count > 1 || (wrappers.count && native)) {
        if (error)
            *error = ArchiveError(5, @"Archive requires one unambiguous account containing .save files.");
        return NO;
    }
    NSString *prefix = wrappers.anyObject;
    NSMutableDictionary *selected = [NSMutableDictionary dictionary];
    for (NSString *path in entries) {
        NSString *relative = prefix ? [path substringFromIndex:prefix.length + 1] : path;
        selected[relative] = entries[path];
    }
    NSURL *stagingParent = [_archiveRoot URLByAppendingPathComponent:@"staging" isDirectory:YES];
    if (!SafeTreeAncestry(stagingParent, _documentsURL, error) ||
        !SafeTreeAncestry(_saveURL, _documentsURL, error))
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *stage = [[_archiveRoot URLByAppendingPathComponent:@"staging" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                        isDirectory:YES];
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&e]) {
        if (error)
            *error = e;
        return NO;
    }
    BOOL ok = YES;
    for (NSString *rel in selected) {
        NSURL *dst = [stage URLByAppendingPathComponent:rel];
        if (![fm createDirectoryAtURL:dst.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&e] ||
            ![selected[rel] writeToURL:dst options:NSDataWritingAtomic error:&e]) {
            ok = NO;
            break;
        }
    }
    if (!ok) {
        [fm removeItemAtURL:stage error:nil];
        if (error)
            *error = e;
        return NO;
    }
    NSURL *parent = _saveURL.URLByDeletingLastPathComponent;
    if (![fm createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:&e]) {
        [fm removeItemAtURL:stage error:nil];
        if (error)
            *error = e;
        return NO;
    }
    BOOL had = [fm fileExistsAtPath:_saveURL.path];
    NSDictionary *oldFiles = had ? [self filesAtSaveURL:_saveURL error:&e] : nil;
    if (had && !oldFiles) {
        [fm removeItemAtURL:stage error:nil];
        if (error)
            *error = e;
        return NO;
    }
    // A damaged account without any .save is exactly when restoring matters, so the
    // safety copy is taken from whatever files exist rather than requiring a save.
    if (oldFiles.count && ![self writeArchiveForFiles:oldFiles
                                             filename:SnapshotFilename(@"Auto-before-restore")
                                                error:&e]) {
        [fm removeItemAtURL:stage error:nil];
        if (error)
            *error = e ?: ArchiveError(6, @"恢复前自动快照失败，原存档未更改。");
        return NO;
    }
    // Both paths are on the Documents volume. RENAME_SWAP is one atomic namespace
    // operation: termination leaves either the complete old or complete new account.
#ifdef STS2_SAVE_ARCHIVE_TESTING
    extern void STS2SaveArchiveCommitTestHook(BOOL after);
    STS2SaveArchiveCommitTestHook(NO);
#endif
    int result = had ? renameatx_np(AT_FDCWD, stage.fileSystemRepresentation, AT_FDCWD,
                                    _saveURL.fileSystemRepresentation, RENAME_SWAP)
                     : rename(stage.fileSystemRepresentation, _saveURL.fileSystemRepresentation);
    int commitErrno = errno;
#ifdef STS2_SAVE_ARCHIVE_TESTING
    STS2SaveArchiveCommitTestHook(YES);
#endif
    if (result != 0) {
        [fm removeItemAtURL:stage error:nil];
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:commitErrno userInfo:nil];
        return NO;
    }
    // After exchange the staging directory holds the old account. A crash before
    // cleanup may leave it here, but never removes the live account.
    if (had)
        [fm removeItemAtURL:stage error:nil];
    [self adoptPlayerID:archivedPlayerID];
    return YES;
}
- (NSDictionary *)currentSaveSummary {
    // A fresh install has no account directory yet; that is an empty state, not an error.
    if (![NSFileManager.defaultManager fileExistsAtPath:_saveURL.path])
        return @{
            @"exists" : @NO,
            @"empty" : @YES,
            @"fileCount" : @0,
            @"saveFileCount" : @0,
            @"totalBytes" : @0,
            @"accountPath" : _saveURL.path
        };
    NSError *e = nil;
    NSDictionary *files = [self filesAtSaveURL:_saveURL error:&e];
    if (!files)
        return @{
            @"exists" : @NO,
            @"error" : e.localizedDescription ?: @"无法读取存档目录",
            @"accountPath" : _saveURL.path
        };
    uint64_t bytes = 0;
    NSUInteger saves = 0;
    for (NSString *p in files) {
        bytes += [files[p] length];
        if ([p.pathExtension.lowercaseString isEqualToString:@"save"])
            saves++;
    }
    return @{
        @"exists" : @(files.count > 0),
        @"fileCount" : @(files.count),
        @"saveFileCount" : @(saves),
        @"totalBytes" : @(bytes),
        @"accountPath" : _saveURL.path
    };
}
@end

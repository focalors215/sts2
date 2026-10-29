#import "../STS2SaveArchiveStore.h"
#import "../STS2ZipArchive.h"
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void Require(BOOL ok, NSString *message) {
    if (!ok) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}
static void Write(NSString *path, NSString *value) {
    [[value dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
}
static NSString *Read(NSString *path) {
    return [[NSString alloc] initWithData:[NSData dataWithContentsOfFile:path] encoding:NSUTF8StringEncoding];
}

static int crashAt = -1;
void STS2SaveArchiveCommitTestHook(BOOL after) {
    if (crashAt == (int)after)
        _exit(73);
}
static NSURL *Import(NSString *base, NSDictionary *files) {
    NSData *zip = STS2ZipCreateData(files, nil);
    Require(zip != nil, @"fixture create");
    NSURL *url = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"case.zip"]];
    Require([zip writeToURL:url atomically:YES], @"fixture write");
    return url;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 5 && strcmp(argv[1], "--crash") == 0) {
            crashAt = atoi(argv[3]);
            STS2SaveArchiveStore *child = [[STS2SaveArchiveStore alloc]
                initWithDocumentsURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]]];
            [child restoreArchiveAtURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]]
                                 error:nil];
            return 74;
        }
        NSString *base = [@"/private/tmp" stringByAppendingPathComponent:[NSUUID.UUID.UUIDString copy]];
        NSURL *docs = [NSURL fileURLWithPath:base isDirectory:YES];
        NSString *save =
            [[[base stringByAppendingPathComponent:@"default"] stringByAppendingPathComponent:@"1"] copy];
        [[NSFileManager defaultManager] createDirectoryAtPath:save
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        Write([save stringByAppendingPathComponent:@"profile.save"], @"old-save-bytes");
        Write([save stringByAppendingPathComponent:@"settings.json"], @"old-settings");
        STS2SaveArchiveStore *store = [[STS2SaveArchiveStore alloc] initWithDocumentsURL:docs];
        NSError *error = nil;
        NSURL *exportURL = [store exportCurrentSave:&error];
        Require(exportURL != nil, error.localizedDescription ?: @"export failed");
        NSDictionary *decoded = STS2ZipReadData([NSData dataWithContentsOfURL:exportURL], &error);
        Require([decoded[@"profile.save"]
                    isEqualToData:[@"old-save-bytes" dataUsingEncoding:NSUTF8StringEncoding]],
                @"export roundtrip mismatch");
        NSURL *snapshot = [store createSnapshotWithName:@"before test" error:&error];
        Require(snapshot != nil, error.localizedDescription ?: @"snapshot failed");
        Require([store.snapshots count] == 1, @"snapshot listing failed");
        // Import an Android/PC-style wrapped account. Every file under the one account root is retained.
        NSData *newSave = [@"new-save-bytes" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *newSettings = [@"new-settings" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *wrapped = STS2ZipCreateData(
            @{@"steam/12345/profile.save" : newSave, @"steam/12345/settings.json" : newSettings}, &error);
        Require(wrapped != nil, @"fixture zip creation failed");
        NSString *import = [base stringByAppendingPathComponent:@"import.zip"];
        [wrapped writeToFile:import atomically:YES];
        Require([store restoreArchiveAtURL:[NSURL fileURLWithPath:import] error:&error],
                error.localizedDescription ?: @"restore failed");
        Require(
            [Read([save stringByAppendingPathComponent:@"profile.save"]) isEqualToString:@"new-save-bytes"],
            @"restored save mismatch");
        Require(
            [Read([save stringByAppendingPathComponent:@"settings.json"]) isEqualToString:@"new-settings"],
            @"restored ancillary file mismatch");
        Require([store.snapshots count] == 2, @"automatic pre-restore snapshot missing");
        NSString *before = Read([save stringByAppendingPathComponent:@"profile.save"]);
        NSMutableData *bad = [wrapped mutableCopy];
        const uint8_t *raw = (const uint8_t *)bad.bytes;
        const char needle[] = "new-save-bytes";
        NSUInteger hit = NSNotFound;
        for (NSUInteger i = 0; i + sizeof(needle) - 1 < bad.length; i++)
            if (memcmp(raw + i, needle, sizeof(needle) - 1) == 0) {
                hit = i;
                break;
            }
        Require(hit != NSNotFound, @"could not locate fixture payload");
        ((uint8_t *)bad.mutableBytes)[hit] ^= 1;
        NSString *badPath = [base stringByAppendingPathComponent:@"bad-crc.zip"];
        [bad writeToFile:badPath atomically:YES];
        error = nil;
        Require(![store restoreArchiveAtURL:[NSURL fileURLWithPath:badPath] error:&error],
                @"bad CRC accepted");
        Require([Read([save stringByAppendingPathComponent:@"profile.save"]) isEqualToString:before],
                @"bad CRC changed current save");
        NSData *truncated = [wrapped subdataWithRange:NSMakeRange(0, wrapped.length - 8)];
        NSString *truncPath = [base stringByAppendingPathComponent:@"truncated.zip"];
        [truncated writeToFile:truncPath atomically:YES];
        Require(![store restoreArchiveAtURL:[NSURL fileURLWithPath:truncPath] error:&error],
                @"truncated ZIP accepted");
        NSMutableData *traversal = [wrapped mutableCopy];
        const char *from = "12345";
        const char *to = "../..";
        Require(strlen(from) == strlen(to), @"bad traversal test lengths");
        for (NSUInteger i = 0; i + strlen(from) <= traversal.length; i++)
            if (memcmp((const uint8_t *)traversal.bytes + i, from, strlen(from)) == 0)
                memcpy((uint8_t *)traversal.mutableBytes + i, to, strlen(to));
        NSString *traversalPath = [base stringByAppendingPathComponent:@"traversal.zip"];
        [traversal writeToFile:traversalPath atomically:YES];
        Require(![store restoreArchiveAtURL:[NSURL fileURLWithPath:traversalPath] error:&error],
                @"path traversal ZIP accepted");
        Require([Read([save stringByAppendingPathComponent:@"profile.save"]) isEqualToString:before],
                @"invalid archive changed original tree");
        // Native root and modded subtree are one account and keep ancillary files.
        NSData *value = [@"layout-save" dataUsingEncoding:NSUTF8StringEncoding];
        for (NSDictionary *layout in @[
                 @{@"profile.save" : value, @"modded/profile.save" : value, @"settings.json" : value},
                 @{@"modded/profile.save" : value, @"settings.json" : value},
                 @{@"default/1/modded/profile.save" : value, @"default/1/settings.json" : value}
             ]) {
            Require([store restoreArchiveAtURL:Import(base, layout) error:&error],
                    error.localizedDescription);
            Require(
                [[NSData dataWithContentsOfFile:[save stringByAppendingPathComponent:@"modded/profile.save"]]
                    isEqual:value],
                @"modded layout stripped");
            Require([[NSData dataWithContentsOfFile:[save stringByAppendingPathComponent:@"settings.json"]]
                        isEqual:value],
                    @"ancillary file lost");
        }
        Require(
            ![store
                restoreArchiveAtURL:Import(
                                        base,
                                        @{@"steam/1/profile.save" : value, @"steam/2/profile.save" : value})
                              error:&error],
            @"multiple accounts accepted");
        Require(
            ![store
                restoreArchiveAtURL:Import(base, @{@"steam/1/profile.save" : value, @"profile.save" : value})
                              error:&error],
            @"mixed native/wrapped account accepted");
        NSURL *firstExport = [store exportCurrentSave:&error];
        NSURL *secondExport = [store exportCurrentSave:&error];
        Require(firstExport && secondExport && ![firstExport isEqual:secondExport],
                @"same-second export collision");

        NSString *fixtures = [[NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"fixtures"];
        for (NSString *name in @[ @"java-equivalent-signed.zip", @"java-equivalent-unsigned.zip" ]) {
            NSData *fixture = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:name]];
            Require(fixture != nil, @"missing descriptor fixture");
            Require(STS2ZipReadData(fixture, &error)[@"profile.save"] != nil, error.localizedDescription);
            NSMutableData *broken = [fixture mutableCopy];
            uint8_t *bytes = (uint8_t *)broken.mutableBytes;
            for (NSUInteger i = 0; i + 4 < broken.length; i++) {
                if (memcmp(bytes + i, "PK\x01\x02", 4) == 0) {
                    bytes[i - 1] ^= 1;
                    break;
                }
            }
            Require(STS2ZipReadData(broken, &error) == nil, @"invalid descriptor accepted");
        }

        Require(STS2ZipCreateData(@{@"A.save" : value, @"a.save" : value}, &error) == nil,
                @"casefold duplicates accepted");
        NSMutableData *large = [NSMutableData dataWithLength:64ull * 1024 * 1024];
        Require(
            STS2ZipCreateData(@{@"a" : large, @"b" : large, @"c" : large, @"d" : large, @"e.save" : large},
                              &error) == nil,
            @"writer total limit missing");
        // Sparse files exercise pre-read size accounting without allocating payloads.
        NSString *limitBase = [base stringByAppendingPathComponent:@"limits"];
        NSString *limitSave = [limitBase stringByAppendingPathComponent:@"default/1"];
        [NSFileManager.defaultManager createDirectoryAtPath:limitSave
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        for (int i = 0; i < 5; i++) {
            NSString *path =
                [limitSave stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.save", i]];
            int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600);
            Require(fd >= 0 && ftruncate(fd, 64ll * 1024 * 1024) == 0, @"sparse fixture creation");
            close(fd);
        }
        STS2SaveArchiveStore *limited =
            [[STS2SaveArchiveStore alloc] initWithDocumentsURL:[NSURL fileURLWithPath:limitBase]];
        Require([limited exportCurrentSave:&error] == nil, @"enumerator total limit missing");
        [NSFileManager.defaultManager
            createSymbolicLinkAtPath:[save stringByAppendingPathComponent:@"linked.save"]
                 withDestinationPath:@"modded/profile.save"
                               error:nil];
        Require([store exportCurrentSave:&error] == nil, @"symbolic tree exported");
        [NSFileManager.defaultManager removeItemAtPath:[save stringByAppendingPathComponent:@"linked.save"]
                                                 error:nil];

#ifdef STS2_SAVE_ARCHIVE_TESTING
        // Terminate immediately on both sides of the actual filesystem commit.
        for (int had = 0; had <= 1; had++)
            for (int point = 0; point <= 1; point++) {
                NSString *crashBase = [base
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"crash-%d-%d", had, point]];
                NSString *crashSave = [crashBase stringByAppendingPathComponent:@"default/1"];
                [NSFileManager.defaultManager createDirectoryAtPath:crashBase
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:nil];
                if (had) {
                    [NSFileManager.defaultManager createDirectoryAtPath:crashSave
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:nil];
                    Write([crashSave stringByAppendingPathComponent:@"profile.save"], @"original");
                }
                NSURL *input = Import(crashBase, @{@"profile.save" : value});
                NSTask *task = [NSTask new];
                task.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]];
                task.arguments = @[ @"--crash", crashBase, @(point).stringValue, input.path ];
                Require([task launchAndReturnError:&error], error.localizedDescription);
                [task waitUntilExit];
                Require(task.terminationStatus == 73, @"commit interruption hook missed");
                STS2SaveArchiveStore *reopened =
                    [[STS2SaveArchiveStore alloc] initWithDocumentsURL:[NSURL fileURLWithPath:crashBase]];
                (void)reopened;
                NSString *contents = Read([crashSave stringByAppendingPathComponent:@"profile.save"]);
                Require(point ? [contents isEqualToString:@"layout-save"]
                              : (had ? [contents isEqualToString:@"original"]
                                     : ![NSFileManager.defaultManager fileExistsAtPath:crashSave]),
                        @"interruption lost or partially installed account");
            }
#endif
        // Identity sidecar: exported with playerId, restored only into a config that lacks one.
        {
            NSString *idBase = [@"/private/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            NSString *idSave = [idBase stringByAppendingPathComponent:@"default/1"];
            [[NSFileManager defaultManager] createDirectoryAtPath:idSave withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:[idBase stringByAppendingPathComponent:@"Launcher"] withIntermediateDirectories:YES attributes:nil error:nil];
            Write([idSave stringByAppendingPathComponent:@"profile.save"], @"id-save");
            NSString *cfg = [idBase stringByAppendingPathComponent:@"Launcher/config.json"];
            Write(cfg, @"{\"schemaVersion\":1,\"network\":{\"playerId\":\"424242\"}}");
            STS2SaveArchiveStore *idStore = [[STS2SaveArchiveStore alloc] initWithDocumentsURL:[NSURL fileURLWithPath:idBase isDirectory:YES]];
            NSURL *idExport = [idStore exportCurrentSave:&error];
            Require(idExport != nil, @"identity export failed");
            NSDictionary *idEntries = STS2ZipReadData([NSData dataWithContentsOfURL:idExport], &error);
            Require(idEntries[@"__launcher/identity.json"] != nil, @"identity sidecar missing from export");
            Require(idEntries[@"profile.save"] != nil, @"save missing from export");
            // Restore with the config gone: ID comes back; the sidecar never lands in the account.
            [[NSFileManager defaultManager] removeItemAtPath:cfg error:nil];
            Require([idStore restoreArchiveAtURL:idExport error:&error], error.localizedDescription ?: @"identity restore failed");
            Require([Read(cfg) containsString:@"424242"], @"playerId not restored into empty config");
            Require(![[NSFileManager defaultManager] fileExistsAtPath:[idSave stringByAppendingPathComponent:@"__launcher"]], @"sidecar leaked into account");
            // An existing different ID is never replaced.
            Write(cfg, @"{\"schemaVersion\":1,\"network\":{\"playerId\":\"777\"}}");
            Require([idStore restoreArchiveAtURL:idExport error:&error], @"second restore failed");
            Require([Read(cfg) containsString:@"777"] && ![Read(cfg) containsString:@"424242"], @"existing playerId was overwritten");
            // Corrupt config is left alone.
            Write(cfg, @"{not json");
            Require([idStore restoreArchiveAtURL:idExport error:&error], @"third restore failed");
            Require([Read(cfg) isEqualToString:@"{not json"], @"corrupt config was overwritten");
            // Damaged current account without any .save can still be restored (auto-snapshot still taken).
            [[NSFileManager defaultManager] removeItemAtPath:[idSave stringByAppendingPathComponent:@"profile.save"] error:nil];
            Write([idSave stringByAppendingPathComponent:@"junk.json"], @"junk");
            NSUInteger before = [idStore snapshots].count;
            Require([idStore restoreArchiveAtURL:idExport error:&error], error.localizedDescription ?: @"restore over save-less account failed");
            Require([idStore snapshots].count == before + 1, @"no auto snapshot for save-less account");
            Require([Read([idSave stringByAppendingPathComponent:@"profile.save"]) isEqualToString:@"id-save"], @"restore over save-less account lost data");
            [[NSFileManager defaultManager] removeItemAtPath:idBase error:nil];
        }
        NSLog(@"PASS: layouts, descriptors, limits, symlinks, unique exports, atomic commit interruption, "
              @"ZIP integrity");
        [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    }
    return 0;
}

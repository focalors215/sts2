// WebDAV 云存档端到端宿主测试：两台“设备”（两个 default/1 目录）通过本地测试服务器同步，
// 覆盖上传、另一台拉取、无变化、冲突检测、强制拉取、Android 同款远端布局与 manifest。
#import <Foundation/Foundation.h>
#import "../STS2WebDavSync.h"
#import "../STS2Log.h"

static int failures = 0;
static void Check(bool ok, const char *name) { if (ok) printf("[OK] %s\n", name); else { printf("[FAIL] %s\n", name); failures++; } }

static NSURL *Temp(NSString *name) {
    NSURL *url = [[NSURL fileURLWithPath:@"/private/tmp"] URLByAppendingPathComponent:[NSString stringWithFormat:@"sts2-dav-%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}
static void Write(NSURL *root, NSString *path, NSString *text) {
    NSURL *url = [root URLByAppendingPathComponent:path];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *Read(NSURL *root, NSString *path) { return [NSString stringWithContentsOfURL:[root URLByAppendingPathComponent:path] encoding:NSUTF8StringEncoding error:nil]; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: tests <port> <server-root>\n"); return 2; }
        NSString *port = @(argv[1]); NSURL *serverRoot = [NSURL fileURLWithPath:@(argv[2])];
        [STS2Log setupWithLogsDirectory:Temp(@"logs") installCrashHandlers:NO];
        Check([STS2WebDavSync isSupportedPath:@"profile1/saves/progress.save" includeSettings:NO] && [STS2WebDavSync isSupportedPath:@"modded/profile2/saves/history/123.run" includeSettings:NO] &&
              ![STS2WebDavSync isSupportedPath:@"settings.save" includeSettings:NO] && [STS2WebDavSync isSupportedPath:@"settings.save" includeSettings:YES] &&
              ![STS2WebDavSync isSupportedPath:@"profile1/saves/../x.save" includeSettings:NO] && ![STS2WebDavSync isSupportedPath:@"profile4/saves/progress.save" includeSettings:NO] &&
              ![STS2WebDavSync isSupportedPath:@"profile1/saves/history/a/b.run" includeSettings:NO], "路径白名单与 Android WebDavSavePathMapper 一致");
        Check([[STS2WebDavConfig sanitizeSlot:@" My Slot!! "] isEqual:@"my-slot"] && [[STS2WebDavConfig sanitizeSlot:@""] isEqual:@"global"], "槽位名规范化同 Android sanitizeId");
        NSData *xml = [@"<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>/dav/a%20b/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response><D:response><D:href>https://x.com/dav/a%20b/f.save</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12</D:getcontentlength><D:getetag>\"e1\"</D:getetag></D:prop></D:propstat></D:response></D:multistatus>" dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *resources = [STS2WebDavSync resourcesFromMultistatus:xml basePath:@"/dav/a%20b/"];
        Check(resources.count == 2 && [resources[0][@"path"] isEqual:@""] && [resources[1][@"path"] isEqual:@"f.save"] && [resources[1][@"size"] isEqual:@12] && [resources[1][@"etag"] isEqual:@"\"e1\""], "PROPFIND 解析（前缀命名空间、绝对 URL、百分号编码）");

        STS2WebDavConfig *config = [STS2WebDavConfig new];
        config.baseURL = [NSString stringWithFormat:@"http://127.0.0.1:%@/dav/", port]; config.username = @"tester"; config.password = @"pw-123456"; config.remoteSlot = @"Shared";
        NSURL *ipad = Temp(@"ipad"), *other = Temp(@"other");
        STS2WebDavSync *a = [[STS2WebDavSync alloc] initWithConfig:config accountURL:ipad stateURL:Temp(@"state-a")];
        STS2WebDavSync *b = [[STS2WebDavSync alloc] initWithConfig:config accountURL:other stateURL:Temp(@"state-b")];
        NSError *error = nil;
        Check([a testConnection:&error] != nil, "测试连接并创建槽位目录");
        STS2WebDavConfig *wrong = [STS2WebDavConfig new]; wrong.baseURL = config.baseURL; wrong.username = @"tester"; wrong.password = @"bad";
        error = nil;
        Check(![[[STS2WebDavSync alloc] initWithConfig:wrong accountURL:ipad stateURL:Temp(@"s")] testConnection:&error] && [error.localizedDescription containsString:@"401"], "密码错误给出 401 提示");
        Write(ipad, @"profile1/saves/progress.save", @"{\"v\":1}");
        Write(ipad, @"profile1/saves/history/1.run", @"run");
        Write(ipad, @"profile1/saves/unrelated.tmp", @"x");
        error = nil;
        NSString *pushed = [a push:NO progress:nil error:&error];
        Check(pushed && [pushed containsString:@"2 个文件"], "上传 2 个白名单文件");
        NSURL *slot = [serverRoot URLByAppendingPathComponent:@"SlayTheSpire2/saves/shared"];
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[slot URLByAppendingPathComponent:@".sts2re/manifest.json"]] options:0 error:nil];
        Check([Read(slot, @"profile1/saves/progress.save") isEqual:@"{\"v\":1}"] && ![NSFileManager.defaultManager fileExistsAtPath:[slot URLByAppendingPathComponent:@"profile1/saves/unrelated.tmp"].path], "远端布局 SlayTheSpire2/saves/<槽位>/");
        Check([manifest[@"entries"] count] == 2 && [manifest[@"entries"][0][@"sha1"] length] == 40, "远端 manifest 带 sha1（Android 同格式）");
        error = nil;
        NSString *pulled = [b pull:NO progress:nil error:&error]; if (!pulled) printf("pull error: %s\n", error.localizedDescription.UTF8String);
        Check(pulled && [Read(other, @"profile1/saves/progress.save") isEqual:@"{\"v\":1}"], "另一台设备拉取");
        Check([[b pull:NO progress:nil error:&error] containsString:@"没有需要拉取"], "无变化时不重复下载");
        Write(other, @"profile1/saves/progress.save", @"{\"v\":2}");
        Check([b push:NO progress:nil error:&error] != nil, "第二台上传修改");
        Check([a pull:NO progress:nil error:&error] && [Read(ipad, @"profile1/saves/progress.save") isEqual:@"{\"v\":2}"], "第一台拉到新进度");
        Write(ipad, @"profile1/saves/progress.save", @"{\"v\":3,\"ipad\":true}");
        Write(other, @"profile1/saves/progress.save", @"{\"v\":3,\"other\":true}");
        Check([b push:NO progress:nil error:&error] != nil, "第二台先上传");
        error = nil;
        Check(![a pull:NO progress:nil error:&error] && error.code == STS2WebDavErrorConflict && [error.userInfo[STS2WebDavConflictPathsKey] containsObject:@"profile1/saves/progress.save"], "两边都改 → 拉取报冲突");
        error = nil;
        Check(![a push:NO progress:nil error:&error] && error.code == STS2WebDavErrorConflict, "两边都改 → 上传也报冲突");
        Check([a pull:YES progress:nil error:&error] && [Read(ipad, @"profile1/saves/progress.save") containsString:@"other"], "强制拉取以云端为准");
        printf(failures ? "%d FAILED\n" : "ALL PASSED\n", failures);
        return failures ? 1 : 0;
    }
}

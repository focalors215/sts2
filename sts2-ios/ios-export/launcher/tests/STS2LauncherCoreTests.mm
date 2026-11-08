// 宿主单测（规范 §7）：房间卡解析、pending-action 读写/过期字段、日志脱敏与滚动、导出包内容、
// 联机身份、日志 AI 工具与会话。只用 /private/tmp 下的临时目录，不碰设备与真实存档。
#import <Foundation/Foundation.h>
#import "../STS2Log.h"
#import "../STS2LogCenter.h"
#import "../STS2LogAnalysis.h"
#import "../STS2PendingAction.h"
#import "../STS2RoomService.h"
#import "../STS2LauncherConfigStore.h"
#import "../STS2SecretStore.h"
#import "../STS2ZipArchive.h"
#import "../STS2NexusMods.h"
#import "../STS2UpdateChecker.h"

// libfrpbridge.a 的符号在宿主测试里用桩替代（房间扫描/开房不在宿主上联网）。
extern "C" {
int Sts2RoomServe(char *info) { return -1; }
void Sts2RoomStopServe(void) {}
char *Sts2RoomScan(char *server, int firstPort, int count, int timeoutMs) { return NULL; }
char *Sts2FrpStart(char *path) { return NULL; }
char *Sts2FrpStatus(char *proxyName) { return NULL; }
void Sts2FrpStop(void) {}
}

static int failures = 0;
// 条件里常有 @[...]/@{...} 的逗号，这里统一用最后一个参数作名字。
#define CHECK(...) CheckImpl(__VA_ARGS__)


static void CheckImpl(bool ok, const char *name) { if (ok) printf("[OK] %s\n", name); else { printf("[FAIL] %s\n", name); failures++; } }

static NSURL *TempDir(NSString *name) {
    NSURL *url = [[NSURL fileURLWithPath:@"/private/tmp"] URLByAppendingPathComponent:[NSString stringWithFormat:@"sts2-core-%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

static NSData *Json(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }

static void TestRoomCards(void) {
    NSData *scan = Json(@[
        @{@"slot": @3, @"info": @{@"v": @1, @"name": @"喵喵零的房间", @"host": @"喵喵零", @"version": @"v0.111.0", @"continuing": @YES, @"created": @1762650000, @"slot": @3, @"port": @1, @"platform": @"android"}},
        @{@"slot": @0, @"info": @{@"name": @"", @"platform": @"Windows", @"extra": @"ignored"}},
        @{@"slot": @0, @"info": @{@"name": @"重复槽位"}},
        @{@"slot": @25, @"info": @{@"name": @"越界槽位"}},
        @{@"slot": @5, @"info": @"not an object"},
        @{@"slot": @7, @"info": @{@"name": @"未知平台", @"platform": @"switch"}},
    ]);
    NSArray *rooms = [STS2RoomService roomsFromScanData:scan];
    CHECK(rooms.count == 3, "房间卡：丢弃越界/重复/非对象，保留 3 个");
    CHECK([rooms[0][@"slot"] isEqual:@0] && [rooms[1][@"slot"] isEqual:@3], "房间卡：按槽位排序");
    CHECK([rooms[1][@"port"] isEqual:@33774], "房间卡：端口由槽位推出，不信任卡片 port");
    CHECK([rooms[1][@"platform"] isEqual:@"android"] && [rooms[0][@"platform"] isEqual:@"windows"] && [rooms[2][@"platform"] isEqual:@"unknown"], "房间卡：platform 规范化");
    CHECK([rooms[0][@"name"] isEqual:@"未命名房间"] && [rooms[0][@"version"] isEqual:@"unknown"] && [rooms[0][@"extra"] isEqual:@"ignored"], "房间卡：缺省名字/版本，保留未知字段");
    CHECK([[STS2RoomService roomsFromScanData:[@"garbage" dataUsingEncoding:NSUTF8StringEncoding]] count] == 0 && [[STS2RoomService roomsFromScanData:nil] count] == 0, "房间卡：坏数据返回空列表");
    NSDictionary *card = [STS2RoomService roomCardWithNickname:@"小鱼" version:@"v0.111.0" continuing:NO slot:4 created:[NSDate dateWithTimeIntervalSince1970:1762650000]];
    CHECK([card[@"platform"] isEqual:@"ios"] && [card[@"v"] isEqual:@1] && [card[@"port"] isEqual:@33775] && [card[@"name"] isEqual:@"小鱼的房间"] && [card[@"created"] isEqual:@1762650000], "房间卡 v1：写 platform=ios 与槽位端口");
    CHECK([[STS2RoomService platformLabel:@"ios"] isEqual:@"iPad"] && [[STS2RoomService platformLabel:nil] isEqual:@"未知平台"], "平台显示名");
}

static void TestPendingAction(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1762650000];
    NSDictionary *join = [STS2PendingAction actionWithType:@"join" online:YES host:@"frp.example.com" port:33774 nickname:@"喵喵零" playerId:@"1234567890123" now:now];
    NSDictionary *expected = @{@"v": @1, @"type": @"join", @"created": @1762650000, @"online": @YES, @"host": @"frp.example.com", @"port": @33774, @"nickname": @"喵喵零", @"playerId": @"1234567890123"};
    CHECK([join isEqual:expected], "pending-action：join 字段与规范 §3.3 一致");
    NSDictionary *host = [STS2PendingAction actionWithType:@"host" online:NO host:nil port:0 nickname:@"小鱼" playerId:@"42" now:now];
    CHECK(!host[@"host"] && !host[@"port"] && [host[@"online"] isEqual:@NO], "pending-action：host 不写地址");
    NSURL *docs = TempDir(@"pending");
    NSError *error = nil;
    CHECK([STS2PendingAction writeAction:join documentsURL:docs error:&error], "pending-action：写入");
    NSURL *file = [STS2PendingAction fileURLForDocuments:docs];
    CHECK([file.path hasSuffix:@"Launcher/pending-action.json"], "pending-action：路径 Documents/Launcher/pending-action.json");
    CHECK([[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:0 error:nil] isEqual:expected], "pending-action：读回一致");
    [STS2PendingAction discardLeftoverInDocuments:docs];
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:file.path], "pending-action：启动器打开时清理残留");
}

static void TestLogging(void) {
    NSURL *dir = TempDir(@"logs");
    [STS2Log setupWithLogsDirectory:dir installCrashHandlers:NO];
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1762662896.789]; // 2025-11-09T12:34:56.789+08:00
    NSString *line = [STS2Log formatLineWithDate:date timeZone:zone level:STS2LogLevelError tag:@"online" message:@"创建房间失败: 原文" detail:[NSError errorWithDomain:@"STS2Room" code:2 userInfo:@{NSLocalizedDescriptionKey: @"服务器房间已满"}]];
    CHECK([line isEqual:@"2025-11-09T12:34:56.789+08:00 E [online] 创建房间失败: 原文 | STS2Room(2): 服务器房间已满"], "日志行格式与规范 §5.1 一致");
    NSException *exception = [NSException exceptionWithName:@"StS2Launch" reason:@"boom" userInfo:nil];
    @try { @throw exception; } @catch (NSException *e) { exception = e; }
    NSString *multi = [STS2Log formatLineWithDate:date timeZone:zone level:STS2LogLevelWarn tag:@"app" message:@"第一行\n第二行" detail:exception];
    CHECK([multi hasPrefix:@"2025-11-09T12:34:56.789+08:00 W [app] 第一行\n    第二行 | StS2Launch: boom\n    at "], "多行消息与堆栈缩进");
    [STS2Log registerSecret:@"tok-SECRET-123"];
    NSString *redacted = [STS2Log redact:@"auth.token = \"tok-SECRET-123\" password=hunter22 {\"apiKey\":\"k-1\"} Authorization: Bearer sk-live-9 原文 tok-SECRET-123"];
    CHECK([redacted rangeOfString:@"tok-SECRET"].location == NSNotFound && [redacted rangeOfString:@"hunter22"].location == NSNotFound &&
          [redacted rangeOfString:@"k-1"].location == NSNotFound && [redacted rangeOfString:@"sk-live"].location == NSNotFound, "脱敏：登记密钥、键值、JSON、Bearer");
    CHECK([[STS2Log redact:@"玩家 token 已保存"] isEqual:@"玩家 token 已保存"], "脱敏：普通文字不误伤");
    STS2Log.minimumLevel = STS2LogLevelInfo;
    [STS2Log log:STS2LogLevelDebug tag:@"app" message:@"不应写入"];
    STS2LogI(STS2LogTagApp, @"写入 %@", @"tok-SECRET-123");
    NSString *content = [NSString stringWithContentsOfURL:STS2Log.launcherLogURL encoding:NSUTF8StringEncoding error:nil];
    CHECK([content rangeOfString:@"不应写入"].location == NSNotFound && [content rangeOfString:@"I [app] 写入 ***"].location != NSNotFound, "按等级过滤并在落盘前脱敏");
    STS2Log.maxFileBytes = 1024;
    for (int i = 0; i < 200; i++) STS2LogI(STS2LogTagApp, @"滚动测试第 %d 行 ................................................", i);
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'launcher'"]];
    NSDictionary *size = [NSFileManager.defaultManager attributesOfItemAtPath:STS2Log.launcherLogURL.path error:nil];
    CHECK(names.count == 5 && [names containsObject:@"launcher.4.log"] && ![names containsObject:@"launcher.5.log"], "滚动保留 5 个文件");
    CHECK([size[NSFileSize] unsignedLongLongValue] <= 1024 + 200, "当前文件不超过上限");
    STS2Log.maxFileBytes = 2ull * 1024 * 1024;
    // 崩溃记录：下一次启动补记到 launcher.log。
    [@"致命信号 SIGSEGV\n0 libsystem\n" writeToURL:[dir URLByAppendingPathComponent:@"pending-crash.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *crash = [STS2Log takePreviousCrashReport];
    CHECK([crash hasPrefix:@"致命信号 SIGSEGV"] && ![STS2Log takePreviousCrashReport], "崩溃记录读一次即清空");
}

static void TestLaunchMarker(void) {
    NSURL *docs = TempDir(@"marker");
    [STS2LaunchMarker setDocumentsURL:docs];
    CHECK([STS2LaunchMarker takePrevious] == nil, "没有残留标记");
    [STS2LaunchMarker writeWithInfo:@{@"reason": @"开始游戏", @"gameVersion": @"v0.111.0"}];
    [STS2LaunchMarker updateState:@"background"];
    NSDictionary *marker = [STS2LaunchMarker takePrevious];
    CHECK([marker[@"state"] isEqual:@"background"] && [marker[@"gameVersion"] isEqual:@"v0.111.0"] && marker[@"started"], "后台标记");
    CHECK([STS2LaunchMarker takePrevious] == nil, "标记读一次即删除");
    [STS2LaunchMarker writeWithInfo:@{@"reason": @"x"}];
    CHECK([[STS2LaunchMarker takePrevious][@"state"] isEqual:@"running"], "前台残留 = running（视为异常退出）");
}

static void TestLogCenter(void) {
    NSString *text = @"2026-11-09T12:34:56.789+08:00 I [app] 启动\n2026-11-09T12:34:57.000+08:00 E [online] 失败 | X: y\n    at Foo\n    at Bar\nERROR: Godot 错误\n   at: res://x.gd:1\nWARNING: 小心\n[STS2MobileIos] [OnlineRoom] 普通\n";
    NSArray *entries = [STS2LogCenter entriesFromText:text];
    CHECK(entries.count == 5, "日志条目：堆栈并入上一条");
    CHECK([entries[1][@"level"] integerValue] == STS2LogLevelError && [entries[1][@"text"] hasSuffix:@"at Bar"], "统一格式 E 级别");
    CHECK([entries[2][@"level"] integerValue] == STS2LogLevelError && [entries[3][@"level"] integerValue] == STS2LogLevelWarn && [entries[4][@"level"] integerValue] == STS2LogLevelInfo, "Godot ERROR/WARNING 识别");

    NSURL *docs = TempDir(@"export"), *caches = TempDir(@"caches");
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:[docs URLByAppendingPathComponent:@"Launcher/logs"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:[docs URLByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"launcher token=abc12345\n" writeToURL:[docs URLByAppendingPathComponent:@"Launcher/logs/launcher.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"online\n" writeToURL:[docs URLByAppendingPathComponent:@"Launcher/online-game.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"godot\n" writeToURL:[docs URLByAppendingPathComponent:@"logs/godot.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"frp\n" writeToURL:[caches URLByAppendingPathComponent:@"frpc.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{}" writeToURL:[docs URLByAppendingPathComponent:@"Launcher/launch-marker.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    STS2LogCenter *center = [[STS2LogCenter alloc] initWithDocumentsURL:docs cachesURL:caches];
    NSArray *files = [center logFiles];
    NSSet *categories = [NSSet setWithArray:[files valueForKey:@"category"]];
    CHECK(files.count == 4 && [categories isEqualToSet:[NSSet setWithArray:@[@"launcher", @"online", @"game", @"frp"]]], "列出四类日志");
    NSError *error = nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1762662896];
    NSURL *zip = [center exportArchiveWithDiagnostics:@{@"platform": @"ios"} redactedConfig:@{@"network": @{@"nickname": @"喵"}} destination:TempDir(@"out") date:date error:&error];
    NSDictionary *entriesInZip = zip ? STS2ZipReadData([NSData dataWithContentsOfURL:zip], &error) : nil;
    CHECK([zip.lastPathComponent hasPrefix:@"sts2-logs-ios-2025"] && [zip.pathExtension isEqual:@"zip"], "导出文件名 sts2-logs-ios-<时间>.zip");
    NSSet *expected = [NSSet setWithArray:@[@"launcher/launcher.log", @"online/online-game.log", @"game/godot.log", @"frp/frpc.log", @"diagnostics.json", @"config.redacted.json", @"launcher/launch-marker.json"]];
    CHECK([[NSSet setWithArray:entriesInZip.allKeys] isEqualToSet:expected], "导出包内容齐全");
    NSString *exportedLauncher = [[NSString alloc] initWithData:entriesInZip[@"launcher/launcher.log"] encoding:NSUTF8StringEncoding];
    CHECK([exportedLauncher rangeOfString:@"abc12345"].location == NSNotFound, "导出日志已脱敏");
    NSDictionary *diag = [NSJSONSerialization JSONObjectWithData:entriesInZip[@"diagnostics.json"] options:0 error:nil];
    CHECK([diag[@"platform"] isEqual:@"ios"] && [diag[@"files"] count] == 4, "diagnostics.json 带文件清单");
}

static void TestConfig(void) {
    NSURL *docs = TempDir(@"config");
    NSURL *file = [docs URLByAppendingPathComponent:@"Launcher/config.json"];
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [Json(@{@"schemaVersion": @1, @"network": @{@"nickname": @"喵", @"frp": @{@"enabled": @YES, @"token": @"legacy-tok-1"}}, @"resourceMods": @[@{@"id": @"a"}], @"unknown": @7}) writeToURL:file atomically:YES];
    STS2LauncherConfigStore *store = [[STS2LauncherConfigStore alloc] initWithDocumentsURL:docs];
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:0 error:nil];
    CHECK([STS2LauncherConfigStore isValidPlayerId:store.playerId] && [root[@"network"][@"playerId"] isEqual:store.playerId], "首次生成并保存 playerId");
    CHECK(strtoull(store.playerId.UTF8String, NULL, 10) > 1 && strtoull(store.playerId.UTF8String, NULL, 10) <= 0x7FFFFFFFFFFFFFFFULL, "playerId 为 >1 的 63 位");
    CHECK(!root[@"network"][@"frp"][@"token"] && [[STS2SecretStore secretForKey:STS2SecretFrpToken] isEqual:@"legacy-tok-1"], "旧 config 里的令牌迁到钥匙串并删除");
    CHECK([root[@"unknown"] isEqual:@7] && [root[@"resourceMods"] count] == 1, "保留未知字段与 resourceMods");
    STS2LauncherConfigStore *again = [[STS2LauncherConfigStore alloc] initWithDocumentsURL:docs];
    CHECK([again.playerId isEqual:store.playerId], "playerId 持久化");
    [again setLauncherSetting:@NO forKey:@"preLaunchSnapshot" error:nil];
    again.nickname = @"小鱼"; [again save:nil];
    root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:0 error:nil];
    CHECK([root[@"launcher"][@"preLaunchSnapshot"] isEqual:@NO] && [root[@"network"][@"nickname"] isEqual:@"小鱼"] && [root[@"network"][@"playerId"] isEqual:store.playerId], "设置与昵称合并保存");
    [again updateRoot:^(NSMutableDictionary *r) { r[@"webdav"] = @{@"url": @"https://dav", @"password": @"pw-123456"}; } error:nil];
    NSData *redacted = Json([again redactedSnapshot]);
    CHECK([[[NSString alloc] initWithData:redacted encoding:NSUTF8StringEncoding] rangeOfString:@"pw-123456"].location == NSNotFound, "导出用配置去掉密钥字段");
    CHECK(![STS2LauncherConfigStore isValidPlayerId:@"0"] && ![STS2LauncherConfigStore isValidPlayerId:@"-5"] && ![STS2LauncherConfigStore isValidPlayerId:@"12a"] && ![STS2LauncherConfigStore isValidPlayerId:@"1"] && [STS2LauncherConfigStore isValidPlayerId:@"2"] && ![STS2LauncherConfigStore isValidPlayerId:@"9223372036854775808"] && [STS2LauncherConfigStore isValidPlayerId:@"9223372036854775807"], "playerId 校验 [2, 2^63-1]");
}

static void TestLegacyHostId(void) {
    NSURL *docs = TempDir(@"legacy-id");
    NSURL *file = [docs URLByAppendingPathComponent:@"Launcher/config.json"];
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [Json(@{@"schemaVersion": @1, @"network": @{@"playerId": @"1"}}) writeToURL:file atomically:YES];
    STS2LauncherConfigStore *store = [[STS2LauncherConfigStore alloc] initWithDocumentsURL:docs];
    CHECK(![store.playerId isEqual:@"1"] && [STS2LauncherConfigStore isValidPlayerId:store.playerId], "旧值 1 重新生成（1 留给房主）");
}

static void TestLogAnalysis(void) {
    STS2LlmConfig *config = [STS2LlmConfig new];
    config.baseURL = @"https://api.example.com"; config.model = @"m";
    CHECK([[config endpoint:nil].absoluteString isEqual:@"https://api.example.com/v1/chat/completions"], "LLM：站点根补 /v1/chat/completions");
    config.baseURL = @"http://127.0.0.1:8080/v1/";
    CHECK([[config endpoint:nil].absoluteString isEqual:@"http://127.0.0.1:8080/v1/chat/completions"], "LLM：/v1 基址");
    config.baseURL = @"https://u:p@x.com/v1";
    CHECK([config validationProblem] != nil, "LLM：拒绝带账号的地址");
    config.baseURL = @"https://x.com/v1/chat/completions?x=1";
    CHECK([config validationProblem] != nil, "LLM：拒绝查询参数");

    NSURL *dir = TempDir(@"llm");
    NSURL *log = [dir URLByAppendingPathComponent:@"godot.log"];
    NSMutableString *body = [NSMutableString string];
    for (int i = 1; i <= 100; i++) [body appendFormat:i == 50 ? @"ERROR: crash here %d\n" : @"line %d\n", i];
    [body writeToURL:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    STS2LogTools *tools = [[STS2LogTools alloc] initWithFiles:@[log] error:&error];
    CHECK(tools && [[tools metadata][0][@"lines"] isEqual:@100], "工具：元数据");
    NSDictionary *read = [tools execute:@"read_lines" arguments:@{@"file_id": @"log_1", @"start_line": @1, @"end_line": @100}];
    CHECK([read[@"lines"] count] == 60 && [read[@"truncated"] boolValue] && [read[@"next_line"] isEqual:@61], "工具：每次最多 60 行并分页");
    NSDictionary *search = [tools execute:@"search_logs" arguments:@{@"file_id": @"log_1", @"keyword": @"crash"}];
    NSArray *lines = search[@"lines"];
    CHECK(lines.count == 3 && [lines[1][@"line"] isEqual:@50] && [lines[1][@"match"] boolValue], "工具：搜索带前后各一行");
    CHECK([tools execute:@"read_lines" arguments:@{@"file_id": @"/etc/passwd", @"start_line": @1, @"end_line": @2}][@"error"] != nil, "工具：拒绝未授权 file_id");
    CHECK([tools execute:@"read_lines" arguments:@{@"file_id": @"log_1", @"start_line": @1, @"end_line": @2, @"path": @"x"}][@"error"] != nil, "工具：拒绝多余参数");
    CHECK([tools execute:@"rm" arguments:@{}][@"error"] != nil, "工具：拒绝未知工具");

    __block int calls = 0;
    STS2ChatTransport fake = ^NSDictionary *(NSArray *messages, NSArray *defs, STS2Cancelled cancelled, NSError **e) {
        calls++;
        if (calls == 1) return @{@"role": @"assistant", @"content": NSNull.null, @"tool_calls": @[@{@"id": @"c1", @"type": @"function", @"function": @{@"name": @"search_logs", @"arguments": @"{\"file_id\":\"log_1\",\"keyword\":\"crash\"}"}}]};
        NSDictionary *toolMessage = messages.lastObject;
        BOOL sawTool = [toolMessage[@"role"] isEqual:@"tool"] && [toolMessage[@"tool_call_id"] isEqual:@"c1"] && [toolMessage[@"content"] rangeOfString:@"crash here"].location != NSNotFound;
        return @{@"role": @"assistant", @"content": sawTool ? @"log_1:50 是崩溃点" : @"没看到工具结果"};
    };
    STS2ChatSession *session = [[STS2ChatSession alloc] initWithTransport:fake tools:tools];
    NSMutableArray *progress = [NSMutableArray array];
    NSString *answer = [session ask:@"为什么崩溃" cancelled:^BOOL { return NO; } progress:^(NSString *s) { [progress addObject:s]; } budgetReached:NULL error:&error];
    CHECK([answer isEqual:@"log_1:50 是崩溃点"] && progress.count == 1, "会话：工具调用往返");
    STS2ChatTransport looping = ^NSDictionary *(NSArray *m, NSArray *d, STS2Cancelled c, NSError **e) {
        return @{@"role": @"assistant", @"tool_calls": @[@{@"id": [NSUUID UUID].UUIDString, @"type": @"function", @"function": @{@"name": @"read_lines", @"arguments": @"{\"file_id\":\"log_1\",\"start_line\":1,\"end_line\":1}"}}]};
    };
    BOOL budget = NO;
    NSString *limited = [[[STS2ChatSession alloc] initWithTransport:looping tools:tools] ask:@"q" cancelled:^BOOL { return NO; } progress:^(NSString *x) {} budgetReached:&budget error:&error];
    CHECK(budget && [limited rangeOfString:@"24 轮"].location != NSNotFound, "会话：24 轮预算");
    STS2ChatTransport failing = ^NSDictionary *(NSArray *m, NSArray *d, STS2Cancelled c, NSError **e) { *e = [NSError errorWithDomain:@"x" code:1 userInfo:@{NSLocalizedDescriptionKey: @"网络请求失败或超时，请检查自定义服务连接"}]; return nil; };
    error = nil;
    CHECK(![[[STS2ChatSession alloc] initWithTransport:failing tools:tools] ask:@"q" cancelled:^BOOL { return NO; } progress:^(NSString *x) {} budgetReached:NULL error:&error] && error, "会话：失败返回错误");
}

static void TestNexusAndUpdate(void) {
    NSDictionary *nxm = [STS2NexusMods parseLink:@"nxm://slaythespire2/mods/12/files/345?key=abc&expires=1762650000&user_id=9"];
    CHECK([nxm[@"modId"] isEqual:@"12"] && [nxm[@"fileId"] isEqual:@"345"] && [nxm[@"key"] isEqual:@"abc"] && [nxm[@"expires"] isEqual:@"1762650000"], "nxm:// 链接解析");
    CHECK([[STS2NexusMods parseLink:@"https://www.nexusmods.com/slaythespire2/mods/77?tab=files"][@"modId"] isEqual:@"77"] && ![STS2NexusMods parseLink:@"nxm://skyrim/mods/1/files/2"] && [[STS2NexusMods parseLink:@"42"][@"modId"] isEqual:@"42"], "Nexus 网页链接 / 编号；拒绝其他游戏");
    NSDictionary *mod = [STS2NexusMods modFromJSON:@{@"mod_id": @5, @"name": @"更好的卡图", @"summary": @"s", @"author": @"a", @"mod_downloads": @123}];
    CHECK([mod[@"id"] isEqual:@"5"] && [mod[@"downloads"] isEqual:@"123"] && [mod[@"page"] hasSuffix:@"/slaythespire2/mods/5"], "Nexus MOD JSON 解析");
    CHECK(![STS2NexusMods modFromJSON:@{@"mod_id": @6, @"available": @NO}] && [[STS2NexusMods modFromJSON:@{@"mod_page_url": @"https://www.nexusmods.com/slaythespire2/mods/9", @"name": @"x"}][@"id"] isEqual:@"9"], "下架条目跳过，v3 从页面链接取编号");
    CHECK([STS2UpdateChecker compareVersion:@"v1.2.10" to:@"1.2.9"] == NSOrderedDescending && [STS2UpdateChecker compareVersion:@"1.0" to:@"v1.0.0"] == NSOrderedSame && [STS2UpdateChecker compareVersion:@"release-0.9-beta" to:@"1.0"] == NSOrderedAscending, "版本号比较");
    NSData *releases = Json(@[@{@"draft": @YES, @"tag_name": @"v9.9"}, @{@"tag_name": @"v1.3.0", @"name": @"小屋 1.3", @"body": @"更新", @"html_url": @"https://github.com/x/y/releases/tag/v1.3.0", @"prerelease": @NO}]);
    NSDictionary *latest = [STS2UpdateChecker latestReleaseFromData:releases];
    CHECK([latest[@"version"] isEqual:@"v1.3.0"] && [latest[@"url"] hasPrefix:@"https://github.com/"], "跳过草稿取最新发布");
}

int main(void) {
    @autoreleasepool {
        TestRoomCards();
        TestPendingAction();
        TestLogging();
        TestLaunchMarker();
        TestLogCenter();
        TestConfig();
        TestLegacyHostId();
        TestLogAnalysis();
        TestNexusAndUpdate();
        printf(failures ? "%d FAILED\n" : "ALL PASSED\n", failures);
        return failures ? 1 : 0;
    }
}

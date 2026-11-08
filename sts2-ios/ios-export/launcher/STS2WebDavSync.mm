#import "STS2WebDavSync.h"
#import "STS2Log.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const STS2WebDavErrorDomain = @"STS2WebDav";
NSString *const STS2WebDavConflictPathsKey = @"conflicts";
static NSString *const kRemoteRoot = @"SlayTheSpire2/saves";
static NSString *const kMetaDir = @".sts2re";
static const NSInteger kMaxDepth = 8;

static NSError *DavError(STS2WebDavError code, NSString *message) {
    return [NSError errorWithDomain:STS2WebDavErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *Sha1(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

@implementation STS2WebDavConfig
- (instancetype)init { if ((self = [super init])) { _baseURL = @""; _username = @""; _password = @""; _remoteSlot = @""; } return self; }
+ (NSString *)sanitizeSlot:(NSString *)slot {
    NSString *lower = [[slot ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSString *clean = [[NSRegularExpression regularExpressionWithPattern:@"[^a-z0-9._-]+" options:0 error:nil] stringByReplacingMatchesInString:lower options:0 range:NSMakeRange(0, lower.length) withTemplate:@"-"];
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"-."];
    clean = [clean stringByTrimmingCharactersInSet:trim];
    return clean.length ? clean : @"global";
}
@end

#pragma mark - PROPFIND parser

@interface STS2MultistatusParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *responses;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic, strong) NSMutableString *text;
@end
@implementation STS2MultistatusParser
- (instancetype)init { if ((self = [super init])) _responses = [NSMutableArray array]; return self; }
static NSString *LocalName(NSString *name) { NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch]; return (colon.location == NSNotFound ? name : [name substringFromIndex:colon.location + 1]).lowercaseString; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)ns qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributes {
    NSString *name = LocalName(element);
    if ([name isEqual:@"response"]) self.current = [NSMutableDictionary dictionary];
    else if ([name isEqual:@"collection"]) self.current[@"dir"] = @YES;
    self.text = [NSMutableString string];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { [self.text appendString:string]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)ns qualifiedName:(NSString *)qName {
    NSString *name = LocalName(element), *value = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!self.current) return;
    if ([name isEqual:@"href"] && !self.current[@"href"]) self.current[@"href"] = value;
    else if ([name isEqual:@"getcontentlength"]) self.current[@"size"] = @(value.longLongValue);
    else if ([name isEqual:@"getetag"]) self.current[@"etag"] = value;
    else if ([name isEqual:@"getlastmodified"]) self.current[@"modifiedText"] = value;
    else if ([name isEqual:@"response"]) { [self.responses addObject:self.current]; self.current = nil; }
}
@end

#pragma mark - Sync

@interface STS2WebDavSync ()
@property(nonatomic, strong) STS2WebDavConfig *config;
@property(nonatomic, strong) NSURL *account;
@property(nonatomic, strong) NSURL *state;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableSet<NSString *> *knownDirectories;
@end

@implementation STS2WebDavSync

+ (BOOL)isSupportedPath:(NSString *)relativePath includeSettings:(BOOL)includeSettings {
    NSString *path = [[relativePath ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    while ([path containsString:@"//"]) path = [path stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    if (!path.length || [path containsString:@":"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    NSString *lower = path.lowercaseString;
    if ([lower isEqual:@"profile.save"] || [lower isEqual:@"modded/profile.save"]) return YES;
    if ([lower isEqual:@"settings.save"]) return includeSettings;
    for (NSString *prefix in @[@"", @"modded/"]) {
        for (int slot = 1; slot <= 3; slot++) {
            NSString *base = [NSString stringWithFormat:@"%@profile%d/saves/", prefix, slot];
            for (NSString *name in @[@"progress.save", @"prefs.save", @"current_run.save", @"current_run.save.backup", @"current_run_mp.save", @"current_run_mp.save.backup"])
                if ([lower isEqual:[base stringByAppendingString:name]]) return YES;
            NSString *history = [base stringByAppendingString:@"history/"];
            if ([lower hasPrefix:history] && [lower hasSuffix:@".run"] && lower.length > history.length + 4 && ![[lower substringFromIndex:history.length] containsString:@"/"]) return YES;
        }
    }
    return NO;
}

+ (NSArray<NSDictionary *> *)resourcesFromMultistatus:(NSData *)xml basePath:(NSString *)basePath {
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xml];
    STS2MultistatusParser *delegate = [STS2MultistatusParser new];
    parser.delegate = delegate; parser.shouldResolveExternalEntities = NO;
    if (![parser parse]) return @[];
    NSDateFormatter *http = [NSDateFormatter new];
    http.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; http.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    http.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSString *base = [basePath.stringByRemovingPercentEncoding ?: basePath stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *response in delegate.responses) {
        NSString *href = response[@"href"];
        if (!href.length) continue;
        NSURL *url = [NSURL URLWithString:href];
        NSString *path = (url.host ? url.path : href).stringByRemovingPercentEncoding ?: href;
        path = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (base.length) {
            if ([path isEqual:base]) path = @"";
            else if ([path hasPrefix:[base stringByAppendingString:@"/"]]) path = [path substringFromIndex:base.length + 1];
            else continue;
        }
        NSDate *modified = response[@"modifiedText"] ? [http dateFromString:response[@"modifiedText"]] : nil;
        [out addObject:@{@"path": path, @"dir": response[@"dir"] ?: @NO, @"size": response[@"size"] ?: @(-1), @"modified": modified ?: NSDate.distantPast, @"etag": response[@"etag"] ?: @""}];
    }
    return out;
}

- (instancetype)initWithConfig:(STS2WebDavConfig *)config accountURL:(NSURL *)accountURL stateURL:(NSURL *)stateURL {
    if ((self = [super init])) {
        _config = config; _account = accountURL;
        _state = [stateURL URLByAppendingPathComponent:[STS2WebDavConfig sanitizeSlot:config.remoteSlot] isDirectory:YES];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 300; c.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:c];
        _knownDirectories = [NSMutableSet set];
        [STS2Log registerSecret:config.password];
    }
    return self;
}

- (NSString *)slot { return [STS2WebDavConfig sanitizeSlot:self.config.remoteSlot]; }
- (NSString *)slotDir { return [NSString stringWithFormat:@"%@/%@/", kRemoteRoot, self.slot]; }
- (NSString *)manifestPath { return [NSString stringWithFormat:@"%@%@/manifest.json", self.slotDir, kMetaDir]; }

- (NSURL *)urlForPath:(NSString *)relative {
    NSString *base = [self.config.baseURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [relative componentsSeparatedByString:@"/"]) if (part.length) [parts addObject:[part stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: part];
    NSString *joined = [parts componentsJoinedByString:@"/"];
    if ([relative hasSuffix:@"/"] && joined.length) joined = [joined stringByAppendingString:@"/"];
    return [NSURL URLWithString:[base stringByAppendingString:joined]];
}

- (NSData *)send:(NSString *)method path:(NSString *)relative body:(NSData *)body headers:(NSDictionary *)headers status:(NSInteger *)status error:(NSError **)error {
    NSURL *url = [self urlForPath:relative];
    if (!url || !([url.scheme.lowercaseString isEqual:@"https"] || [url.scheme.lowercaseString isEqual:@"http"])) { if (error) *error = DavError(STS2WebDavErrorNotConfigured, @"WebDAV 地址无效，应为 http(s):// 开头。"); return nil; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method; request.HTTPBody = body;
    if (self.config.username.length || self.config.password.length) {
        NSString *pair = [NSString stringWithFormat:@"%@:%@", self.config.username, self.config.password];
        [request setValue:[@"Basic " stringByAppendingString:[[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]] forHTTPHeaderField:@"Authorization"];
    }
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) { [request setValue:value forHTTPHeaderField:key]; }];
    __block NSData *data = nil; __block NSInteger code = 0; __block NSError *networkError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; code = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0; networkError = e; dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (status) *status = code;
    if (networkError) {
        if (error) *error = [NSError errorWithDomain:STS2WebDavErrorDomain code:STS2WebDavErrorHTTP userInfo:@{NSLocalizedDescriptionKey: [@"连接 WebDAV 失败：" stringByAppendingString:networkError.localizedDescription], NSUnderlyingErrorKey: networkError}];
        return nil;
    }
    return data ?: [NSData data];
}

static NSError *StatusError(NSString *method, NSString *path, NSInteger status) {
    NSString *hint = status == 401 ? @"（用户名或密码错误；坚果云等需要使用「应用密码」）" : status == 403 ? @"（没有权限）" : status == 404 ? @"（路径不存在）" : status == 507 ? @"（空间不足）" : @"";
    return DavError(STS2WebDavErrorHTTP, [NSString stringWithFormat:@"WebDAV %@ %@ 返回 HTTP %ld%@", method, path.lastPathComponent.length ? path.lastPathComponent : path, (long)status, hint]);
}

- (BOOL)ensureDirectory:(NSString *)relative error:(NSError **)error {
    NSString *accumulated = @"";
    for (NSString *part in [relative componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        accumulated = [accumulated stringByAppendingFormat:@"%@/", part];
        if ([self.knownDirectories containsObject:accumulated]) continue;
        NSInteger status = 0;
        if (![self send:@"MKCOL" path:accumulated body:nil headers:@{} status:&status error:error]) return NO;
        // 201 新建；405/301 已存在。
        if (status != 201 && status != 405 && status != 301 && status != 200 && status != 204) {
            if (error) *error = StatusError(@"MKCOL", accumulated, status);
            return NO;
        }
        [self.knownDirectories addObject:accumulated];
    }
    return YES;
}

- (NSArray<NSDictionary *> *)listDirectory:(NSString *)relative depth:(NSInteger)depth error:(NSError **)error {
    NSData *body = [@"<?xml version=\"1.0\" encoding=\"utf-8\" ?><propfind xmlns=\"DAV:\"><prop><resourcetype/><getcontentlength/><getlastmodified/><getetag/></prop></propfind>" dataUsingEncoding:NSUTF8StringEncoding];
    NSInteger status = 0;
    NSData *xml = [self send:@"PROPFIND" path:relative body:body headers:@{@"Depth": @"1", @"Content-Type": @"application/xml; charset=utf-8"} status:&status error:error];
    if (!xml) return nil;
    if (status == 404) return @[];
    if (status != 207) { if (error) *error = StatusError(@"PROPFIND", relative, status); return nil; }
    NSString *basePath = [self urlForPath:relative].path;
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *resource in [STS2WebDavSync resourcesFromMultistatus:xml basePath:basePath]) {
        NSString *path = resource[@"path"];
        if (!path.length) continue;
        NSString *child = [relative stringByAppendingString:path];
        if ([resource[@"dir"] boolValue]) {
            if ([path isEqual:kMetaDir] || depth >= kMaxDepth) continue;
            NSArray *nested = [self listDirectory:[child stringByAppendingString:@"/"] depth:depth + 1 error:error];
            if (!nested) return nil;
            [files addObjectsFromArray:nested];
        } else {
            NSMutableDictionary *file = [resource mutableCopy];
            file[@"remotePath"] = child;
            [files addObject:file];
        }
    }
    return files;
}

- (NSString *)testConnection:(NSError **)error {
    if (!self.config.baseURL.length) { if (error) *error = DavError(STS2WebDavErrorNotConfigured, @"请先填写 WebDAV 地址。"); return nil; }
    if (![self ensureDirectory:self.slotDir error:error]) return nil;
    NSArray *files = [self listDirectory:self.slotDir depth:0 error:error];
    if (!files) return nil;
    STS2LogI(STS2LogTagCloud, @"WebDAV 连接成功：槽位 %@，远端 %lu 个文件", self.slot, (unsigned long)files.count);
    return [NSString stringWithFormat:@"连接成功。远端槽位「%@」现有 %lu 个文件。", self.slot, (unsigned long)files.count];
}

#pragma mark Entries

- (NSDictionary<NSString *, NSDictionary *> *)remoteManifest {
    NSInteger status = 0;
    NSData *data = [self send:@"GET" path:self.manifestPath body:nil headers:@{} status:&status error:nil];
    NSDictionary *root = data && status == 200 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in [root isKindOfClass:NSDictionary.class] && [root[@"entries"] isKindOfClass:NSArray.class] ? root[@"entries"] : @[]) {
        NSString *local = [entry isKindOfClass:NSDictionary.class] ? entry[@"local_relative_path"] : nil;
        if ([local isKindOfClass:NSString.class] && [STS2WebDavSync isSupportedPath:local includeSettings:self.config.syncSettingsSave]) map[local.lowercaseString] = entry;
    }
    return map;
}

- (NSArray<NSMutableDictionary *> *)remoteEntries:(void (^)(NSString *))progress error:(NSError **)error {
    NSDictionary *manifest = [self remoteManifest];
    NSArray *files = [self listDirectory:self.slotDir depth:0 error:error];
    if (!files) return nil;
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *file in files) {
        NSString *local = [file[@"remotePath"] substringFromIndex:self.slotDir.length];
        if (![STS2WebDavSync isSupportedPath:local includeSettings:self.config.syncSettingsSave] || [seen containsObject:local.lowercaseString]) continue;
        [seen addObject:local.lowercaseString];
        NSDictionary *known = manifest[local.lowercaseString];
        long long knownSize = [known[@"size"] longLongValue];
        BOOL matches = [known[@"sha1"] length] && (knownSize < 0 || [file[@"size"] longLongValue] < 0 || knownSize == [file[@"size"] longLongValue]) &&
                       (![known[@"etag"] length] || ![file[@"etag"] length] || [known[@"etag"] isEqual:file[@"etag"]]);
        [entries addObject:[@{@"local": local, @"remotePath": file[@"remotePath"], @"size": file[@"size"], @"etag": file[@"etag"],
                              @"timestamp": @((long long)([file[@"modified"] timeIntervalSince1970] * 1000)), @"sha1": matches ? known[@"sha1"] : @""} mutableCopy]];
    }
    // 远端清单里没有可信 sha1 的文件下载一次算哈希（与 Android ensureRemoteHashes 相同）。
    NSUInteger index = 0;
    for (NSMutableDictionary *entry in entries) {
        index++;
        if ([entry[@"sha1"] length]) continue;
        if (progress) progress([NSString stringWithFormat:@"计算远端哈希 %lu/%lu：%@", (unsigned long)index, (unsigned long)entries.count, entry[@"local"]]);
        NSInteger status = 0;
        NSData *data = [self send:@"GET" path:entry[@"remotePath"] body:nil headers:@{} status:&status error:error];
        if (!data) return nil;
        if (status != 200) { if (error) *error = StatusError(@"GET", entry[@"remotePath"], status); return nil; }
        entry[@"sha1"] = Sha1(data); entry[@"size"] = @(data.length);
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"local"] caseInsensitiveCompare:b[@"local"]]; }];
    return entries;
}

- (NSArray<NSDictionary *> *)localEntries {
    NSMutableArray *entries = [NSMutableArray array];
    NSDirectoryEnumerator *walker = [NSFileManager.defaultManager enumeratorAtURL:self.account includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey] options:0 errorHandler:nil];
    NSString *root = self.account.URLByResolvingSymlinksInPath.path;
    for (NSURL *url in walker) {
        NSDictionary *v = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey] error:nil];
        if (![v[NSURLIsRegularFileKey] boolValue]) continue;
        NSString *path = url.URLByResolvingSymlinksInPath.path;
        if (![path hasPrefix:[root stringByAppendingString:@"/"]]) continue;
        NSString *relative = [path substringFromIndex:root.length + 1];
        if (![STS2WebDavSync isSupportedPath:relative includeSettings:self.config.syncSettingsSave]) continue;
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) continue;
        [entries addObject:@{@"local": relative, @"url": url, @"size": @(data.length), @"sha1": Sha1(data)}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"local"] caseInsensitiveCompare:b[@"local"]]; }];
    return entries;
}

- (NSURL *)baselineURL { return [self.state URLByAppendingPathComponent:@"baseline.json"]; }
- (NSDictionary<NSString *, NSDictionary *> *)baseline {
    NSData *data = [NSData dataWithContentsOfURL:self.baselineURL];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in [root isKindOfClass:NSDictionary.class] && [root[@"entries"] isKindOfClass:NSArray.class] ? root[@"entries"] : @[])
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"local_relative_path"] isKindOfClass:NSString.class]) map[[entry[@"local_relative_path"] lowercaseString]] = entry;
    return map;
}
static BOOL SameContent(NSDictionary *local, NSDictionary *remote) {
    if (!local || !remote || ![local[@"sha1"] length] || ![remote[@"sha1"] length]) return NO;
    if ([local[@"sha1"] caseInsensitiveCompare:remote[@"sha1"]] != NSOrderedSame) return NO;
    return [remote[@"size"] longLongValue] < 0 || [local[@"size"] longLongValue] == [remote[@"size"] longLongValue];
}
- (BOOL)writeBaselineLocal:(NSArray *)locals remote:(NSArray *)remotes error:(NSError **)error {
    NSMutableDictionary *remoteBy = [NSMutableDictionary dictionary];
    for (NSDictionary *r in remotes) remoteBy[[r[@"local"] lowercaseString]] = r;
    NSMutableArray *agreed = [NSMutableArray array];
    for (NSDictionary *l in locals) {
        NSDictionary *r = remoteBy[[l[@"local"] lowercaseString]];
        if (!SameContent(l, r)) continue;
        [agreed addObject:@{@"local_relative_path": l[@"local"], @"local_sha1": l[@"sha1"], @"size": l[@"size"], @"remote_path": r[@"remotePath"], @"remote_sha1": r[@"sha1"], @"remote_timestamp_ms": r[@"timestamp"] ?: @0}];
    }
    NSDictionary *root = @{@"schema": @1, @"remote_slot": self.slot, @"written_at_ms": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)), @"entries": agreed};
    [NSFileManager.defaultManager createDirectoryAtURL:self.state withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:self.baselineURL options:NSDataWritingAtomic error:error];
}
- (BOOL)writeRemoteManifest:(NSArray *)remotes error:(NSError **)error {
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *r in remotes)
        [entries addObject:@{@"local_relative_path": r[@"local"], @"remote_path": r[@"remotePath"], @"size": r[@"size"], @"updated_at_ms": r[@"timestamp"] ?: @0, @"etag": r[@"etag"] ?: @"", @"sha1": r[@"sha1"]}];
    NSDictionary *root = @{@"schema": @1, @"provider": @"webdav", @"profile_id": @"ios", @"remote_slot": self.slot, @"written_at_ms": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)), @"entries": entries};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
    if (!data || ![self ensureDirectory:[self.slotDir stringByAppendingString:kMetaDir] error:error]) return NO;
    NSInteger status = 0;
    if (![self send:@"PUT" path:self.manifestPath body:data headers:@{@"Content-Type": @"application/json"} status:&status error:error]) return NO;
    if (status < 200 || status >= 300) { if (error) *error = StatusError(@"PUT", self.manifestPath, status); return NO; }
    return YES;
}

static NSError *ConflictError(NSArray<NSString *> *paths) {
    NSString *list = [[paths subarrayWithRange:NSMakeRange(0, MIN(paths.count, (NSUInteger)6))] componentsJoinedByString:@"\n"];
    return [NSError errorWithDomain:STS2WebDavErrorDomain code:STS2WebDavErrorConflict userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"本地和云端都改过以下 %lu 个文件，需要你决定保留哪一边：\n%@%@", (unsigned long)paths.count, list, paths.count > 6 ? @"\n…" : @""],
        STS2WebDavConflictPathsKey: paths}];
}

- (NSString *)pull:(BOOL)force progress:(void (^)(NSString *))progress error:(NSError **)error {
    if (!self.config.baseURL.length) { if (error) *error = DavError(STS2WebDavErrorNotConfigured, @"请先填写 WebDAV 地址。"); return nil; }
    if (progress) progress(@"列出云端存档…");
    NSArray *remotes = [self remoteEntries:progress error:error];
    if (!remotes) return nil;
    NSArray *locals = [self localEntries];
    NSDictionary *base = [self baseline];
    NSMutableDictionary *localBy = [NSMutableDictionary dictionary];
    for (NSDictionary *l in locals) localBy[[l[@"local"] lowercaseString]] = l;
    NSMutableArray *downloads = [NSMutableArray array], *conflicts = [NSMutableArray array];
    for (NSDictionary *r in remotes) {
        NSString *key = [r[@"local"] lowercaseString];
        NSDictionary *l = localBy[key], *b = base[key];
        if (SameContent(l, r)) continue;
        BOOL localChanged = l && (!b || [l[@"sha1"] caseInsensitiveCompare:b[@"local_sha1"] ?: @""] != NSOrderedSame);
        BOOL remoteChanged = !b || [r[@"sha1"] caseInsensitiveCompare:b[@"remote_sha1"] ?: @""] != NSOrderedSame;
        if (!force && localChanged) { if (remoteChanged) [conflicts addObject:r[@"local"]]; continue; }
        [downloads addObject:r];
    }
    if (conflicts.count) { if (error) *error = ConflictError(conflicts); STS2LogW(STS2LogTagCloud, @"拉取冲突 %lu 个文件", (unsigned long)conflicts.count); return nil; }
    NSUInteger index = 0;
    for (NSDictionary *r in downloads) {
        if (progress) progress([NSString stringWithFormat:@"下载 %lu/%lu：%@", (unsigned long)++index, (unsigned long)downloads.count, r[@"local"]]);
        NSInteger status = 0;
        NSData *data = [self send:@"GET" path:r[@"remotePath"] body:nil headers:@{} status:&status error:error];
        if (!data) return nil;
        if (status != 200) { if (error) *error = StatusError(@"GET", r[@"remotePath"], status); return nil; }
        // 白名单已拒绝绝对路径、..、反斜杠和冒号；这里再确认拼出来的路径仍在账号目录下。
        NSURL *target = [self.account URLByAppendingPathComponent:r[@"local"]];
        if (![STS2WebDavSync isSupportedPath:r[@"local"] includeSettings:self.config.syncSettingsSave] || ![target.path hasPrefix:[self.account.path stringByAppendingString:@"/"]]) { if (error) *error = DavError(STS2WebDavErrorInvalid, @"云端路径越界，已停止。"); return nil; }
        [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![data writeToURL:target options:NSDataWritingAtomic error:error]) return nil;
    }
    NSArray *after = [self localEntries];
    if (![self writeRemoteManifest:remotes error:error] || ![self writeBaselineLocal:after remote:remotes error:error]) return nil;
    NSString *summary = downloads.count ? [NSString stringWithFormat:@"已从云端拉取 %lu 个文件（共 %lu 个云端文件）。", (unsigned long)downloads.count, (unsigned long)remotes.count] : @"云端没有需要拉取的新变化，本地改动已保留。";
    STS2LogI(STS2LogTagCloud, @"WebDAV 拉取完成：%@", summary);
    return summary;
}

- (NSString *)push:(BOOL)force progress:(void (^)(NSString *))progress error:(NSError **)error {
    if (!self.config.baseURL.length) { if (error) *error = DavError(STS2WebDavErrorNotConfigured, @"请先填写 WebDAV 地址。"); return nil; }
    if (progress) progress(@"列出云端存档…");
    if (![self ensureDirectory:self.slotDir error:error]) return nil;
    NSMutableArray *remotes = [[self remoteEntries:progress error:error] mutableCopy];
    if (!remotes) return nil;
    NSArray *locals = [self localEntries];
    NSDictionary *base = [self baseline];
    NSMutableDictionary *remoteBy = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *r in remotes) remoteBy[[r[@"local"] lowercaseString]] = r;
    NSMutableArray *uploads = [NSMutableArray array], *conflicts = [NSMutableArray array];
    for (NSDictionary *l in locals) {
        NSString *key = [l[@"local"] lowercaseString];
        NSDictionary *r = remoteBy[key], *b = base[key];
        if (SameContent(l, r)) continue;
        BOOL localChanged = !b || [l[@"sha1"] caseInsensitiveCompare:b[@"local_sha1"] ?: @""] != NSOrderedSame;
        BOOL remoteChanged = !b ? (r && [r[@"sha1"] caseInsensitiveCompare:l[@"sha1"]] != NSOrderedSame)
                                : (r ? [r[@"sha1"] caseInsensitiveCompare:b[@"remote_sha1"] ?: @""] != NSOrderedSame : [b[@"remote_sha1"] length] > 0);
        if (!force && localChanged && remoteChanged) { [conflicts addObject:l[@"local"]]; continue; }
        if (force ? (!r || [l[@"sha1"] caseInsensitiveCompare:r[@"sha1"]] != NSOrderedSame) : (localChanged || !r)) [uploads addObject:l];
    }
    if (conflicts.count) { if (error) *error = ConflictError(conflicts); STS2LogW(STS2LogTagCloud, @"推送冲突 %lu 个文件", (unsigned long)conflicts.count); return nil; }
    NSUInteger index = 0;
    for (NSDictionary *l in uploads) {
        if (progress) progress([NSString stringWithFormat:@"上传 %lu/%lu：%@", (unsigned long)++index, (unsigned long)uploads.count, l[@"local"]]);
        NSString *remotePath = [self.slotDir stringByAppendingString:l[@"local"]];
        if (![self ensureDirectory:[remotePath stringByDeletingLastPathComponent] error:error]) return nil;
        NSData *data = [NSData dataWithContentsOfURL:l[@"url"] options:0 error:error];
        if (!data) return nil;
        NSInteger status = 0;
        if (![self send:@"PUT" path:remotePath body:data headers:@{@"Content-Type": @"application/octet-stream"} status:&status error:error]) return nil;
        if (status < 200 || status >= 300) { if (error) *error = StatusError(@"PUT", remotePath, status); return nil; }
        NSMutableDictionary *r = remoteBy[[l[@"local"] lowercaseString]];
        if (!r) { r = [@{@"local": l[@"local"], @"remotePath": remotePath, @"etag": @""} mutableCopy]; [remotes addObject:r]; remoteBy[[l[@"local"] lowercaseString]] = r; }
        r[@"sha1"] = l[@"sha1"]; r[@"size"] = l[@"size"]; r[@"etag"] = @""; r[@"timestamp"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
    }
    if (![self writeRemoteManifest:remotes error:error] || ![self writeBaselineLocal:locals remote:remotes error:error]) return nil;
    NSString *summary = uploads.count ? [NSString stringWithFormat:@"已上传 %lu 个文件到云端槽位「%@」。", (unsigned long)uploads.count, self.slot] : @"本地没有需要上传的新变化。";
    STS2LogI(STS2LogTagCloud, @"WebDAV 推送完成：%@", summary);
    return summary;
}

- (NSDictionary *)status {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.baselineURL.path error:nil];
    return @{@"slot": self.slot, @"localFiles": @([self localEntries].count), @"lastSync": attributes[NSFileModificationDate] ?: NSNull.null};
}
@end

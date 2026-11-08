#import "STS2NexusMods.h"
#import "STS2Log.h"

NSString *const STS2NexusGameDomain = @"slaythespire2";
static NSString *const kV1 = @"https://api.nexusmods.com/v1/games/slaythespire2";

static NSError *NexusError(NSString *message) { return [NSError errorWithDomain:@"STS2Nexus" code:1 userInfo:@{NSLocalizedDescriptionKey: message}]; }
static NSString *First(NSDictionary *o, NSArray<NSString *> *keys) {
    for (NSString *k in keys) { id v = o[k]; if ([v isKindOfClass:NSString.class] && [v length]) return v; if ([v isKindOfClass:NSNumber.class]) return [v stringValue]; }
    return @"";
}

@interface STS2NexusDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) void (^progress)(double);
@property(nonatomic, copy) void (^finished)(NSURL *, NSError *);
@end
@implementation STS2NexusDelegate
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (expected > 0 && self.progress) { double f = (double)written / expected; dispatch_async(dispatch_get_main_queue(), ^{ self.progress(f); }); }
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
    if (status != 200) { self.finished(nil, NexusError([NSString stringWithFormat:@"下载返回 HTTP %ld", (long)status])); self.finished = nil; return; }
    NSURL *keep = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    [NSFileManager.defaultManager moveItemAtURL:location toURL:keep error:&error];
    self.finished(error ? nil : keep, error); self.finished = nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.finished) self.finished(nil, error ?: NexusError(@"下载未完成"));
    self.finished = nil;
    [session finishTasksAndInvalidate];
}
@end

@interface STS2NexusMods ()
@property(nonatomic, copy) NSString *apiKey;
@end

@implementation STS2NexusMods
- (instancetype)initWithApiKey:(NSString *)apiKey {
    if ((self = [super init])) { _apiKey = [apiKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""; [STS2Log registerSecret:_apiKey]; }
    return self;
}

+ (NSDictionary *)modFromJSON:(NSDictionary *)o {
    if (![o isKindOfClass:NSDictionary.class]) return nil;
    NSString *modId = First(o, @[@"mod_id", @"game_scoped_id", @"id", @"uid"]);
    NSString *page = First(o, @[@"mod_page_uri", @"mod_page_url"]);
    if (!modId.length && page.length) {
        NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:@"/mods/(\\d+)" options:0 error:nil];
        NSTextCheckingResult *m = [r firstMatchInString:page options:0 range:NSMakeRange(0, page.length)];
        if (m) modId = [page substringWithRange:[m rangeAtIndex:1]];
    }
    if (!modId.length) return nil;
    if ([o[@"available"] isKindOfClass:NSNumber.class] && ![o[@"available"] boolValue]) return nil;
    return @{@"id": modId, @"name": First(o, @[@"name", @"title"]).length ? First(o, @[@"name", @"title"]) : @"未命名 MOD",
             @"summary": First(o, @[@"summary", @"short_description"]), @"description": First(o, @[@"description", @"desc"]),
             @"author": First(o, @[@"author", @"uploaded_by", @"user"]), @"version": First(o, @[@"version"]),
             @"picture": First(o, @[@"picture_url"]), @"downloads": First(o, @[@"mod_downloads", @"downloads", @"unique_downloads"]),
             @"updated": First(o, @[@"updated_timestamp", @"updated_time"]),
             @"page": page.length ? page : [NSString stringWithFormat:@"https://www.nexusmods.com/%@/mods/%@", STS2NexusGameDomain, modId]};
}

+ (NSDictionary *)parseLink:(NSString *)text {
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *nxm = [NSRegularExpression regularExpressionWithPattern:@"^nxm://([^/]+)/mods/(\\d+)/files/(\\d+)(?:\\?(\\S+))?$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [nxm firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (m) {
        if (![[t substringWithRange:[m rangeAtIndex:1]].lowercaseString isEqual:STS2NexusGameDomain]) return nil;
        NSMutableDictionary *link = [@{@"modId": [t substringWithRange:[m rangeAtIndex:2]], @"fileId": [t substringWithRange:[m rangeAtIndex:3]]} mutableCopy];
        if ([m rangeAtIndex:4].location != NSNotFound) {
            NSURLComponents *c = [NSURLComponents new]; c.percentEncodedQuery = [t substringWithRange:[m rangeAtIndex:4]];
            for (NSURLQueryItem *item in c.queryItems) if (item.value.length && ([item.name isEqual:@"key"] || [item.name isEqual:@"expires"])) link[item.name] = item.value;
        }
        return link;
    }
    NSRegularExpression *web = [NSRegularExpression regularExpressionWithPattern:@"nexusmods\\.com/([^/]+)/mods/(\\d+)" options:NSRegularExpressionCaseInsensitive error:nil];
    m = [web firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (m && [[t substringWithRange:[m rangeAtIndex:1]].lowercaseString isEqual:STS2NexusGameDomain]) return @{@"modId": [t substringWithRange:[m rangeAtIndex:2]]};
    if (t.length && t.length < 12 && [t rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) return @{@"modId": t};
    return nil;
}

- (void)get:(NSString *)url needsKey:(BOOL)needsKey completion:(void (^)(id json, NSError *error))completion {
    if (needsKey && !self.apiKey.length) { completion(nil, NexusError(@"需要先在右上角填写 Nexus Mods API key（网站「设置 → API Keys」页面可以生成）。")); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"STS2iPadLauncher" forHTTPHeaderField:@"Application-Name"];
    if (self.apiKey.length) [request setValue:self.apiKey forHTTPHeaderField:@"apikey"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSError *failure = nil;
        if (error) failure = NexusError(@"连接 Nexus Mods 失败，请检查网络。");
        else if (status == 401) failure = NexusError(@"API key 无效或已失效，请重新填写。");
        else if (status == 403) failure = NexusError([json isKindOfClass:NSDictionary.class] && [json[@"message"] isKindOfClass:NSString.class] ? [@"Nexus 拒绝请求：" stringByAppendingString:json[@"message"]] : @"Nexus 拒绝请求（非 Premium 账号需要用网页的 Mod Manager Download 链接）。");
        else if (status == 429) failure = NexusError(@"请求过于频繁，已达 Nexus 每日/每小时限额，请稍后再试。");
        else if (status < 200 || status >= 300 || !json) failure = NexusError([NSString stringWithFormat:@"Nexus 返回 HTTP %ld", (long)status]);
        if (failure) [STS2Log log:STS2LogLevelWarn tag:STS2LogTagNexus message:[NSString stringWithFormat:@"Nexus 请求失败 %@", [NSURL URLWithString:url].path] detail:error ?: failure];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure ? nil : json, failure); });
    }] resume];
}

- (void)validate:(void (^)(NSDictionary *, NSError *))completion {
    [self get:@"https://api.nexusmods.com/v1/users/validate.json" needsKey:YES completion:^(id json, NSError *error) {
        if (error) { completion(nil, error); return; }
        completion(@{@"name": First(json, @[@"name", @"username"]), @"premium": @([json[@"is_premium"] boolValue])}, nil);
    }];
}

- (void)feed:(STS2NexusFeed)feed completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    if (feed == STS2NexusFeedTrending && !self.apiKey.length) {
        [self get:@"https://api.nexusmods.com/v3/games/slaythespire2/trending-mods" needsKey:NO completion:^(id json, NSError *error) {
            NSArray *raw = [json isKindOfClass:NSDictionary.class] && [json[@"data"] isKindOfClass:NSDictionary.class] ? json[@"data"][@"mods"] : nil;
            NSMutableArray *mods = [NSMutableArray array];
            for (NSDictionary *o in [raw isKindOfClass:NSArray.class] ? raw : @[]) { NSDictionary *mod = [STS2NexusMods modFromJSON:o]; if (mod) [mods addObject:mod]; }
            completion(mods, error);
        }];
        return;
    }
    NSString *name = @[@"trending", @"latest_added", @"latest_updated"][feed];
    [self get:[NSString stringWithFormat:@"%@/mods/%@.json", kV1, name] needsKey:YES completion:^(id json, NSError *error) {
        NSMutableArray *mods = [NSMutableArray array];
        for (NSDictionary *o in [json isKindOfClass:NSArray.class] ? json : @[]) { NSDictionary *mod = [STS2NexusMods modFromJSON:o]; if (mod) [mods addObject:mod]; }
        completion(mods, error);
    }];
}

- (void)mod:(NSString *)modId completion:(void (^)(NSDictionary *, NSError *))completion {
    [self get:[NSString stringWithFormat:@"%@/mods/%@.json", kV1, modId] needsKey:YES completion:^(id json, NSError *error) { completion(error ? nil : [STS2NexusMods modFromJSON:json], error); }];
}

- (void)filesForMod:(NSString *)modId completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    [self get:[NSString stringWithFormat:@"%@/mods/%@/files.json", kV1, modId] needsKey:YES completion:^(id json, NSError *error) {
        NSMutableArray *files = [NSMutableArray array];
        for (NSDictionary *f in [json isKindOfClass:NSDictionary.class] && [json[@"files"] isKindOfClass:NSArray.class] ? json[@"files"] : @[]) {
            NSString *fileId = First(f, @[@"file_id", @"id"]);
            if (!fileId.length || [f[@"category_name"] isEqual:@"ARCHIVED"] || [f[@"category_name"] isEqual:@"DELETED"]) continue;
            [files addObject:@{@"id": fileId, @"name": First(f, @[@"name"]), @"fileName": First(f, @[@"file_name"]), @"version": First(f, @[@"version", @"mod_version"]),
                               @"category": First(f, @[@"category_name"]), @"sizeKB": @([f[@"size_kb"] longLongValue]), @"uploaded": @([f[@"uploaded_timestamp"] longLongValue]),
                               @"primary": @([f[@"is_primary"] boolValue])}];
        }
        [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            if ([a[@"primary"] boolValue] != [b[@"primary"] boolValue]) return [a[@"primary"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
            return [b[@"uploaded"] compare:a[@"uploaded"]];
        }];
        completion(files, error);
    }];
}

- (void)downloadLinksForMod:(NSString *)modId file:(NSString *)fileId key:(NSString *)key expires:(NSString *)expires completion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    NSURLComponents *c = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"%@/mods/%@/files/%@/download_link.json", kV1, modId, fileId]];
    if (key.length && expires.length) c.queryItems = @[[NSURLQueryItem queryItemWithName:@"key" value:key], [NSURLQueryItem queryItemWithName:@"expires" value:expires]];
    [self get:c.URL.absoluteString needsKey:YES completion:^(id json, NSError *error) {
        NSMutableArray *urls = [NSMutableArray array];
        NSArray *array = [json isKindOfClass:NSArray.class] ? json : [json isKindOfClass:NSDictionary.class] && [json[@"URI"] isKindOfClass:NSString.class] ? @[json] : @[];
        for (NSDictionary *link in array) {
            NSURL *url = [link isKindOfClass:NSDictionary.class] && [link[@"URI"] isKindOfClass:NSString.class] ? [NSURL URLWithString:link[@"URI"]] : nil;
            if ([url.scheme.lowercaseString isEqual:@"https"]) [urls addObject:url];
        }
        completion(urls, error ?: (urls.count ? nil : NexusError(@"没有拿到可用的下载地址。")));
    }];
}

- (void)download:(NSURL *)url fileName:(NSString *)name progress:(void (^)(double))progress completion:(void (^)(NSURL *, NSError *))completion {
    STS2NexusDelegate *delegate = [STS2NexusDelegate new];
    delegate.progress = progress;
    delegate.finished = ^(NSURL *file, NSError *error) {
        NSURL *named = nil;
        if (file) {
            NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"nexus-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *safe = [[name lastPathComponent] stringByReplacingOccurrencesOfString:@":" withString:@"_"];
            named = [dir URLByAppendingPathComponent:safe.length ? safe : @"download.zip"];
            NSError *moveError = nil;
            if (![NSFileManager.defaultManager moveItemAtURL:file toURL:named error:&moveError]) { named = nil; error = moveError; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(named, error); });
    };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:delegate delegateQueue:nil];
    [[session downloadTaskWithURL:url] resume];
}
@end

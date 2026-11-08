#import "STS2UpdateChecker.h"
#import "STS2Log.h"

NSString *const STS2UpdateReleasesURL = @"https://github.com/jhaizhou-ops/sts2-ios/releases";
static NSString *const kReleasesAPI = @"https://api.github.com/repos/jhaizhou-ops/sts2-ios/releases?per_page=20";

static NSArray<NSNumber *> *VersionNumbers(NSString *text) {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+(?:\\.\\d+)*)" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:text ?: @"" options:0 range:NSMakeRange(0, text.length)];
    if (!match) return @[];
    NSMutableArray *numbers = [NSMutableArray array];
    for (NSString *part in [[text substringWithRange:match.range] componentsSeparatedByString:@"."]) [numbers addObject:@(part.longLongValue)];
    return numbers;
}

@implementation STS2UpdateChecker
+ (NSComparisonResult)compareVersion:(NSString *)left to:(NSString *)right {
    NSArray *a = VersionNumbers(left), *b = VersionNumbers(right);
    for (NSUInteger i = 0; i < MAX(a.count, b.count); i++) {
        long long x = i < a.count ? [a[i] longLongValue] : 0, y = i < b.count ? [b[i] longLongValue] : 0;
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

+ (NSDictionary *)latestReleaseFromData:(NSData *)data {
    NSArray *releases = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    for (NSDictionary *release in [releases isKindOfClass:NSArray.class] ? releases : @[]) {
        if (![release isKindOfClass:NSDictionary.class] || [release[@"draft"] boolValue]) continue;
        NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] && [release[@"tag_name"] length] ? release[@"tag_name"] : release[@"name"];
        if (![tag isKindOfClass:NSString.class] || !tag.length) continue;
        return @{@"version": tag, @"title": [release[@"name"] isKindOfClass:NSString.class] ? release[@"name"] : tag,
                 @"body": [release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @"",
                 @"url": [release[@"html_url"] isKindOfClass:NSString.class] ? release[@"html_url"] : STS2UpdateReleasesURL,
                 @"prerelease": @([release[@"prerelease"] boolValue])};
    }
    return nil;
}

+ (void)checkCurrentVersion:(NSString *)current completion:(void (^)(NSDictionary *, NSError *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kReleasesAPI] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:[@"STS2iPadLauncher/" stringByAppendingString:current] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    STS2LogI(STS2LogTagUpdate, @"检查启动器更新（当前 %@）", current);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *latest = !error && status == 200 ? [self latestReleaseFromData:data] : nil;
        NSError *failure = nil;
        NSMutableDictionary *info = nil;
        if (!latest) {
            NSString *message = error ? @"网络请求失败，请检查网络后重试。" : status == 403 ? @"GitHub 请求过于频繁，请稍后再试。" : status && status != 200 ? [NSString stringWithFormat:@"GitHub 返回 HTTP %ld。", (long)status] : @"还没有发布任何版本。";
            failure = [NSError errorWithDomain:@"STS2Update" code:status userInfo:@{NSLocalizedDescriptionKey: message}];
            [STS2Log log:STS2LogLevelWarn tag:STS2LogTagUpdate message:[@"检查更新失败：" stringByAppendingString:message] detail:error];
        } else {
            info = [latest mutableCopy];
            info[@"newer"] = @([self compareVersion:latest[@"version"] to:current] == NSOrderedDescending);
            STS2LogI(STS2LogTagUpdate, @"最新发布 %@，%@", latest[@"version"], [info[@"newer"] boolValue] ? @"有新版本" : @"已是最新");
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(info, failure); });
    }] resume];
}
@end

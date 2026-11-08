#import "STS2LogCenter.h"
#import "STS2ZipArchive.h"

static const NSUInteger kExportTailBytes = 8 * 1024 * 1024;

@interface STS2LogCenter ()
@property(nonatomic, strong) NSURL *documents;
@property(nonatomic, strong) NSURL *caches;
@end

@implementation STS2LogCenter
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL cachesURL:(NSURL *)cachesURL {
    if ((self = [super init])) { _documents = documentsURL; _caches = cachesURL; }
    return self;
}

+ (NSString *)titleForCategory:(NSString *)category {
    return @{@"launcher": @"启动器日志", @"online": @"联机日志", @"game": @"游戏日志", @"frp": @"frp 日志", @"other": @"其他"}[category] ?: category;
}

- (void)addFilesIn:(NSURL *)directory category:(NSString *)category limit:(NSUInteger)limit
           matching:(BOOL (^)(NSString *name))match into:(NSMutableArray *)out {
    NSArray *keys = @[NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsRegularFileKey];
    NSMutableArray *found = [NSMutableArray array];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        if (![values[NSURLIsRegularFileKey] boolValue] || !match(url.lastPathComponent)) continue;
        [found addObject:@{@"category": category, @"categoryTitle": [STS2LogCenter titleForCategory:category], @"title": url.lastPathComponent, @"url": url,
                           @"size": values[NSURLFileSizeKey] ?: @0, @"date": values[NSURLContentModificationDateKey] ?: NSDate.distantPast}];
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
    [out addObjectsFromArray:[found subarrayWithRange:NSMakeRange(0, MIN(limit, found.count))]];
}

- (NSArray<NSDictionary *> *)logFiles {
    NSMutableArray *out = [NSMutableArray array];
    NSURL *launcher = [self.documents URLByAppendingPathComponent:@"Launcher" isDirectory:YES];
    [self addFilesIn:[launcher URLByAppendingPathComponent:@"logs" isDirectory:YES] category:@"launcher" limit:5 matching:^BOOL(NSString *name) {
        return [name hasPrefix:@"launcher"] && [name hasSuffix:@".log"];
    } into:out];
    [self addFilesIn:launcher category:@"online" limit:2 matching:^BOOL(NSString *name) { return [name hasPrefix:@"online-game"] && [name hasSuffix:@".log"]; } into:out];
    [self addFilesIn:[self.documents URLByAppendingPathComponent:@"logs" isDirectory:YES] category:@"game" limit:5 matching:^BOOL(NSString *name) {
        return [name hasSuffix:@".log"] || [name hasSuffix:@".txt"];
    } into:out];
    [self addFilesIn:self.caches category:@"frp" limit:3 matching:^BOOL(NSString *name) { return [name hasPrefix:@"frpc"] && [name rangeOfString:@".log"].location != NSNotFound; } into:out];
    return out;
}

+ (NSString *)tailOfFileAtURL:(NSURL *)url maxBytes:(NSUInteger)maxBytes {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return @"";
    unsigned long long size = [handle seekToEndOfFile];
    unsigned long long start = size > maxBytes ? size - maxBytes : 0;
    [handle seekToFileOffset:start];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    if (start > 0) {
        NSRange newline = [data rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, data.length)];
        if (newline.location != NSNotFound) data = [data subdataWithRange:NSMakeRange(newline.location + 1, data.length - newline.location - 1)];
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    return text;
}

static NSInteger LevelOfHeadLine(NSString *line) {
    // 统一格式：2026-11-09T12:34:56.789+08:00 E [tag] ...
    NSRange space = [line rangeOfString:@" "];
    if (space.location != NSNotFound && space.location >= 19 && line.length > space.location + 3 &&
        [line characterAtIndex:4] == '-' && [line characterAtIndex:space.location + 2] == ' ') {
        switch ([line characterAtIndex:space.location + 1]) {
            case 'D': return STS2LogLevelDebug; case 'I': return STS2LogLevelInfo;
            case 'W': return STS2LogLevelWarn; case 'E': return STS2LogLevelError;
        }
    }
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([trimmed hasPrefix:@"ERROR"] || [trimmed hasPrefix:@"SCRIPT ERROR"] || [trimmed hasPrefix:@"USER ERROR"] || [trimmed rangeOfString:@"[ERROR]"].location != NSNotFound || [trimmed hasPrefix:@"Unhandled exception"] || [trimmed hasPrefix:@"致命信号"])
        return STS2LogLevelError;
    if ([trimmed hasPrefix:@"WARNING"] || [trimmed hasPrefix:@"USER WARNING"] || [trimmed rangeOfString:@"[WARN"].location != NSNotFound) return STS2LogLevelWarn;
    if ([trimmed rangeOfString:@"[DEBUG]"].location != NSNotFound) return STS2LogLevelDebug;
    return STS2LogLevelInfo;
}

+ (NSArray<NSDictionary *> *)entriesFromText:(NSString *)text {
    NSMutableArray *entries = [NSMutableArray array];
    __block NSMutableString *current = nil;
    __block NSInteger level = STS2LogLevelInfo;
    void (^flush)(void) = ^{ if (current) [entries addObject:@{@"level": @(level), @"text": [current copy]}]; current = nil; };
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        BOOL continuation = current && line.length && ([line hasPrefix:@"    "] || [line hasPrefix:@"\t"] || [line hasPrefix:@"   at "] || [line hasPrefix:@"   "]);
        if (continuation) { [current appendFormat:@"\n%@", line]; return; }
        flush();
        current = [line mutableCopy];
        level = LevelOfHeadLine(line);
    }];
    flush();
    return entries;
}

- (NSURL *)exportArchiveWithDiagnostics:(NSDictionary *)diagnostics redactedConfig:(NSDictionary *)config
                            destination:(NSURL *)directory date:(NSDate *)date error:(NSError **)error {
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    NSMutableArray *manifest = [NSMutableArray array];
    for (NSDictionary *file in [self logFiles]) {
        NSString *text = [STS2LogCenter tailOfFileAtURL:file[@"url"] maxBytes:kExportTailBytes];
        NSString *path = [NSString stringWithFormat:@"%@/%@", file[@"category"], [file[@"title"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
        files[path] = [[STS2Log redact:text] dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        [manifest addObject:@{@"path": path, @"originalSize": file[@"size"], @"truncated": @([file[@"size"] unsignedLongLongValue] > kExportTailBytes)}];
    }
    NSURL *marker = [[self.documents URLByAppendingPathComponent:@"Launcher" isDirectory:YES] URLByAppendingPathComponent:@"launch-marker.json"];
    NSData *markerData = [NSData dataWithContentsOfURL:marker];
    if (markerData) files[@"launcher/launch-marker.json"] = markerData;
    NSMutableDictionary *diag = [diagnostics mutableCopy];
    diag[@"files"] = manifest;
    NSData *diagData = [NSJSONSerialization dataWithJSONObject:diag options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    NSData *configData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!diagData || !configData) return nil;
    files[@"diagnostics.json"] = [[STS2Log redact:[[NSString alloc] initWithData:diagData encoding:NSUTF8StringEncoding]] dataUsingEncoding:NSUTF8StringEncoding];
    files[@"config.redacted.json"] = [[STS2Log redact:[[NSString alloc] initWithData:configData encoding:NSUTF8StringEncoding]] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *zip = STS2ZipCreateData(files, error);
    if (!zip) return nil;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"sts2-logs-ios-%@.zip", [formatter stringFromDate:date]]];
    if (![zip writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
    return url;
}
@end

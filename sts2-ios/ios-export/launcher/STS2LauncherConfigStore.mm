#import "STS2LauncherConfigStore.h"

static NSInteger ValidPort(id value, NSInteger fallback) {
    NSInteger port = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
    return port >= 1 && port <= 65535 ? port : fallback;
}

@interface STS2LauncherConfigStore ()
@property(nonatomic, strong) NSURL *fileURL;
@end

@implementation STS2LauncherConfigStore
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if ((self = [super init])) {
        NSURL *directory = [documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        _fileURL = [directory URLByAppendingPathComponent:@"config.json"];
        NSData *data = [NSData dataWithContentsOfURL:_fileURL];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
        NSDictionary *root = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
        NSDictionary *network = [root[@"network"] isKindOfClass:NSDictionary.class] ? root[@"network"] : @{};
        _nickname = [network[@"nickname"] isKindOfClass:NSString.class] ? network[@"nickname"] : @"玩家";
        _host = [network[@"host"] isKindOfClass:NSString.class] ? network[@"host"] : @"";
        _port = ValidPort(network[@"port"], 33771);
    }
    return self;
}
- (BOOL)save:(NSError **)error {
    @synchronized (NSFileManager.defaultManager) {
        // MOD operations also update this file after the launcher has been created.
        // Merge into the latest disk version instead of the initial in-memory snapshot.
        NSError *readError = nil;
        NSData *existing = [NSData dataWithContentsOfURL:self.fileURL options:0 error:&readError];
        NSMutableDictionary *root = [NSMutableDictionary dictionary];
        if (existing) {
            id parsed = [NSJSONSerialization JSONObjectWithData:existing options:NSJSONReadingMutableContainers error:error];
            if (!parsed) return NO;
            if (![parsed isKindOfClass:NSDictionary.class]) {
                if (error) *error = [NSError errorWithDomain:@"STS2LauncherConfig" code:1 userInfo:@{NSLocalizedDescriptionKey: @"启动器配置不是 JSON 对象，未覆盖原文件。"}];
                return NO;
            }
            root = [parsed mutableCopy];
        } else if (readError && !([readError.domain isEqualToString:NSCocoaErrorDomain] && readError.code == NSFileReadNoSuchFileError)) {
            if (error) *error = readError;
            return NO;
        }
        NSMutableDictionary *network = [root[@"network"] isKindOfClass:NSDictionary.class] ? [root[@"network"] mutableCopy] : [NSMutableDictionary dictionary];
        network[@"nickname"] = self.nickname ?: @"玩家"; network[@"host"] = self.host ?: @""; network[@"port"] = @(self.port);
        root[@"schemaVersion"] = @1; root[@"network"] = network;
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
        return data && [data writeToURL:self.fileURL options:NSDataWritingAtomic error:error];
    }
}
@end

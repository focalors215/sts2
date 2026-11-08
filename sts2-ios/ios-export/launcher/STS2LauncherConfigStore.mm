#import "STS2LauncherConfigStore.h"
#import "STS2Log.h"
#import "STS2SecretStore.h"
#import <Security/Security.h>
#include <errno.h>

static NSInteger ValidPort(id value, NSInteger fallback) {
    NSInteger port = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
    return port >= 1 && port <= 65535 ? port : fallback;
}

static BOOL LooksSecret(NSString *key) {
    NSString *lower = key.lowercaseString;
    for (NSString *word in @[@"token", @"password", @"passwd", @"secret", @"apikey", @"api_key", @"cookie", @"refresh"])
        if ([lower rangeOfString:word].location != NSNotFound) return YES;
    return NO;
}

static id StripSecrets(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *copy = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            copy[key] = [key isKindOfClass:NSString.class] && LooksSecret(key) ? @"***" : StripSecrets(object);
        }];
        return copy;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *copy = [NSMutableArray array];
        for (id object in value) [copy addObject:StripSecrets(object)];
        return copy;
    }
    return value;
}

@interface STS2LauncherConfigStore ()
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic, copy) NSString *playerId;
@property(nonatomic, strong) NSDictionary *launcherSettings;
@end

@implementation STS2LauncherConfigStore
+ (NSString *)generatePlayerId {
    uint64_t value = 0;
    do {
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(value), &value) != errSecSuccess) value = arc4random() | ((uint64_t)arc4random() << 32);
        value &= 0x7FFFFFFFFFFFFFFFULL;
    } while (value <= 1);
    return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

+ (BOOL)isValidPlayerId:(id)value {
    NSString *text = [value isKindOfClass:NSString.class] ? value : [value isKindOfClass:NSNumber.class] ? [value stringValue] : nil;
    if (!text.length || text.length > 20) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if ([text rangeOfCharacterFromSet:digits].location != NSNotFound) return NO;
    errno = 0;
    unsigned long long parsed = strtoull(text.UTF8String, NULL, 10);
    // 规范 §3.4：[2, 2^63-1]；1 永远是 ENet 房主的 NetId，0/1/越界都要重新生成。
    return errno == 0 && parsed > 1 && parsed <= 0x7FFFFFFFFFFFFFFFULL;
}

- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if ((self = [super init])) {
        NSURL *directory = [documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        _fileURL = [directory URLByAppendingPathComponent:@"config.json"];
        NSDictionary *root = [self readRoot:nil] ?: @{};
        NSDictionary *network = [root[@"network"] isKindOfClass:NSDictionary.class] ? root[@"network"] : @{};
        _nickname = [network[@"nickname"] isKindOfClass:NSString.class] ? network[@"nickname"] : @"玩家";
        _host = [network[@"host"] isKindOfClass:NSString.class] ? network[@"host"] : @"";
        _port = ValidPort(network[@"port"], 33771);
        _launcherSettings = [root[@"launcher"] isKindOfClass:NSDictionary.class] ? root[@"launcher"] : @{};
        id saved = network[@"playerId"];
        NSDictionary *legacyFrp = [network[@"frp"] isKindOfClass:NSDictionary.class] ? network[@"frp"] : nil;
        if ([STS2LauncherConfigStore isValidPlayerId:saved] && !legacyFrp[@"token"]) {
            _playerId = [saved isKindOfClass:NSString.class] ? saved : [saved stringValue];
        } else {
            NSError *error = nil;
            __block NSString *created = nil;
            BOOL ok = [self updateRoot:^(NSMutableDictionary *latest) {
                NSMutableDictionary *net = [latest[@"network"] isKindOfClass:NSDictionary.class] ? [latest[@"network"] mutableCopy] : [NSMutableDictionary dictionary];
                if ([STS2LauncherConfigStore isValidPlayerId:net[@"playerId"]]) created = [net[@"playerId"] description];
                else { created = [STS2LauncherConfigStore generatePlayerId]; net[@"playerId"] = created; }
                // 旧版「远程联机」把 frp 令牌写在 config.json；迁到钥匙串并从文件删除。
                NSMutableDictionary *frp = [net[@"frp"] isKindOfClass:NSDictionary.class] ? [net[@"frp"] mutableCopy] : nil;
                if ([frp[@"token"] isKindOfClass:NSString.class]) {
                    if (![STS2SecretStore secretForKey:STS2SecretFrpToken].length)
                        [STS2SecretStore setSecret:frp[@"token"] forKey:STS2SecretFrpToken error:nil];
                    [frp removeObjectForKey:@"token"];
                    net[@"frp"] = frp;
                }
                latest[@"network"] = net;
            } error:&error];
            _playerId = created ?: [STS2LauncherConfigStore generatePlayerId];
            if (!ok) STS2LogE(STS2LogTagOnline, error, @"无法保存联机身份 playerId，本次使用临时值");
            else if (![STS2LauncherConfigStore isValidPlayerId:saved]) STS2LogI(STS2LogTagOnline, @"已生成本机联机身份 playerId=%@", _playerId);
        }
    }
    return self;
}

- (NSMutableDictionary *)readRoot:(NSError **)error {
    NSError *readError = nil;
    NSData *existing = [NSData dataWithContentsOfURL:self.fileURL options:0 error:&readError];
    if (!existing) {
        if (readError && !([readError.domain isEqualToString:NSCocoaErrorDomain] && readError.code == NSFileReadNoSuchFileError)) {
            if (error) *error = readError;
            return nil;
        }
        return [NSMutableDictionary dictionary];
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:existing options:NSJSONReadingMutableContainers error:error];
    if (!parsed) return nil;
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"STS2LauncherConfig" code:1 userInfo:@{NSLocalizedDescriptionKey: @"启动器配置不是 JSON 对象，未覆盖原文件。"}];
        return nil;
    }
    return parsed;
}

- (BOOL)updateRoot:(void (^)(NSMutableDictionary *))block error:(NSError **)error {
    @synchronized (NSFileManager.defaultManager) {
        // MOD operations also update this file after the launcher has been created.
        // Merge into the latest disk version instead of the initial in-memory snapshot.
        NSError *localError = nil;
        NSMutableDictionary *root = [self readRoot:&localError];
        if (!root) {
            STS2LogE(STS2LogTagApp, localError, @"读取 config.json 失败，未覆盖原文件");
            if (error) *error = localError;
            return NO;
        }
        block(root);
        root[@"schemaVersion"] = @1;
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:&localError];
        if (!data || ![data writeToURL:self.fileURL options:NSDataWritingAtomic error:&localError]) {
            STS2LogE(STS2LogTagApp, localError, @"写入 config.json 失败");
            if (error) *error = localError;
            return NO;
        }
        self.launcherSettings = [root[@"launcher"] isKindOfClass:NSDictionary.class] ? [root[@"launcher"] copy] : @{};
        return YES;
    }
}

- (BOOL)save:(NSError **)error {
    return [self updateRoot:^(NSMutableDictionary *root) {
        NSMutableDictionary *network = [root[@"network"] isKindOfClass:NSDictionary.class] ? [root[@"network"] mutableCopy] : [NSMutableDictionary dictionary];
        network[@"nickname"] = self.nickname ?: @"玩家"; network[@"host"] = self.host ?: @""; network[@"port"] = @(self.port);
        if (![STS2LauncherConfigStore isValidPlayerId:network[@"playerId"]]) network[@"playerId"] = self.playerId;
        root[@"network"] = network;
    } error:error];
}

- (id)launcherSettingForKey:(NSString *)key { return self.launcherSettings[key]; }

- (BOOL)setLauncherSetting:(id)value forKey:(NSString *)key error:(NSError **)error {
    return [self updateRoot:^(NSMutableDictionary *root) {
        NSMutableDictionary *launcher = [root[@"launcher"] isKindOfClass:NSDictionary.class] ? [root[@"launcher"] mutableCopy] : [NSMutableDictionary dictionary];
        if (value) launcher[key] = value; else [launcher removeObjectForKey:key];
        root[@"launcher"] = launcher;
    } error:error];
}

- (NSDictionary *)redactedSnapshot {
    NSMutableDictionary *root = [self readRoot:nil];
    return root ? StripSecrets(root) : @{@"error": @"config.json 无法解析"};
}
@end

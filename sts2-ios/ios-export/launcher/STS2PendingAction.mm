#import "STS2PendingAction.h"
#import "STS2Log.h"

@implementation STS2PendingAction
+ (NSDictionary *)actionWithType:(NSString *)type online:(BOOL)online host:(NSString *)host port:(NSInteger)port
                        nickname:(NSString *)nickname playerId:(NSString *)playerId now:(NSDate *)now {
    NSMutableDictionary *action = [@{@"v": @1, @"type": type, @"created": @((long long)now.timeIntervalSince1970), @"online": @(online),
                                     @"nickname": nickname ?: @"玩家", @"playerId": playerId ?: @""} mutableCopy];
    if (host.length) action[@"host"] = host;
    if (port > 0) action[@"port"] = @(port);
    return action;
}

+ (NSURL *)fileURLForDocuments:(NSURL *)documentsURL {
    return [[documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES] URLByAppendingPathComponent:@"pending-action.json"];
}

+ (BOOL)writeAction:(NSDictionary *)action documentsURL:(NSURL *)documentsURL error:(NSError **)error {
    NSURL *url = [self fileURLForDocuments:documentsURL];
    NSError *localError = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:action options:NSJSONWritingSortedKeys error:&localError];
    if (data && [data writeToURL:url options:NSDataWritingAtomic error:&localError]) {
        STS2LogI(STS2LogTagOnline, @"写入联机指令: type=%@ online=%@ host=%@ port=%@", action[@"type"], action[@"online"], action[@"host"] ?: @"-", action[@"port"] ?: @"-");
        return YES;
    }
    STS2LogE(STS2LogTagOnline, localError, @"写入联机指令失败");
    if (error) *error = localError;
    return NO;
}

+ (void)discardLeftoverInDocuments:(NSURL *)documentsURL {
    NSURL *url = [self fileURLForDocuments:documentsURL];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;
    NSDictionary *action = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:url error:&error]) STS2LogE(STS2LogTagOnline, error, @"删除残留联机指令失败");
    else STS2LogW(STS2LogTagOnline, @"丢弃游戏未消费的联机指令（上次启动后未进入主菜单）: type=%@",
                  [action isKindOfClass:NSDictionary.class] ? action[@"type"] : @"(无法解析)");
}
@end

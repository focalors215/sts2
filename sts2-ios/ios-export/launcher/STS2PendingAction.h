#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动器 → 游戏的一次性指令 Documents/Launcher/pending-action.json（规范 §3.3）。
/// 游戏补丁 RemoteRoomPatches 在主菜单读一次即删除；created 超过 600 s 的指令丢弃并写日志。
@interface STS2PendingAction : NSObject
+ (NSDictionary *)actionWithType:(NSString *)type online:(BOOL)online host:(nullable NSString *)host port:(NSInteger)port
                        nickname:(NSString *)nickname playerId:(NSString *)playerId now:(NSDate *)now;
+ (NSURL *)fileURLForDocuments:(NSURL *)documentsURL;
+ (BOOL)writeAction:(NSDictionary *)action documentsURL:(NSURL *)documentsURL error:(NSError **)error;
/// 启动器打开时清理游戏没来得及消费的旧指令，并写日志。
+ (void)discardLeftoverInDocuments:(NSURL *)documentsURL;
@end

NS_ASSUME_NONNULL_END

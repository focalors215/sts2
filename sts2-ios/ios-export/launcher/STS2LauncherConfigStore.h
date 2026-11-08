#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Documents/Launcher/config.json（schemaVersion 1）。游戏补丁 LauncherConfigPatches 读同一文件。
/// 每次保存都重新读取磁盘最新内容再合并，保留未知字段（含 MOD 管理写入的 resourceMods）。
/// 启动器自己的设置放在根层 "launcher" 对象里。密钥一律不进此文件（见 STS2SecretStore）。
@interface STS2LauncherConfigStore : NSObject
@property(nonatomic, copy) NSString *nickname;
@property(nonatomic, copy) NSString *host;
@property(nonatomic) NSInteger port;
/// 本机持久的随机联机身份，范围 [2, 2^63-1]（十进制字符串，规范 §3.4）。缺失或为 0/1 时生成并保存。
/// 加入房间时它就是本机 NetId；当房主时原版固定用 1。
@property(nonatomic, readonly, copy) NSString *playerId;
@property(nonatomic, readonly) NSURL *fileURL;
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
- (BOOL)save:(NSError **)error;
/// 原子地读-改-写整个根对象。
- (BOOL)updateRoot:(void (^)(NSMutableDictionary *root))block error:(NSError **)error;
- (nullable id)launcherSettingForKey:(NSString *)key;
- (BOOL)setLauncherSetting:(nullable id)value forKey:(NSString *)key error:(NSError **)error;
/// 用于日志导出：读当前文件并去掉任何疑似密钥字段。
- (NSDictionary *)redactedSnapshot;
/// 纯函数：生成与游戏补丁相同规则的 playerId（>1 的 63 位随机数）。
+ (NSString *)generatePlayerId;
+ (BOOL)isValidPlayerId:(nullable id)value;
@end

NS_ASSUME_NONNULL_END

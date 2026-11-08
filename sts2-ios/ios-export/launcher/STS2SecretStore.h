#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 本机密钥（frp 令牌、WebDAV 密码、Nexus API key、AI 接口 key）。
/// 存在钥匙串 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly：不进 iCloud/iTunes 备份、
/// 不进 config.json、不进日志与导出包（读出的值会自动登记到 STS2Log 脱敏表）。
FOUNDATION_EXPORT NSString *const STS2SecretFrpToken;
FOUNDATION_EXPORT NSString *const STS2SecretWebDavPassword;
FOUNDATION_EXPORT NSString *const STS2SecretNexusApiKey;
FOUNDATION_EXPORT NSString *const STS2SecretLlmApiKey;

@interface STS2SecretStore : NSObject
+ (nullable NSString *)secretForKey:(NSString *)key;
/// 传 nil 或空串表示删除。
+ (BOOL)setSecret:(nullable NSString *)value forKey:(NSString *)key error:(NSError **)error;
/// 启动时把已保存的密钥都登记进日志脱敏表。
+ (void)registerAllForRedaction;
@end

NS_ASSUME_NONNULL_END

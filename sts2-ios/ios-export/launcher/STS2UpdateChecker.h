#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动器更新检查（对齐 Android ExtraSettingsUpdateChecker）：查 GitHub Releases，只提示，不自动安装。
FOUNDATION_EXPORT NSString *const STS2UpdateReleasesURL;

@interface STS2UpdateChecker : NSObject
/// 比较版本号里的数字段（v1.2.10 > v1.2.9），忽略前缀 v 与后缀。
+ (NSComparisonResult)compareVersion:(NSString *)left to:(NSString *)right;
/// 从 releases 列表里取第一个非草稿发布：{version, title, body, url, prerelease}。
+ (nullable NSDictionary *)latestReleaseFromData:(NSData *)data;
/// completion 在主线程：info 含 newer(BOOL)；error 为可展示的中文。
+ (void)checkCurrentVersion:(NSString *)current completion:(void (^)(NSDictionary *_Nullable info, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END

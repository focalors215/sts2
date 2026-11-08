#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Nexus Mods（对齐 Android NexusModsApiClient）：API key 存钥匙串，请求头 apikey。
/// 热门列表（v3）无需 key；最新/最近更新、文件列表与下载需要 key；直接下载链接只对 Premium 开放，
/// 普通账号需在网页上点「Mod Manager Download」后把 nxm:// 链接粘贴回来（含 key/expires）。
FOUNDATION_EXPORT NSString *const STS2NexusGameDomain; // slaythespire2

typedef NS_ENUM(NSInteger, STS2NexusFeed) { STS2NexusFeedTrending = 0, STS2NexusFeedLatestAdded, STS2NexusFeedLatestUpdated };

@interface STS2NexusMods : NSObject
- (instancetype)initWithApiKey:(nullable NSString *)apiKey;
/// 回调都在主线程。user: {name, premium}
- (void)validate:(void (^)(NSDictionary *_Nullable user, NSError *_Nullable error))completion;
- (void)feed:(STS2NexusFeed)feed completion:(void (^)(NSArray<NSDictionary *> *mods, NSError *_Nullable error))completion;
- (void)mod:(NSString *)modId completion:(void (^)(NSDictionary *_Nullable mod, NSError *_Nullable error))completion;
- (void)filesForMod:(NSString *)modId completion:(void (^)(NSArray<NSDictionary *> *files, NSError *_Nullable error))completion;
/// key/expires 来自 nxm 链接（Premium 可传 nil）。返回下载 URL 列表。
- (void)downloadLinksForMod:(NSString *)modId file:(NSString *)fileId key:(nullable NSString *)key expires:(nullable NSString *)expires
                 completion:(void (^)(NSArray<NSURL *> *urls, NSError *_Nullable error))completion;
/// 下载到临时目录（文件名取自链接），主线程回调。
- (void)download:(NSURL *)url fileName:(NSString *)name progress:(void (^)(double fraction))progress completion:(void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

#pragma mark 纯函数（宿主测试）
+ (nullable NSDictionary *)modFromJSON:(NSDictionary *)object;
/// nxm://slaythespire2/mods/12/files/34?key=..&expires=.. → {modId, fileId, key, expires}；或网页链接 → {modId}
+ (nullable NSDictionary *)parseLink:(NSString *)text;
@end

NS_ASSUME_NONNULL_END

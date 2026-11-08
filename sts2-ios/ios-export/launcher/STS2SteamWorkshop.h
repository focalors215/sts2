#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Steam 创意工坊（对齐 Android SteamWorkshopCatalog / SteamWorkshopDownloader 的公开路径，不需要 Steam 账号）：
/// - 浏览：steamcommunity.com 工坊浏览页取条目 ID，再用公开的 ISteamRemoteStorage/GetPublishedFileDetails 取详情；
/// - 详情图：条目页里的截图链接；
/// - 下载：与 Android 相同的「尖塔补给站」公开下载协议（workshop.apricityx.top，只给出 Steam CDN 授权，
///   不接触任何 Steam 账号凭据），从 Steam CDN 取 depot manifest 与分块，AES 解密、LZMA/ZIP 解压、Adler32 与 SHA-1 校验。
/// 下载结果交给 STS2ModStore 导入，按 iOS 规则：资源 PCK 可启用，DLL 归档并说明原因。
FOUNDATION_EXPORT const NSUInteger STS2WorkshopAppId; // 2868840
FOUNDATION_EXPORT NSString *const STS2WorkshopErrorDomain;

typedef NS_ENUM(NSInteger, STS2WorkshopSort) {
    STS2WorkshopSortPopular = 0,   // trend
    STS2WorkshopSortRecent,        // mostrecent
    STS2WorkshopSortUpdated,       // lastupdated
    STS2WorkshopSortSubscribed,    // totaluniquesubscribers
};

@interface STS2SteamWorkshop : NSObject
+ (instancetype)shared;
/// items: [{id, title, description, preview, size, updated, subscriptions, views, tags}]，主线程回调。
- (void)browse:(NSString *)query page:(NSInteger)page sort:(STS2WorkshopSort)sort
    completion:(void (^)(NSArray<NSDictionary *> *items, BOOL hasNext, NSError *_Nullable error))completion;
/// 按条目 ID 取详情（只用 api.steampowered.com，社区网页打不开时也能用）。
- (void)itemsForIds:(NSArray<NSString *> *)ids completion:(void (^)(NSArray<NSDictionary *> *items, NSError *_Nullable error))completion;
/// item + screenshots(NSArray<NSString *>)、requiredItems。
- (void)detailsForItem:(NSDictionary *)item completion:(void (^)(NSDictionary *_Nullable detail, NSError *_Nullable error))completion;
/// 图片（内存缓存），主线程回调。
- (void)imageDataForURL:(NSString *)url completion:(void (^)(NSData *_Nullable data))completion;
/// 同步下载到 directory（应为空的暂存目录）。progress 在调用线程回调。返回下载的文件数。
- (BOOL)downloadItem:(NSDictionary *)item into:(NSURL *)directory
            progress:(nullable void (^)(double fraction, NSString *status))progress
           cancelled:(nullable BOOL (^)(void))cancelled error:(NSError **)error;

#pragma mark 纯函数（宿主测试）
/// 从工坊链接（…filedetails/?id=123）或纯数字里取条目 ID；无效返回 nil。
+ (nullable NSString *)itemIdFromInput:(NSString *)text;
+ (NSArray<NSString *> *)itemIdsFromBrowseHTML:(NSString *)html;
+ (NSArray<NSDictionary *> *)itemsFromDetailsJSON:(NSData *)data;
+ (NSArray<NSString *> *)screenshotURLsFromPageHTML:(NSString *)html;
/// 解析 depot manifest（PROTOBUF 分段）：{depotId, manifestId, filenamesEncrypted, files:[{path,size,flags,sha,linkTarget,chunks:[{id,crc,offset,original,compressed}]}]}
+ (nullable NSDictionary *)parseManifest:(NSData *)data error:(NSError **)error;
+ (nullable NSString *)decryptFilename:(NSString *)encoded key:(NSData *)depotKey;
+ (nullable NSData *)processChunk:(NSData *)raw key:(nullable NSData *)depotKey expectedLength:(NSUInteger)length checksum:(uint32_t)checksum error:(NSError **)error;
+ (uint32_t)steamAdler32:(NSData *)data;
@end

NS_ASSUME_NONNULL_END

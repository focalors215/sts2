#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// MOD 列表需要重新读取（工坊 / Nexus 导入后发出）。
FOUNDATION_EXPORT NSString *const STS2ModsDidChangeNotification;

/// 创意工坊页（对齐 Android SteamWorkshopActivity / WorkshopImageViewerActivity）：浏览、搜索、排序、详情、
/// 截图大图、下载后导入本地 MOD（iOS 规则：PCK 可启用，DLL 归档）。
@interface STS2WorkshopViewController : UITableViewController
@property(nonatomic, readonly) BOOL hasPendingOperations;
@property(nonatomic, readonly) BOOL downloading;
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
@end

NS_ASSUME_NONNULL_END

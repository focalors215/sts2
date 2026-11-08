#import "STS2Form.h"

NS_ASSUME_NONNULL_BEGIN

@class STS2LauncherConfigStore, STS2SaveArchiveStore, STS2WebDavSync;

/// 云存档页（WebDAV；对齐 Android WebDavCloudActivity）。Steam 云存档需要 Steam 账号登录，iPad 暂不支持。
@interface STS2CloudSaveViewController : STS2FormViewController
- (instancetype)initWithConfig:(STS2LauncherConfigStore *)config saves:(STS2SaveArchiveStore *)saves documentsURL:(NSURL *)documentsURL ioQueue:(dispatch_queue_t)queue;
/// 未配置时返回 nil。
+ (nullable STS2WebDavSync *)syncWithConfig:(STS2LauncherConfigStore *)config documentsURL:(NSURL *)documentsURL;
+ (BOOL)autoSyncEnabled:(STS2LauncherConfigStore *)config;
@end

NS_ASSUME_NONNULL_END

#import "STS2Form.h"

NS_ASSUME_NONNULL_BEGIN

/// Nexus Mods 商店（对齐 Android NexusModsStoreActivity）。下载后按 iOS 规则导入本地 MOD。
@interface STS2NexusViewController : STS2FormViewController
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
@end

NS_ASSUME_NONNULL_END

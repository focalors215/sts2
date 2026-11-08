#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 文件浏览 / 文本编辑（对齐 Android FileBrowserActivity / TextEditorActivity）。根目录为应用 Documents。
@interface STS2FileBrowserViewController : UITableViewController
- (instancetype)initWithDirectory:(NSURL *)directory root:(NSURL *)root;
@end

NS_ASSUME_NONNULL_END

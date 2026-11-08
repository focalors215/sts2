#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class STS2LauncherConfigStore;

/// 启动器「日志」页（规范 §5.5，对齐 Android LogViewerActivity / LogFileViewerActivity / loganalysis）：
/// 列出启动器、联机、游戏、frp 日志；查看、搜索、按级别过滤；导出 zip（含 diagnostics.json）走分享面板；日志 AI 分析。
@interface STS2LogsViewController : UITableViewController
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL config:(STS2LauncherConfigStore *)config
                 diagnosticsProvider:(NSDictionary * (^)(void))diagnosticsProvider;
/// 从任意页面导出日志（例如「上次游戏异常退出」提示）。
- (void)exportFromView:(UIView *)sourceView presenter:(UIViewController *)presenter;
@end

NS_ASSUME_NONNULL_END

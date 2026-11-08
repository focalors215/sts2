#import <Foundation/Foundation.h>
#import "STS2Log.h"

NS_ASSUME_NONNULL_BEGIN

/// 日志页的数据层（规范 §5.5）：列出启动器 / 联机 / 游戏 / frp 日志，按行解析级别，打包导出。
/// 只依赖 Foundation，可在 macOS 宿主上测试。
@interface STS2LogCenter : NSObject
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL cachesURL:(NSURL *)cachesURL;
/// 每项：category（launcher/online/game/frp）、categoryTitle、title、url、size、date。分类内新的在前。
- (NSArray<NSDictionary *> *)logFiles;
+ (NSString *)titleForCategory:(NSString *)category;
/// 读文件末尾最多 maxBytes 字节（从下一个完整行开始），按 UTF-8 宽松解码。
+ (NSString *)tailOfFileAtURL:(NSURL *)url maxBytes:(NSUInteger)maxBytes;
/// 把文本拆成条目：{level(NSNumber STS2LogLevel), text}。缩进行/堆栈并入上一条。
/// 识别统一格式「时间 L [tag]」、Godot 的 ERROR:/WARNING:、以及 [OnlineRoom]。
+ (NSArray<NSDictionary *> *)entriesFromText:(NSString *)text;
/// 生成导出包：sts2-logs-ios-<yyyyMMdd-HHmmss>.zip，内含各日志（已脱敏）、diagnostics.json、config.redacted.json。
- (nullable NSURL *)exportArchiveWithDiagnostics:(NSDictionary *)diagnostics redactedConfig:(NSDictionary *)config
                                     destination:(NSURL *)directory date:(NSDate *)date error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END

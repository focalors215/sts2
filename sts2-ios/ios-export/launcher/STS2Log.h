#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 三端统一日志（规范 §5.1）：Documents/Launcher/logs/launcher.log，单文件 2 MiB，保留 5 个
/// （launcher.log + launcher.1.log … launcher.4.log）。行格式：
///   2026-11-09T12:34:56.789+08:00 E [online] 创建房间失败: <原文> | <异常类型>: <消息>
///       at ...（堆栈缩进 4 格）
/// 标签固定集合：app launch online frp mods saves cloud workshop nexus update ui。
/// 所有写入都经过脱敏（已登记的密钥原文 + token/password/apiKey 等键值 + Bearer）。
typedef NS_ENUM(NSInteger, STS2LogLevel) {
    STS2LogLevelDebug = 0,
    STS2LogLevelInfo,
    STS2LogLevelWarn,
    STS2LogLevelError,
};

FOUNDATION_EXPORT NSString *const STS2LogTagApp, *const STS2LogTagLaunch, *const STS2LogTagOnline, *const STS2LogTagFrp,
    *const STS2LogTagMods, *const STS2LogTagSaves, *const STS2LogTagCloud, *const STS2LogTagWorkshop, *const STS2LogTagNexus,
    *const STS2LogTagUpdate, *const STS2LogTagUI;

@interface STS2Log : NSObject
/// 指定日志目录（Documents/Launcher/logs）并安装未捕获 ObjC 异常 / 致命信号记录。可重复调用。
+ (void)setupWithDocumentsURL:(NSURL *)documentsURL;
/// 只设置目录，不安装崩溃处理（宿主测试用）。
+ (void)setupWithLogsDirectory:(NSURL *)directory installCrashHandlers:(BOOL)install;
@property(class, nonatomic, readonly, nullable) NSURL *logsDirectory;
@property(class, nonatomic, readonly, nullable) NSURL *launcherLogURL;
/// 低于此级别的日志不写（设置页「日志等级」）。默认 Info。
@property(class, nonatomic) STS2LogLevel minimumLevel;
/// 单文件上限，默认 2 MiB；宿主测试可调小。
@property(class, nonatomic) unsigned long long maxFileBytes;

+ (void)log:(STS2LogLevel)level tag:(NSString *)tag message:(NSString *)message;
/// detail 可以是 NSError、NSException 或 nil；NSError 会带上 underlying error 链。
+ (void)log:(STS2LogLevel)level tag:(NSString *)tag message:(NSString *)message detail:(nullable id)detail;

/// 登记一个绝不能出现在日志/导出里的原文（frp 令牌、密码、API key）。空串忽略。
+ (void)registerSecret:(nullable NSString *)secret;
+ (NSString *)redact:(NSString *)text;
/// 纯函数：格式化一条日志（含脱敏），供测试与游戏内日志对齐。
+ (NSString *)formatLineWithDate:(NSDate *)date timeZone:(NSTimeZone *)zone level:(STS2LogLevel)level tag:(NSString *)tag
                         message:(NSString *)message detail:(nullable id)detail;
+ (unichar)letterForLevel:(STS2LogLevel)level;

/// 上一次运行留下的致命信号 / 未捕获异常记录（已写入 launcher.log）；读取后清空。
+ (nullable NSString *)takePreviousCrashReport;
@end

/// 启动标记（规范 §5.4，以 Android StartupHealthTracker 为准）：启动游戏前写 Documents/Launcher/launch-marker.json，
/// 游戏补丁在进入主菜单时删除（RemoteRoomPatches.ClearLaunchMarker）；加载途中进入后台标为 background。
/// 下次打开启动器若发现 state=running 的残留，视为游戏没能启动到主菜单（启动阶段崩溃/卡死被杀）。
@interface STS2LaunchMarker : NSObject
+ (void)setDocumentsURL:(NSURL *)documentsURL;
+ (void)writeWithInfo:(NSDictionary *)info;
+ (void)updateState:(NSString *)state;
+ (void)clear;
/// 读取并删除上一次的标记；返回 nil 表示没有残留。
+ (nullable NSDictionary *)takePrevious;
@end

#define STS2LogD(logTag, ...) [STS2Log log:STS2LogLevelDebug tag:(logTag) message:[NSString stringWithFormat:__VA_ARGS__]]
#define STS2LogI(logTag, ...) [STS2Log log:STS2LogLevelInfo tag:(logTag) message:[NSString stringWithFormat:__VA_ARGS__]]
#define STS2LogW(logTag, ...) [STS2Log log:STS2LogLevelWarn tag:(logTag) message:[NSString stringWithFormat:__VA_ARGS__]]
#define STS2LogE(logTag, detailObject, ...) [STS2Log log:STS2LogLevelError tag:(logTag) message:[NSString stringWithFormat:__VA_ARGS__] detail:(detailObject)]

NS_ASSUME_NONNULL_END

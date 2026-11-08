#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// WebDAV 云存档（对齐 Android webdav/WebDavSyncManager，远端布局相同，可与 Android 共用同一槽位）：
///   <服务器>/SlayTheSpire2/saves/<槽位>/<profileN/saves/...>，元数据 .sts2re/manifest.json（含 sha1）。
/// 只同步 profile.save、profile1-3/saves 下的进度/偏好/当前局/多人局与 history/*.run（可选 settings.save）。
/// 用本地 baseline 做三方比较：两边都改过同一文件 = 冲突，交给用户选择强制拉取或强制推送。
/// 所有方法同步执行，请在后台队列调用；密码由调用方从钥匙串传入。
FOUNDATION_EXPORT NSString *const STS2WebDavErrorDomain;
typedef NS_ENUM(NSInteger, STS2WebDavError) {
    STS2WebDavErrorNotConfigured = 1,
    STS2WebDavErrorHTTP = 2,
    STS2WebDavErrorConflict = 3,
    STS2WebDavErrorInvalid = 4,
};
/// 冲突时 userInfo[STS2WebDavConflictPathsKey] 为冲突文件列表。
FOUNDATION_EXPORT NSString *const STS2WebDavConflictPathsKey;

@interface STS2WebDavConfig : NSObject
@property(nonatomic, copy) NSString *baseURL, *username, *password, *remoteSlot;
@property(nonatomic) BOOL syncSettingsSave;
/// 与 Android sanitizeId 相同：小写、非 [a-z0-9._-] 换成 -，空则 global。
+ (NSString *)sanitizeSlot:(NSString *)slot;
@end

@interface STS2WebDavSync : NSObject
/// accountURL = Documents/default/1；stateURL = 本地 baseline 目录。
- (instancetype)initWithConfig:(STS2WebDavConfig *)config accountURL:(NSURL *)accountURL stateURL:(NSURL *)stateURL;
/// 测试连接并确保槽位目录存在。
- (nullable NSString *)testConnection:(NSError **)error;
/// 拉取远端变更；force 时覆盖本地。返回摘要。调用前应由上层先做本地快照。
- (nullable NSString *)pull:(BOOL)force progress:(nullable void (^)(NSString *status))progress error:(NSError **)error;
- (nullable NSString *)push:(BOOL)force progress:(nullable void (^)(NSString *status))progress error:(NSError **)error;
/// 本地可同步文件数、上次同步时间等。
- (NSDictionary *)status;

/// 纯函数：与 Android WebDavSavePathMapper 相同的路径白名单。
+ (BOOL)isSupportedPath:(NSString *)relativePath includeSettings:(BOOL)includeSettings;
/// 纯函数：解析 PROPFIND multistatus（href 相对 basePath）→ [{path, dir, size, modified, etag}]。
+ (NSArray<NSDictionary *> *)resourcesFromMultistatus:(NSData *)xml basePath:(NSString *)basePath;
@end

NS_ASSUME_NONNULL_END

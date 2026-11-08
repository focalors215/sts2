#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages the game's Documents/default/1 save tree and portable ZIP archives.
/// All methods are synchronous; callers should serialize them off the UI thread.
@interface STS2SaveArchiveStore : NSObject
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
- (nullable NSURL *)exportCurrentSave:(NSError **)error;
- (nullable NSURL *)createSnapshotWithName:(NSString *)name error:(NSError **)error;
/// 新的在前：path(NSURL)、name(文件名)、title(创建时的名字)、date、size。
- (NSArray<NSDictionary *> *)snapshots;
/// 只删除归档目录下 Snapshot-*.zip。
- (BOOL)deleteSnapshotAtURL:(NSURL *)url error:(NSError **)error;
/// 同名快照只保留最新 keep 个，返回删除数。
- (NSUInteger)pruneSnapshotsTitled:(NSString *)title keep:(NSUInteger)keep;
- (BOOL)restoreArchiveAtURL:(NSURL *)archiveURL error:(NSError **)error;
- (NSDictionary *)currentSaveSummary;
@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages the game's Documents/default/1 save tree and portable ZIP archives.
/// All methods are synchronous; callers should serialize them off the UI thread.
@interface STS2SaveArchiveStore : NSObject
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
- (nullable NSURL *)exportCurrentSave:(NSError **)error;
- (nullable NSURL *)createSnapshotWithName:(NSString *)name error:(NSError **)error;
- (NSArray<NSDictionary *> *)snapshots;
- (BOOL)restoreArchiveAtURL:(NSURL *)archiveURL error:(NSError **)error;
- (NSDictionary *)currentSaveSummary;
@end

NS_ASSUME_NONNULL_END

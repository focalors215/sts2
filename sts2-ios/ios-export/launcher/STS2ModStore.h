#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^STS2ModCompletion)(NSError * _Nullable error);
/// Serialized disk operations; all completion blocks arrive on the main queue.
@interface STS2ModStore : NSObject
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
#if defined(STS2_MODSTORE_TESTING)
/// Host-test only injection. Production builds can only read the signed main bundle resource.
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL compiledModsURLForTesting:(nullable NSURL *)compiledModsURL;
#endif
- (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *mods, NSError * _Nullable error))completion;
- (void)createStagingDirectoryWithCompletion:(void (^)(NSURL * _Nullable directory, NSError * _Nullable error))completion;
- (void)discardStagingDirectoryURL:(NSURL *)url completion:(STS2ModCompletion)completion;
/// Accepts only a direct child of this store's staging directory. Consumes it on success.
- (void)importStagedDirectoryURL:(NSURL *)url source:(NSString *)source completion:(STS2ModCompletion)completion;
/// Copies a document-picker ZIP/PCK into private staging under security-scoped access.
- (void)importDocumentURL:(NSURL *)url completion:(STS2ModCompletion)completion;
- (void)setEnabled:(BOOL)enabled modID:(NSString *)modID completion:(STS2ModCompletion)completion;
- (void)moveModID:(NSString *)modID toIndex:(NSUInteger)index completion:(STS2ModCompletion)completion;
- (void)deleteModID:(NSString *)modID completion:(STS2ModCompletion)completion;
@end
NS_ASSUME_NONNULL_END

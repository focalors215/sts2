#import <UIKit/UIKit.h>
@class STS2ModStore;
NS_ASSUME_NONNULL_BEGIN
@interface STS2ModsViewController : UITableViewController
/// Main-thread lifecycle gate: true until every queued read/download/import/mutation finishes.
@property(nonatomic, readonly) BOOL hasPendingOperations;
- (instancetype)initWithStore:(STS2ModStore *)store;
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
@end
NS_ASSUME_NONNULL_END

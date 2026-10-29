#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface STS2LauncherConfigStore : NSObject
@property(nonatomic, copy) NSString *nickname;
@property(nonatomic, copy) NSString *host;
@property(nonatomic) NSInteger port;
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL;
- (BOOL)save:(NSError **)error;
@end

NS_ASSUME_NONNULL_END

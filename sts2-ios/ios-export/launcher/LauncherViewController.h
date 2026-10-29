#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, StS2LauncherState) {
    StS2LauncherStateLauncher,
    StS2LauncherStateStarting,
    StS2LauncherStateRunning,
    StS2LauncherStateFailed,
};

@interface LauncherViewController : UIViewController
@property(nonatomic, copy, nullable) dispatch_block_t startHandler;
@property(nonatomic) StS2LauncherState state;
/// Optional resource MOD controller supplied by the resource installer integration.
@property(nonatomic, copy, nullable) UIViewController * _Nullable (^modContentProvider)(void);
- (void)showStartFailure:(NSString *)message;
@end

NS_ASSUME_NONNULL_END

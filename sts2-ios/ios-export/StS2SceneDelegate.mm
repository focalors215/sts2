// Defer only Godot's exact built-in service. Its original launch IMP owns engine setup.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "launcher/LauncherViewController.h"
static id STS2Service;
static NSDictionary *STS2LaunchOptions;
static UIWindow *STS2GameWindow;
static __weak UIWindowScene *STS2Scene;
static StS2LauncherState STS2State = StS2LauncherStateLauncher;
static BOOL STS2Attempted;
static IMP STS2OriginalLaunch;
static IMP STS2OriginalSetWindow;
static BOOL STS2DeferLaunch(id service, SEL selector, UIApplication *application, NSDictionary *options) {
    STS2Service = service; STS2LaunchOptions = [options copy]; return YES;
}
static void STS2BindWindow(id service, SEL selector, UIWindow *window) {
    if (window && STS2Scene) { window.windowScene = STS2Scene; window.frame = STS2Scene.coordinateSpace.bounds; }
    ((void(*)(id,SEL,UIWindow *))STS2OriginalSetWindow)(service, selector, window);
}
@interface StS2SceneDelegate : NSObject <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) LauncherViewController *launcher;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL backgrounded;
@end
@implementation StS2SceneDelegate
+ (void)load {
    Class service = NSClassFromString(@"GDTAppDelegateService");
    Method launch = class_getInstanceMethod(service, @selector(application:didFinishLaunchingWithOptions:));
    Method setter = class_getInstanceMethod(service, @selector(setWindow:));
    if (!launch || !setter) { NSLog(@"[StS2Launcher] Unsupported Godot service; hooks not installed"); return; }
    STS2OriginalLaunch = method_setImplementation(launch, (IMP)STS2DeferLaunch);
    STS2OriginalSetWindow = method_setImplementation(setter, (IMP)STS2BindWindow);
    // The app delegate can send these before a scene starts the engine.
    for (NSString *name in @[@"applicationWillEnterForeground:", @"applicationDidBecomeActive:", @"applicationWillResignActive:", @"applicationDidEnterBackground:", @"applicationWillTerminate:", @"applicationDidReceiveMemoryWarning:"]) {
        SEL selector = NSSelectorFromString(name); Method method = class_getInstanceMethod(service, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        IMP guarded = imp_implementationWithBlock(^(id object, UIApplication *application) {
            if (STS2State == StS2LauncherStateRunning) ((void(*)(id,SEL,UIApplication *))original)(object, selector, application);
        });
        method_setImplementation(method, guarded);
    }
}
- (instancetype)init { if ((self = [super init])) _backgrounded = YES; return self; }
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    STS2Scene = (UIWindowScene *)scene;
    if (STS2GameWindow) {
        self.window = STS2GameWindow; self.window.windowScene = STS2Scene;
    } else {
        self.window = [[UIWindow alloc] initWithWindowScene:STS2Scene];
        self.launcher = [LauncherViewController new]; self.launcher.state = STS2State;
        __weak StS2SceneDelegate *weakSelf = self;
        self.launcher.startHandler = ^{ [weakSelf startGame]; };
        self.window.rootViewController = self.launcher;
    }
    [self.window makeKeyAndVisible];
}
- (void)startGame {
    if (STS2Attempted || STS2State != StS2LauncherStateLauncher || self.window.windowScene.activationState != UISceneActivationStateForegroundActive) return;
    if (!STS2Service || !STS2OriginalLaunch) { [self.launcher showStartFailure:@"Godot 启动服务不可用，请重新打开应用。"]; return; }
    STS2State = StS2LauncherStateStarting; self.launcher.state = STS2State;
    // Let UIKit render the progress state before invoking the original engine entry point.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.window.windowScene.activationState != UISceneActivationStateForegroundActive) {
            STS2State = StS2LauncherStateLauncher; self.launcher.state = STS2State; return;
        }
        STS2Attempted = YES;
        @try {
            BOOL ok = ((BOOL(*)(id,SEL,UIApplication *,NSDictionary *))STS2OriginalLaunch)(STS2Service, @selector(application:didFinishLaunchingWithOptions:), UIApplication.sharedApplication, STS2LaunchOptions);
            UIWindow *gameWindow = [STS2Service window];
            if (!ok || !gameWindow.rootViewController) @throw [NSException exceptionWithName:@"StS2Launch" reason:@"引擎没有创建游戏画面。" userInfo:nil];
            STS2GameWindow = gameWindow; self.window.hidden = YES; self.window = gameWindow;
            STS2State = StS2LauncherStateRunning; [gameWindow makeKeyAndVisible];
            self.active = NO; self.backgrounded = YES;
            if (gameWindow.windowScene.activationState == UISceneActivationStateForegroundActive) { [self sceneWillEnterForeground:gameWindow.windowScene]; [self sceneDidBecomeActive:gameWindow.windowScene]; }
        } @catch (NSException *exception) {
            STS2State = StS2LauncherStateFailed;
            [self.window makeKeyAndVisible];
            [self.launcher showStartFailure:[NSString stringWithFormat:@"%@\n请完全关闭应用后重试。", exception.reason ?: @"启动失败"]];
        }
    });
}
- (BOOL)isRunningScene:(UIScene *)scene { return STS2State == StS2LauncherStateRunning && self.window.windowScene == scene; }
- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (![self isRunningScene:scene] || !self.backgrounded) return; self.backgrounded = NO;
    [UIApplication.sharedApplication.delegate applicationWillEnterForeground:UIApplication.sharedApplication];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    if (![self isRunningScene:scene] || self.active) return; self.active = YES;
    [UIApplication.sharedApplication.delegate applicationDidBecomeActive:UIApplication.sharedApplication];
}
- (void)sceneWillResignActive:(UIScene *)scene {
    if (![self isRunningScene:scene] || !self.active) return; self.active = NO;
    [UIApplication.sharedApplication.delegate applicationWillResignActive:UIApplication.sharedApplication];
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    if (![self isRunningScene:scene] || self.backgrounded) return;
    [self sceneWillResignActive:scene]; self.backgrounded = YES;
    [UIApplication.sharedApplication.delegate applicationDidEnterBackground:UIApplication.sharedApplication];
}
- (void)sceneDidDisconnect:(UIScene *)scene { [self sceneDidEnterBackground:scene]; self.window = nil; STS2Scene = nil; }
@end

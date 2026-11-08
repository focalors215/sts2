#import "LauncherViewController.h"
#import "STS2LauncherConfigStore.h"
#import "STS2SaveArchiveStore.h"
#import "STS2ModsViewController.h"
#import "STS2Theme.h"
#import "STS2LauncherArt.h"
#import "STS2RoomService.h"
#import "STS2PendingAction.h"
#import "STS2SecretStore.h"
#import "STS2Log.h"
#import "STS2FrpTunnel.h"
#import "STS2LogsViewController.h"
#import "STS2Form.h"
#import "STS2FileBrowserViewController.h"
#import "STS2UpdateChecker.h"
#import "STS2CloudSaveViewController.h"
#import "STS2WebDavSync.h"
#import "STS2WorkshopViewController.h"
#import "STS2NexusViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/utsname.h>

// 主题：喵喵零和小鱼的小屋（配色与组件见 STS2Theme）。
enum { PageHome, PageSaves, PageMods, PageWorkshop, PageNetwork, PageLogs, PageSettings };
static NSArray<NSString *> *PageNames() { return @[ @"回到小屋", @"存档管理", @"本地 MOD", @"创意工坊", @"联机小屋", @"日志", @"设置" ]; }
static NSArray<NSString *> *PageSymbols() { return @[ @"house.fill", @"folder.fill", @"puzzlepiece.extension.fill", @"square.grid.2x2.fill", @"network", @"doc.text.magnifyingglass", @"gearshape.fill" ]; }
// 这些页面是整页表格控制器，放在独立容器里而不是滚动卡片区。
static BOOL IsEmbeddedPage(NSInteger page) { return page == PageMods || page == PageWorkshop || page == PageLogs; }

// 主页插画 (1536x1024) 里已画好的按钮位置；这里在上面盖透明的真实按钮。
static const CGSize kArtSize = {1536, 1024};
static const CGRect kHotspotRects[] = {
    {{52, 405}, {313, 102}},  // 存档管理 -> PageSaves
    {{52, 522}, {313, 103}},  // 本地 MOD -> PageMods
    {{52, 640}, {313, 102}},  // 联机小屋 -> PageNetwork
    {{52, 757}, {103, 98}},   // 设置 -> PageSettings
    {{488, 788}, {590, 147}}, // 开始游戏
};
static const NSInteger kHotspotCount = 5;
static NSString *const kHotspotLabels[] = {@"存档管理", @"本地 MOD", @"联机小屋", @"设置", @"开始游戏"};

// 子页面背景：同一张插画，只做轻度模糊（保留灯笼和窗外夜景的轮廓），再压暗以保证文字可读。
static UIImage *BlurredArt(void) {
    static UIImage *blurred;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *art = STS2LauncherArtImage();
        if (!art.CGImage) return;
        CIImage *input = [CIImage imageWithCGImage:art.CGImage];
        CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [filter setValue:[input imageByClampingToExtent] forKey:kCIInputImageKey];
        [filter setValue:@26 forKey:kCIInputRadiusKey];
        CIImage *output = [filter.outputImage imageByCroppingToRect:input.extent];
        CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:output fromRect:input.extent];
        if (cg) { blurred = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
    });
    return blurred ?: STS2LauncherArtImage();
}

@interface LauncherViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) STS2SaveArchiveStore *saves;
@property(nonatomic, strong) STS2LauncherConfigStore *config;
@property(nonatomic, strong) NSURL *documents;
@property(nonatomic, strong) UIStackView *layout;
@property(nonatomic, strong) UIStackView *sidebar;
@property(nonatomic, strong) UIStackView *content;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIStackView *> *embeddedContainers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIViewController *> *embeddedControllers;
@property(nonatomic, strong) UIViewController *modsController;
@property(nonatomic, strong) STS2LogsViewController *logsController;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UISegmentedControl *tabs;
@property(nonatomic, strong) NSArray<UIButton *> *navButtons;
@property(nonatomic, strong) UIImageView *backdrop;
@property(nonatomic, strong) UIImageView *blur;
@property(nonatomic, strong) UIView *postcard;
@property(nonatomic, strong) UIView *dim;
@property(nonatomic, strong) UIView *stage;
@property(nonatomic, strong) NSArray<UIButton *> *hotspots;
@property(nonatomic, strong) UIView *statusPill;
@property(nonatomic, strong) UILabel *pillLabel;
@property(nonatomic, strong) UIView *startOverlay;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextField *nicknameField;
@property(nonatomic, strong) UITextField *lanHostField;
@property(nonatomic, strong) UITextField *lanPortField;
@property(nonatomic, strong) NSArray<NSDictionary *> *rooms;
@property(nonatomic) BOOL scanningRooms;
@property(nonatomic, strong) NSArray<NSDictionary *> *snapshots;
@property(nonatomic, strong) NSDictionary *saveSummary;
@property(nonatomic) NSInteger selectedPage;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) dispatch_queue_t ioQueue;
@property(nonatomic, strong) NSDictionary *previousLaunch;
@property(nonatomic, copy) NSString *previousCrash;
@property(nonatomic) BOOL checkedPreviousRun;
@end
@implementation LauncherViewController
- (NSString *)availableGamePackSource {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSArray *arguments = [info[@"godot_cmdline"] isKindOfClass:NSArray.class] ? info[@"godot_cmdline"] : nil;
    NSString *mainPack = nil;
    for (NSUInteger i = 0; i + 1 < arguments.count; i++) {
        if ([arguments[i] isEqual:@"--main-pack"] && [arguments[i + 1] isKindOfClass:NSString.class]) {
            mainPack = arguments[i + 1];
            break;
        }
    }

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    if (mainPack.length) {
        NSString *path = nil;
        if ([mainPack hasPrefix:@"user://"]) {
            path = [self.documents.path stringByAppendingPathComponent:[mainPack substringFromIndex:7]];
        } else if ([mainPack hasPrefix:@"res://"]) {
            path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[mainPack substringFromIndex:6]];
        } else if ([mainPack isAbsolutePath]) {
            path = mainPack;
        }
        if (path) [candidates addObject:@{@"path": path, @"source": [mainPack hasPrefix:@"user://"] ? @"Documents" : @"应用内置素材包"}];
    } else {
        [candidates addObject:@{@"path": [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"StS2.pck"], @"source": @"应用内置素材包"}];
        [candidates addObject:@{@"path": [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"StS2.pck"], @"source": @"应用内置素材包"}];
        [candidates addObject:@{@"path": [self.documents.path stringByAppendingPathComponent:@"StS2.pck"], @"source": @"Documents"}];
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSDictionary *candidate in candidates) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:candidate[@"path"] error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] > 0) return candidate[@"source"];
    }
    return nil;
}

#pragma mark - Layout

// 喵喵零（小猫）和小鱼（小鲨鱼）并排。
- (UIStackView *)mascotRow:(CGFloat)size centered:(BOOL)centered {
    // 弹性空白吸收多余宽度，否则 Fill 分布会把最后一只拉宽。
    UIView *(^spacer)(void) = ^UIView *{ UIView *s = [UIView new]; [s setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal]; return s; };
    NSMutableArray *views = [NSMutableArray array];
    UIView *leading = centered ? spacer() : nil, *trailing = spacer();
    if (leading) [views addObject:leading];
    [views addObjectsFromArray:@[[STS2MascotView mascot:STS2MascotKindCat size:size], [STS2MascotView mascot:STS2MascotKindShark size:size]]];
    [views addObject:trailing];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8; row.alignment = UIStackViewAlignmentCenter; row.isAccessibilityElement = NO;
    if (leading) [leading.widthAnchor constraintEqualToAnchor:trailing.widthAnchor].active = YES;
    return row;
}
// 插画裁片：圆角 + 描边，像贴在小屋墙上的画。
- (UIView *)artCard:(CGRect)pixelRect label:(NSString *)label {
    UIImageView *iv = [[UIImageView alloc] initWithImage:[STS2Theme artCrop:pixelRect]];
    iv.contentMode = UIViewContentModeScaleAspectFill; iv.clipsToBounds = YES;
    iv.layer.cornerRadius = 20; iv.layer.cornerCurve = kCACornerCurveContinuous; iv.layer.borderWidth = 2; iv.layer.borderColor = STS2Theme.outline.CGColor;
    iv.isAccessibilityElement = YES; iv.accessibilityLabel = label; iv.accessibilityTraits = UIAccessibilityTraitImage;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [iv.heightAnchor constraintEqualToAnchor:iv.widthAnchor multiplier:pixelRect.size.height / pixelRect.size.width].active = YES;
    return iv;
}
- (UIView *)brandView { return [self artCard:CGRectMake(36, 64, 576, 308) label:STS2ThemeName]; }
// 页面标题：与插画 logo 同款描边圆体，下面一条「— 标语 —」小标签。
- (UIView *)pageTitle:(NSString *)title tagline:(NSString *)tagline {
    UILabel *l = [UILabel new]; l.attributedText = [STS2Theme outlinedTitle:title size:44]; l.numberOfLines = 0; l.accessibilityTraits = UIAccessibilityTraitHeader;
    UILabel *t = [self label:[NSString stringWithFormat:@"—  %@  —", tagline] style:UIFontTextStyleFootnote bold:YES color:STS2Theme.cat];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *pill = [UIView new]; pill.backgroundColor = [STS2Theme.card colorWithAlphaComponent:0.9]; pill.layer.cornerRadius = 15; pill.layer.borderWidth = 1.5; pill.layer.borderColor = [STS2Theme.cat colorWithAlphaComponent:0.7].CGColor;
    [pill addSubview:t];
    [NSLayoutConstraint activateConstraints:@[[t.topAnchor constraintEqualToAnchor:pill.topAnchor constant:6], [t.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-6], [t.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:16], [t.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-16]]];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[l, pill]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.alignment = UIStackViewAlignmentLeading;
    return stack;
}
- (UILabel *)sectionHeading:(NSString *)text { return [self label:[@"✦ " stringByAppendingString:text] style:UIFontTextStyleHeadline bold:YES color:STS2Theme.cat]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    // 夜晚小屋是深色主题；让系统控件（表格、弹窗、开关）一并用深色外观。
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = STS2Theme.background;
    self.backdrop = [[UIImageView alloc] initWithImage:STS2LauncherArtImage()];
    self.backdrop.contentMode = UIViewContentModeScaleAspectFill; self.backdrop.clipsToBounds = YES;
    self.blur = [[UIImageView alloc] initWithImage:BlurredArt()];
    self.blur.contentMode = UIViewContentModeScaleAspectFill; self.blur.clipsToBounds = YES;
    self.dim = [UIView new]; self.dim.backgroundColor = [UIColor colorWithRed:0.05 green:0.08 blue:0.18 alpha:0.45];
    for (UIView *v in @[self.backdrop, self.blur, self.dim]) {
        v.frame = self.view.bounds; v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; v.isAccessibilityElement = NO; [self.view addSubview:v];
    }
    self.documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.saves = [[STS2SaveArchiveStore alloc] initWithDocumentsURL:self.documents];
    self.config = [[STS2LauncherConfigStore alloc] initWithDocumentsURL:self.documents];
    self.ioQueue = dispatch_queue_create("com.sts2.launcher.files", DISPATCH_QUEUE_SERIAL);
    id level = [self.config launcherSettingForKey:@"logLevel"];
    if ([level isKindOfClass:NSNumber.class]) STS2Log.minimumLevel = (STS2LogLevel)MAX(0, MIN(3, [level integerValue]));
    [STS2LaunchMarker setDocumentsURL:self.documents];
    self.previousCrash = [STS2Log takePreviousCrashReport];
    self.previousLaunch = [STS2LaunchMarker takePrevious];
    __weak LauncherViewController *weakSelf = self;
    self.logsController = [[STS2LogsViewController alloc] initWithDocumentsURL:self.documents config:self.config diagnosticsProvider:^NSDictionary *{ return [weakSelf diagnostics]; }];
    // A room action the game never consumed (e.g. the app was closed) must not fire later.
    [STS2PendingAction discardLeftoverInDocuments:self.documents];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"小屋", @"存档", @"MOD", @"工坊", @"联机", @"日志", @"设置"]];
    [self.tabs.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    self.tabs.selectedSegmentIndex = 0; [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    self.tabs.selectedSegmentTintColor = STS2Theme.cat; self.tabs.backgroundColor = STS2Theme.card;
    [self.tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [STS2Theme font:UIFontTextStyleSubheadline bold:YES]} forState:UIControlStateSelected];
    [self.tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: STS2Theme.ink, NSFontAttributeName: [STS2Theme font:UIFontTextStyleSubheadline bold:NO]} forState:UIControlStateNormal];
    self.sidebar = [[UIStackView alloc] init]; self.sidebar.axis = UILayoutConstraintAxisVertical; self.sidebar.spacing = 12;
    [self.sidebar addArrangedSubview:[self brandView]];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < PageNames().count; i++) {
        UIButton *b = [self button:PageNames()[i] symbol:PageSymbols()[i] style:STS2ButtonStyleNav action:@selector(sidebarChanged:)]; b.tag = i; [self.sidebar addArrangedSubview:b]; [buttons addObject:b];
    }
    self.navButtons = buttons;
    self.postcard = [self artCard:CGRectMake(560, 372, 715, 380) label:@"喵喵零和小鱼盖着毯子看书"];
    [self.sidebar addArrangedSubview:self.postcard];
    UIView *spacer = [UIView new]; [self.sidebar addArrangedSubview:spacer];
    self.scroll = [UIScrollView new]; self.scroll.alwaysBounceVertical = YES; self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.content = [UIStackView new]; self.content.axis = UILayoutConstraintAxisVertical; self.content.spacing = 18;
    self.content.translatesAutoresizingMaskIntoConstraints = NO; [self.scroll addSubview:self.content];
    [NSLayoutConstraint activateConstraints:@[[self.content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:24], [self.content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-24], [self.content.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:24], [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-24], [self.content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-48]]];
    self.embeddedContainers = [NSMutableDictionary dictionary]; self.embeddedControllers = [NSMutableDictionary dictionary];
    self.layout = [[UIStackView alloc] initWithArrangedSubviews:@[self.sidebar, self.tabs, self.scroll]];
    self.layout.spacing = 16; self.layout.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.layout];
    [NSLayoutConstraint activateConstraints:@[[self.layout.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16], [self.layout.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16], [self.layout.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [self.layout.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self.sidebar.widthAnchor constraintEqualToConstant:220].active = YES;
    [self registerForTraitChanges:@[UITraitHorizontalSizeClass.class] withHandler:^(__kindof id<UITraitEnvironment> environment, UITraitCollection *previous) { [(LauncherViewController *)environment updateLayout]; }];
    [self buildStage];
    [self updateLayout]; [self renderPage]; [self refreshSaves];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.checkedPreviousRun) return;
    self.checkedPreviousRun = YES;
    [self reportPreviousRun];
    if ([self launcherBool:@"autoUpdateCheck" fallback:YES]) [self checkUpdatesQuietly:YES];
    [self autoPushCloudSaves];
}
// 规范 §5.4：游戏进入主菜单时补丁删除标记；残留 running = 没能启动到主菜单（启动阶段崩溃/卡死被杀）。
// 加载途中切到后台会标为 background，被系统回收不提示。进入主菜单后的崩溃由致命信号/异常记录补报。
- (void)reportPreviousRun {
    NSDictionary *marker = self.previousLaunch;
    BOOL crashedInForeground = [marker[@"state"] isEqual:@"running"];
    if (marker && !crashedInForeground)
        STS2LogI(STS2LogTagLaunch, @"上次游戏在后台被系统结束（启动于 %@），不视为崩溃", marker[@"started"]);
    if (!crashedInForeground && !self.previousCrash.length) return;
    NSString *when = [marker[@"started"] isKindOfClass:NSNumber.class] ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[marker[@"started"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle] : @"未知时间";
    if (crashedInForeground)
        STS2LogW(STS2LogTagLaunch, @"上次游戏异常退出（没能进入主菜单）：启动于 %@，原因 %@，版本 %@，资源 MOD %@", when, marker[@"reason"] ?: @"-", marker[@"gameVersion"] ?: @"-", [marker[@"resourceMods"] isKindOfClass:NSArray.class] && [marker[@"resourceMods"] count] ? [marker[@"resourceMods"] componentsJoinedByString:@"、"] : @"无");
    NSString *body = crashedInForeground
        ? [NSString stringWithFormat:@"游戏（%@ 启动）没能进入主菜单就结束了，可能是启动时闪退、被系统因内存不足结束，或卡住后被强制关闭。%@\n可以先查看日志，或导出日志发给开发者。", when, self.previousCrash.length ? @"\n已记录到崩溃信号/异常。" : @""]
        : @"上次运行时发生了崩溃（启动器或游戏中），已记录到日志。可以导出日志发给开发者。";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"上次游戏异常退出" message:body preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self selectPage:PageLogs]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"导出日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self.logsController exportFromView:self.view presenter:self]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
// 字段名与规范 §5.5（Android LogExportBundle）一致；平台没有的字段省略。
- (NSDictionary *)diagnostics {
    struct utsname system; uname(&system);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSDictionary *disk = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.documents.path error:nil];
    NSDateFormatter *iso = [NSDateFormatter new]; iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx";
    NSMutableDictionary *mods = [[self modSummary] mutableCopy];
    mods[@"loadingEnabled"] = @YES; // iPad 只加载已启用的资源 PCK / 应用内置编译 MOD
    NSMutableDictionary *settings = [[[self.config redactedSnapshot][@"launcher"] isKindOfClass:NSDictionary.class] ? [self.config redactedSnapshot][@"launcher"] : @{} mutableCopy];
    settings[@"logLevel"] = @(STS2Log.minimumLevel);
    NSMutableDictionary *d = [@{
        @"platform": @"ios", @"generatedAt": [iso stringFromDate:NSDate.date],
        @"osVersion": [NSString stringWithFormat:@"%@ %@", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion],
        @"deviceModel": @(system.machine), @"abis": @[@"arm64"],
        @"launcherVersion": [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"],
        @"launchProfile": @{@"profileId": @"default", @"gameVersion": STS2RoomService.shared.gameVersion, @"gamePack": [self availableGamePackSource] ?: @"未找到",
                            @"runtime": @"NativeAOT + 静态织入补丁", @"onlineRooms": @YES},
        @"mods": mods,
        @"online": @{@"configured": @(STS2RoomService.shared.server.length > 0), @"server": STS2RoomService.shared.server ?: @"", @"serverPort": @(STS2RoomService.shared.serverPort),
                     @"nickname": self.config.nickname ?: @"", @"playerId": self.config.playerId ?: @"", @"lanHost": self.config.host ?: @"", @"port": @(self.config.port),
                     @"hostTokenSaved": @([STS2SecretStore secretForKey:STS2SecretFrpToken].length > 0), @"hasMultiplayerSave": @([self hasMultiplayerSave])},
        @"settings": settings,
        @"locale": NSLocale.currentLocale.localeIdentifier, @"timeZone": NSTimeZone.localTimeZone.name, @"freeDiskBytes": disk[NSFileSystemFreeSize] ?: @0,
    } mutableCopy];
    if (self.previousLaunch) d[@"lastStartupMarker"] = self.previousLaunch;
    return d;
}
- (void)updateLayout {
    BOOL compact = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    self.layout.axis = compact ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.sidebar.hidden = compact; self.tabs.hidden = !compact;
}

#pragma mark - Home scene

// 主页：插画铺满，真实按钮透明地盖在插画已画好的按钮上。
- (void)buildStage {
    self.stage = [UIView new];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSInteger i = 0; i < kHotspotCount; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i; b.accessibilityLabel = kHotspotLabels[i]; b.accessibilityTraits = UIAccessibilityTraitButton;
        b.configurationUpdateHandler = ^(UIButton *button) {
            UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
            c.background.backgroundColor = button.isHighlighted ? [UIColor colorWithWhite:1 alpha:0.2] : UIColor.clearColor;
            c.background.cornerRadius = button.tag == 4 ? 40 : 26;
            button.configuration = c;
        };
        [b addTarget:self action:@selector(hotspotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.stage addSubview:b]; [buttons addObject:b];
    }
    self.hotspots = buttons;
    self.startOverlay = [UIView new]; self.startOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4]; self.startOverlay.layer.cornerRadius = 40; self.startOverlay.hidden = YES; self.startOverlay.userInteractionEnabled = NO;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; self.spinner.color = UIColor.whiteColor; [self.startOverlay addSubview:self.spinner];
    [self.stage addSubview:self.startOverlay];
    self.statusPill = [UIView new]; self.statusPill.backgroundColor = [STS2Theme.card colorWithAlphaComponent:0.92]; self.statusPill.layer.cornerRadius = 18; self.statusPill.hidden = YES;
    self.pillLabel = [self label:@"" style:UIFontTextStyleSubheadline bold:YES color:STS2Theme.ink]; self.pillLabel.textAlignment = NSTextAlignmentCenter;
    self.pillLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.statusPill addSubview:self.pillLabel];
    [NSLayoutConstraint activateConstraints:@[[self.pillLabel.topAnchor constraintEqualToAnchor:self.statusPill.topAnchor constant:10], [self.pillLabel.bottomAnchor constraintEqualToAnchor:self.statusPill.bottomAnchor constant:-10], [self.pillLabel.leadingAnchor constraintEqualToAnchor:self.statusPill.leadingAnchor constant:18], [self.pillLabel.trailingAnchor constraintEqualToAnchor:self.statusPill.trailingAnchor constant:-18]]];
    [self.stage addSubview:self.statusPill];
    [self.view addSubview:self.stage];
}
- (BOOL)showsScene { return self.selectedPage == PageHome && self.view.bounds.size.height > 0 && self.view.bounds.size.width / self.view.bounds.size.height >= 1.25; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat scale = MAX(w / kArtSize.width, h / kArtSize.height);
    self.stage.frame = CGRectMake((w - kArtSize.width * scale) / 2, (h - kArtSize.height * scale) / 2, kArtSize.width * scale, kArtSize.height * scale);
    for (NSInteger i = 0; i < kHotspotCount; i++) {
        CGRect r = kHotspotRects[i];
        self.hotspots[i].frame = CGRectMake(r.origin.x * scale, r.origin.y * scale, r.size.width * scale, r.size.height * scale);
    }
    CGRect start = self.hotspots[4].frame;
    self.startOverlay.frame = start; self.startOverlay.layer.cornerRadius = start.size.height / 2; self.spinner.center = CGPointMake(start.size.width / 2, start.size.height / 2);
    CGFloat maxWidth = 640 * scale;
    self.pillLabel.preferredMaxLayoutWidth = maxWidth - 36;
    CGSize fit = [self.statusPill systemLayoutSizeFittingSize:CGSizeMake(maxWidth, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    self.statusPill.frame = CGRectMake(CGRectGetMidX(start) - fit.width / 2, start.origin.y - fit.height - 10 * scale, fit.width, fit.height);
    self.statusPill.layer.cornerRadius = MIN(18, fit.height / 2);
    [self applyMode];
}
// 主页显示插画；其余页面把同一张插画调暗模糊后做背景。
- (void)applyMode {
    BOOL scene = [self showsScene];
    self.postcard.hidden = self.view.bounds.size.height < 650;
    self.stage.hidden = !scene; self.layout.hidden = scene; self.blur.hidden = scene; self.dim.hidden = scene;
    [self updateHomeStatus];
}
- (void)updateHomeStatus {
    NSString *text = nil;
    if (self.state == StS2LauncherStateStarting) text = @"小鱼正在布置小屋，请稍候…";
    else if (self.state == StS2LauncherStateFailed) text = @"启动失败，请完全关闭应用后重新打开。";
    else if (![self availableGamePackSource]) text = @"尚未找到可用的 StS2.pck 游戏素材包。";
    self.pillLabel.text = text; self.statusPill.hidden = text == nil;
    BOOL starting = self.state == StS2LauncherStateStarting;
    self.startOverlay.hidden = !starting; if (starting) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.hotspots[4].enabled = self.state == StS2LauncherStateLauncher && !self.busy;
}
- (void)hotspotTapped:(UIButton *)sender {
    if (sender.tag == 4) { [self startTapped]; return; }
    if (self.busy || self.state != StS2LauncherStateLauncher) return;
    NSInteger pages[] = {PageSaves, PageMods, PageNetwork, PageSettings};
    [self selectPage:pages[sender.tag]];
}
- (void)selectPage:(NSInteger)page {
    self.selectedPage = page; self.tabs.selectedSegmentIndex = page; [self renderPage];
    if (page == PageNetwork) [self refreshRooms];
}

#pragma mark - Building blocks

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style bold:(BOOL)bold color:(UIColor *)color {
    UILabel *l = [UILabel new]; l.text = text; l.font = [STS2Theme font:style bold:bold]; l.textColor = color; l.adjustsFontForContentSizeCategory = YES; l.numberOfLines = 0; return l;
}
- (UILabel *)title:(NSString *)text { return [self label:text style:UIFontTextStyleLargeTitle bold:YES color:STS2Theme.ink]; }
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol style:(STS2ButtonStyle)style action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.configuration = [STS2Theme configurationForStyle:style title:title symbol:symbol];
    if (style == STS2ButtonStyleNav || style == STS2ButtonStyleNavSelected) b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
- (void)addText:(NSString *)text { [self.content addArrangedSubview:[self label:text style:UIFontTextStyleBody bold:NO color:STS2Theme.inkSoft]]; }
- (void)addCard:(NSArray<UIView *> *)views { [self.content addArrangedSubview:[STS2CardView cardContaining:views]]; }
- (void)updateNav {
    for (UIButton *b in self.navButtons)
        b.configuration = [STS2Theme configurationForStyle:b.tag == self.selectedPage ? STS2ButtonStyleNavSelected : STS2ButtonStyleNav title:PageNames()[b.tag] symbol:PageSymbols()[b.tag]];
}
- (void)tabChanged:(UISegmentedControl *)sender { [self selectPage:sender.selectedSegmentIndex]; }
- (void)sidebarChanged:(UIButton *)sender { [self selectPage:sender.tag]; }

#pragma mark - Pages

- (void)renderPage {
    [self updateNav];
    self.scroll.hidden = IsEmbeddedPage(self.selectedPage);
    if (IsEmbeddedPage(self.selectedPage)) [self embeddedContainerForPage:self.selectedPage];
    [self.embeddedContainers enumerateKeysAndObjectsUsingBlock:^(NSNumber *page, UIStackView *container, BOOL *stop) { container.hidden = page.integerValue != self.selectedPage; }];
    for (UIView *v in self.content.arrangedSubviews) { [self.content removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (self.selectedPage == PageHome) {
        [self renderGamePage]; // 横屏时被插画主页盖住，窄屏时作为后备主页
    } else if (self.selectedPage == PageSaves) {
        [self renderSavePage];
    } else if (self.selectedPage == PageNetwork) {
        [self renderNetworkPage];
    } else {
        [self renderSettingsPage];
    }
    [self applyMode];
}
- (UIViewController *)makeControllerForPage:(NSInteger)page {
    if (page == PageMods) {
        UIViewController *controller = self.modContentProvider ? self.modContentProvider() : nil;
        self.modsController = controller ?: [[STS2ModsViewController alloc] initWithDocumentsURL:self.documents];
        return self.modsController;
    }
    if (page == PageLogs) return self.logsController;
    if (page == PageWorkshop) return [[STS2WorkshopViewController alloc] initWithDocumentsURL:self.documents];
    return nil;
}
// A table controller needs a full-height container, not a zero-height view inside the
// launcher's scroll stack. Keep each one alive across page switches.
- (UIStackView *)embeddedContainerForPage:(NSInteger)page {
    UIStackView *container = self.embeddedContainers[@(page)];
    if (container) return container;
    NSDictionary *taglines = @{@(PageMods): @"给小屋添点新花样", @(PageWorkshop): @"逛逛 Steam 创意工坊", @(PageLogs): @"出问题时先看这里"};
    container = [UIStackView new]; container.axis = UILayoutConstraintAxisVertical; container.spacing = 12;
    container.layoutMarginsRelativeArrangement = YES; container.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(24, 0, 0, 0);
    // 标题缩进，与下方 inset-grouped 表格的卡片左边对齐；多余高度交给表格。
    UIView *titleRow = [UIView new]; UIView *title = [self pageTitle:PageNames()[page] tagline:taglines[@(page)] ?: @""]; title.translatesAutoresizingMaskIntoConstraints = NO; [titleRow addSubview:title];
    [NSLayoutConstraint activateConstraints:@[[title.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor], [title.topAnchor constraintEqualToAnchor:titleRow.topAnchor], [title.bottomAnchor constraintEqualToAnchor:titleRow.bottomAnchor]]];
    [titleRow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [titleRow setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [container addArrangedSubview:titleRow];
    UIViewController *controller = [self makeControllerForPage:page];
    if (controller) {
        [self addChildViewController:controller];
        [controller.view setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
        [container addArrangedSubview:controller.view];
        [controller didMoveToParentViewController:self];
        self.embeddedControllers[@(page)] = controller;
    }
    self.embeddedContainers[@(page)] = container;
    [self.layout addArrangedSubview:container];
    return container;
}
- (void)renderGamePage {
    UIStackView *emoji = [self mascotRow:96 centered:NO];
    UILabel *name = [self label:STS2ThemeName style:UIFontTextStyleLargeTitle bold:YES color:STS2Theme.cat];
    UILabel *sub = [self label:@"杀戮尖塔 2 · 今天也一起爬塔喵～" style:UIFontTextStyleTitle3 bold:NO color:STS2Theme.ink];
    [self addCard:@[emoji, name, sub]];

    NSString *message = self.state == StS2LauncherStateStarting ? @"小鱼正在布置小屋，请稍候…" : (self.state == StS2LauncherStateFailed ? @"启动失败，请完全关闭应用后重新打开。" : @"使用你自己的正版游戏素材。");
    self.statusLabel = [self label:message style:UIFontTextStyleBody bold:YES color:STS2Theme.ink];
    self.statusLabel.accessibilityTraits |= UIAccessibilityTraitUpdatesFrequently;
    NSString *packSource = [self availableGamePackSource];
    UILabel *pack = [self label:packSource ? [NSString stringWithFormat:@"✅ 已找到游戏素材：%@", packSource] : @"😿 尚未找到可用的 StS2.pck 游戏素材包。" style:UIFontTextStyleSubheadline bold:NO color:packSource ? STS2Theme.fish : STS2Theme.cat];
    UIButton *start = [self button:@"进屋开玩" symbol:@"play.fill" style:STS2ButtonStylePrimary action:@selector(startTapped)];
    start.enabled = self.state == StS2LauncherStateLauncher && !self.busy;
    [self addCard:@[self.statusLabel, pack, start]];
    [self addText:@"启动游戏后，存档与 MOD 管理需完全关闭应用再打开。"];
}
- (void)renderSavePage {
    [self.content addArrangedSubview:[self pageTitle:@"存档管理" tagline:@"守护你的爬塔进度"]];
    NSDictionary *s = self.saveSummary;
    NSString *summary = [s[@"empty"] boolValue] ? @"存档还是空的～进入游戏产生第一份存档，或导入 ZIP 存档。" : s ? (s[@"error"] ?: [NSString stringWithFormat:@"当前账号：default/1\n%@ 个存档文件 · %@ 个文件 · %@", s[@"saveFileCount"] ?: @0, s[@"fileCount"] ?: @0, [NSByteCountFormatter stringFromByteCount:[s[@"totalBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]]) : @"正在读取存档…";
    [self addCard:@[[self label:summary style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self button:@"导入 ZIP 存档" symbol:@"square.and.arrow.down" style:STS2ButtonStylePrimary action:@selector(importTapped)],
                    [self button:@"导出当前存档" symbol:@"square.and.arrow.up" style:STS2ButtonStyleSecondary action:@selector(exportTapped:)],
                    [self button:@"创建本地快照" symbol:@"plus.circle" style:STS2ButtonStyleSecondary action:@selector(backupTapped)],
                    [self button:@"云存档（WebDAV）" symbol:@"icloud.and.arrow.up" style:STS2ButtonStyleSecondary action:@selector(openCloudSaves)]]];
    UISwitch *autoSnapshot = [UISwitch new]; autoSnapshot.on = [self launcherBool:@"preLaunchSnapshot" fallback:YES]; autoSnapshot.onTintColor = STS2Theme.cat;
    [autoSnapshot addTarget:self action:@selector(preLaunchSnapshotChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *autoRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"启动前自动快照（保留最近 5 份）" style:UIFontTextStyleBody bold:YES color:STS2Theme.ink], autoSnapshot]];
    autoRow.alignment = UIStackViewAlignmentCenter; autoRow.spacing = 12;
    [self addCard:@[autoRow, [self label:@"每次从启动器进入游戏前，先把当前存档打包成快照；坏档、误操作时可以从下面恢复。" style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]]];
    [self.content addArrangedSubview:[self sectionHeading:@"本地快照"]];
    if (!self.snapshots.count) [self addText:@"暂无快照。导入或恢复时会先自动备份已有存档。"];
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.snapshots.count; i++) {
        NSDictionary *snapshot = self.snapshots[i];
        NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@", snapshot[@"title"] ?: snapshot[@"name"], [formatter stringFromDate:snapshot[@"date"]], [NSByteCountFormatter stringFromByteCount:[snapshot[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
        UIButton *b = [self button:title symbol:@"clock.arrow.circlepath" style:STS2ButtonStyleSecondary action:@selector(snapshotTapped:)]; b.tag = i; [rows addObject:b];
    }
    if (rows.count) [self addCard:rows];
}
- (void)renderSettingsPage {
    [self.content addArrangedSubview:[self pageTitle:@"设置" tagline:@"小屋的小角落"]];
    NSString *packSource = [self availableGamePackSource];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [NSString stringWithFormat:@"启动器 %@（%@）", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    [self addCard:@[[self sectionHeading:@"启动配置与版本信息"],
                    [self label:[NSString stringWithFormat:@"游戏版本：%@\n%@\n引擎：Godot 4.5.1 Mono · NativeAOT（静态织入补丁）\n游戏素材：%@\n启动配置：默认（iPad 只有一套游戏本体，不支持多配置与额外启动参数）", STS2RoomService.shared.gameVersion, version, packSource ?: @"未找到 StS2.pck"] style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:@"联机只能和同版本互通；iPad 目前只提供 v0.111.0。" style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]]];
    UISwitch *updates = [UISwitch new]; updates.on = [self launcherBool:@"autoUpdateCheck" fallback:YES]; updates.onTintColor = STS2Theme.cat;
    [updates addTarget:self action:@selector(autoUpdateChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *updateRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"打开启动器时检查更新" style:UIFontTextStyleBody bold:YES color:STS2Theme.ink], updates]];
    updateRow.alignment = UIStackViewAlignmentCenter; updateRow.spacing = 12;
    [self addCard:@[[self sectionHeading:@"启动器更新"], updateRow,
                    [self button:@"检查更新" symbol:@"arrow.triangle.2.circlepath" style:STS2ButtonStyleSecondary action:@selector(checkUpdatesTapped)],
                    [self label:@"只提示新版本并打开发布页，不会自动安装（侧载应用需要你自己重新签名安装）。" style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]]];
    [self addCard:@[[self sectionHeading:@"工具"],
                    [self button:@"文件浏览 / 文本编辑" symbol:@"folder.badge.gearshape" style:STS2ButtonStyleSecondary action:@selector(openFileBrowser)],
                    [self button:@"云存档（WebDAV）" symbol:@"icloud" style:STS2ButtonStyleSecondary action:@selector(openCloudSaves)],
                    [self button:@"Nexus Mods 商店" symbol:@"bag" style:STS2ButtonStyleSecondary action:@selector(openNexus)],
                    [self button:@"Steam 账号" symbol:@"person.crop.circle" style:STS2ButtonStyleSecondary action:@selector(openSteamAccount)],
                    [self button:[NSString stringWithFormat:@"日志等级：%@（在「日志」页修改）", @[@"调试", @"信息", @"警告", @"错误"][STS2Log.minimumLevel]] symbol:@"slider.horizontal.3" style:STS2ButtonStyleSecondary action:@selector(openLogs)]]];
    [self addCard:@[[self sectionHeading:@"关于"],
                    [self label:version style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:[NSString stringWithFormat:@"主题：%@", STS2ThemeName] style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:@"语言、画质、帧率等游戏设置请在游戏内调整；iPad 只有 Metal 渲染器，没有渲染器切换。" style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft],
                    [self label:@"本项目与 MegaCrit 无关，需自备正版游戏。启动游戏后，存档与 MOD 管理需完全关闭应用再打开。" style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft]]];
}
- (void)renderNetworkPage {
    [self.content addArrangedSubview:[self pageTitle:@"联机小屋" tagline:@"和朋友一起爬塔，不在一个 Wi‑Fi 也行"]];
    BOOL continuing = [self hasMultiplayerSave];
    NSMutableArray *profile = [NSMutableArray arrayWithObject:[self sectionHeading:@"昵称"]];
    self.nicknameField = [self field:@"房间名会显示为“昵称的房间”。" value:self.config.nickname keyboard:UIKeyboardTypeDefault into:profile];
    [profile addObject:[self button:@"保存" symbol:@"checkmark.circle" style:STS2ButtonStyleSecondary action:@selector(saveNickname)]];
    [profile addObject:[self label:[NSString stringWithFormat:@"本机联机身份 ID：%@\n继续多人存档时需与创建存档时一致；换设备会生成新的 ID。", self.config.playerId] style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]];
    [self addCard:profile];

    [self addCard:@[[self sectionHeading:@"创建房间"],
                    [self button:@"创建房间" symbol:@"plus.circle.fill" style:STS2ButtonStylePrimary action:@selector(createRoomTapped)],
                    [self label:continuing ? @"你有未完成的多人存档，创建房间将继续这一局。" : @"创建后直接进入选角色界面，朋友在这里就能看到你的房间。"
                          style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft],
                    [self label:@"开房需要联机服务器的令牌（只保存在本机钥匙串，不进备份、日志或导出）；加入房间不需要令牌。" style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]]];

    UILabel *heading = [self sectionHeading:@"在线房间"];
    UIButton *refresh = [self button:@"刷新" symbol:@"arrow.clockwise" style:STS2ButtonStyleSecondary action:@selector(refreshRooms)];
    refresh.enabled = !self.scanningRooms;
    [refresh setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[heading, refresh]];
    header.alignment = UIStackViewAlignmentCenter; header.spacing = 12;
    [self.content addArrangedSubview:header];

    if (self.scanningRooms && !self.rooms.count) [self addText:@"正在查找房间…"];
    else if (!self.rooms.count) [self addText:@"暂时没有在线房间，创建一个吧。"];
    NSString *myVersion = STS2RoomService.shared.gameVersion;
    NSDateFormatter *time = [NSDateFormatter new]; time.dateFormat = @"HH:mm";
    [self.rooms enumerateObjectsUsingBlock:^(NSDictionary *room, NSUInteger index, BOOL *stop) {
        BOOL sameVersion = [room[@"version"] isEqual:myVersion];
        NSMutableString *details = [NSMutableString stringWithFormat:@"%@ · 游戏 %@", [STS2RoomService platformLabel:room[@"platform"]], room[@"version"]];
        if (!sameVersion) [details appendFormat:@" · 你的版本 %@", myVersion];
        if ([room[@"created"] isKindOfClass:NSNumber.class])
            [details appendFormat:@" · %@ 创建", [time stringFromDate:[NSDate dateWithTimeIntervalSince1970:[room[@"created"] doubleValue]]]];
        if ([room[@"continuing"] boolValue]) [details appendString:@" · 继续存档"];
        UIButton *join = [self button:sameVersion ? @"加入游戏" : @"版本不同" symbol:@"person.2.fill" style:STS2ButtonStylePrimary action:@selector(joinRoomTapped:)];
        join.tag = index; join.enabled = sameVersion;
        [self addCard:@[[self label:room[@"name"] style:UIFontTextStyleTitle3 bold:YES color:STS2Theme.ink],
                        [self label:details style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft],
                        join]];
    }];

    NSMutableArray *lan = [NSMutableArray arrayWithObject:[self sectionHeading:@"局域网直连"]];
    [lan addObject:[self label:@"同一 Wi‑Fi 下不经过服务器：房主点「局域网开房」，其他人填房主的局域网 IP 和端口后点「直连加入」。访客网络/AP 隔离会阻止设备互访；首次使用需允许“本地网络”权限。" style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft]];
    self.lanHostField = [self field:@"房主 IP / 主机名" value:self.config.host keyboard:UIKeyboardTypeURL into:lan];
    self.lanPortField = [self field:@"UDP 端口（默认 33771，房主也用这个端口开房）" value:[NSString stringWithFormat:@"%ld", (long)self.config.port] keyboard:UIKeyboardTypeNumberPad into:lan];
    [lan addObject:[self button:@"直连加入" symbol:@"link" style:STS2ButtonStylePrimary action:@selector(lanJoinTapped)]];
    [lan addObject:[self button:@"局域网开房" symbol:@"wifi" style:STS2ButtonStyleSecondary action:@selector(lanHostTapped)]];
    NSString *addresses = [self localAddresses];
    if (addresses.length) [lan addObject:[self label:[@"本机局域网地址：" stringByAppendingString:addresses] style:UIFontTextStyleFootnote bold:NO color:STS2Theme.inkSoft]];
    [self addCard:lan];
}
- (UITextField *)field:(NSString *)title value:(NSString *)value keyboard:(UIKeyboardType)keyboard into:(NSMutableArray *)views {
    [views addObject:[self label:title style:UIFontTextStyleHeadline bold:YES color:STS2Theme.ink]];
    UITextField *f = [UITextField new]; f.text = value; f.placeholder = title; f.accessibilityLabel = title; f.borderStyle = UITextBorderStyleRoundedRect; f.font = [STS2Theme font:UIFontTextStyleBody bold:NO]; f.textColor = STS2Theme.ink; f.tintColor = STS2Theme.cat; f.backgroundColor = STS2Theme.background; f.adjustsFontForContentSizeCategory = YES; f.keyboardType = keyboard; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; [f.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES; [views addObject:f]; return f;
}

#pragma mark - Actions

- (void)setState:(StS2LauncherState)state { _state = state; if (self.isViewLoaded) [self renderPage]; }
- (void)message:(NSString *)message { UIAlertController *a = [UIAlertController alertControllerWithTitle:STS2ThemeName message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; a.view.tintColor = STS2Theme.cat; [self presentViewController:a animated:YES completion:nil]; }
- (void)error:(NSString *)message tag:(NSString *)tag detail:(id)detail {
    // 规范 §5.1：任何展示给用户的错误提示都先写一条 E 日志。
    [STS2Log log:STS2LogLevelError tag:tag message:message detail:detail];
    [self message:message];
}
- (void)showStartFailure:(NSString *)message {
    [STS2Log log:STS2LogLevelError tag:STS2LogTagLaunch message:[@"启动失败：" stringByAppendingString:message]];
    [STS2LaunchMarker clear];
    self.state = StS2LauncherStateFailed; [self message:message];
}
- (BOOL)canStartGame {
    if (self.busy || self.state != StS2LauncherStateLauncher) return NO;
    if ([self.modsController isKindOfClass:STS2ModsViewController.class] && ((STS2ModsViewController *)self.modsController).hasPendingOperations) {
        [STS2Log log:STS2LogLevelWarn tag:STS2LogTagLaunch message:@"MOD 正在处理文件，暂不启动"];
        [self message:@"MOD 正在处理文件，请等待操作完成后再启动游戏。"];
        return NO;
    }
    STS2WorkshopViewController *workshop = (STS2WorkshopViewController *)self.embeddedControllers[@(PageWorkshop)];
    if ([workshop isKindOfClass:STS2WorkshopViewController.class] && workshop.hasPendingOperations) {
        [STS2Log log:STS2LogLevelWarn tag:STS2LogTagLaunch message:@"工坊正在下载，暂不启动"];
        [self message:@"创意工坊正在下载，请等下载完成或取消后再启动游戏。"];
        return NO;
    }
    if (![self availableGamePackSource]) { [self error:@"未找到引擎配置所需的 StS2.pck 游戏素材包，请放入对应位置后重试。" tag:STS2LogTagLaunch detail:nil]; return NO; }
    return YES;
}
- (void)startTapped { if ([self canStartGame]) [self launchGame:@"开始游戏"]; }
// Launcher/Mods/index.json（STS2ModStore）里的记录，按启用状态分组：「名字@版本」。
- (NSDictionary<NSString *, NSArray<NSString *> *> *)modSummary {
    NSData *data = [NSData dataWithContentsOfURL:[self.documents URLByAppendingPathComponent:@"Launcher/Mods/index.json"]];
    NSArray *records = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray *enabled = [NSMutableArray array], *disabled = [NSMutableArray array];
    for (NSDictionary *record in [records isKindOfClass:NSArray.class] ? records : @[]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [record[@"displayName"] isKindOfClass:NSString.class] ? record[@"displayName"] : [record[@"id"] description];
        NSDictionary *manifest = [record[@"manifest"] isKindOfClass:NSDictionary.class] ? record[@"manifest"] : nil;
        NSString *version = [manifest[@"version"] isKindOfClass:NSString.class] ? manifest[@"version"] : @"?";
        [([record[@"enabled"] boolValue] ? enabled : disabled) addObject:[NSString stringWithFormat:@"%@@%@", name, version]];
    }
    return @{@"enabled": enabled, @"disabled": disabled};
}
- (NSArray<NSString *> *)enabledResourceMods { return [self modSummary][@"enabled"]; }
- (NSDictionary *)launchInfo:(NSString *)reason {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return @{@"reason": reason, @"gameVersion": STS2RoomService.shared.gameVersion,
             @"launcherVersion": [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"],
             @"profile": @"默认（iPad 单配置）", @"pack": [self availableGamePackSource] ?: @"-", @"resourceMods": [self enabledResourceMods]};
}
// 所有「进入游戏」都走这里：启动前快照（可在设置关闭）→ 写 launch-marker → 交给 Scene 启动引擎。
- (void)launchGame:(NSString *)reason {
    if (![self canStartGame]) return;
    BOOL snapshot = [self launcherBool:@"preLaunchSnapshot" fallback:YES] && ![self.saveSummary[@"empty"] boolValue];
    void (^start)(void) = ^{
        NSDictionary *info = [self launchInfo:reason];
        [STS2LaunchMarker writeWithInfo:info];
        STS2LogI(STS2LogTagLaunch, @"启动游戏（%@）：版本 %@，素材 %@，资源 MOD %@", reason, info[@"gameVersion"], info[@"pack"], [info[@"resourceMods"] count] ? [info[@"resourceMods"] componentsJoinedByString:@"、"] : @"无");
        if (self.startHandler) self.startHandler();
    };
    void (^go)(void) = ^{ [self pullCloudSavesBeforeLaunch:start]; };
    if (!snapshot) { go(); return; }
    self.busy = YES; self.view.userInteractionEnabled = NO;
    dispatch_async(self.ioQueue, ^{
        NSError *error = nil;
        NSURL *url = [self.saves createSnapshotWithName:@"启动前自动快照" error:&error];
        NSUInteger pruned = url ? [self.saves pruneSnapshotsTitled:@"启动前自动快照" keep:5] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO; self.view.userInteractionEnabled = YES;
            if (url) { STS2LogI(STS2LogTagSaves, @"已创建启动前快照 %@（清理旧快照 %lu 个）", url.lastPathComponent, (unsigned long)pruned); go(); return; }
            BOOL noSave = [error.domain isEqualToString:@"STS2SaveArchiveStore"] && error.code == 4;
            if (noSave) { STS2LogI(STS2LogTagSaves, @"当前没有存档，跳过启动前快照"); go(); return; }
            [STS2Log log:STS2LogLevelError tag:STS2LogTagSaves message:@"启动前快照失败" detail:error];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"启动前快照失败" message:[error.localizedDescription stringByAppendingString:@"\n仍要启动游戏吗？"] preferredStyle:UIAlertControllerStyleAlert];
            a.view.tintColor = STS2Theme.cat;
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [NSFileManager.defaultManager removeItemAtURL:[STS2PendingAction fileURLForDocuments:self.documents] error:nil]; [STS2FrpTunnel.shared stop]; }]];
            [a addAction:[UIAlertAction actionWithTitle:@"仍然启动" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { go(); }]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}
// 自动同步开启时，开始游戏前先从云端拉取；冲突交给用户选择。
- (void)pullCloudSavesBeforeLaunch:(dispatch_block_t)start {
    if (![STS2CloudSaveViewController autoSyncEnabled:self.config]) { start(); return; }
    STS2WebDavSync *sync = [STS2CloudSaveViewController syncWithConfig:self.config documentsURL:self.documents];
    self.busy = YES; self.view.userInteractionEnabled = NO;
    dispatch_async(self.ioQueue, ^{
        NSError *error = nil;
        NSString *result = [sync pull:NO progress:nil error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO; self.view.userInteractionEnabled = YES;
            if (result) { start(); return; }
            BOOL conflict = [error.domain isEqual:STS2WebDavErrorDomain] && error.code == STS2WebDavErrorConflict;
            [STS2Log log:conflict ? STS2LogLevelWarn : STS2LogLevelError tag:STS2LogTagCloud message:@"启动前云存档拉取未完成" detail:error];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:conflict ? @"云存档冲突" : @"云存档拉取失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            a.view.tintColor = STS2Theme.cat;
            [a addAction:[UIAlertAction actionWithTitle:@"取消启动" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [NSFileManager.defaultManager removeItemAtURL:[STS2PendingAction fileURLForDocuments:self.documents] error:nil]; [STS2FrpTunnel.shared stop]; }]];
            if (conflict) [a addAction:[UIAlertAction actionWithTitle:@"用云端覆盖本机再启动" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
                dispatch_async(self.ioQueue, ^{
                    NSError *e = nil; NSString *r = [sync pull:YES progress:nil error:&e];
                    dispatch_async(dispatch_get_main_queue(), ^{ if (!r) [self error:[@"强制拉取失败：" stringByAppendingString:e.localizedDescription ?: @""] tag:STS2LogTagCloud detail:e]; else start(); });
                });
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"保留本机存档启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { start(); }]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}
- (BOOL)launcherBool:(NSString *)key fallback:(BOOL)fallback {
    id value = [self.config launcherSettingForKey:key];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}
- (void)performIO:(id(^)(NSError **))operation completion:(void(^)(id))completion {
    if (self.busy || self.state != StS2LauncherStateLauncher) return;
    self.busy = YES; self.view.userInteractionEnabled = NO;
    dispatch_async(self.ioQueue, ^{ NSError *error = nil; id result = operation(&error); dispatch_async(dispatch_get_main_queue(), ^{ self.busy = NO; self.view.userInteractionEnabled = YES; if (error) [self error:error.localizedDescription tag:STS2LogTagSaves detail:error]; else if (completion) completion(result); }); });
}
- (void)refreshSaves {
    [self performIO:^id(NSError **error) { return @{@"summary": [self.saves currentSaveSummary], @"snapshots": [self.saves snapshots]}; } completion:^(NSDictionary *result) { self.saveSummary = result[@"summary"]; self.snapshots = result[@"snapshots"]; if (self.selectedPage == PageSaves) [self renderPage]; }];
}
- (void)backupTapped { [self performIO:^id(NSError **error) { return [self.saves createSnapshotWithName:@"手动快照" error:error]; } completion:^(id result) { STS2LogI(STS2LogTagSaves, @"已创建手动快照"); [self refreshSaves]; }]; }
- (void)preLaunchSnapshotChanged:(UISwitch *)sender { [self.config setLauncherSetting:@(sender.on) forKey:@"preLaunchSnapshot" error:nil]; STS2LogI(STS2LogTagSaves, @"启动前自动快照：%@", sender.on ? @"开" : @"关"); }
- (void)autoUpdateChanged:(UISwitch *)sender { [self.config setLauncherSetting:@(sender.on) forKey:@"autoUpdateCheck" error:nil]; }
- (void)snapshotTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.snapshots.count) return;
    NSDictionary *snapshot = self.snapshots[sender.tag];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:snapshot[@"title"] ?: snapshot[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = STS2Theme.cat;
    [sheet addAction:[UIAlertAction actionWithTitle:@"恢复这份快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self confirmRestore:snapshot[@"path"]]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享 / 存到“文件”" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[snapshot[@"path"]] applicationActivities:nil];
        share.popoverPresentationController.sourceView = sender; share.popoverPresentationController.sourceRect = sender.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除快照" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"删除快照？" message:@"删除后无法恢复这份快照。" preferredStyle:UIAlertControllerStyleAlert];
        confirm.view.tintColor = STS2Theme.cat;
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self performIO:^id(NSError **error) { return [self.saves deleteSnapshotAtURL:snapshot[@"path"] error:error] ? @YES : nil; } completion:^(id r) { STS2LogI(STS2LogTagSaves, @"删除快照 %@", [snapshot[@"path"] lastPathComponent]); [self refreshSaves]; }];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender; sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)checkUpdatesTapped { [self checkUpdatesQuietly:NO]; }
- (void)checkUpdatesQuietly:(BOOL)quiet {
    NSString *current = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    [STS2UpdateChecker checkCurrentVersion:current completion:^(NSDictionary *info, NSError *error) {
        if (error) { if (!quiet) [self message:[@"检查更新失败：" stringByAppendingString:error.localizedDescription]]; return; }
        if (![info[@"newer"] boolValue]) { if (!quiet) [self message:[NSString stringWithFormat:@"已是最新版本（%@）。", current]]; return; }
        if (self.presentedViewController) return;
        NSString *body = [info[@"body"] length] > 600 ? [[info[@"body"] substringToIndex:600] stringByAppendingString:@"…"] : info[@"body"];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"发现新版本 %@%@", info[@"version"], [info[@"prerelease"] boolValue] ? @"（预发布）" : @""] message:[body length] ? body : info[@"title"] preferredStyle:UIAlertControllerStyleAlert];
        a.view.tintColor = STS2Theme.cat;
        [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"打开发布页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSURL *url = [NSURL URLWithString:info[@"url"]];
            if ([url.scheme.lowercaseString isEqual:@"https"]) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }];
}
- (void)openFileBrowser {
    if (self.state != StS2LauncherStateLauncher) return;
    STS2PresentSheet(self, [[STS2FileBrowserViewController alloc] initWithDirectory:self.documents root:self.documents]);
}
- (void)openLogs { [self selectPage:PageLogs]; }
- (void)openCloudSaves {
    if (self.state != StS2LauncherStateLauncher) return;
    STS2CloudSaveViewController *cloud = [[STS2CloudSaveViewController alloc] initWithConfig:self.config saves:self.saves documentsURL:self.documents ioQueue:self.ioQueue];
    STS2PresentSheet(self, cloud);
}
// 自动同步：打开启动器时把上次游戏的进度推上去；冲突只记日志，交给用户在云存档页处理。
- (void)autoPushCloudSaves {
    if (![STS2CloudSaveViewController autoSyncEnabled:self.config]) return;
    STS2WebDavSync *sync = [STS2CloudSaveViewController syncWithConfig:self.config documentsURL:self.documents];
    dispatch_async(self.ioQueue, ^{
        NSError *error = nil;
        NSString *result = [sync push:NO progress:nil error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) return;
            [STS2Log log:STS2LogLevelWarn tag:STS2LogTagCloud message:@"自动上传云存档未完成" detail:error];
            if (!self.presentedViewController) [self message:[@"自动上传云存档未完成：" stringByAppendingString:error.localizedDescription ?: @"未知错误"]];
        });
    });
}
- (void)openNexus { if (self.state == StS2LauncherStateLauncher) STS2PresentSheet(self, [[STS2NexusViewController alloc] initWithDocumentsURL:self.documents]); }
- (void)openSteamAccount {
    // Android 用 JavaSteam 实现了 Steam 客户端协议（CM 连接、Steam Guard、refresh token）。iPad 版尚未移植，
    // 不做半成品登录页：不收集任何 Steam 凭据。工坊下载与云存档已有不需要账号的替代路径。
    STS2FormViewController *form = [STS2FormViewController new];
    form.title = @"Steam 账号";
    form.builder = ^NSArray *(STS2FormViewController *f) {
        return @[[STS2FormSection sectionWithTitle:@"暂不支持" footer:nil rows:@[
                     [STS2FormRow infoWithTitle:@"iPad 版暂不支持登录 Steam 账号" detail:@"Steam 登录需要完整的 Steam 客户端协议（连接 Steam 服务器、Steam 令牌验证、长期登录凭据保管），Android 版依赖的 JavaSteam 没有 iOS 版本，尚未移植。为了安全，这里不提供任何输入 Steam 密码的界面。"]]],
                 [STS2FormSection sectionWithTitle:@"不需要账号的替代方式" footer:nil rows:@[
                     [STS2FormRow infoWithTitle:@"创意工坊" detail:@"浏览、按链接打开和下载都走公开接口，不需要登录。"],
                     [STS2FormRow infoWithTitle:@"云存档" detail:@"用 WebDAV 云存档与 Android / 电脑共用同一槽位；或在电脑上用 Steam 同步后导出 ZIP 再导入。"]]]];
    };
    STS2PresentSheet(self, form);
}
- (void)exportTapped:(UIButton *)sender {
    [self performIO:^id(NSError **error) { return [self.saves exportCurrentSave:error]; } completion:^(NSURL *url) {
        if (!url) return; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.popoverPresentationController.sourceView = sender; share.popoverPresentationController.sourceRect = sender.bounds; [self presentViewController:share animated:YES completion:nil];
    }];
}
- (void)importTapped { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES]; picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { if (urls.firstObject) [self confirmRestore:urls.firstObject]; }
- (void)confirmRestore:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"替换当前存档？" message:@"将先自动备份当前存档，再导入所选 ZIP。请确认这是要使用的账号进度。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"备份并恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performIO:^id(NSError **error) { BOOL access = [url startAccessingSecurityScopedResource]; BOOL ok = [self.saves restoreArchiveAtURL:url error:error]; if (access) [url stopAccessingSecurityScopedResource]; return @(ok); } completion:^(id result) { [self refreshSaves]; [self message:@"存档恢复完成。"]; }];
    }]]; [self presentViewController:a animated:YES completion:nil];
}
#pragma mark - Online rooms

- (BOOL)writePendingActionType:(NSString *)type online:(BOOL)online host:(NSString *)host port:(NSInteger)port {
    NSDictionary *action = [STS2PendingAction actionWithType:type online:online host:host port:port nickname:self.config.nickname playerId:self.config.playerId now:NSDate.date];
    NSError *error = nil;
    if ([STS2PendingAction writeAction:action documentsURL:self.documents error:&error]) return YES;
    [self error:[@"无法写入联机指令：" stringByAppendingString:error.localizedDescription ?: @"未知错误"] tag:STS2LogTagOnline detail:error];
    return NO;
}
- (BOOL)hasMultiplayerSave {
    NSURL *account = [[self.documents URLByAppendingPathComponent:@"default" isDirectory:YES] URLByAppendingPathComponent:@"1" isDirectory:YES];
    for (NSURL *profile in [NSFileManager.defaultManager contentsOfDirectoryAtURL:account includingPropertiesForKeys:nil options:0 error:nil]) {
        if (![profile.lastPathComponent hasPrefix:@"profile"]) continue;
        NSURL *save = [[profile URLByAppendingPathComponent:@"saves" isDirectory:YES] URLByAppendingPathComponent:@"current_run_mp.save"];
        if ([NSFileManager.defaultManager fileExistsAtPath:save.path] || [NSFileManager.defaultManager fileExistsAtPath:[save.path stringByAppendingString:@".backup"]]) return YES;
    }
    return NO;
}
- (NSString *)localAddresses {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return @"";
    for (struct ifaddrs *item = list; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET || !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
        NSString *name = @(item->ifa_name);
        if (![name hasPrefix:@"en"]) continue;
        char buffer[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)item->ifa_addr)->sin_addr, buffer, sizeof(buffer))) [result addObject:@(buffer)];
    }
    freeifaddrs(list);
    return [result componentsJoinedByString:@"、"];
}
- (void)refreshRooms {
    if (self.scanningRooms || self.state != StS2LauncherStateLauncher) return;
    self.scanningRooms = YES;
    if (self.selectedPage == PageNetwork) [self renderPage];
    [STS2RoomService.shared scanRooms:^(NSArray<NSDictionary *> *rooms) {
        self.scanningRooms = NO; self.rooms = rooms;
        if (self.selectedPage == PageNetwork && self.state == StS2LauncherStateLauncher) [self renderPage];
    }];
}
- (void)createRoomTapped {
    if (![self canStartGame]) return;
    NSString *saved = [STS2SecretStore secretForKey:STS2SecretFrpToken];
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"创建房间" message:@"输入联机服务器的令牌（token）。令牌只保存在本机钥匙串。" preferredStyle:UIAlertControllerStyleAlert];
    prompt.view.tintColor = STS2Theme.cat;
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"frp 令牌"; field.secureTextEntry = YES; field.text = saved.length ? saved : STS2RoomService.shared.defaultToken;
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *token = [weakPrompt.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!token.length) { [self error:@"开房需要 frp 令牌，请向服务器管理员索取。" tag:STS2LogTagOnline detail:nil]; return; }
        [self createRoomWithToken:token];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)createRoomWithToken:(NSString *)token {
    if (![self canStartGame]) return;
    self.busy = YES; self.view.userInteractionEnabled = NO;
    BOOL continuing = [self hasMultiplayerSave];
    STS2LogI(STS2LogTagOnline, @"创建在线房间：昵称 %@，本机 UDP %ld，%@", self.config.nickname, (long)self.config.port, continuing ? @"续局" : @"新局");
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在创建房间…" message:@"连接联机服务器" preferredStyle:UIAlertControllerStyleAlert];
    progress.view.tintColor = STS2Theme.cat;
    [self presentViewController:progress animated:YES completion:^{
        [STS2RoomService.shared createRoomWithNickname:self.config.nickname token:token localPort:self.config.port continuing:continuing completion:^(NSDictionary *room, NSError *error) {
            self.busy = NO; self.view.userInteractionEnabled = YES;
            [progress dismissViewControllerAnimated:YES completion:^{
                if (error) { [self error:[@"创建房间失败：" stringByAppendingString:error.localizedDescription] tag:STS2LogTagOnline detail:error]; return; }
                NSError *saveError = nil;
                if (![STS2SecretStore setSecret:token forKey:STS2SecretFrpToken error:&saveError]) STS2LogW(STS2LogTagOnline, @"令牌未能保存到钥匙串，下次需要重新输入");
                if ([self writePendingActionType:@"host" online:YES host:nil port:0]) [self launchGame:@"在线开房"];
                else [STS2FrpTunnel.shared stop];
            }];
        }];
    }];
}
- (void)joinRoomTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.rooms.count || ![self canStartGame]) return;
    NSDictionary *room = self.rooms[sender.tag];
    if (![room[@"version"] isEqual:STS2RoomService.shared.gameVersion]) {
        [self error:[NSString stringWithFormat:@"版本不同：房间是 %@，你的版本是 %@。跨版本无法联机。", room[@"version"], STS2RoomService.shared.gameVersion] tag:STS2LogTagOnline detail:nil];
        return;
    }
    STS2LogI(STS2LogTagOnline, @"加入在线房间「%@」（%@，槽位 %@）", room[@"name"], [STS2RoomService platformLabel:room[@"platform"]], room[@"slot"]);
    if ([self writePendingActionType:@"join" online:YES host:STS2RoomService.shared.server port:[room[@"port"] integerValue]]) [self launchGame:@"加入在线房间"];
}
- (BOOL)saveLanFields {
    NSString *host = [self.lanHostField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSInteger port = [self.lanPortField.text integerValue];
    if (port < 1 || port > 65535) { [self error:@"请输入 1–65535 的 UDP 端口。" tag:STS2LogTagOnline detail:nil]; return NO; }
    if ([host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound || host.length > 253) {
        [self error:@"房主地址不能包含空格。" tag:STS2LogTagOnline detail:nil]; return NO;
    }
    self.config.host = host; self.config.port = port;
    NSError *error = nil;
    if (![self.config save:&error]) { [self error:[@"保存联机设置失败：" stringByAppendingString:error.localizedDescription] tag:STS2LogTagOnline detail:error]; return NO; }
    return YES;
}
- (void)lanJoinTapped {
    [self.view endEditing:YES];
    if (![self canStartGame] || ![self saveLanFields]) return;
    if (!self.config.host.length) { [self error:@"请输入房主的局域网 IP 或主机名。" tag:STS2LogTagOnline detail:nil]; return; }
    if ([self writePendingActionType:@"join" online:NO host:self.config.host port:self.config.port]) [self launchGame:@"局域网直连加入"];
}
- (void)lanHostTapped {
    [self.view endEditing:YES];
    if (![self canStartGame] || ![self saveLanFields]) return;
    if ([self writePendingActionType:@"host" online:NO host:nil port:0]) [self launchGame:@"局域网开房"];
}
- (void)saveNickname {
    NSString *nickname = [self.nicknameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.config.nickname = nickname.length ? [nickname substringToIndex:MIN(nickname.length, (NSUInteger)16)] : @"玩家";
    [self.view endEditing:YES];
    [self performIO:^id(NSError **error) { return @([self.config save:error]); } completion:^(id result) { STS2LogI(STS2LogTagOnline, @"昵称已保存：%@", self.config.nickname); [self message:@"昵称已保存。"]; }];
}
@end

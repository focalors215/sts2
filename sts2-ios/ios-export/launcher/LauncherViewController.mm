#import "LauncherViewController.h"
#import "STS2LauncherConfigStore.h"
#import "STS2SaveArchiveStore.h"
#import "STS2ModsViewController.h"
#import "STS2Theme.h"
#import "STS2LauncherArt.h"
#import "STS2RoomService.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// 主题：喵喵零和小鱼的小屋（配色与组件见 STS2Theme）。
enum { PageHome, PageSaves, PageMods, PageNetwork, PageSettings };
static NSArray<NSString *> *PageNames() { return @[ @"回到小屋", @"存档管理", @"本地 MOD", @"联机小屋", @"设置" ]; }
static NSArray<NSString *> *PageSymbols() { return @[ @"house.fill", @"folder.fill", @"puzzlepiece.extension.fill", @"network", @"gearshape.fill" ]; }

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
@property(nonatomic, strong) UIStackView *modContainer;
@property(nonatomic, strong) UIViewController *modsController;
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
@property(nonatomic, strong) NSArray<NSDictionary *> *rooms;
@property(nonatomic) BOOL scanningRooms;
@property(nonatomic, strong) NSArray<NSDictionary *> *snapshots;
@property(nonatomic, strong) NSDictionary *saveSummary;
@property(nonatomic) NSInteger selectedPage;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) dispatch_queue_t ioQueue;
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
    // A room action the game never consumed (e.g. the app was closed) must not fire later.
    [NSFileManager.defaultManager removeItemAtURL:self.pendingActionURL error:nil];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"小屋", @"存档", @"MOD", @"联机", @"设置"]];
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
    self.modContainer = [UIStackView new]; self.modContainer.axis = UILayoutConstraintAxisVertical; self.modContainer.spacing = 12;
    self.modContainer.layoutMarginsRelativeArrangement = YES; self.modContainer.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(24, 0, 0, 0); self.modContainer.hidden = YES;
    // Indent the title to line up with the inset-grouped table's cards below it.
    // 标题缩进，与下方 inset-grouped 表格的卡片左边对齐。
    UIView *modTitleRow = [UIView new]; UIView *modTitle = [self pageTitle:@"本地 MOD" tagline:@"给小屋添点新花样"]; modTitle.translatesAutoresizingMaskIntoConstraints = NO; [modTitleRow addSubview:modTitle];
    [NSLayoutConstraint activateConstraints:@[[modTitle.leadingAnchor constraintEqualToAnchor:modTitleRow.leadingAnchor constant:20], [modTitle.trailingAnchor constraintEqualToAnchor:modTitleRow.trailingAnchor], [modTitle.topAnchor constraintEqualToAnchor:modTitleRow.topAnchor], [modTitle.bottomAnchor constraintEqualToAnchor:modTitleRow.bottomAnchor]]];
    // 多余高度交给下面的表格，标题行保持自身高度。
    [modTitleRow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [modTitleRow setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.modContainer addArrangedSubview:modTitleRow];
    self.layout = [[UIStackView alloc] initWithArrangedSubviews:@[self.sidebar, self.tabs, self.scroll, self.modContainer]];
    self.layout.spacing = 16; self.layout.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.layout];
    [NSLayoutConstraint activateConstraints:@[[self.layout.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16], [self.layout.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16], [self.layout.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16], [self.layout.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self.sidebar.widthAnchor constraintEqualToConstant:220].active = YES;
    [self registerForTraitChanges:@[UITraitHorizontalSizeClass.class] withHandler:^(__kindof id<UITraitEnvironment> environment, UITraitCollection *previous) { [(LauncherViewController *)environment updateLayout]; }];
    [self buildStage];
    [self updateLayout]; [self renderPage]; [self refreshSaves];
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
    self.scroll.hidden = self.selectedPage == PageMods; self.modContainer.hidden = self.selectedPage != PageMods;
    for (UIView *v in self.content.arrangedSubviews) { [self.content removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (self.selectedPage == PageHome) {
        [self renderGamePage]; // 横屏时被插画主页盖住，窄屏时作为后备主页
    } else if (self.selectedPage == PageSaves) {
        [self renderSavePage];
    } else if (self.selectedPage == PageMods) {
        if (!self.modsController) {
            self.modsController = self.modContentProvider ? self.modContentProvider() : nil;
            if (!self.modsController) self.modsController = [[STS2ModsViewController alloc] initWithDocumentsURL:self.documents];
            // A table controller needs a full-height container, not a zero-height view
            // inside the launcher's scroll stack. Keep it alive across page switches.
            [self addChildViewController:self.modsController];
            [self.modsController.view setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
            [self.modContainer addArrangedSubview:self.modsController.view];
            [self.modsController didMoveToParentViewController:self];
        }
    } else if (self.selectedPage == PageNetwork) {
        [self renderNetworkPage];
    } else {
        [self renderSettingsPage];
    }
    [self applyMode];
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
                    [self button:@"创建本地备份" symbol:@"plus.circle" style:STS2ButtonStyleSecondary action:@selector(backupTapped)]]];
    [self.content addArrangedSubview:[self sectionHeading:@"本地备份"]];
    if (!self.snapshots.count) [self addText:@"暂无备份。导入或恢复时会先自动备份已有存档。"];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.snapshots.count; i++) {
        NSDictionary *snapshot = self.snapshots[i];
        UIButton *b = [self button:snapshot[@"name"] symbol:@"clock.arrow.circlepath" style:STS2ButtonStyleSecondary action:@selector(restoreTapped:)]; b.tag = i; [rows addObject:b];
    }
    if (rows.count) [self addCard:rows];
}
- (void)renderSettingsPage {
    [self.content addArrangedSubview:[self pageTitle:@"设置" tagline:@"小屋的小角落"]];
    NSString *packSource = [self availableGamePackSource];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [NSString stringWithFormat:@"启动器 %@（%@）", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    [self addCard:@[[self sectionHeading:@"游戏素材"],
                    [self label:packSource ? [NSString stringWithFormat:@"已找到游戏素材：%@", packSource] : @"尚未找到可用的 StS2.pck 游戏素材包。请放入应用文档目录后重新打开。" style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:@"使用你自己的正版游戏素材。" style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft]]];
    NSMutableArray *profile = [NSMutableArray arrayWithObject:[self sectionHeading:@"联机昵称"]];
    self.nicknameField = [self field:@"昵称（房间名会显示为“昵称的房间”）" value:self.config.nickname keyboard:UIKeyboardTypeDefault into:profile];
    [profile addObject:[self button:@"保存昵称" symbol:@"checkmark.circle" style:STS2ButtonStyleSecondary action:@selector(saveNickname)]];
    [self addCard:profile];
    [self addCard:@[[self sectionHeading:@"关于"],
                    [self label:version style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:[NSString stringWithFormat:@"主题：%@", STS2ThemeName] style:UIFontTextStyleBody bold:NO color:STS2Theme.ink],
                    [self label:@"本项目与 MegaCrit 无关，需自备正版游戏。启动游戏后，存档与 MOD 管理需完全关闭应用再打开。" style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft]]];
}
- (void)renderNetworkPage {
    [self.content addArrangedSubview:[self pageTitle:@"联机小屋" tagline:@"和朋友一起爬塔"]];
    BOOL continuing = [self hasMultiplayerSave];
    [self addCard:@[[self button:@"创建房间" symbol:@"plus.circle.fill" style:STS2ButtonStylePrimary action:@selector(createRoomTapped)],
                    [self label:continuing ? @"你有未完成的多人存档，创建房间将继续这一局。" : @"创建后直接进入选角色界面，朋友在这里就能看到你的房间。"
                          style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft]]];

    UILabel *heading = [self sectionHeading:@"在线房间"];
    UIButton *refresh = [self button:@"刷新" symbol:@"arrow.clockwise" style:STS2ButtonStyleSecondary action:@selector(refreshRooms)];
    refresh.enabled = !self.scanningRooms;
    [refresh setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[heading, refresh]];
    header.alignment = UIStackViewAlignmentCenter; header.spacing = 12;
    [self.content addArrangedSubview:header];

    if (self.scanningRooms && !self.rooms.count) { [self addText:@"正在查找房间…"]; return; }
    if (!self.rooms.count) { [self addText:@"暂时没有在线房间，创建一个吧。"]; return; }
    NSString *myVersion = STS2RoomService.shared.gameVersion;
    NSDateFormatter *time = [NSDateFormatter new]; time.dateFormat = @"HH:mm";
    [self.rooms enumerateObjectsUsingBlock:^(NSDictionary *room, NSUInteger index, BOOL *stop) {
        BOOL sameVersion = [room[@"version"] isEqual:myVersion];
        NSMutableArray *details = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"版本 %@", room[@"version"]]];
        if ([room[@"created"] isKindOfClass:NSNumber.class])
            [details addObject:[NSString stringWithFormat:@"%@ 创建", [time stringFromDate:[NSDate dateWithTimeIntervalSince1970:[room[@"created"] doubleValue]]]]];
        if ([room[@"continuing"] boolValue]) [details addObject:@"继续存档"];
        UIButton *join = [self button:sameVersion ? @"加入游戏" : @"版本不同" symbol:@"person.2.fill" style:STS2ButtonStylePrimary action:@selector(joinRoomTapped:)];
        join.tag = index; join.enabled = sameVersion;
        [self addCard:@[[self label:room[@"name"] style:UIFontTextStyleTitle3 bold:YES color:STS2Theme.ink],
                        [self label:[details componentsJoinedByString:@" · "] style:UIFontTextStyleSubheadline bold:NO color:STS2Theme.inkSoft],
                        join]];
    }];
}
- (UITextField *)field:(NSString *)title value:(NSString *)value keyboard:(UIKeyboardType)keyboard into:(NSMutableArray *)views {
    [views addObject:[self label:title style:UIFontTextStyleHeadline bold:YES color:STS2Theme.ink]];
    UITextField *f = [UITextField new]; f.text = value; f.placeholder = title; f.accessibilityLabel = title; f.borderStyle = UITextBorderStyleRoundedRect; f.font = [STS2Theme font:UIFontTextStyleBody bold:NO]; f.textColor = STS2Theme.ink; f.tintColor = STS2Theme.cat; f.backgroundColor = STS2Theme.background; f.adjustsFontForContentSizeCategory = YES; f.keyboardType = keyboard; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; [f.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES; [views addObject:f]; return f;
}

#pragma mark - Actions

- (void)setState:(StS2LauncherState)state { _state = state; if (self.isViewLoaded) [self renderPage]; }
- (void)message:(NSString *)message { UIAlertController *a = [UIAlertController alertControllerWithTitle:STS2ThemeName message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; a.view.tintColor = STS2Theme.cat; [self presentViewController:a animated:YES completion:nil]; }
- (void)showStartFailure:(NSString *)message { self.state = StS2LauncherStateFailed; [self message:message]; }
- (BOOL)canStartGame {
    if (self.busy || self.state != StS2LauncherStateLauncher) return NO;
    if ([self.modsController isKindOfClass:STS2ModsViewController.class] && ((STS2ModsViewController *)self.modsController).hasPendingOperations) {
        [self message:@"MOD 正在处理文件，请等待操作完成后再启动游戏。"];
        return NO;
    }
    if (![self availableGamePackSource]) { [self message:@"未找到引擎配置所需的 StS2.pck 游戏素材包，请放入对应位置后重试。"]; return NO; }
    return YES;
}
- (void)startTapped {
    if ([self canStartGame] && self.startHandler) self.startHandler();
}
- (void)performIO:(id(^)(NSError **))operation completion:(void(^)(id))completion {
    if (self.busy || self.state != StS2LauncherStateLauncher) return;
    self.busy = YES; self.view.userInteractionEnabled = NO;
    dispatch_async(self.ioQueue, ^{ NSError *error = nil; id result = operation(&error); dispatch_async(dispatch_get_main_queue(), ^{ self.busy = NO; self.view.userInteractionEnabled = YES; if (error) [self message:error.localizedDescription]; else if (completion) completion(result); }); });
}
- (void)refreshSaves {
    [self performIO:^id(NSError **error) { return @{@"summary": [self.saves currentSaveSummary], @"snapshots": [self.saves snapshots]}; } completion:^(NSDictionary *result) { self.saveSummary = result[@"summary"]; self.snapshots = result[@"snapshots"]; if (self.selectedPage == PageSaves) [self renderPage]; }];
}
- (void)backupTapped { [self performIO:^id(NSError **error) { return [self.saves createSnapshotWithName:@"手动备份" error:error]; } completion:^(id result) { [self refreshSaves]; }]; }
- (void)exportTapped:(UIButton *)sender {
    [self performIO:^id(NSError **error) { return [self.saves exportCurrentSave:error]; } completion:^(NSURL *url) {
        if (!url) return; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.popoverPresentationController.sourceView = sender; share.popoverPresentationController.sourceRect = sender.bounds; [self presentViewController:share animated:YES completion:nil];
    }];
}
- (void)importTapped { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES]; picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { if (urls.firstObject) [self confirmRestore:urls.firstObject]; }
- (void)restoreTapped:(UIButton *)sender { if (sender.tag >= 0 && (NSUInteger)sender.tag < self.snapshots.count) [self confirmRestore:self.snapshots[sender.tag][@"path"]]; }
- (void)confirmRestore:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"替换当前存档？" message:@"将先自动备份当前存档，再导入所选 ZIP。请确认这是要使用的账号进度。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"备份并恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performIO:^id(NSError **error) { BOOL access = [url startAccessingSecurityScopedResource]; BOOL ok = [self.saves restoreArchiveAtURL:url error:error]; if (access) [url stopAccessingSecurityScopedResource]; return @(ok); } completion:^(id result) { [self refreshSaves]; [self message:@"存档恢复完成。"]; }];
    }]]; [self presentViewController:a animated:YES completion:nil];
}
#pragma mark - Online rooms

// One-shot action read (and deleted) by the game's RemoteRoomPatches on the main menu.
- (NSURL *)pendingActionURL { return [[self.documents URLByAppendingPathComponent:@"Launcher" isDirectory:YES] URLByAppendingPathComponent:@"pending-action.json"]; }
- (BOOL)writePendingAction:(NSDictionary *)action {
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:self.pendingActionURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:action options:0 error:&error];
    if (data && [data writeToURL:self.pendingActionURL options:NSDataWritingAtomic error:&error]) return YES;
    [self message:error.localizedDescription ?: @"无法写入联机指令。"];
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
    self.busy = YES; self.view.userInteractionEnabled = NO;
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在创建房间…" message:@"连接联机服务器" preferredStyle:UIAlertControllerStyleAlert];
    progress.view.tintColor = STS2Theme.cat;
    [self presentViewController:progress animated:YES completion:^{
        [STS2RoomService.shared createRoomWithNickname:self.config.nickname localPort:self.config.port continuing:[self hasMultiplayerSave] completion:^(NSDictionary *room, NSError *error) {
            self.busy = NO; self.view.userInteractionEnabled = YES;
            [progress dismissViewControllerAnimated:YES completion:^{
                if (error) { [self message:[@"创建房间失败：" stringByAppendingString:error.localizedDescription]]; return; }
                if ([self writePendingAction:@{@"type": @"host"}] && self.startHandler) self.startHandler();
            }];
        }];
    }];
}
- (void)joinRoomTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.rooms.count || ![self canStartGame]) return;
    NSDictionary *room = self.rooms[sender.tag];
    if ([self writePendingAction:@{@"type": @"join", @"host": STS2RoomService.shared.server, @"port": room[@"port"]}] && self.startHandler) self.startHandler();
}
- (void)saveNickname {
    NSString *nickname = [self.nicknameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.config.nickname = nickname.length ? [nickname substringToIndex:MIN(nickname.length, (NSUInteger)16)] : @"玩家";
    [self.view endEditing:YES];
    [self performIO:^id(NSError **error) { return @([self.config save:error]); } completion:^(id result) { [self message:@"昵称已保存。"]; }];
}
@end

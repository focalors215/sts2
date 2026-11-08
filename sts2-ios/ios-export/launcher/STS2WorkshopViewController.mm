#import "STS2WorkshopViewController.h"
#import "STS2SteamWorkshop.h"
#import "STS2ModStore.h"
#import "STS2Form.h"
#import "STS2Log.h"
#import "STS2Theme.h"

NSString *const STS2ModsDidChangeNotification = @"STS2ModsDidChangeNotification";

static void WorkshopAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:a animated:YES completion:nil];
}

static NSString *StripBBCode(NSString *text) {
    NSString *out = [[NSRegularExpression regularExpressionWithPattern:@"\\[/?[a-zA-Z0-9*]+(=[^\\]]*)?\\]" options:0 error:nil] stringByReplacingMatchesInString:text ?: @"" options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ItemSubtitle(NSDictionary *item) {
    NSMutableArray *parts = [NSMutableArray array];
    if ([item[@"size"] longLongValue] > 0) [parts addObject:[NSByteCountFormatter stringFromByteCount:[item[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    if ([item[@"updated"] longLongValue] > 0) {
        NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd";
        [parts addObject:[@"更新于 " stringByAppendingString:[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"updated"] doubleValue]]]]];
    }
    if ([item[@"subscriptions"] longLongValue] > 0) [parts addObject:[NSString stringWithFormat:@"%@ 订阅", item[@"subscriptions"]]];
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark - Image viewer

@interface STS2WorkshopImageViewer : UIViewController <UIScrollViewDelegate>
@property(nonatomic, strong) NSArray<NSString *> *urls;
@property(nonatomic) NSUInteger index;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UIImageView *imageView;
@end
@implementation STS2WorkshopImageViewer
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.minimumZoomScale = 1; self.scroll.maximumZoomScale = 4; self.scroll.delegate = self;
    self.imageView = [[UIImageView alloc] initWithFrame:self.scroll.bounds];
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.scroll addSubview:self.imageView]; [self.view addSubview:self.scroll];
    for (NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight)]) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
        swipe.direction = direction.unsignedIntegerValue; [self.view addGestureRecognizer:swipe];
    }
    [self load];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return self.imageView; }
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    if (self.scroll.zoomScale > 1.01) return;
    NSInteger next = (NSInteger)self.index + (gesture.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : -1);
    if (next < 0 || next >= (NSInteger)self.urls.count) return;
    self.index = next; [self load];
}
- (void)load {
    self.title = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)self.index + 1, (unsigned long)self.urls.count];
    self.imageView.image = nil; self.scroll.zoomScale = 1;
    NSString *url = self.urls[self.index];
    [STS2SteamWorkshop.shared imageDataForURL:url completion:^(NSData *data) { if ([self.urls[self.index] isEqual:url]) self.imageView.image = [UIImage imageWithData:data]; }];
}
@end

#pragma mark - Detail

@interface STS2WorkshopDetailViewController : UIViewController
@property(nonatomic, strong) NSDictionary *item;
@property(nonatomic, strong) NSDictionary *detail;
@property(nonatomic, weak) STS2WorkshopViewController *owner;
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UIScrollView *gallery;
@property(nonatomic, strong) UIButton *download;
@property(nonatomic, strong) UIProgressView *progress;
@property(nonatomic, strong) UILabel *status;
@end

@interface STS2WorkshopViewController ()
@property(nonatomic, strong) STS2ModStore *store;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, copy) NSString *query;
@property(nonatomic) STS2WorkshopSort sort;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL hasNext, loading;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, readwrite) BOOL downloading;
@property(atomic) BOOL cancelRequested;
- (void)downloadItem:(NSDictionary *)item progress:(void (^)(double, NSString *))progress completion:(void (^)(NSString *_Nullable summary, NSError *_Nullable error))completion;
@end

@implementation STS2WorkshopDetailViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.item[@"title"];
    self.view.backgroundColor = STS2Theme.background;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:scroll];
    self.stack = [UIStackView new]; self.stack.axis = UILayoutConstraintAxisVertical; self.stack.spacing = 12; self.stack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:self.stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor], [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16], [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16], [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]]];
    self.gallery = [UIScrollView new]; self.gallery.showsHorizontalScrollIndicator = NO;
    [self.gallery.heightAnchor constraintEqualToConstant:220].active = YES;
    [self.stack addArrangedSubview:self.gallery];
    UILabel *title = [UILabel new]; title.text = self.item[@"title"]; title.font = [STS2Theme font:UIFontTextStyleTitle2 bold:YES]; title.textColor = STS2Theme.ink; title.numberOfLines = 0;
    UILabel *meta = [UILabel new]; meta.text = ItemSubtitle(self.item); meta.font = [STS2Theme font:UIFontTextStyleSubheadline bold:NO]; meta.textColor = STS2Theme.inkSoft; meta.numberOfLines = 0;
    [self.stack addArrangedSubview:title]; [self.stack addArrangedSubview:meta];
    if ([self.item[@"tags"] count]) { UILabel *tags = [UILabel new]; tags.text = [@"标签：" stringByAppendingString:[self.item[@"tags"] componentsJoinedByString:@"、"]]; tags.font = [STS2Theme font:UIFontTextStyleFootnote bold:NO]; tags.textColor = STS2Theme.fish; tags.numberOfLines = 0; [self.stack addArrangedSubview:tags]; }
    self.download = [UIButton buttonWithType:UIButtonTypeSystem];
    self.download.configuration = [STS2Theme configurationForStyle:STS2ButtonStylePrimary title:@"下载并导入" symbol:@"arrow.down.circle.fill"];
    [self.download addTarget:self action:@selector(downloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.download.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; self.progress.progressTintColor = STS2Theme.cat; self.progress.hidden = YES;
    self.status = [UILabel new]; self.status.font = [STS2Theme font:UIFontTextStyleFootnote bold:NO]; self.status.textColor = STS2Theme.inkSoft; self.status.numberOfLines = 0;
    self.status.text = @"iPad 只能启用资源 PCK；含 DLL 的代码 MOD 会被归档并说明原因（iOS 不能在运行时加载 DLL / Harmony）。";
    [self.stack addArrangedSubview:self.download]; [self.stack addArrangedSubview:self.progress]; [self.stack addArrangedSubview:self.status];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"safari"] style:UIBarButtonItemStylePlain target:self action:@selector(openInBrowser)];
    [self showDescription:self.item[@"description"] required:@[]];
    [self showScreenshots:[self.item[@"preview"] length] ? @[self.item[@"preview"]] : @[]];
    [STS2SteamWorkshop.shared detailsForItem:self.item completion:^(NSDictionary *detail, NSError *error) {
        if (!detail) return;
        self.detail = detail;
        [self showScreenshots:detail[@"screenshots"]];
        [self showDescription:detail[@"description"] required:detail[@"requiredItems"]];
    }];
}
- (void)showScreenshots:(NSArray<NSString *> *)urls {
    for (UIView *v in self.gallery.subviews) [v removeFromSuperview];
    CGFloat x = 0;
    for (NSUInteger i = 0; i < urls.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, 0, 360, 220); b.layer.cornerRadius = 14; b.clipsToBounds = YES; b.backgroundColor = STS2Theme.card; b.tag = i;
        b.imageView.contentMode = UIViewContentModeScaleAspectFill; b.accessibilityLabel = [NSString stringWithFormat:@"截图 %lu", (unsigned long)i + 1];
        [b addTarget:self action:@selector(screenshotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.gallery addSubview:b];
        [STS2SteamWorkshop.shared imageDataForURL:urls[i] completion:^(NSData *data) { UIImage *img = [UIImage imageWithData:data]; if (img) [b setImage:img forState:UIControlStateNormal]; b.imageView.contentMode = UIViewContentModeScaleAspectFill; }];
        x += 372;
    }
    self.gallery.contentSize = CGSizeMake(MAX(0, x - 12), 220);
    self.gallery.hidden = urls.count == 0;
}
- (void)screenshotTapped:(UIButton *)sender {
    NSArray *urls = self.detail[@"screenshots"] ?: ([self.item[@"preview"] length] ? @[self.item[@"preview"]] : @[]);
    if (!urls.count) return;
    STS2WorkshopImageViewer *viewer = [STS2WorkshopImageViewer new]; viewer.urls = urls; viewer.index = MIN((NSUInteger)sender.tag, urls.count - 1);
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)showDescription:(NSString *)text required:(NSArray *)required {
    NSInteger tag = 7701;
    [[self.stack viewWithTag:tag] removeFromSuperview];
    UILabel *body = [UILabel new]; body.tag = tag; body.numberOfLines = 0; body.font = [STS2Theme font:UIFontTextStyleBody bold:NO]; body.textColor = STS2Theme.ink;
    NSString *description = StripBBCode(text);
    if (required.count) description = [NSString stringWithFormat:@"需要先安装的工坊条目：%@\n\n%@", [required componentsJoinedByString:@"、"], description];
    body.text = description.length ? description : @"（作者没有写简介）";
    [self.stack addArrangedSubview:body];
}
- (void)openInBrowser {
    NSURL *url = [NSURL URLWithString:[@"https://steamcommunity.com/sharedfiles/filedetails/?id=" stringByAppendingString:self.item[@"id"]]];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
- (void)downloadTapped {
    STS2WorkshopViewController *owner = self.owner;
    if (!owner) return;
    if (owner.downloading) { owner.cancelRequested = YES; self.status.text = @"正在取消…"; return; }
    self.progress.hidden = NO; self.progress.progress = 0;
    self.download.configuration = [STS2Theme configurationForStyle:STS2ButtonStyleSecondary title:@"取消下载" symbol:@"xmark.circle"];
    __weak STS2WorkshopDetailViewController *weakSelf = self;
    [owner downloadItem:self.item progress:^(double fraction, NSString *status) {
        weakSelf.progress.progress = (float)fraction; weakSelf.status.text = status;
    } completion:^(NSString *summary, NSError *error) {
        STS2WorkshopDetailViewController *s = weakSelf;
        s.download.configuration = [STS2Theme configurationForStyle:STS2ButtonStylePrimary title:@"下载并导入" symbol:@"arrow.down.circle.fill"];
        s.status.text = summary ?: error.localizedDescription;
        if (s) WorkshopAlert(s, summary ? @"已导入到本地 MOD" : @"下载未完成", summary ?: error.localizedDescription);
    }];
}
@end

#pragma mark - List

@implementation STS2WorkshopViewController
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _store = [[STS2ModStore alloc] initWithDocumentsURL:documentsURL];
        _items = [NSMutableArray array]; _query = @""; _page = 1;
        self.title = @"创意工坊";
    }
    return self;
}
- (BOOL)hasPendingOperations { return self.downloading; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.tintColor = STS2Theme.cat;
    self.tableView.rowHeight = 88;
    UISearchBar *search = [UISearchBar new]; search.placeholder = @"搜索工坊（回车搜索）"; search.searchBarStyle = UISearchBarStyleMinimal; search.delegate = (id<UISearchBarDelegate>)self;
    UISegmentedControl *sort = [[UISegmentedControl alloc] initWithItems:@[@"热门", @"最新", @"最近更新", @"订阅最多"]];
    sort.selectedSegmentIndex = 0; sort.selectedSegmentTintColor = STS2Theme.cat;
    [sort addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[search, sort]];
    header.axis = UILayoutConstraintAxisVertical; header.spacing = 8; header.layoutMarginsRelativeArrangement = YES; header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 20, 8, 20);
    header.frame = CGRectMake(0, 0, 600, 104);
    self.tableView.tableHeaderView = header;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    open.configuration = [STS2Theme configurationForStyle:STS2ButtonStyleSecondary title:@"按链接 / ID 打开" symbol:@"link"];
    [open addTarget:self action:@selector(openById) forControlEvents:UIControlEventTouchUpInside];
    [header addArrangedSubview:open];
    header.frame = CGRectMake(0, 0, 600, 160);
    self.tableView.tableHeaderView = header;
    [self reload];
}
- (void)openById {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"按链接 / ID 打开" message:@"粘贴工坊条目链接（…filedetails/?id=数字）或直接输入条目 ID。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"https://steamcommunity.com/sharedfiles/filedetails/?id=…"; f.keyboardType = UIKeyboardTypeURL; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.text = UIPasteboard.generalPasteboard.hasURLs ? UIPasteboard.generalPasteboard.URL.absoluteString : nil; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *identifier = [STS2SteamWorkshop itemIdFromInput:weak.textFields.firstObject.text ?: @""];
        if (!identifier) { WorkshopAlert(self, @"无法识别", @"没有找到条目 ID，请粘贴工坊条目链接或纯数字 ID。"); return; }
        [STS2SteamWorkshop.shared itemsForIds:@[identifier] completion:^(NSArray *items, NSError *error) {
            if (!items.count) {
                [STS2Log log:STS2LogLevelWarn tag:STS2LogTagWorkshop message:[@"按 ID 打开工坊条目失败：" stringByAppendingString:identifier] detail:error];
                WorkshopAlert(self, @"打开失败", error.localizedDescription ?: @"没有找到这个条目，或它不属于杀戮尖塔 2。"); return;
            }
            STS2WorkshopDetailViewController *detail = [STS2WorkshopDetailViewController new];
            detail.item = items.firstObject; detail.owner = self;
            STS2PresentSheet(self, detail);
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; self.query = searchBar.text ?: @""; [self reload]; }
- (void)sortChanged:(UISegmentedControl *)sender { self.sort = (STS2WorkshopSort)sender.selectedSegmentIndex; [self reload]; }
- (void)reload { self.page = 1; [self.items removeAllObjects]; [self loadPage]; }
- (void)loadPage {
    if (self.loading) return;
    self.loading = YES; self.lastError = nil; [self.tableView reloadData];
    NSInteger page = self.page;
    [STS2SteamWorkshop.shared browse:self.query page:page sort:self.sort completion:^(NSArray *items, BOOL hasNext, NSError *error) {
        self.loading = NO; [self.refreshControl endRefreshing];
        if (error) self.lastError = error.localizedDescription;
        if (page == self.page) { [self.items addObjectsFromArray:items]; self.hasNext = hasNext && items.count > 0; }
        [self.tableView reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.items.count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"✦ 杀戮尖塔 2 创意工坊" : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? @"浏览不需要 Steam 账号。下载走公开的「尖塔补给站」协议（与 Android 启动器相同），只从 Steam CDN 取文件。下载后自动导入「本地 MOD」：资源 PCK 可启用，DLL 代码 MOD 归档并说明原因。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = STS2Theme.card; cell.textLabel.textColor = STS2Theme.ink; cell.detailTextLabel.textColor = STS2Theme.inkSoft;
    if (indexPath.section == 1) {
        cell.textLabel.text = self.loading ? @"正在加载…" : self.lastError ? [@"加载失败，点此重试：" stringByAppendingString:self.lastError] : self.hasNext ? @"加载更多" : (self.items.count ? @"没有更多了" : @"没有找到条目");
        cell.textLabel.numberOfLines = 0; cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = self.lastError ? UIColor.systemRedColor : STS2Theme.cat;
        return cell;
    }
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"]; cell.textLabel.font = [STS2Theme font:UIFontTextStyleBody bold:YES]; cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = ItemSubtitle(item);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = [UIImage systemImageNamed:@"photo"]; cell.imageView.tintColor = STS2Theme.inkSoft;
    NSString *preview = item[@"preview"];
    if (preview.length) [STS2SteamWorkshop.shared imageDataForURL:preview completion:^(NSData *data) {
        UIImage *image = [UIImage imageWithData:data];
        UITableViewCell *visible = [tableView cellForRowAtIndexPath:indexPath];
        if (!image || !visible) return;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(96, 64)];
        visible.imageView.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 96, 64) cornerRadius:10] addClip];
            CGFloat scale = MAX(96 / image.size.width, 64 / image.size.height);
            [image drawInRect:CGRectMake((96 - image.size.width * scale) / 2, (64 - image.size.height * scale) / 2, image.size.width * scale, image.size.height * scale)];
        }];
        [visible setNeedsLayout];
    }];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { if (!self.loading && (self.hasNext || self.lastError)) { if (!self.lastError) self.page++; [self loadPage]; } return; }
    STS2WorkshopDetailViewController *detail = [STS2WorkshopDetailViewController new];
    detail.item = self.items[indexPath.row]; detail.owner = self;
    STS2PresentSheet(self, detail);
}

- (void)downloadItem:(NSDictionary *)item progress:(void (^)(double, NSString *))progress completion:(void (^)(NSString *, NSError *))completion {
    if (self.downloading) return;
    [self willChangeValueForKey:@"hasPendingOperations"];
    self.downloading = YES; self.cancelRequested = NO;
    [self didChangeValueForKey:@"hasPendingOperations"];
    void (^finish)(NSString *, NSError *) = ^(NSString *summary, NSError *error) {
        [self willChangeValueForKey:@"hasPendingOperations"];
        self.downloading = NO;
        [self didChangeValueForKey:@"hasPendingOperations"];
        if (error) [STS2Log log:STS2LogLevelError tag:STS2LogTagWorkshop message:[NSString stringWithFormat:@"工坊条目 %@ 下载/导入失败", item[@"id"]] detail:error];
        if (summary) [NSNotificationCenter.defaultCenter postNotificationName:STS2ModsDidChangeNotification object:self];
        completion(summary, error);
    };
    [self.store createStagingDirectoryWithCompletion:^(NSURL *directory, NSError *error) {
        if (!directory) { finish(nil, error); return; }
        __weak STS2WorkshopViewController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *downloadError = nil;
            BOOL ok = [STS2SteamWorkshop.shared downloadItem:item into:directory progress:^(double fraction, NSString *status) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction, status); });
            } cancelled:^BOOL { return !weakSelf || weakSelf.cancelRequested; } error:&downloadError];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) { [self.store discardStagingDirectoryURL:directory completion:^(NSError *e) {}]; finish(nil, downloadError); return; }
                progress(1, @"导入本地 MOD…");
                NSString *source = [NSString stringWithFormat:@"Steam 创意工坊 %@", item[@"id"]];
                [self.store importStagedDirectoryURL:directory source:source completion:^(NSError *importError) {
                    if (importError) { finish(nil, importError); return; }
                    STS2LogI(STS2LogTagWorkshop, @"工坊条目 %@ 已导入本地 MOD", item[@"id"]);
                    finish(@"已导入「本地 MOD」。资源 PCK 可以在本地 MOD 页启用（下次启动游戏生效）；如果是 DLL 代码 MOD，会显示在「归档 / 待验证」里——iOS 的 NativeAOT 不能在运行时加载 DLL / Harmony。", nil);
                }];
            });
        });
    }];
}
@end

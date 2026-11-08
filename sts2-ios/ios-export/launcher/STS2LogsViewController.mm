#import "STS2LogsViewController.h"
#import "STS2LauncherConfigStore.h"
#import "STS2LogAnalysis.h"
#import "STS2LogCenter.h"
#import "STS2Log.h"
#import "STS2SecretStore.h"
#import "STS2Theme.h"

static const NSUInteger kViewerTailBytes = 4 * 1024 * 1024;
static const NSUInteger kViewerMaxEntries = 3000;

static void STS2Alert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:a animated:YES completion:nil];
}

static NSString *LevelName(NSInteger level) { return @[@"调试", @"信息", @"警告", @"错误"][MAX(0, MIN(3, level))]; }

#pragma mark - Viewer

@interface STS2LogFileViewController : UIViewController <UISearchBarDelegate>
@property(nonatomic, strong) NSDictionary *file;
@property(nonatomic, strong) NSArray<NSDictionary *> *entries;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) UISegmentedControl *levels;
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, copy) void (^analyze)(NSURL *file);
@end

@implementation STS2LogFileViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.file[@"title"];
    self.view.backgroundColor = STS2Theme.background;
    self.search = [UISearchBar new]; self.search.placeholder = @"搜索（不区分大小写）"; self.search.delegate = self; self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.levels = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"信息+", @"警告+", @"仅错误"]];
    self.levels.selectedSegmentIndex = 0; self.levels.selectedSegmentTintColor = STS2Theme.cat;
    [self.levels addTarget:self action:@selector(refilter) forControlEvents:UIControlEventValueChanged];
    self.countLabel = [UILabel new]; self.countLabel.font = [STS2Theme font:UIFontTextStyleFootnote bold:NO]; self.countLabel.textColor = STS2Theme.inkSoft; self.countLabel.numberOfLines = 0;
    self.textView = [UITextView new]; self.textView.editable = NO; self.textView.backgroundColor = STS2Theme.card; self.textView.layer.cornerRadius = 12;
    self.textView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8); self.textView.alwaysBounceVertical = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.search, self.levels, self.countLabel, self.textView]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:8], [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
                                              [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12], [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12]]];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareFile:)];
    UIBarButtonItem *ai = [[UIBarButtonItem alloc] initWithTitle:@"LLM 分析" style:UIBarButtonItemStylePlain target:self action:@selector(analyzeFile)];
    UIBarButtonItem *bottom = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.to.line"] style:UIBarButtonItemStylePlain target:self action:@selector(scrollToBottom)];
    self.navigationItem.rightBarButtonItems = @[share, ai, bottom];
    self.countLabel.text = @"正在读取…";
    NSURL *url = self.file[@"url"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *text = [STS2LogCenter tailOfFileAtURL:url maxBytes:kViewerTailBytes];
        NSArray *entries = [STS2LogCenter entriesFromText:[STS2Log redact:text]];
        dispatch_async(dispatch_get_main_queue(), ^{ self.entries = entries; [self refilter]; [self scrollToBottom]; });
    });
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self refilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (void)refilter {
    NSInteger minimum = [@[@(STS2LogLevelDebug), @(STS2LogLevelInfo), @(STS2LogLevelWarn), @(STS2LogLevelError)][self.levels.selectedSegmentIndex] integerValue];
    NSString *query = [self.search.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray *matched = [NSMutableArray array];
    for (NSDictionary *entry in self.entries) {
        if ([entry[@"level"] integerValue] < minimum) continue;
        if (query.length && [entry[@"text"] rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [matched addObject:entry];
    }
    NSUInteger shown = MIN(matched.count, kViewerMaxEntries);
    NSArray *visible = [matched subarrayWithRange:NSMakeRange(matched.count - shown, shown)];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSDictionary *colors = @{@(STS2LogLevelDebug): STS2Theme.inkSoft, @(STS2LogLevelInfo): STS2Theme.ink, @(STS2LogLevelWarn): UIColor.systemOrangeColor, @(STS2LogLevelError): UIColor.systemRedColor};
    for (NSDictionary *entry in visible)
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[entry[@"text"] stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: colors[entry[@"level"]] ?: STS2Theme.ink}]];
    self.textView.attributedText = out;
    NSString *size = [NSByteCountFormatter stringFromByteCount:[self.file[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    self.countLabel.text = [NSString stringWithFormat:@"%@ · 共 %lu 条，匹配 %lu 条%@%@", size, (unsigned long)self.entries.count, (unsigned long)matched.count,
                            matched.count > shown ? [NSString stringWithFormat:@"，只显示最后 %lu 条", (unsigned long)shown] : @"",
                            [self.file[@"size"] unsignedLongLongValue] > kViewerTailBytes ? @"；文件较大，只读取末尾 4 MiB（导出包含末尾 8 MiB）" : @""];
}
- (void)scrollToBottom {
    if (!self.textView.text.length) return;
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
}
- (void)shareFile:(UIBarButtonItem *)sender {
    // 分享前同样脱敏：写一份临时副本。
    NSURL *source = self.file[@"url"];
    NSURL *copy = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:source.lastPathComponent];
    NSString *text = [STS2Log redact:[STS2LogCenter tailOfFileAtURL:source maxBytes:8 * 1024 * 1024]];
    NSError *error = nil;
    if (![text writeToURL:copy atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:@"准备分享日志失败" detail:error];
        STS2Alert(self, @"分享失败", error.localizedDescription); return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[copy] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}
- (void)analyzeFile { if (self.analyze) self.analyze(self.file[@"url"]); }
@end

#pragma mark - LLM analysis

@interface STS2LogAnalysisViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) STS2LauncherConfigStore *config;
@property(nonatomic, strong) NSArray<NSDictionary *> *availableFiles;
@property(nonatomic, strong) NSMutableArray<NSURL *> *selected;
@property(nonatomic, strong) STS2ChatSession *session;
@property(nonatomic) BOOL consented;
@property(nonatomic) BOOL working;
@property(atomic) BOOL stopRequested;
@property(nonatomic, strong) UITextView *transcript;
@property(nonatomic, strong) UITextView *input;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *send;
@property(nonatomic, strong) NSMutableAttributedString *log;
@end

@implementation STS2LogAnalysisViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志分析 · LLM";
    self.view.backgroundColor = STS2Theme.background;
    self.log = [NSMutableAttributedString new];
    self.status = [UILabel new]; self.status.font = [STS2Theme font:UIFontTextStyleFootnote bold:YES]; self.status.textColor = STS2Theme.inkSoft; self.status.numberOfLines = 0;
    self.transcript = [UITextView new]; self.transcript.editable = NO; self.transcript.backgroundColor = STS2Theme.card; self.transcript.layer.cornerRadius = 12;
    self.transcript.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.input = [UITextView new]; self.input.font = [STS2Theme font:UIFontTextStyleBody bold:NO]; self.input.textColor = STS2Theme.ink; self.input.backgroundColor = STS2Theme.card; self.input.layer.cornerRadius = 12;
    self.input.accessibilityLabel = @"描述问题，或继续追问证据";
    [self.input.heightAnchor constraintEqualToConstant:88].active = YES;
    self.send = [UIButton buttonWithType:UIButtonTypeSystem];
    self.send.configuration = [STS2Theme configurationForStyle:STS2ButtonStylePrimary title:@"发送问题" symbol:@"paperplane.fill"];
    [self.send addTarget:self action:@selector(sendOrStop) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status, self.transcript, self.input, self.send]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.keyboardLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8], [stack.bottomAnchor constraintEqualToAnchor:g.topAnchor constant:-8],
                                              [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12], [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12]]];
    self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithTitle:@"LLM 配置" style:UIBarButtonItemStylePlain target:self action:@selector(editConfig)],
                                                [[UIBarButtonItem alloc] initWithTitle:@"授权日志" style:UIBarButtonItemStylePlain target:self action:@selector(chooseFiles)],
                                                [[UIBarButtonItem alloc] initWithTitle:@"重新开始" style:UIBarButtonItemStylePlain target:self action:@selector(restart)]];
    [self append:@"提示" text:@"先在右上角配置自定义 OpenAI 兼容服务，再提出问题。只有明确勾选的日志可被读取。建议问：“请定位崩溃原因，引用文件与行号，并区分证据与推测。”\n长按或选中文字即可复制；工具进度只显示文件与行区间。" color:STS2Theme.inkSoft];
    [self append:@"分析说明" text:@"仅发送授权日志的按需工具片段，不自动上传全文。每次问题最多 24 轮；对话仅存于内存，离开页面即清空。" color:STS2Theme.inkSoft];
    [self updateStatus:nil];
}
- (STS2LlmConfig *)llmConfig {
    STS2LlmConfig *c = [STS2LlmConfig new];
    NSDictionary *saved = [[self.config launcherSettingForKey:@"llm"] isKindOfClass:NSDictionary.class] ? [self.config launcherSettingForKey:@"llm"] : @{};
    c.baseURL = [saved[@"baseUrl"] isKindOfClass:NSString.class] ? saved[@"baseUrl"] : @"";
    c.model = [saved[@"model"] isKindOfClass:NSString.class] ? saved[@"model"] : @"";
    c.reasoningEffort = [saved[@"effort"] isKindOfClass:NSString.class] ? saved[@"effort"] : @"";
    c.apiKey = [STS2SecretStore secretForKey:STS2SecretLlmApiKey] ?: @"";
    return c;
}
- (void)updateStatus:(NSString *)text {
    NSString *files = self.selected.count ? [NSString stringWithFormat:@"授权日志：%@", [[self.selected valueForKey:@"lastPathComponent"] componentsJoinedByString:@"、"]] : @"请选择授权日志";
    self.status.text = [NSString stringWithFormat:@"%@\n%@", text ?: (self.working ? @"分析中 · 24 轮预算" : @"可提问 · 24 轮预算"), files];
    self.send.configuration = [STS2Theme configurationForStyle:self.working ? STS2ButtonStyleSecondary : STS2ButtonStylePrimary title:self.working ? @"停止" : @"发送问题" symbol:self.working ? @"stop.fill" : @"paperplane.fill"];
}
- (void)append:(NSString *)who text:(NSString *)text color:(UIColor *)color {
    UIFont *bold = [STS2Theme font:UIFontTextStyleHeadline bold:YES], *body = [STS2Theme font:UIFontTextStyleBody bold:NO];
    [self.log appendAttributedString:[[NSAttributedString alloc] initWithString:[who stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: STS2Theme.cat}]];
    [self.log appendAttributedString:[[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:@{NSFontAttributeName: body, NSForegroundColorAttributeName: color}]];
    self.transcript.attributedText = self.log;
    [self.transcript scrollRangeToVisible:NSMakeRange(self.log.length ? self.log.length - 1 : 0, 0)];
}
- (void)restart {
    self.stopRequested = YES; self.session = nil; self.consented = NO;
    self.log = [NSMutableAttributedString new]; self.transcript.attributedText = self.log;
    [self updateStatus:@"已重新开始"];
}
- (void)editConfig {
    STS2LlmConfig *current = [self llmConfig];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"LLM 配置" message:@"Base URL 可填 /v1 基址或完整 /chat/completions；站点根地址会补 /v1。API Key 可留空用于本地服务。Thinking effort 留空则不发送；配置变更将清空会话。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    NSArray *placeholders = @[@"Base URL（HTTP / HTTPS）", @"API Key（钥匙串保存，可留空）", @"Model ID", @"Thinking effort（默认留空，如 low / medium / high）"];
    NSArray *values = @[current.baseURL, current.apiKey, current.model, current.reasoningEffort];
    for (NSUInteger i = 0; i < 4; i++) [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = placeholders[i]; f.text = values[i]; f.secureTextEntry = i == 1;
        f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.keyboardType = i == 0 ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"加密保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray<UITextField *> *f = weak.textFields;
        STS2LlmConfig *c = [STS2LlmConfig new];
        c.baseURL = f[0].text ?: @""; c.apiKey = f[1].text ?: @""; c.model = f[2].text ?: @""; c.reasoningEffort = f[3].text ?: @"";
        NSString *problem = [c validationProblem];
        if (problem) { [STS2Log log:STS2LogLevelWarn tag:STS2LogTagUI message:[@"LLM 配置无效：" stringByAppendingString:problem]]; STS2Alert(self, @"LLM 配置", problem); return; }
        NSError *error = nil;
        if (![STS2SecretStore setSecret:c.apiKey forKey:STS2SecretLlmApiKey error:&error] ||
            ![self.config setLauncherSetting:@{@"baseUrl": c.baseURL, @"model": c.model, @"effort": c.reasoningEffort} forKey:@"llm" error:&error]) {
            STS2Alert(self, @"LLM 配置", [@"保存失败：" stringByAppendingString:error.localizedDescription ?: @""]); return;
        }
        if ([c.baseURL.lowercaseString hasPrefix:@"http:"]) STS2LogW(STS2LogTagUI, @"LLM 服务使用 HTTP 明文地址");
        [self restart];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)chooseFiles {
    UITableViewController *picker = [[UITableViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.title = @"授权日志"; picker.tableView.dataSource = self; picker.tableView.delegate = self;
    picker.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"确认选择并清空会话" style:UIBarButtonItemStyleDone target:self action:@selector(filesChosen)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.view.tintColor = STS2Theme.cat;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)filesChosen { [self dismissViewControllerAnimated:YES completion:nil]; [self restart]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.availableFiles.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return @"最多 3 个。只勾选当前文件；最新 godot.log 必须由你主动勾选。确认会停止当前请求并清空会话。"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"f"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    NSDictionary *file = self.availableFiles[indexPath.row];
    cell.textLabel.text = file[@"title"]; cell.detailTextLabel.text = file[@"categoryTitle"];
    cell.accessoryType = [self.selected containsObject:file[@"url"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSURL *url = self.availableFiles[indexPath.row][@"url"];
    if ([self.selected containsObject:url]) [self.selected removeObject:url];
    else if (self.selected.count < 3) [self.selected addObject:url];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)sendOrStop {
    if (self.working) { self.stopRequested = YES; [self updateStatus:@"已停止"]; return; }
    NSString *question = [self.input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!question.length) return;
    STS2LlmConfig *config = [self llmConfig];
    NSString *problem = [config validationProblem];
    if (problem) { STS2Alert(self, @"LLM 配置", problem); return; }
    if (!self.selected.count) { STS2Alert(self, @"授权日志", @"请选择授权日志"); return; }
    if (!self.consented) {
        NSString *files = [[self.selected valueForKey:@"lastPathComponent"] componentsJoinedByString:@"\n"];
        NSString *message = [NSString stringWithFormat:@"问题、文件名、行数、大小和模型按需读取/搜索的日志片段将发送至：\n%@\n\n授权文件：\n%@\n\n片段可能含个人信息或凭据。日志中的指令不会被执行，模型结果仍须核实。HTTP 明文地址可能被网络窃听。仅本会话记住同意；变更配置或文件将清空历史并重新征求同意。", [config endpoint:nil].absoluteString, files];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"同意发送所选日志片段？" message:message preferredStyle:UIAlertControllerStyleAlert];
        a.view.tintColor = STS2Theme.cat;
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"同意并发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { self.consented = YES; [self sendOrStop]; }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (!self.session) {
        NSError *error = nil;
        STS2LogTools *tools = [[STS2LogTools alloc] initWithFiles:self.selected error:&error];
        if (!tools) { [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:@"日志分析准备失败" detail:error]; STS2Alert(self, @"工具读取失败", error.localizedDescription); return; }
        self.session = [[STS2ChatSession alloc] initWithTransport:STS2OpenAiTransport(config) tools:tools];
    }
    self.input.text = @"";
    [self append:@"你" text:question color:STS2Theme.ink];
    self.working = YES; self.stopRequested = NO; [self updateStatus:nil];
    STS2ChatSession *session = self.session;
    __weak STS2LogAnalysisViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil; BOOL budget = NO;
        NSString *answer = [session ask:question cancelled:^BOOL { STS2LogAnalysisViewController *s = weakSelf; return !s || s.stopRequested; }
                               progress:^(NSString *status) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateStatus:status]; }); }
                          budgetReached:&budget error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            STS2LogAnalysisViewController *s = weakSelf;
            if (!s) return;
            s.working = NO;
            if (answer) { [s append:@"分析" text:answer color:STS2Theme.ink]; [s updateStatus:budget ? @"预算已达 · 可继续追问" : nil]; }
            else {
                [STS2Log log:STS2LogLevelWarn tag:STS2LogTagUI message:@"日志分析失败" detail:error];
                [s append:@"提示" text:error.localizedDescription ?: @"分析失败，请检查服务与日志状态；未上传全文。可重新提问。" color:UIColor.systemRedColor];
                [s updateStatus:@"分析失败 · 可重试"];
            }
        });
    });
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; if (self.isMovingFromParentViewController || self.isBeingDismissed) self.stopRequested = YES; }
@end

#pragma mark - List

@interface STS2LogsViewController ()
@property(nonatomic, strong) NSURL *documents;
@property(nonatomic, strong) STS2LauncherConfigStore *config;
@property(nonatomic, strong) STS2LogCenter *center;
@property(nonatomic, copy) NSDictionary * (^diagnosticsProvider)(void);
@property(nonatomic, strong) NSArray<NSDictionary *> *files;
@property(nonatomic, strong) NSArray<NSString *> *categories;
@property(nonatomic) BOOL exporting;
@end

@implementation STS2LogsViewController
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL config:(STS2LauncherConfigStore *)config diagnosticsProvider:(NSDictionary * (^)(void))diagnosticsProvider {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _documents = documentsURL; _config = config; _diagnosticsProvider = [diagnosticsProvider copy];
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        _center = [[STS2LogCenter alloc] initWithDocumentsURL:documentsURL cachesURL:caches];
        self.title = @"日志";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.tintColor = STS2Theme.cat;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)reload {
    NSArray *files = [self.center logFiles];
    NSMutableArray *categories = [NSMutableArray array];
    for (NSDictionary *file in files) if (![categories containsObject:file[@"category"]]) [categories addObject:file[@"category"]];
    self.files = files; self.categories = categories;
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}
- (NSArray *)filesIn:(NSInteger)section { NSString *category = self.categories[section - 1]; return [self.files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"category == %@", category]]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1 + self.categories.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : [self filesIn:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"✦ 日志工具" : [@"✦ " stringByAppendingString:[STS2LogCenter titleForCategory:self.categories[section - 1]]];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"导出包含启动器、联机、游戏、frp 日志与 diagnostics.json，已去掉令牌、密码和 API key。遇到问题时请把导出的 zip 发给开发者。";
    if (section == (NSInteger)self.categories.count && !self.files.count) return nil;
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"log"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"log"];
    cell.backgroundColor = STS2Theme.card; cell.textLabel.textColor = STS2Theme.ink; cell.detailTextLabel.textColor = STS2Theme.inkSoft;
    cell.textLabel.font = [STS2Theme font:UIFontTextStyleBody bold:YES]; cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.imageView.tintColor = STS2Theme.cat;
    if (indexPath.section == 0) {
        NSArray *titles = @[self.exporting ? @"正在打包…" : @"导出日志", @"LLM 日志分析", [NSString stringWithFormat:@"日志等级：%@", LevelName(STS2Log.minimumLevel)]];
        NSArray *details = @[@"打包成 zip，用分享面板发送或存到“文件”", @"用自定义 OpenAI 兼容服务按需读取所选日志片段", @"低于此等级的启动器日志不会写入"];
        NSArray *symbols = @[@"square.and.arrow.up", @"sparkles", @"slider.horizontal.3"];
        cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row]; cell.imageView.image = [UIImage systemImageNamed:symbols[indexPath.row]];
        return cell;
    }
    NSDictionary *file = [self filesIn:indexPath.section][indexPath.row];
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"MM-dd HH:mm:ss";
    cell.textLabel.text = file[@"title"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [NSByteCountFormatter stringFromByteCount:[file[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], [formatter stringFromDate:file[@"date"]]];
    cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        UIView *source = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
        if (indexPath.row == 0) [self exportFromView:source presenter:self];
        else if (indexPath.row == 1) [self openAnalysisWith:nil];
        else [self chooseLevelFrom:source];
        return;
    }
    STS2LogFileViewController *viewer = [STS2LogFileViewController new];
    viewer.file = [self filesIn:indexPath.section][indexPath.row];
    __weak STS2LogsViewController *weakSelf = self;
    viewer.analyze = ^(NSURL *file) { [weakSelf openAnalysisWith:file]; };
    [self presentWrapped:viewer];
}
- (void)presentWrapped:(UIViewController *)controller {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.view.tintColor = STS2Theme.cat; nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closePresented)];
    UIViewController *presenter = self.presentedViewController ?: self;
    [presenter presentViewController:nav animated:YES completion:nil];
}
- (void)closePresented { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)openAnalysisWith:(NSURL *)file {
    STS2LogAnalysisViewController *analysis = [STS2LogAnalysisViewController new];
    analysis.config = self.config; analysis.availableFiles = [self.center logFiles];
    analysis.selected = file ? [NSMutableArray arrayWithObject:file] : [NSMutableArray array];
    if (self.presentedViewController) [self dismissViewControllerAnimated:YES completion:^{ [self presentWrapped:analysis]; }];
    else [self presentWrapped:analysis];
}
- (void)chooseLevelFrom:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"日志等级" message:@"错误（E）与警告（W）始终建议保留。" preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = STS2Theme.cat;
    for (NSInteger level = STS2LogLevelDebug; level <= STS2LogLevelError; level++) {
        [sheet addAction:[UIAlertAction actionWithTitle:LevelName(level) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            STS2Log.minimumLevel = (STS2LogLevel)level;
            [self.config setLauncherSetting:@(level) forKey:@"logLevel" error:nil];
            STS2LogI(STS2LogTagUI, @"日志等级改为 %@", LevelName(level));
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source; sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)exportFromView:(UIView *)sourceView presenter:(UIViewController *)presenter {
    if (self.exporting) return;
    self.exporting = YES; if (self.isViewLoaded) [self.tableView reloadData];
    NSDictionary *diagnostics = self.diagnosticsProvider ? self.diagnosticsProvider() : @{};
    NSDictionary *config = [self.config redactedSnapshot];
    STS2LogI(STS2LogTagUI, @"开始导出日志");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"log-export" isDirectory:YES];
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        NSURL *zip = [self.center exportArchiveWithDiagnostics:diagnostics redactedConfig:config destination:directory date:NSDate.date error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exporting = NO; if (self.isViewLoaded) [self.tableView reloadData];
            if (!zip) {
                [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:@"导出日志失败" detail:error];
                STS2Alert(presenter, @"导出日志失败", error.localizedDescription ?: @"未知错误"); return;
            }
            STS2LogI(STS2LogTagUI, @"日志已打包：%@", zip.lastPathComponent);
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zip] applicationActivities:nil];
            share.popoverPresentationController.sourceView = sourceView; share.popoverPresentationController.sourceRect = sourceView.bounds;
            [presenter presentViewController:share animated:YES completion:nil];
        });
    });
}
@end

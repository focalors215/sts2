#import "STS2FileBrowserViewController.h"
#import "STS2Log.h"
#import "STS2Theme.h"

static const unsigned long long kMaxEditableBytes = 2 * 1024 * 1024;

static BOOL IsTextLike(NSURL *url) {
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ extensions = [NSSet setWithArray:@[@"json", @"txt", @"log", @"cfg", @"ini", @"toml", @"md", @"save", @"backup", @"xml", @"csv", @"tres", @"tscn", @"godot", @"yaml", @"yml", @"settings"]]; });
    NSString *ext = url.pathExtension.lowercaseString;
    return [extensions containsObject:ext] || [url.lastPathComponent hasSuffix:@".save.backup"];
}

static void Alert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:a animated:YES completion:nil];
}

#pragma mark - Text editor

@interface STS2TextEditorViewController : UIViewController
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, copy) NSString *original;
@end

@implementation STS2TextEditorViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.url.lastPathComponent;
    self.view.backgroundColor = STS2Theme.background;
    self.textView = [UITextView new];
    self.textView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.textView.textColor = STS2Theme.ink; self.textView.backgroundColor = STS2Theme.card; self.textView.layer.cornerRadius = 12;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo; self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.smartQuotesType = UITextSmartQuotesTypeNo; self.textView.smartDashesType = UITextSmartDashesTypeNo;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[self.textView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8], [self.textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],
                                              [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12], [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12]]];
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfURL:self.url encoding:NSUTF8StringEncoding error:&error];
    if (!text) {
        [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:[NSString stringWithFormat:@"无法以 UTF-8 打开 %@", self.url.lastPathComponent] detail:error];
        self.textView.editable = NO; self.textView.text = @"该文件不是 UTF-8 文本，无法编辑。";
        return;
    }
    self.original = text; self.textView.text = text;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
}
- (BOOL)expectsJSON {
    NSString *ext = self.url.pathExtension.lowercaseString;
    return [ext isEqual:@"json"] || [ext isEqual:@"save"] || [self.url.lastPathComponent hasSuffix:@".save.backup"];
}
- (void)save {
    NSString *text = self.textView.text ?: @"";
    if ([text isEqualToString:self.original]) { Alert(self, @"保存", @"没有修改。"); return; }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    BOOL originalWasJSON = self.expectsJSON && [NSJSONSerialization JSONObjectWithData:[self.original dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil] != nil;
    if (originalWasJSON && ![NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JSON 格式错误" message:@"修改后的内容不是有效的 JSON，游戏可能无法读取。仍要保存吗？（会先备份原文件）" preferredStyle:UIAlertControllerStyleAlert];
        a.view.tintColor = STS2Theme.cat;
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"仍然保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self write:data]; }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self write:data];
}
- (void)write:(NSData *)data {
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSURL *backup = [self.url.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.edit-%@.bak", self.url.lastPathComponent, [formatter stringFromDate:NSDate.date]]];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:self.url toURL:backup error:&error] || ![data writeToURL:self.url options:NSDataWritingAtomic error:&error]) {
        [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:[@"保存文件失败：" stringByAppendingString:self.url.lastPathComponent] detail:error];
        Alert(self, @"保存失败", error.localizedDescription); return;
    }
    self.original = self.textView.text;
    STS2LogI(STS2LogTagUI, @"已编辑文件 %@（原文件备份为 %@）", self.url.lastPathComponent, backup.lastPathComponent);
    Alert(self, @"已保存", [NSString stringWithFormat:@"原文件已备份为隐藏文件 %@。", backup.lastPathComponent]);
}
@end

#pragma mark - Browser

@interface STS2FileBrowserViewController ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic) BOOL showHidden;
@end

@implementation STS2FileBrowserViewController
- (instancetype)initWithDirectory:(NSURL *)directory root:(NSURL *)root {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _directory = directory; _root = root;
        self.title = [directory.URLByStandardizingPath.path isEqual:root.URLByStandardizingPath.path] ? @"文件浏览" : directory.lastPathComponent;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = STS2Theme.background; self.tableView.backgroundColor = STS2Theme.background; self.tableView.tintColor = STS2Theme.cat;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"eye"] style:UIBarButtonItemStylePlain target:self action:@selector(toggleHidden)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)toggleHidden { self.showHidden = !self.showHidden; [self reload]; }
- (void)reload {
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsSymbolicLinkKey];
    NSError *error = nil;
    NSArray *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:keys options:self.showHidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles error:&error];
    if (!urls) [STS2Log log:STS2LogLevelWarn tag:STS2LogTagUI message:[@"无法列出目录 " stringByAppendingString:self.directory.lastPathComponent] detail:error];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSDictionary *v = [url resourceValuesForKeys:keys error:nil];
        if ([v[NSURLIsSymbolicLinkKey] boolValue]) continue;
        [items addObject:@{@"url": url, @"dir": v[NSURLIsDirectoryKey] ?: @NO, @"size": v[NSURLFileSizeKey] ?: @0, @"date": v[NSURLContentModificationDateKey] ?: NSDate.distantPast}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([a[@"dir"] boolValue] != [b[@"dir"] boolValue]) return [a[@"dir"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [[a[@"url"] lastPathComponent] localizedStandardCompare:[b[@"url"] lastPathComponent]];
    }];
    self.items = items;
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *relative = [self.directory.URLByStandardizingPath.path substringFromIndex:MIN(self.root.URLByStandardizingPath.path.length, self.directory.URLByStandardizingPath.path.length)];
    return [@"Documents" stringByAppendingString:relative];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"点文本文件（JSON、存档、配置、日志）可直接编辑，保存前会自动备份原文件；其他文件可分享或删除。启动游戏后再改存档请先完全关闭应用。右上角眼睛切换显示隐藏文件。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"file"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"file"];
    NSDictionary *item = self.items[indexPath.row];
    BOOL dir = [item[@"dir"] boolValue];
    cell.backgroundColor = STS2Theme.card; cell.textLabel.textColor = STS2Theme.ink; cell.detailTextLabel.textColor = STS2Theme.inkSoft;
    cell.textLabel.text = [item[@"url"] lastPathComponent];
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    cell.detailTextLabel.text = dir ? [formatter stringFromDate:item[@"date"]] : [NSString stringWithFormat:@"%@ · %@", [NSByteCountFormatter stringFromByteCount:[item[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], [formatter stringFromDate:item[@"date"]]];
    cell.imageView.image = [UIImage systemImageNamed:dir ? @"folder.fill" : (IsTextLike(item[@"url"]) ? @"doc.text" : @"doc")];
    cell.imageView.tintColor = dir ? STS2Theme.fish : STS2Theme.cat;
    cell.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    NSURL *url = item[@"url"];
    if ([item[@"dir"] boolValue]) { [self.navigationController pushViewController:[[STS2FileBrowserViewController alloc] initWithDirectory:url root:self.root] animated:YES]; return; }
    UIView *source = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:url.lastPathComponent message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = STS2Theme.cat;
    if (IsTextLike(url) && [item[@"size"] unsignedLongLongValue] <= kMaxEditableBytes)
        [sheet addAction:[UIAlertAction actionWithTitle:@"查看 / 编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            STS2TextEditorViewController *editor = [STS2TextEditorViewController new]; editor.url = url;
            [self.navigationController pushViewController:editor animated:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = source; share.popoverPresentationController.sourceRect = source.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }]];
    BOOL protectedPack = [url.lastPathComponent isEqualToString:@"StS2.pck"] && [url.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqual:self.root.URLByStandardizingPath.path];
    if (!protectedPack) [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self confirmDelete:url]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source; sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)confirmDelete:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除文件？" message:[NSString stringWithFormat:@"%@ 会被永久删除，无法恢复。", url.lastPathComponent] preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"永久删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        NSError *error = nil;
        if (![NSFileManager.defaultManager removeItemAtURL:url error:&error]) {
            [STS2Log log:STS2LogLevelError tag:STS2LogTagUI message:[@"删除文件失败：" stringByAppendingString:url.lastPathComponent] detail:error];
            Alert(self, @"删除失败", error.localizedDescription);
        } else STS2LogI(STS2LogTagUI, @"文件浏览中删除了 %@", url.lastPathComponent);
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

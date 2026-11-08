#import "STS2NexusViewController.h"
#import "STS2NexusMods.h"
#import "STS2ModStore.h"
#import "STS2SecretStore.h"
#import "STS2WorkshopViewController.h"
#import "STS2Log.h"
#import "STS2Theme.h"

static NSString *StripHTML(NSString *text) {
    NSString *out = [[NSRegularExpression regularExpressionWithPattern:@"<br\\s*/?>" options:NSRegularExpressionCaseInsensitive error:nil] stringByReplacingMatchesInString:text ?: @"" options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n"];
    out = [[NSRegularExpression regularExpressionWithPattern:@"(<[^>]+>|\\[/?[a-zA-Z0-9*]+(=[^\\]]*)?\\])" options:0 error:nil] stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@""];
    for (NSArray *pair in @[@[@"&amp;", @"&"], @[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&nbsp;", @" "]]) out = [out stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface STS2NexusModViewController : STS2FormViewController
@property(nonatomic, strong) NSDictionary *mod;
@property(nonatomic, strong) NSArray<NSDictionary *> *files;
@property(nonatomic, strong) STS2NexusMods *client;
@property(nonatomic, strong) STS2ModStore *store;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL premium, busy;
@end

@implementation STS2NexusModViewController
- (void)viewDidLoad {
    self.title = self.mod[@"name"];
    __weak STS2NexusModViewController *weakSelf = self;
    self.builder = ^NSArray *(STS2FormViewController *form) { return [weakSelf sections]; };
    [super viewDidLoad];
    [self.client mod:self.mod[@"id"] completion:^(NSDictionary *full, NSError *error) { if (full) { weakSelf.mod = full; [weakSelf rebuild]; } }];
    [self.client filesForMod:self.mod[@"id"] completion:^(NSArray *files, NSError *error) { weakSelf.files = files; weakSelf.status = error.localizedDescription; [weakSelf rebuild]; }];
}
- (NSArray *)sections {
    __weak STS2NexusModViewController *weakSelf = self;
    NSString *info = [NSString stringWithFormat:@"作者 %@ · 版本 %@%@", [self.mod[@"author"] length] ? self.mod[@"author"] : @"?", [self.mod[@"version"] length] ? self.mod[@"version"] : @"?", [self.mod[@"downloads"] length] ? [NSString stringWithFormat:@" · %@ 次下载", self.mod[@"downloads"]] : @""];
    NSString *body = StripHTML([self.mod[@"description"] length] ? self.mod[@"description"] : self.mod[@"summary"]);
    STS2FormSection *about = [STS2FormSection sectionWithTitle:self.mod[@"name"] footer:nil rows:@[
        [STS2FormRow infoWithTitle:info detail:body.length > 1500 ? [[body substringToIndex:1500] stringByAppendingString:@"…"] : body],
        [STS2FormRow rowWithTitle:@"在浏览器打开 MOD 页面" detail:@"普通账号在网页上点「Mod Manager Download」，复制 nxm:// 链接后回到这里粘贴" symbol:@"safari" action:^(UIView *v) { [UIApplication.sharedApplication openURL:[NSURL URLWithString:weakSelf.mod[@"page"]] options:@{} completionHandler:nil]; }],
        [STS2FormRow rowWithTitle:@"粘贴 nxm:// 下载链接" detail:nil symbol:@"link" action:^(UIView *v) { [weakSelf pasteNxm]; }],
    ]];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *file in self.files) {
        NSString *size = [NSByteCountFormatter stringFromByteCount:[file[@"sizeKB"] longLongValue] * 1024 countStyle:NSByteCountFormatterCountStyleFile];
        STS2FormRow *row = [STS2FormRow rowWithTitle:[NSString stringWithFormat:@"%@%@", [file[@"primary"] boolValue] ? @"★ " : @"", file[@"name"]] detail:[NSString stringWithFormat:@"%@ · %@ · %@ · %@", file[@"version"], file[@"category"], size, file[@"fileName"]] symbol:@"arrow.down.circle" action:^(UIView *v) { [weakSelf downloadFile:file key:nil expires:nil]; }];
        row.disabled = self.busy;
        [rows addObject:row];
    }
    if (!rows.count) [rows addObject:[STS2FormRow infoWithTitle:self.files ? @"没有可下载的文件" : @"正在读取文件列表…" detail:nil]];
    STS2FormSection *files = [STS2FormSection sectionWithTitle:@"文件" footer:self.status ?: (self.premium ? @"Premium 账号可直接下载。" : @"直接下载只对 Premium 开放；普通账号请用上面的 nxm:// 链接。只支持 ZIP / PCK；资源 PCK 可启用，DLL 代码 MOD 归档（iOS 不能运行时加载 DLL）。") rows:rows];
    return @[about, files];
}
- (void)pasteNxm {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"粘贴 nxm:// 链接" message:@"在 Nexus 网页点「Mod Manager Download」后复制得到的链接。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"nxm://slaythespire2/mods/…/files/…?key=…&expires=…"; f.text = UIPasteboard.generalPasteboard.string; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSDictionary *link = [STS2NexusMods parseLink:weak.textFields.firstObject.text ?: @""];
        if (!link[@"fileId"] || !link[@"key"]) { [self alert:@"链接无效" message:@"需要完整的 nxm://slaythespire2/mods/…/files/…?key=…&expires=… 链接。"]; return; }
        NSDictionary *file = nil;
        for (NSDictionary *f in self.files) if ([f[@"id"] isEqual:link[@"fileId"]]) file = f;
        [self downloadFile:file ?: @{@"id": link[@"fileId"], @"fileName": [link[@"fileId"] stringByAppendingString:@".zip"], @"name": link[@"fileId"]} key:link[@"key"] expires:link[@"expires"]];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)downloadFile:(NSDictionary *)file key:(NSString *)key expires:(NSString *)expires {
    if (self.busy) return;
    NSString *ext = [file[@"fileName"] pathExtension].lowercaseString;
    if (ext.length && ![@[@"zip", @"pck"] containsObject:ext]) { [self alert:@"格式不支持" message:[NSString stringWithFormat:@"%@ 是 %@ 格式；iPad 只能导入 ZIP / PCK。可在电脑上解压后重新打包为 ZIP 再从「本地 MOD」导入。", file[@"fileName"], ext]]; return; }
    self.busy = YES; self.status = @"获取下载地址…"; [self rebuild];
    STS2LogI(STS2LogTagNexus, @"下载 Nexus MOD %@ 文件 %@", self.mod[@"id"], file[@"id"]);
    __weak STS2NexusModViewController *weakSelf = self;
    void (^fail)(NSError *) = ^(NSError *error) {
        weakSelf.busy = NO; weakSelf.status = error.localizedDescription; [weakSelf rebuild];
        [STS2Log log:STS2LogLevelError tag:STS2LogTagNexus message:@"Nexus 下载/导入失败" detail:error];
        [weakSelf alert:@"下载未完成" message:error.localizedDescription];
    };
    [self.client downloadLinksForMod:self.mod[@"id"] file:file[@"id"] key:key expires:expires completion:^(NSArray<NSURL *> *urls, NSError *error) {
        if (!urls.count) { fail(error); return; }
        [weakSelf.client download:urls.firstObject fileName:[file[@"fileName"] length] ? file[@"fileName"] : urls.firstObject.lastPathComponent progress:^(double f) {
            weakSelf.status = [NSString stringWithFormat:@"下载中 %.0f%%", f * 100]; [weakSelf rebuild];
        } completion:^(NSURL *local, NSError *downloadError) {
            if (!local) { fail(downloadError); return; }
            weakSelf.status = @"导入本地 MOD…"; [weakSelf rebuild];
            [weakSelf.store importDocumentURL:local source:[NSString stringWithFormat:@"Nexus Mods %@", weakSelf.mod[@"id"]] completion:^(NSError *importError) {
                [NSFileManager.defaultManager removeItemAtURL:local.URLByDeletingLastPathComponent error:nil];
                if (importError) { fail(importError); return; }
                weakSelf.busy = NO; weakSelf.status = @"已导入「本地 MOD」。"; [weakSelf rebuild];
                STS2LogI(STS2LogTagNexus, @"Nexus MOD %@ 已导入", weakSelf.mod[@"id"]);
                [NSNotificationCenter.defaultCenter postNotificationName:STS2ModsDidChangeNotification object:weakSelf];
                [weakSelf alert:@"已导入到本地 MOD" message:@"资源 PCK 可以在本地 MOD 页启用（下次启动游戏生效）；DLL 代码 MOD 会显示在「归档 / 待验证」里——iOS 的 NativeAOT 不能在运行时加载 DLL / Harmony。"];
            }];
        }];
    }];
}
@end

@interface STS2NexusViewController ()
@property(nonatomic, strong) NSURL *documents;
@property(nonatomic, strong) STS2ModStore *store;
@property(nonatomic, strong) NSArray<NSDictionary *> *mods;
@property(nonatomic) STS2NexusFeed feed;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, strong) NSDictionary *user;
@end

@implementation STS2NexusViewController
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if ((self = [super init])) {
        _documents = documentsURL; _store = [[STS2ModStore alloc] initWithDocumentsURL:documentsURL];
        self.title = @"Nexus Mods";
        __weak STS2NexusViewController *weakSelf = self;
        self.builder = ^NSArray *(STS2FormViewController *form) { return [weakSelf sections]; };
    }
    return self;
}
- (STS2NexusMods *)client { return [[STS2NexusMods alloc] initWithApiKey:[STS2SecretStore secretForKey:STS2SecretNexusApiKey]]; }
- (void)viewDidLoad { [super viewDidLoad]; [self validate]; [self load]; }
- (void)validate {
    if (![STS2SecretStore secretForKey:STS2SecretNexusApiKey].length) return;
    [[self client] validate:^(NSDictionary *user, NSError *error) { self.user = user; if (error) self.status = error.localizedDescription; [self rebuild]; }];
}
- (void)load {
    self.status = @"加载中…"; [self rebuild];
    [[self client] feed:self.feed completion:^(NSArray *mods, NSError *error) { self.mods = mods; self.status = error.localizedDescription; [self rebuild]; }];
}
- (NSArray *)sections {
    __weak STS2NexusViewController *weakSelf = self;
    BOOL hasKey = [STS2SecretStore secretForKey:STS2SecretNexusApiKey].length > 0;
    NSString *account = !hasKey ? @"未填写（热门列表可以不填；文件列表与下载需要）" : self.user ? [NSString stringWithFormat:@"%@%@", self.user[@"name"], [self.user[@"premium"] boolValue] ? @" · Premium" : @" · 普通账号"] : @"已保存在钥匙串";
    STS2FormSection *accountSection = [STS2FormSection sectionWithTitle:@"账号" footer:@"API key 在 nexusmods.com「账号设置 → API Keys」生成，只保存在本机钥匙串，不进日志与导出。" rows:@[
        [STS2FormRow rowWithTitle:@"API key" detail:account symbol:@"key" action:^(UIView *v) { [weakSelf editKey]; }],
        [STS2FormRow rowWithTitle:@"按链接打开" detail:@"粘贴 MOD 页面链接、MOD 编号或 nxm:// 链接" symbol:@"link" action:^(UIView *v) { [weakSelf openLink]; }],
    ]];
    NSArray *names = @[@"热门", @"最新发布", @"最近更新"];
    NSMutableArray *feedRows = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        STS2FormRow *row = [STS2FormRow rowWithTitle:[NSString stringWithFormat:@"%@%@", i == self.feed ? @"● " : @"○ ", names[i]] detail:nil symbol:nil action:^(UIView *v) { weakSelf.feed = (STS2NexusFeed)i; [weakSelf load]; }];
        [feedRows addObject:row];
    }
    NSMutableArray *modRows = [NSMutableArray array];
    for (NSDictionary *mod in self.mods) {
        NSString *detail = [NSString stringWithFormat:@"%@%@", [mod[@"author"] length] ? [mod[@"author"] stringByAppendingString:@" · "] : @"", StripHTML(mod[@"summary"])];
        [modRows addObject:[STS2FormRow rowWithTitle:mod[@"name"] detail:detail symbol:@"shippingbox" action:^(UIView *v) { [weakSelf openMod:mod]; }]];
    }
    if (!modRows.count) [modRows addObject:[STS2FormRow infoWithTitle:self.status ?: @"没有内容" detail:nil]];
    return @[accountSection, [STS2FormSection sectionWithTitle:@"列表" footer:nil rows:feedRows], [STS2FormSection sectionWithTitle:names[self.feed] footer:self.mods.count ? self.status : nil rows:modRows]];
}
- (void)editKey {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nexus Mods API key" message:@"留空表示删除。" preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.secureTextEntry = YES; f.placeholder = @"API key"; f.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSError *error = nil;
        if (![STS2SecretStore setSecret:weak.textFields.firstObject.text forKey:STS2SecretNexusApiKey error:&error]) { [self alert:@"保存失败" message:error.localizedDescription]; return; }
        self.user = nil; [self validate]; [self load];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)openLink {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"按链接打开" message:nil preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"https://www.nexusmods.com/slaythespire2/mods/…"; f.text = UIPasteboard.generalPasteboard.string; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSDictionary *link = [STS2NexusMods parseLink:weak.textFields.firstObject.text ?: @""];
        if (!link) { [self alert:@"无法识别" message:@"请粘贴杀戮尖塔 2 的 Nexus MOD 页面链接、编号或 nxm:// 链接。"]; return; }
        STS2NexusModViewController *mod = [self openMod:@{@"id": link[@"modId"], @"name": [@"MOD " stringByAppendingString:link[@"modId"]], @"page": [NSString stringWithFormat:@"https://www.nexusmods.com/slaythespire2/mods/%@", link[@"modId"]]}];
        if (link[@"key"]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [mod downloadFile:@{@"id": link[@"fileId"], @"fileName": @"", @"name": link[@"fileId"]} key:link[@"key"] expires:link[@"expires"]];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (STS2NexusModViewController *)openMod:(NSDictionary *)mod {
    STS2NexusModViewController *controller = [STS2NexusModViewController new];
    controller.mod = mod; controller.client = [self client]; controller.store = self.store; controller.premium = [self.user[@"premium"] boolValue];
    [self.navigationController pushViewController:controller animated:YES];
    return controller;
}
@end

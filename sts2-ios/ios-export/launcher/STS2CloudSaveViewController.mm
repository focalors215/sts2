#import "STS2CloudSaveViewController.h"
#import "STS2LauncherConfigStore.h"
#import "STS2SaveArchiveStore.h"
#import "STS2SecretStore.h"
#import "STS2WebDavSync.h"
#import "STS2Log.h"
#import "STS2Theme.h"

static NSDictionary *WebDavSettings(STS2LauncherConfigStore *config) {
    id value = [config launcherSettingForKey:@"webdav"];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

@interface STS2CloudSaveViewController ()
@property(nonatomic, strong) STS2LauncherConfigStore *config;
@property(nonatomic, strong) STS2SaveArchiveStore *saves;
@property(nonatomic, strong) NSURL *documents;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic) BOOL working;
@end

@implementation STS2CloudSaveViewController
+ (STS2WebDavSync *)syncWithConfig:(STS2LauncherConfigStore *)config documentsURL:(NSURL *)documentsURL {
    NSDictionary *s = WebDavSettings(config);
    if (![s[@"baseUrl"] length]) return nil;
    STS2WebDavConfig *c = [STS2WebDavConfig new];
    c.baseURL = s[@"baseUrl"]; c.username = s[@"username"] ?: @""; c.remoteSlot = s[@"remoteSlot"] ?: @"";
    c.syncSettingsSave = [s[@"syncSettingsSave"] boolValue];
    c.password = [STS2SecretStore secretForKey:STS2SecretWebDavPassword] ?: @"";
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[STS2WebDavSync alloc] initWithConfig:c accountURL:[documentsURL URLByAppendingPathComponent:@"default/1" isDirectory:YES] stateURL:[support URLByAppendingPathComponent:@"webdav" isDirectory:YES]];
}
+ (BOOL)autoSyncEnabled:(STS2LauncherConfigStore *)config { return [WebDavSettings(config)[@"autoSync"] boolValue] && [WebDavSettings(config)[@"baseUrl"] length]; }

- (instancetype)initWithConfig:(STS2LauncherConfigStore *)config saves:(STS2SaveArchiveStore *)saves documentsURL:(NSURL *)documentsURL ioQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _config = config; _saves = saves; _documents = documentsURL; _queue = queue;
        self.title = @"云存档";
        __weak STS2CloudSaveViewController *weakSelf = self;
        self.builder = ^NSArray *(STS2FormViewController *form) { return [weakSelf sections]; };
    }
    return self;
}

- (void)updateSetting:(NSString *)key value:(id)value {
    NSMutableDictionary *s = [WebDavSettings(self.config) mutableCopy];
    if (value) s[key] = value; else [s removeObjectForKey:key];
    NSError *error = nil;
    if (![self.config setLauncherSetting:s forKey:@"webdav" error:&error]) [self alert:@"保存失败" message:error.localizedDescription];
}

- (NSArray<STS2FormSection *> *)sections {
    NSDictionary *s = WebDavSettings(self.config);
    BOOL configured = [s[@"baseUrl"] length] > 0;
    BOOL hasPassword = [STS2SecretStore secretForKey:STS2SecretWebDavPassword].length > 0;
    __weak STS2CloudSaveViewController *weakSelf = self;
    NSString *slot = [STS2WebDavConfig sanitizeSlot:s[@"remoteSlot"] ?: @""];
    STS2FormSection *server = [STS2FormSection sectionWithTitle:@"WebDAV 服务器" footer:@"支持坚果云、Nextcloud、群晖等 WebDAV。远端目录为 SlayTheSpire2/saves/<槽位>/，与 Android 启动器相同；两台设备填同一个槽位名即可共用云存档。密码只保存在本机钥匙串。" rows:@[
        [STS2FormRow rowWithTitle:@"服务器地址" detail:configured ? s[@"baseUrl"] : @"未设置（例如 https://dav.jianguoyun.com/dav/）" symbol:@"server.rack" action:^(UIView *v) { [weakSelf editField:@"baseUrl" title:@"服务器地址" placeholder:@"https://…/dav/" secure:NO]; }],
        [STS2FormRow rowWithTitle:@"用户名" detail:[s[@"username"] length] ? s[@"username"] : @"未设置" symbol:@"person" action:^(UIView *v) { [weakSelf editField:@"username" title:@"用户名" placeholder:@"账号" secure:NO]; }],
        [STS2FormRow rowWithTitle:@"密码 / 应用密码" detail:hasPassword ? @"已保存在钥匙串" : @"未设置" symbol:@"key" action:^(UIView *v) { [weakSelf editField:nil title:@"密码 / 应用密码" placeholder:@"密码" secure:YES]; }],
        [STS2FormRow rowWithTitle:@"远程槽位" detail:[NSString stringWithFormat:@"%@（留空为 global）", slot] symbol:@"tray.2" action:^(UIView *v) { [weakSelf editField:@"remoteSlot" title:@"远程槽位" placeholder:@"global" secure:NO]; }],
        [STS2FormRow switchWithTitle:@"同步 settings.save" detail:@"游戏设置也一起同步（不同设备分辨率等设置可能互相覆盖）" on:[s[@"syncSettingsSave"] boolValue] changed:^(BOOL on) { [weakSelf updateSetting:@"syncSettingsSave" value:@(on)]; }],
    ]];
    STS2FormSection *actions = [STS2FormSection sectionWithTitle:@"同步" footer:self.statusText ?: @"拉取前会先自动创建本地快照。两边都改过同一文件时会提示冲突，由你选择保留云端还是本机。" rows:@[
        [STS2FormRow rowWithTitle:@"测试连接" detail:nil symbol:@"bolt.horizontal" action:^(UIView *v) { [weakSelf run:@"测试连接" force:NO operation:0]; }],
        [STS2FormRow rowWithTitle:@"从云端拉取" detail:@"把云端较新的存档下载到本机" symbol:@"icloud.and.arrow.down" action:^(UIView *v) { [weakSelf run:@"拉取" force:NO operation:1]; }],
        [STS2FormRow rowWithTitle:@"上传到云端" detail:@"把本机改动上传" symbol:@"icloud.and.arrow.up" action:^(UIView *v) { [weakSelf run:@"上传" force:NO operation:2]; }],
        [STS2FormRow switchWithTitle:@"自动同步" detail:@"打开启动器时上传上次游戏的进度；开始游戏前先从云端拉取" on:[s[@"autoSync"] boolValue] changed:^(BOOL on) { [weakSelf updateSetting:@"autoSync" value:@(on)]; STS2LogI(STS2LogTagCloud, @"WebDAV 自动同步：%@", on ? @"开" : @"关"); }],
    ]];
    for (STS2FormRow *row in actions.rows) if (!row.isSwitch) row.disabled = !configured || self.working;
    STS2FormSection *steam = [STS2FormSection sectionWithTitle:@"Steam 云存档" footer:@"Steam 云同步需要登录 Steam 账号并使用 Steam 客户端协议，iPad 版暂不支持；可以在电脑上用 Steam 同步后，通过 WebDAV 或导入 ZIP 存档迁移。" rows:@[]];
    return @[server, actions, steam];
}

- (void)editField:(NSString *)key title:(NSString *)title placeholder:(NSString *)placeholder secure:(BOOL)secure {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = placeholder; f.secureTextEntry = secure; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.text = key ? WebDavSettings(self.config)[key] : @""; f.keyboardType = [key isEqual:@"baseUrl"] ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak = a;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *value = [weak.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        if (!key) { [STS2SecretStore setSecret:value forKey:STS2SecretWebDavPassword error:nil]; }
        else {
            if ([key isEqual:@"baseUrl"] && value.length) {
                NSURL *url = [NSURL URLWithString:value];
                if (!url.host.length || !([url.scheme.lowercaseString isEqual:@"https"] || [url.scheme.lowercaseString isEqual:@"http"])) { [self alert:@"地址无效" message:@"请输入以 https:// 开头的 WebDAV 地址。"]; return; }
                if ([url.scheme.lowercaseString isEqual:@"http"]) STS2LogW(STS2LogTagCloud, @"WebDAV 使用 HTTP 明文地址");
            }
            [self updateSetting:key value:value.length ? value : nil];
        }
        [self rebuild];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// operation: 0 测试，1 拉取，2 上传
- (void)run:(NSString *)name force:(BOOL)force operation:(NSInteger)operation {
    STS2WebDavSync *sync = [STS2CloudSaveViewController syncWithConfig:self.config documentsURL:self.documents];
    if (!sync || self.working) return;
    self.working = YES; self.statusText = [name stringByAppendingString:@"中…"]; [self rebuild];
    __weak STS2CloudSaveViewController *weakSelf = self;
    void (^progress)(NSString *) = ^(NSString *text) { dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.statusText = text; [weakSelf rebuild]; }); };
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        NSString *result = nil;
        if (operation == 1) {
            NSError *snapshotError = nil;
            NSURL *snapshot = [self.saves createSnapshotWithName:@"云同步前快照" error:&snapshotError];
            if (snapshot) [self.saves pruneSnapshotsTitled:@"云同步前快照" keep:5];
            else if (!([snapshotError.domain isEqual:@"STS2SaveArchiveStore"] && snapshotError.code == 4)) { error = snapshotError; }
        }
        if (!error) {
            if (operation == 0) result = [sync testConnection:&error];
            else if (operation == 1) result = [sync pull:force progress:progress error:&error];
            else result = [sync push:force progress:progress error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            STS2CloudSaveViewController *s = weakSelf;
            if (!s) return;
            s.working = NO;
            if (result) { s.statusText = result; [s rebuild]; [s alert:name message:result]; return; }
            s.statusText = [NSString stringWithFormat:@"%@失败：%@", name, error.localizedDescription];
            [s rebuild];
            if ([error.domain isEqual:STS2WebDavErrorDomain] && error.code == STS2WebDavErrorConflict && operation != 0) {
                [s resolveConflict:error name:name operation:operation];
                return;
            }
            [STS2Log log:STS2LogLevelError tag:STS2LogTagCloud message:[NSString stringWithFormat:@"WebDAV %@失败", name] detail:error];
            [s alert:[name stringByAppendingString:@"失败"] message:error.localizedDescription];
        });
    });
}

- (void)resolveConflict:(NSError *)error name:(NSString *)name operation:(NSInteger)operation {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"云存档冲突" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"用云端覆盖本机（先快照）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { STS2LogW(STS2LogTagCloud, @"用户选择以云端为准"); [self run:@"强制拉取" force:YES operation:1]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"用本机覆盖云端" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { STS2LogW(STS2LogTagCloud, @"用户选择以本机为准"); [self run:@"强制上传" force:YES operation:2]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

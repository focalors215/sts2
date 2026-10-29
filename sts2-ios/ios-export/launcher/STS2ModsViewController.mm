#import "STS2ModsViewController.h"
#import "STS2ModStore.h"
#import "STS2Theme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
@interface STS2ModsViewController () <UIDocumentPickerDelegate>
@property STS2ModStore *store;
@property NSArray<NSDictionary *> *mods;
@property NSDictionary *loadStatus;
@property NSDictionary *compiledLoadStatus;
@property NSURL *documentsURL;
@property NSUInteger pendingOperationCount;
@end
@implementation STS2ModsViewController
- (BOOL)hasPendingOperations { return self.pendingOperationCount > 0; }
- (BOOL)busy { return self.hasPendingOperations; }
- (void)beginOperation {
    NSAssert(NSThread.isMainThread, @"MOD lifecycle state is main-thread only");
    if (!self.pendingOperationCount) [self willChangeValueForKey:@"hasPendingOperations"];
    self.pendingOperationCount++;
    if (self.pendingOperationCount == 1) [self didChangeValueForKey:@"hasPendingOperations"];
    if (self.isViewLoaded) [self.tableView reloadData];
}
- (void)endOperation {
    NSAssert(NSThread.isMainThread && self.pendingOperationCount > 0, @"Unbalanced MOD operation");
    if (!self.pendingOperationCount) return;
    if (self.pendingOperationCount == 1) [self willChangeValueForKey:@"hasPendingOperations"];
    self.pendingOperationCount--;
    if (!self.pendingOperationCount) [self didChangeValueForKey:@"hasPendingOperations"];
    if (self.isViewLoaded) [self.tableView reloadData];
}
- (instancetype)initWithStore:(STS2ModStore *)store {if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_store=store;_mods=@[];self.title=@"本地 MOD";}return self;}
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {self=[self initWithStore:[[STS2ModStore alloc]initWithDocumentsURL:documentsURL]];if(self)_documentsURL=documentsURL;return self;}
- (void)viewDidLoad {[super viewDidLoad];self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=80;self.view.backgroundColor=UIColor.clearColor;self.tableView.backgroundColor=UIColor.clearColor;self.tableView.tintColor=STS2Theme.cat;[self reloadMods];}
- (void)reloadMods {
    [self beginOperation];
    [self.store loadWithCompletion:^(NSArray *mods, NSError *error) {
        self.mods = mods;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *resourceData = self.documentsURL ? [NSData dataWithContentsOfURL:[self.documentsURL URLByAppendingPathComponent:@"Launcher/mod-load-status.json"]] : nil;
            NSData *compiledData = self.documentsURL ? [NSData dataWithContentsOfURL:[self.documentsURL URLByAppendingPathComponent:@"Launcher/compiled-mod-load-status.json"]] : nil;
            id resourceStatus = resourceData ? [NSJSONSerialization JSONObjectWithData:resourceData options:0 error:nil] : nil;
            id compiledStatus = compiledData ? [NSJSONSerialization JSONObjectWithData:compiledData options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loadStatus = [resourceStatus isKindOfClass:NSDictionary.class] ? resourceStatus : nil;
                self.compiledLoadStatus = [compiledStatus isKindOfClass:NSDictionary.class] ? compiledStatus : nil;
                [self endOperation];
                if (error) [self showError:error];
            });
        });
    }];
}
- (void)showError:(NSError *)error {UIAlertController *a=[UIAlertController alertControllerWithTitle:@"操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (NSArray *)group:(NSInteger)section {NSPredicate *p=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *m,NSDictionary *bindings){BOOL enabledType=[m[@"resourceSafe"] boolValue]||[m[@"compiledSupported"] boolValue];return enabledType==(section==1);}];return [self.mods filteredArrayUsingPredicate:p];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?1:MAX(1,[self group:section].count);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"✦ 安装 MOD",@"✦ 可启用的 MOD",@"✦ 归档 / 待验证"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"从“文件”导入本地 ZIP 或 PCK，完成校验后显示兼容性。";if(section==1)return @"启停将在下次冷启动时生效；开关表示已请求加载，不代表游戏运行成功。只有应用内置编译能力与完整导入文件匹配的代码 MOD 才可启用。资源校验通过不代表与所有游戏版本兼容。长按 MOD 可调整顺序或删除。";return @"NativeAOT 不能运行期加载普通 DLL / Harmony MOD。代码 MOD 可保存归档，但需要明确的应用内置预编译支持才能启用；依赖与游戏版本未确认的 MOD 不会启用。";}
// Resource packs retain their separate per-file result format and aggregation.
- (NSString *)resourceLoadSummaryForMod:(NSDictionary *)mod status:(NSDictionary *)status {
    if (![mod[@"enabled"] boolValue] || !status) return nil;
    NSArray *packs = mod[@"packs"];
    if (!packs.count) return nil;
    NSArray *entries = [status[@"entries"] isKindOfClass:NSArray.class] ? status[@"entries"] : @[];
    NSUInteger loaded = 0, failed = 0;
    NSString *firstError = nil;
    for (NSDictionary *pack in packs) {
        NSString *expectedPath = [NSString stringWithFormat:@"Launcher/Mods/%@/payload/%@", mod[@"id"], pack[@"path"]];
        NSDictionary *match = nil;
        for (id value in entries) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *entry = value;
            BOOL samePack = [entry[@"id"] isEqual:mod[@"id"]] && [entry[@"path"] isEqual:expectedPath];
            BOOL verifiedHash = [entry[@"sha256"] isEqual:pack[@"sha256"]];
            BOOL validationFailedBeforeHash = [entry[@"status"] isEqual:@"failed"] && !entry[@"sha256"];
            if (samePack && (verifiedHash || validationFailedBeforeHash)) { match = entry; break; }
        }
        if ([match[@"status"] isEqual:@"loaded"]) loaded++;
        else if ([match[@"status"] isEqual:@"failed"]) {
            failed++;
            if (!firstError && [match[@"error"] isKindOfClass:NSString.class]) firstError = match[@"error"];
        }
    }
    if (![status[@"completed"] boolValue]) return [NSString stringWithFormat:@"上次启动：加载未完成（%lu/%lu 包成功）", (unsigned long)loaded, (unsigned long)packs.count];
    if (loaded == packs.count) return [NSString stringWithFormat:@"上次启动：全部 %lu 包已加载", (unsigned long)packs.count];
    if (failed) return [NSString stringWithFormat:@"上次启动：%lu/%lu 包成功，%lu 包失败%@", (unsigned long)loaded, (unsigned long)packs.count, (unsigned long)failed, firstError.length ? [@"：" stringByAppendingString:firstError] : @""];
    NSString *globalError = [status[@"error"] isKindOfClass:NSString.class] ? status[@"error"] : nil;
    if (globalError.length) return [@"上次启动：配置加载失败：" stringByAppendingString:globalError];
    return [NSString stringWithFormat:@"上次启动：%lu/%lu 包有成功记录，其余待验证", (unsigned long)loaded, (unsigned long)packs.count];
}
// Compiled mods use build identity and loader status, isolated from PCK status.
- (NSString *)compiledLoadSummaryForMod:(NSDictionary *)mod status:(NSDictionary *)status {
    if (![mod[@"compiledSupported"] boolValue] || !status) return nil;
    if ([status[@"schemaVersion"] integerValue] != 1 || ![status[@"completed"] boolValue] || ![status[@"buildId"] isEqual:mod[@"compiledBuildId"]]) return nil;
    NSArray *entries = [status[@"entries"] isKindOfClass:NSArray.class] ? status[@"entries"] : @[];
    for(id value in entries){
        if(![value isKindOfClass:NSDictionary.class])continue;
        NSDictionary *entry=value;
        BOOL same=[entry[@"id"] isEqual:mod[@"id"]]&&[entry[@"modId"] isEqual:mod[@"compiledModId"]]&&[entry[@"feature"] isEqual:mod[@"compiledFeature"]]&&[entry[@"sourceSha256"] isEqual:mod[@"compiledSourceSha256"]];
        if(!same)continue;
        if(![entry[@"requested"] boolValue])return @"上次启动：该 MOD 未请求加载";
        if([entry[@"status"] isEqual:@"loaded"])return @"上次启动：游戏确认已加载";
        if([entry[@"status"] isEqual:@"failed"]){NSString *error=[entry[@"error"] isKindOfClass:NSString.class]?entry[@"error"]:@"未提供错误详情";return [@"上次启动：加载失败：" stringByAppendingString:error];}
        if([entry[@"status"] isEqual:@"disabled"])return @"上次启动：该 MOD 已禁用";
    }
    return nil;
}
- (NSString *)loadSummaryForMod:(NSDictionary *)mod {
    if ([mod[@"compiledSupported"] boolValue]) return [self compiledLoadSummaryForMod:mod status:self.compiledLoadStatus];
    if ([mod[@"resourceSafe"] boolValue]) return [self resourceLoadSummaryForMod:mod status:self.loadStatus];
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0;cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textColor=STS2Theme.inkSoft;cell.backgroundColor=STS2Theme.card;cell.textLabel.textColor=STS2Theme.ink;cell.textLabel.font=[STS2Theme font:UIFontTextStyleBody bold:YES];cell.detailTextLabel.font=[STS2Theme font:UIFontTextStyleSubheadline bold:NO];
    if(path.section==0){cell.textLabel.text=@"从“文件”导入 ZIP / PCK";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.userInteractionEnabled=!self.busy;cell.textLabel.textColor=self.busy?STS2Theme.inkSoft:STS2Theme.cat;return cell;}
    NSArray *group=[self group:path.section];if(!group.count){cell.textLabel.text=path.section==1?@"尚未安装可启用 MOD":@"暂无归档 MOD";cell.detailTextLabel.text=@"从上方“文件”导入后会在这里显示。";cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;}
    NSDictionary *m=group[path.row];cell.textLabel.text=m[@"displayName"];BOOL enabled=[m[@"enabled"] boolValue];
    NSString *status;
    if([m[@"resourceSafe"] boolValue]||[m[@"compiledSupported"] boolValue])status=enabled?@"下次启动：已请求加载（尚未验证运行）":@"下次启动：不加载";
    else status=m[@"status"];
    if([m[@"compiledSupported"] boolValue])status=[status stringByAppendingFormat:@"\n预编译支持：%@ · %@",m[@"compiledFeature"],m[@"compiledBuildId"]];
    NSString *summary = [self loadSummaryForMod:m];
    if (summary) status = [status stringByAppendingFormat:@"\n%@", summary];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@ · %@",status,m[@"source"],[NSByteCountFormatter stringFromByteCount:[m[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    if([m[@"resourceSafe"] boolValue]||[m[@"compiledSupported"] boolValue]){UISwitch *toggle=[[UISwitch alloc]init];toggle.on=enabled;toggle.onTintColor=STS2Theme.cat;toggle.accessibilityLabel=[NSString stringWithFormat:@"启用 %@",m[@"displayName"]];toggle.tag=[self.mods indexOfObject:m];[toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];toggle.enabled=!self.busy;cell.accessoryView=toggle;}return cell;
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [STS2Theme font:UIFontTextStyleHeadline bold:YES];
        header.textLabel.textColor = STS2Theme.cat;
    }
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.font = [STS2Theme font:UIFontTextStyleFootnote bold:NO];
        footer.textLabel.textColor = STS2Theme.inkSoft;
    }
}
- (void)toggle:(UISwitch *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.mods.count) return;
    NSDictionary *mod = self.mods[sender.tag];
    if (self.hasPendingOperations) { sender.on = [mod[@"enabled"] boolValue]; return; }
    [self beginOperation];
    STS2ModStore *store = self.store;
    [store setEnabled:sender.on modID:mod[@"id"] completion:^(NSError *error) {
        [self endOperation];
        [self reloadMods];
        if (error) [self showError:error];
    }];
}
// The two lists share one stored order; step relative to the neighbour in the visible list.
- (void)moveMod:(NSDictionary *)mod by:(NSInteger)delta {
    BOOL enabledType = [mod[@"resourceSafe"] boolValue] || [mod[@"compiledSupported"] boolValue];
    NSArray *group = [self group:enabledType ? 1 : 2];
    NSInteger position = (NSInteger)[group indexOfObject:mod] + delta;
    if (position < 0 || position >= (NSInteger)group.count) return;
    [self moveMod:mod toIndex:[self.mods indexOfObject:group[position]]];
}
- (void)moveMod:(NSDictionary *)mod toIndex:(NSUInteger)index {
    if (self.hasPendingOperations) return;
    [self beginOperation];
    [self.store moveModID:mod[@"id"] toIndex:index completion:^(NSError *error) {
        [self endOperation];
        [self reloadMods];
        if (error) [self showError:error];
    }];
}
- (void)deleteMod:(NSDictionary *)mod {
    if (self.hasPendingOperations) return;
    [self beginOperation];
    [self.store deleteModID:mod[@"id"] completion:^(NSError *error) {
        [self endOperation];
        [self reloadMods];
        if (error) [self showError:error];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {[tableView deselectRowAtIndexPath:path animated:YES];if(self.busy||path.section!=0)return;{UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeZIP, [UTType typeWithFilenameExtension:@"pck"]?:UTTypeData] asCopy:NO];picker.delegate=self;picker.allowsMultipleSelection=NO;[self presentViewController:picker animated:YES completion:nil];}}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {if(!urls.count)return;[self beginOperation];[self.tableView reloadData];[self.store importDocumentURL:urls.firstObject completion:^(NSError *e){[self endOperation];[self reloadMods];if(e)[self showError:e];}];}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {if(path.section==0||self.busy)return nil;NSArray *group=[self group:path.section];if(path.row>=group.count)return nil;NSDictionary *m=group[path.row];return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){UIAction *up=[UIAction actionWithTitle:@"上移" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[self moveMod:m by:-1];}];UIAction *down=[UIAction actionWithTitle:@"下移" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[self moveMod:m by:1];}];UIAction *remove=[UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"删除 MOD？" message:m[@"displayName"] preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self deleteMod:m];}]];[self presentViewController:a animated:YES completion:nil];}];remove.attributes=UIMenuElementAttributesDestructive;return [UIMenu menuWithTitle:@"下次冷启动时应用" children:@[up,down,remove]];}];}
@end

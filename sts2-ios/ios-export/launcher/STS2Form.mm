#import "STS2Form.h"
#import "STS2Theme.h"

@implementation STS2FormRow
+ (instancetype)rowWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol action:(void (^)(UIView *))action {
    STS2FormRow *row = [self new]; row.title = title; row.detail = detail; row.symbol = symbol; row.action = action; return row;
}
+ (instancetype)switchWithTitle:(NSString *)title detail:(NSString *)detail on:(BOOL)on changed:(void (^)(BOOL))changed {
    STS2FormRow *row = [self new]; row.title = title; row.detail = detail; row.isSwitch = YES; row.on = on; row.changed = changed; return row;
}
+ (instancetype)infoWithTitle:(NSString *)title detail:(NSString *)detail {
    STS2FormRow *row = [self new]; row.title = title; row.detail = detail; return row;
}
@end

@implementation STS2FormSection
+ (instancetype)sectionWithTitle:(NSString *)title footer:(NSString *)footer rows:(NSArray<STS2FormRow *> *)rows {
    STS2FormSection *s = [self new]; s.title = title; s.footer = footer; s.rows = rows; return s;
}
@end

@interface STS2FormViewController ()
@property(nonatomic, strong) NSArray<STS2FormSection *> *sections;
@end

@implementation STS2FormViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tintColor = STS2Theme.cat;
    self.view.backgroundColor = self.transparentBackground ? UIColor.clearColor : STS2Theme.background;
    self.tableView.backgroundColor = self.view.backgroundColor;
    [self rebuild];
}
- (void)rebuild { self.sections = self.builder ? self.builder(self) : @[]; if (self.isViewLoaded) [self.tableView reloadData]; }
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    a.view.tintColor = STS2Theme.cat;
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.sections[section].rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { NSString *t = self.sections[section].title; return t ? [@"✦ " stringByAppendingString:t] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return self.sections[section].footer; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    STS2FormRow *row = self.sections[indexPath.section].rows[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = STS2Theme.card;
    cell.textLabel.text = row.title; cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [STS2Theme font:UIFontTextStyleBody bold:row.action != nil || row.isSwitch];
    cell.textLabel.textColor = row.destructive ? UIColor.systemRedColor : (row.disabled ? STS2Theme.inkSoft : STS2Theme.ink);
    cell.detailTextLabel.text = row.detail; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.textColor = STS2Theme.inkSoft;
    cell.detailTextLabel.font = [STS2Theme font:UIFontTextStyleFootnote bold:NO];
    if (row.symbol) { cell.imageView.image = [UIImage systemImageNamed:row.symbol]; cell.imageView.tintColor = row.destructive ? UIColor.systemRedColor : STS2Theme.cat; }
    if (row.isSwitch) {
        UISwitch *toggle = [UISwitch new]; toggle.on = row.on; toggle.onTintColor = STS2Theme.cat; toggle.enabled = !row.disabled;
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) { row.on = toggle.on; if (row.changed) row.changed(toggle.on); }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row.action && !row.disabled) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    STS2FormRow *row = self.sections[indexPath.section].rows[indexPath.row];
    if (row.action && !row.disabled && !row.isSwitch) row.action([tableView cellForRowAtIndexPath:indexPath] ?: tableView);
}
@end

void STS2PresentSheet(UIViewController *presenter, UIViewController *content) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:content];
    nav.view.tintColor = STS2Theme.cat; nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    __weak UINavigationController *weakNav = nav;
    content.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"关闭" image:nil identifier:nil handler:^(UIAction *a) { [weakNav dismissViewControllerAnimated:YES completion:nil]; }]];
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:nav animated:YES completion:nil];
}

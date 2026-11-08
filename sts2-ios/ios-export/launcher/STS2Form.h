#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 设置类页面的简单表单（小屋配色的 inset-grouped 表格）：按钮行、开关行、说明行。
@interface STS2FormRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, copy, nullable) NSString *symbol;
@property(nonatomic, copy, nullable) void (^action)(UIView *source);
@property(nonatomic) BOOL isSwitch, on, destructive;
@property(nonatomic) BOOL disabled;
@property(nonatomic, copy, nullable) void (^changed)(BOOL on);
+ (instancetype)rowWithTitle:(NSString *)title detail:(nullable NSString *)detail symbol:(nullable NSString *)symbol action:(nullable void (^)(UIView *source))action;
+ (instancetype)switchWithTitle:(NSString *)title detail:(nullable NSString *)detail on:(BOOL)on changed:(void (^)(BOOL on))changed;
+ (instancetype)infoWithTitle:(NSString *)title detail:(nullable NSString *)detail;
@end

@interface STS2FormSection : NSObject
@property(nonatomic, copy, nullable) NSString *title, *footer;
@property(nonatomic, copy) NSArray<STS2FormRow *> *rows;
+ (instancetype)sectionWithTitle:(nullable NSString *)title footer:(nullable NSString *)footer rows:(NSArray<STS2FormRow *> *)rows;
@end

@interface STS2FormViewController : UITableViewController
/// 每次 rebuild 时调用，返回最新的分区。
@property(nonatomic, copy, nullable) NSArray<STS2FormSection *> * (^builder)(STS2FormViewController *form);
@property(nonatomic) BOOL transparentBackground;
- (void)rebuild;
- (void)alert:(NSString *)title message:(NSString *)message;
@end

/// 包一层导航并以 page sheet 弹出（带「关闭」按钮）。
FOUNDATION_EXPORT void STS2PresentSheet(UIViewController *presenter, UIViewController *content);

NS_ASSUME_NONNULL_END

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 主题：喵喵零和小鱼的小屋。奶油色小屋 + 暖橘粉猫咪 + 海蓝小鲨鱼，深色模式为夜间小屋。
FOUNDATION_EXPORT NSString *const STS2ThemeName;

typedef NS_ENUM(NSInteger, STS2ButtonStyle) {
    STS2ButtonStylePrimary,   // 猫咪橘粉，主操作
    STS2ButtonStyleSecondary, // 小鲨鱼海蓝，次要操作
    STS2ButtonStyleNav,       // 侧栏未选中
    STS2ButtonStyleNavSelected,
};

@interface STS2Theme : NSObject
@property(class, nonatomic, readonly) UIColor *background;
@property(class, nonatomic, readonly) UIColor *card;
@property(class, nonatomic, readonly) UIColor *outline;
@property(class, nonatomic, readonly) UIColor *ink;
@property(class, nonatomic, readonly) UIColor *inkSoft;
@property(class, nonatomic, readonly) UIColor *cat;  // 喵喵零
@property(class, nonatomic, readonly) UIColor *fish; // 小鱼
/// 圆体字，跟随动态字体。
+ (UIFont *)font:(UIFontTextStyle)style bold:(BOOL)bold;
/// 与插画 logo 同款的粗圆体描边标题（暖奶油填充 + 深蓝描边）。
+ (NSAttributedString *)outlinedTitle:(NSString *)text size:(CGFloat)size;
/// 从启动器插画里按像素矩形裁出一块（logo、猫和鲨鱼等）。
+ (nullable UIImage *)artCrop:(CGRect)pixelRect;
+ (UIButtonConfiguration *)configurationForStyle:(STS2ButtonStyle)style title:(NSString *)title symbol:(nullable NSString *)symbol;
@end

/// 圆角奶油卡片，边框随明暗模式更新。
@interface STS2CardView : UIView
+ (STS2CardView *)cardContaining:(NSArray<UIView *> *)views;
@end

typedef NS_ENUM(NSInteger, STS2MascotKind) {
    STS2MascotKindCat,   // 喵喵零：呆呆的八字分脸小猫
    STS2MascotKindShark, // 小鱼：圆滚滚的可爱小鲨鱼
};

/// 原创矢量吉祥物（纯代码绘制，不使用任何外部图片或第三方角色素材）。
@interface STS2MascotView : UIView
@property(nonatomic) STS2MascotKind kind;
+ (STS2MascotView *)mascot:(STS2MascotKind)kind size:(CGFloat)size;
@end

NS_ASSUME_NONNULL_END

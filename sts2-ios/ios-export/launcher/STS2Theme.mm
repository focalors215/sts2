#import "STS2Theme.h"
#import "STS2LauncherArt.h"
#include <initializer_list>

NSString *const STS2ThemeName = @"喵喵零和小鱼的小屋";

static UIColor *Hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}
@implementation STS2Theme
// 夜晚小屋：深蓝夜色 + 奶油字 + 灯笼琥珀 + 海蓝，取自启动器插画的配色。
+ (UIColor *)background { return Hex(0x121A33); }
+ (UIColor *)card { return [Hex(0x1B2540) colorWithAlphaComponent:0.88]; }
+ (UIColor *)outline { return Hex(0x3A476B); }
+ (UIColor *)ink { return Hex(0xFFF1D6); }
+ (UIColor *)inkSoft { return Hex(0xB9C2DA); }
+ (UIColor *)cat { return Hex(0xFFC76B); }
+ (UIColor *)fish { return Hex(0x7FB7FF); }

+ (UIFont *)font:(UIFontTextStyle)style bold:(BOOL)bold {
    UIFontDescriptor *descriptor = [UIFont preferredFontForTextStyle:style].fontDescriptor;
    UIFontDescriptor *rounded = [descriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    if (rounded)
        descriptor = rounded;
    if (bold)
        descriptor = [descriptor fontDescriptorWithSymbolicTraits:descriptor.symbolicTraits | UIFontDescriptorTraitBold] ?: descriptor;
    return [UIFont fontWithDescriptor:descriptor size:0];
}

+ (NSAttributedString *)outlinedTitle:(NSString *)text size:(CGFloat)size {
    UIFontDescriptor *d = [[UIFont systemFontOfSize:size weight:UIFontWeightHeavy].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *font = d ? [UIFont fontWithDescriptor:d size:size] : [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
    // 贴纸感：奶油填充 + 细深蓝描边 + 向下的硬阴影，在任何背景上都清晰。
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = Hex(0x0B1022); shadow.shadowOffset = CGSizeMake(0, 3); shadow.shadowBlurRadius = 0;
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : Hex(0xFFEBC8),
        NSStrokeColorAttributeName : Hex(0x1B2540),
        NSStrokeWidthAttributeName : @(-1.6),
        NSShadowAttributeName : shadow,
    }];
}
+ (UIImage *)artCrop:(CGRect)pixelRect {
    UIImage *art = STS2LauncherArtImage();
    CGImageRef cropped = art.CGImage ? CGImageCreateWithImageInRect(art.CGImage, pixelRect) : NULL;
    if (!cropped) return nil;
    UIImage *image = [UIImage imageWithCGImage:cropped scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    return image;
}

+ (UIButtonConfiguration *)configurationForStyle:(STS2ButtonStyle)style title:(NSString *)title symbol:(NSString *)symbol {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    BOOL pill = YES;
    switch (style) {
    case STS2ButtonStylePrimary: // 奶油色大按钮，同插画里的「开始游戏」
        c.baseBackgroundColor = Hex(0xFFF2D8);
        c.baseForegroundColor = Hex(0x1B2540);
        break;
    case STS2ButtonStyleSecondary:
        c.baseBackgroundColor = Hex(0x2C3A63);
        c.baseForegroundColor = STS2Theme.ink;
        break;
    case STS2ButtonStyleNav: // 深色圆角方块，同插画左侧菜单
        c.baseBackgroundColor = [Hex(0x1B2540) colorWithAlphaComponent:0.9];
        c.baseForegroundColor = STS2Theme.ink;
        pill = NO;
        break;
    case STS2ButtonStyleNavSelected:
        c.baseBackgroundColor = STS2Theme.cat;
        c.baseForegroundColor = Hex(0x1B2540);
        pill = NO;
        break;
    }
    c.cornerStyle = pill ? UIButtonConfigurationCornerStyleCapsule : UIButtonConfigurationCornerStyleLarge;
    c.title = title;
    c.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    c.imagePadding = 10;
    c.contentInsets = NSDirectionalEdgeInsetsMake(12, 18, 12, 18);
    c.titleLineBreakMode = NSLineBreakByTruncatingMiddle;
    if (style == STS2ButtonStylePrimary) {
        // 与插画「开始游戏」一致：标题后跟一枚琥珀色小猫爪（取代左侧图标）。
        c.image = [UIImage systemImageNamed:@"pawprint.fill"];
        c.imagePlacement = NSDirectionalRectEdgeTrailing;
        c.imageColorTransformer = ^UIColor *(UIColor *color) { return STS2Theme.cat; };
    }
    c.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary *out = [attributes mutableCopy];
        out[NSFontAttributeName] = [STS2Theme font:UIFontTextStyleHeadline bold:YES];
        return out;
    };
    return c;
}
@end

@implementation STS2CardView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = STS2Theme.card;
        self.layer.cornerRadius = 26;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.5;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.08;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 4);
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.borderColor = [STS2Theme.outline resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}
+ (STS2CardView *)cardContaining:(NSArray<UIView *> *)views {
    STS2CardView *card = [STS2CardView new];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
    ]];
    return card;
}
@end

static UIBezierPath *Poly(std::initializer_list<CGPoint> points) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    BOOL first = YES;
    for (CGPoint p : points) {
        if (first) [path moveToPoint:p]; else [path addLineToPoint:p];
        first = NO;
    }
    [path closePath];
    return path;
}
static void Paint(UIBezierPath *path, UIColor *fill, UIColor *stroke) {
    path.lineWidth = 2.6; path.lineJoinStyle = kCGLineJoinRound; path.lineCapStyle = kCGLineCapRound;
    if (fill) { [fill setFill]; [path fill]; }
    if (stroke) { [stroke setStroke]; [path stroke]; }
}
static UIBezierPath *Circle(CGFloat x, CGFloat y, CGFloat r) {
    return [UIBezierPath bezierPathWithOvalInRect:CGRectMake(x - r, y - r, 2 * r, 2 * r)];
}

@implementation STS2MascotView
+ (STS2MascotView *)mascot:(STS2MascotKind)kind size:(CGFloat)size {
    STS2MascotView *view = [[STS2MascotView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    view.kind = kind;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view.widthAnchor constraintEqualToConstant:size].active = YES;
    [view.heightAnchor constraintEqualToConstant:size].active = YES;
    return view;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.isAccessibilityElement = NO;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)setKind:(STS2MascotKind)kind { _kind = kind; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextScaleCTM(ctx, self.bounds.size.width / 100.0, self.bounds.size.height / 100.0);
    // 吉祥物自带浅色填充，描边固定深棕；随深色模式变浅会让眼睛消失在奶白脸上。
    UIColor *ink = Hex(0x5A3A2E);
    if (self.kind == STS2MascotKindCat) [self drawCat:ink]; else [self drawShark:ink];
    CGContextRestoreGState(ctx);
}
// 呆猫：奶白脸、放空的小圆眼、八字分脸花纹。
- (void)drawCat:(UIColor *)ink {
    UIColor *fur = Hex(0xFFF8EE), *patch = Hex(0x8C6B5A), *pink = Hex(0xFFB3B8);
    Paint(Poly({{14, 44}, {16, 8}, {44, 28}}), fur, ink);
    Paint(Poly({{86, 44}, {84, 8}, {56, 28}}), fur, ink);
    Paint(Poly({{20, 38}, {21, 17}, {36, 30}}), pink, nil);
    Paint(Poly({{80, 38}, {79, 17}, {64, 30}}), pink, nil);
    Paint([UIBezierPath bezierPathWithOvalInRect:CGRectMake(8, 26, 84, 66)], fur, ink);
    // 八字花纹：从额头中线向两侧分开
    Paint(Poly({{46, 29}, {54, 29}, {41, 52}, {29, 52}}), patch, nil);
    Paint(Poly({{54, 29}, {46, 29}, {59, 52}, {71, 52}}), patch, nil);
    // 呆呆的眼睛和小嘴
    Paint(Circle(35, 64, 3.8), ink, nil);
    Paint(Circle(65, 64, 3.8), ink, nil);
    Paint(Circle(23, 73, 5.5), [pink colorWithAlphaComponent:0.7], nil);
    Paint(Circle(77, 73, 5.5), [pink colorWithAlphaComponent:0.7], nil);
    UIBezierPath *mouth = [UIBezierPath bezierPath];
    [mouth moveToPoint:CGPointMake(44, 74)]; [mouth addQuadCurveToPoint:CGPointMake(50, 77) controlPoint:CGPointMake(46, 79)];
    [mouth addQuadCurveToPoint:CGPointMake(56, 74) controlPoint:CGPointMake(54, 79)];
    Paint(mouth, nil, ink);
    for (int side = -1; side <= 1; side += 2) {
        for (int i = 0; i < 2; i++) {
            UIBezierPath *whisker = [UIBezierPath bezierPath];
            [whisker moveToPoint:CGPointMake(50 + side * 34, 70 + i * 5)];
            [whisker addLineToPoint:CGPointMake(50 + side * 47, 66 + i * 10)];
            whisker.lineWidth = 1.8; whisker.lineCapStyle = kCGLineCapRound; [ink setStroke]; [whisker stroke];
        }
    }
}
// 小鲨鱼：圆圆的蓝灰身体、大眼睛、带小尖牙的笑。
- (void)drawShark:(UIColor *)ink {
    UIColor *body = Hex(0x8CC8E3), *belly = Hex(0xF4FBFF), *pink = Hex(0xFFB3B8);
    Paint(Poly({{88, 56}, {99, 38}, {99, 74}}), body, ink);
    Paint(Poly({{42, 36}, {55, 5}, {66, 36}}), body, ink);
    Paint([UIBezierPath bezierPathWithOvalInRect:CGRectMake(6, 28, 88, 58)], body, ink);
    Paint([UIBezierPath bezierPathWithOvalInRect:CGRectMake(20, 60, 56, 22)], belly, nil);
    for (int i = 0; i < 3; i++) {
        UIBezierPath *gill = [UIBezierPath bezierPath];
        [gill moveToPoint:CGPointMake(74 + i * 4, 50)]; [gill addLineToPoint:CGPointMake(72 + i * 4, 58)];
        gill.lineWidth = 1.8; gill.lineCapStyle = kCGLineCapRound; [ink setStroke]; [gill stroke];
    }
    Paint(Circle(32, 52, 7), UIColor.whiteColor, ink);
    Paint(Circle(58, 52, 7), UIColor.whiteColor, ink);
    Paint(Circle(33, 53, 3.8), ink, nil);
    Paint(Circle(59, 53, 3.8), ink, nil);
    Paint(Circle(34.5, 51.2, 1.3), UIColor.whiteColor, nil);
    Paint(Circle(60.5, 51.2, 1.3), UIColor.whiteColor, nil);
    Paint(Circle(21, 65, 4.5), [pink colorWithAlphaComponent:0.75], nil);
    Paint(Circle(69, 65, 4.5), [pink colorWithAlphaComponent:0.75], nil);
    UIBezierPath *smile = [UIBezierPath bezierPath];
    [smile moveToPoint:CGPointMake(36, 67)]; [smile addQuadCurveToPoint:CGPointMake(54, 67) controlPoint:CGPointMake(45, 77)];
    Paint(smile, nil, ink);
    Paint(Poly({{39, 69}, {43, 69}, {41, 74}}), UIColor.whiteColor, nil);
    Paint(Poly({{47, 69}, {51, 69}, {49, 74}}), UIColor.whiteColor, nil);
}
@end

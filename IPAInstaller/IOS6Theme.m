#import "IOS6Theme.h"

// Internal helper: cap-inset stretchable. Uses old `stretchableImageWithLeftCapWidth:` because
// `resizableImageWithCapInsets:` requires iOS 5 (we support that) but cap insets API behavior
// is identical on iOS 5+. We use the older API here for one-line clarity.
static UIImage *stretchable(NSString *name, NSInteger leftCap, NSInteger topCap) {
    UIImage *base = [UIImage imageNamed:name];
    if (!base) return nil;
    return [base stretchableImageWithLeftCapWidth:leftCap topCapHeight:topCap];
}

@implementation IOS6Theme

+ (instancetype)shared {
    static IOS6Theme *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IOS6Theme alloc] init]; });
    return s;
}

// ---- Backgrounds ----

+ (UIImage *)navBarBackground {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"navbar-blue", 1, 0);
    return img;
}

+ (UIImage *)tabBarBackground {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"tabbar-dark", 1, 0);
    return img;
}

+ (UIImage *)cellBackground {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"cell-bg", 1, 1);
    return img;
}

+ (UIImage *)cellSelectedBackground {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"cell-selected", 1, 1);
    return img;
}

+ (UIImage *)cardBackground {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"card-bg", 14, 14);  // 12px corner radius + 2px slack
    return img;
}

+ (UIImage *)linenPattern {
    static UIImage *img = nil;
    if (!img) img = [UIImage imageNamed:@"linen"];
    return img;
}

+ (UIImage *)linenBackground {  // legacy alias
    return [self linenPattern];
}

+ (UIColor *)linenPatternColor {
    static UIColor *c = nil;
    if (!c && [self linenPattern]) c = [UIColor colorWithPatternImage:[self linenPattern]];
    if (!c) c = [self groupedBackgroundColor];
    return c;
}

+ (UIColor *)linenColor { return [self linenPatternColor]; }

+ (UIColor *)chatBackgroundColor {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
    return c;
}

+ (UIColor *)contentBackgroundColor {
    return [UIColor whiteColor];
}

+ (UIColor *)groupedBackgroundColor {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.866 green:0.875 blue:0.890 alpha:1.0];
    return c;
}

// ---- Buttons ----

+ (UIImage *)blueButtonNormal {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"btn-blue", 12, 12);
    return img;
}

+ (UIImage *)blueButtonPressed {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"btn-blue-pressed", 12, 12);
    return img;
}

+ (UIImage *)grayButtonNormal {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"btn-gray", 12, 12);
    return img;
}

+ (UIImage *)grayButtonPressed {
    static UIImage *img = nil;
    if (!img) img = stretchable(@"btn-gray-pressed", 12, 12);
    return img;
}

// ---- Style helpers ----

+ (void)applyToNavigationBar:(UINavigationBar *)nav {
    if (!nav) return;
    if ([nav respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)]) {
        UIImage *bg = [self navBarBackground];
        if (bg) [nav setBackgroundImage:bg forBarMetrics:UIBarMetricsDefault];
    }
    nav.tintColor = [self primaryBlue];
    NSDictionary *titleAttrs = @{
        UITextAttributeTextColor: [UIColor whiteColor],
        UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.5],
        UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
        UITextAttributeFont: [UIFont boldSystemFontOfSize:18],
    };
    if ([nav respondsToSelector:@selector(setTitleTextAttributes:)]) {
        nav.titleTextAttributes = titleAttrs;
    }
}

+ (void)applyToTabBar:(UITabBar *)tab {
    if (!tab) return;
    if ([tab respondsToSelector:@selector(setBackgroundImage:)]) {
        UIImage *bg = [self tabBarBackground];
        if (bg) tab.backgroundImage = bg;
    }
    if ([tab respondsToSelector:@selector(setTintColor:)]) {
        tab.tintColor = [self primaryBlue];
    }
}

+ (void)styleButton:(UIButton *)button {
    if (!button) return;
    [button setBackgroundImage:[self blueButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self blueButtonPressed] forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateDisabled];
    button.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.4];
    button.titleLabel.shadowOffset = CGSizeMake(0, -1);
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
}

+ (void)styleGrayButton:(UIButton *)button {
    if (!button) return;
    [button setBackgroundImage:[self grayButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self grayButtonPressed] forState:UIControlStateHighlighted];
    [button setTitleColor:[self labelDark] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor grayColor] forState:UIControlStateDisabled];
    button.titleLabel.shadowColor = [UIColor whiteColor];
    button.titleLabel.shadowOffset = CGSizeMake(0, 1);
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
}

+ (void)styleSmallInstallButton:(UIButton *)button {
    // App Store iOS 6 small install pill: gray rounded with blue text, becomes solid blue on tap
    if (!button) return;
    [button setBackgroundImage:[self grayButtonNormal] forState:UIControlStateNormal];
    [button setBackgroundImage:[self blueButtonPressed] forState:UIControlStateHighlighted];
    [button setTitleColor:[self primaryBlue] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    button.titleLabel.shadowColor = nil;
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;
    searchBar.barStyle = UIBarStyleDefault;
    searchBar.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    if ([searchBar respondsToSelector:@selector(setBackgroundImage:)]) {
        // Use a 1x1 light-gray image to remove the default gradient (cleaner on iPad 1)
        UIGraphicsBeginImageContext(CGSizeMake(1, 1));
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.91 green:0.92 blue:0.94 alpha:1.0].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));
        UIImage *bg = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        searchBar.backgroundImage = bg;
    }
}

// ---- Color palette ----

+ (UIColor *)primaryBlue {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.118 green:0.435 blue:0.902 alpha:1.0];  // ~iOS 6 system blue
    return c;
}

+ (UIColor *)separatorColor {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.784 green:0.784 blue:0.804 alpha:1.0];
    return c;
}

+ (UIColor *)labelDark {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithWhite:0.12 alpha:1.0];
    return c;
}

+ (UIColor *)labelGray {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithWhite:0.45 alpha:1.0];
    return c;
}

+ (UIColor *)bubbleBlueColor {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
    return c;
}

+ (UIColor *)bubbleGrayColor {
    static UIColor *c = nil;
    if (!c) c = [UIColor colorWithRed:0.91 green:0.91 blue:0.93 alpha:1.0];
    return c;
}

// ---- Fonts ----

+ (UIFont *)bodyFont { return [UIFont systemFontOfSize:15]; }
+ (UIFont *)bodyBoldFont { return [UIFont boldSystemFontOfSize:15]; }
+ (UIFont *)titleFont { return [UIFont boldSystemFontOfSize:17]; }
+ (UIFont *)caption { return [UIFont systemFontOfSize:11]; }

// ---- Bubble drawing (iOS 6 Messages-style with tail) ----

+ (void)drawChatBubbleInRect:(CGRect)rect isUser:(BOOL)isUser {
    // We draw the bubble path entirely in the current CGContext.
    // Faster than CALayer corner-radius + mask on iPad 1 (single rasterization pass).
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat tailW = 10.0;                       // tail width
    CGFloat tailH = 14.0;                       // tail height
    CGFloat radius = 14.0;                      // corner radius
    CGFloat bodyLeft, bodyRight;
    if (isUser) {
        bodyLeft = CGRectGetMinX(rect);
        bodyRight = CGRectGetMaxX(rect) - tailW;
    } else {
        bodyLeft = CGRectGetMinX(rect) + tailW;
        bodyRight = CGRectGetMaxX(rect);
    }
    CGFloat top = CGRectGetMinY(rect);
    CGFloat bottom = CGRectGetMaxY(rect);

    // Build bubble path
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, bodyLeft + radius, top);
    CGPathAddLineToPoint(path, NULL, bodyRight - radius, top);
    CGPathAddArc(path, NULL, bodyRight - radius, top + radius, radius, -M_PI_2, 0, NO);
    if (isUser) {
        // Right tail
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom - tailH - 2);
        CGPathAddLineToPoint(path, NULL, bodyRight + tailW, bottom - 2);
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom);
    } else {
        CGPathAddLineToPoint(path, NULL, bodyRight, bottom - radius);
        CGPathAddArc(path, NULL, bodyRight - radius, bottom - radius, radius, 0, M_PI_2, NO);
    }
    CGPathAddLineToPoint(path, NULL, bodyLeft + radius, bottom);
    if (isUser) {
        CGPathAddArc(path, NULL, bodyLeft + radius, bottom - radius, radius, M_PI_2, M_PI, NO);
    } else {
        // Left tail
        CGPathAddLineToPoint(path, NULL, bodyLeft, bottom);
        CGPathAddLineToPoint(path, NULL, bodyLeft - tailW, bottom - 2);
        CGPathAddLineToPoint(path, NULL, bodyLeft, bottom - tailH - 2);
    }
    CGPathAddLineToPoint(path, NULL, bodyLeft, top + radius);
    CGPathAddArc(path, NULL, bodyLeft + radius, top + radius, radius, M_PI, M_PI + M_PI_2, NO);
    CGPathCloseSubpath(path);

    // Fill with vertical gradient — gives iOS 6 glossy look
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat *comps;
    CGFloat locs[2] = { 0.0, 1.0 };
    CGFloat userTop[4] = { 0.18, 0.62, 1.0, 1.0 };
    CGFloat userBot[4] = { 0.00, 0.42, 0.96, 1.0 };
    CGFloat aiTop[4]   = { 0.965, 0.965, 0.975, 1.0 };
    CGFloat aiBot[4]   = { 0.875, 0.875, 0.895, 1.0 };
    if (isUser) {
        CGFloat colors[8] = { userTop[0], userTop[1], userTop[2], userTop[3],
                              userBot[0], userBot[1], userBot[2], userBot[3] };
        comps = colors;
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(ctx, grad,
                                     CGPointMake(0, top),
                                     CGPointMake(0, bottom),
                                     0);
        CGGradientRelease(grad);
    } else {
        CGFloat colors[8] = { aiTop[0], aiTop[1], aiTop[2], aiTop[3],
                              aiBot[0], aiBot[1], aiBot[2], aiBot[3] };
        comps = colors;
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(ctx, grad,
                                     CGPointMake(0, top),
                                     CGPointMake(0, bottom),
                                     0);
        CGGradientRelease(grad);
    }

    // Glossy top highlight (light overlay covering top 40% of bubble)
    CGFloat highlightHeight = (bottom - top) * 0.5;
    CGFloat glossColors[8] = {
        1, 1, 1, isUser ? 0.30 : 0.55,
        1, 1, 1, 0.0,
    };
    CGGradientRef glossGrad = CGGradientCreateWithColorComponents(cs, glossColors, locs, 2);
    CGContextDrawLinearGradient(ctx, glossGrad,
                                 CGPointMake(0, top),
                                 CGPointMake(0, top + highlightHeight),
                                 0);
    CGGradientRelease(glossGrad);

    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);

    // 1px subtle outer border for definition
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.18].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);

    CGPathRelease(path);
}

@end

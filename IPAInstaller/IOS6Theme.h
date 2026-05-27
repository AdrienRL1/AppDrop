#import <UIKit/UIKit.h>

// Centralized iOS 6 skeuomorphic theme.
// All UIImage getters return cached singletons (created once, GPU-resident).
// Designed to be FAST on iPad 1 (A4, 256 MB RAM, no Retina) — uses pre-rendered PNG
// stretchables instead of runtime CALayer effects (no cornerRadius, no shadow, no blur).
@interface IOS6Theme : NSObject

+ (instancetype)shared;

// ---- Legacy compat (existing code uses these names) ----
+ (UIImage *)linenBackground;
+ (UIColor *)linenColor;

// ---- Background images (stretchable / tileable) ----
+ (UIImage *)navBarBackground;       // iOS 6 blue glossy gradient, stretchable
+ (UIImage *)tabBarBackground;       // dark metal gradient, stretchable
+ (UIImage *)cellBackground;         // white with 1px bottom hairline
+ (UIImage *)cellSelectedBackground; // blue gradient for selected state
+ (UIImage *)cardBackground;         // rounded white card for app cells in chat
+ (UIImage *)linenPattern;           // tileable cream linen
+ (UIColor *)linenPatternColor;      // shortcut for tile pattern color
+ (UIColor *)chatBackgroundColor;    // light gray with subtle tint (Messages-like)
+ (UIColor *)contentBackgroundColor; // white (App Store style)
+ (UIColor *)groupedBackgroundColor; // light gray for grouped tables

// ---- Buttons ----
+ (UIImage *)blueButtonNormal;       // stretchable glossy blue iOS 6 button
+ (UIImage *)blueButtonPressed;
+ (UIImage *)grayButtonNormal;
+ (UIImage *)grayButtonPressed;

// ---- Style helpers (call once per element after creation) ----
+ (void)applyToNavigationBar:(UINavigationBar *)nav;
+ (void)applyToTabBar:(UITabBar *)tab;
+ (void)styleButton:(UIButton *)button;            // primary blue
+ (void)styleGrayButton:(UIButton *)button;        // secondary
+ (void)styleSmallInstallButton:(UIButton *)button; // App Store "+" pill style
+ (void)styleSearchBar:(UISearchBar *)searchBar;

// ---- Color palette (iOS 6 system) ----
+ (UIColor *)primaryBlue;            // ~#1E6FE6
+ (UIColor *)separatorColor;         // ~#c8c8cd
+ (UIColor *)labelDark;              // near-black for body text
+ (UIColor *)labelGray;              // secondary text
+ (UIColor *)bubbleBlueColor;        // user bubble base color
+ (UIColor *)bubbleGrayColor;        // assistant bubble base color

// ---- Font helpers ----
+ (UIFont *)bodyFont;
+ (UIFont *)bodyBoldFont;
+ (UIFont *)titleFont;
+ (UIFont *)caption;

// ---- Bubble drawing (drawRect helper for chat cells) ----
// Renders an iOS 6 Messages-style chat bubble with tail into the current graphics context.
// rect: full bubble bounds. isUser: YES = right-aligned blue; NO = left-aligned gray.
+ (void)drawChatBubbleInRect:(CGRect)rect isUser:(BOOL)isUser;

@end

#import "AppTileView.h"
#import "Localization.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "IOS6Theme.h"

static UIImage *_sharedTileBg = nil;
static UIImage *_sharedCheckOn = nil;
static UIImage *_sharedCheckOff = nil;

@interface AppTileView ()
@property (nonatomic, strong) UIImageView *bgView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *checkOverlay;
@property (nonatomic, copy) NSString *currentIconUrl;
@end

@implementation AppTileView

+ (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f %@", bytes / 1024.0, T(@"unit.kb")];
    if (bytes < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f %@", bytes / (1024.0 * 1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes / (1024.0 * 1024 * 1024), T(@"unit.gb")];
}

+ (UIImage *)tileBackgroundForSize:(CGSize)size {
    if (_sharedTileBg) return _sharedTileBg;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, YES, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // v1.3.2.1: iOS 6 design unconditionally — subtle top-light → mid-light
    // vertical gradient + 1 px gray border. (The v1.3 iOS-7+ flat branch was
    // removed per user request to keep the iOS 6 aesthetic on every device.)
    CGFloat colors[] = {
        1.00, 1.00, 1.00, 1.0,
        0.94, 0.95, 0.97, 1.0,
    };
    CGFloat locs[] = { 0.0, 1.0 };
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, colors, locs, 2);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    CGContextSetRGBStrokeColor(ctx, 0.72, 0.74, 0.78, 1.0);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeRect(ctx, CGRectMake(0.5, 0.5, size.width - 1, size.height - 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    _sharedTileBg = img;
    return img;
}

+ (UIImage *)checkGlyphOn {
    if (_sharedCheckOn) return _sharedCheckOn;
    CGFloat size = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO,
                                           [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // Filled blue circle
    CGContextSetRGBFillColor(ctx, 0.13, 0.55, 0.96, 1.0);
    UIBezierPath *circ = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size-2, size-2)];
    [circ fill];
    // White check
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 7, 13);
    CGContextAddLineToPoint(ctx, 12, 18);
    CGContextAddLineToPoint(ctx, 20, 9);
    CGContextStrokePath(ctx);
    _sharedCheckOn = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return _sharedCheckOn;
}

+ (UIImage *)checkGlyphOff {
    if (_sharedCheckOff) return _sharedCheckOff;
    CGFloat size = 26;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO,
                                           [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // White semi-transparent circle with gray border
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.85);
    UIBezierPath *circ = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size-2, size-2)];
    [circ fill];
    CGContextSetRGBStrokeColor(ctx, 0.55, 0.58, 0.62, 1.0);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(2, 2, size-4, size-4));
    _sharedCheckOff = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return _sharedCheckOff;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];

        self.bgView = [[UIImageView alloc] initWithFrame:self.bounds];
        self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bgView.opaque = YES;
        [self addSubview:self.bgView];

        self.iconView = [[UIImageView alloc] init];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        self.titleLabel.textColor = [UIColor colorWithRed:0.13 green:0.18 blue:0.32 alpha:1.0];
        self.titleLabel.numberOfLines = 2;
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.backgroundColor = [UIColor clearColor];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:10];
        self.subtitleLabel.textColor = [UIColor grayColor];
        self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
        self.subtitleLabel.numberOfLines = 1;
        self.subtitleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:self.subtitleLabel];

        // Selection check overlay (visible only in selectionMode). Sits over the
        // top-left of the tile.
        self.checkOverlay = [[UIImageView alloc] init];
        self.checkOverlay.hidden = YES;
        [self addSubview:self.checkOverlay];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.bgView.image = [AppTileView tileBackgroundForSize:b.size];

    CGFloat iconSize = MIN(b.size.width - 24, 80);
    self.iconView.frame = CGRectMake((b.size.width - iconSize) / 2, 10, iconSize, iconSize);

    CGFloat tY = self.iconView.frame.origin.y + self.iconView.frame.size.height + 6;
    self.titleLabel.frame = CGRectMake(6, tY, b.size.width - 12, 28);

    self.subtitleLabel.frame = CGRectMake(6, b.size.height - 18, b.size.width - 12, 14);

    // Check overlay — top-left corner, 26×26. Only visible in selection mode.
    self.checkOverlay.frame = CGRectMake(6, 6, 26, 26);
}

- (void)setApp:(NSDictionary *)app {
    _app = [app copy];
    if (!app) {
        self.titleLabel.text = @"";
        self.subtitleLabel.text = @"";
        self.iconView.image = nil;
        self.currentIconUrl = nil;
        self.hidden = YES;
        return;
    }
    self.hidden = NO;
    self.titleLabel.text = app[@"title"] ?: @"";
    long long size = [app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [AppTileView humanSize:size] : @"?";
    NSString *sub = [NSString stringWithFormat:@"v%@ • iOS %@ • %@",
                       app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", sizeStr];
    self.subtitleLabel.text = sub;

    [self refreshModeOverlays];

    NSString *iconUrl = app[@"icon"];
    self.currentIconUrl = [iconUrl copy];
    if (!iconUrl.length) {
        self.iconView.image = nil;
        return;
    }
    CGSize sz = CGSizeMake(80, 80);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) {
        self.iconView.image = cached;
    } else {
        self.iconView.image = nil;
        __weak typeof(self) weakSelf = self;
        [[IconLoader shared] loadImageForURL:iconUrl
                                   targetSize:sz
                                          via:nil
                                   completion:^(UIImage *img) {
            if (!img) return;
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            if (![s.currentIconUrl isEqualToString:iconUrl]) return;
            s.iconView.image = img;
        }];
    }
}

- (void)setSelectionMode:(BOOL)selectionMode {
    if (_selectionMode == selectionMode) return;
    _selectionMode = selectionMode;
    [self refreshModeOverlays];
}

- (void)setTileSelected:(BOOL)tileSelected {
    _tileSelected = tileSelected;
    if (self.selectionMode) [self refreshModeOverlays];
}

- (void)refreshModeOverlays {
    // Selection mode: show check overlay. Default mode: nothing.
    self.checkOverlay.hidden = !self.selectionMode;
    if (self.selectionMode) {
        self.checkOverlay.image = self.tileSelected
            ? [AppTileView checkGlyphOn]
            : [AppTileView checkGlyphOff];
    }
}

- (void)tapped {
    if (!self.onTap || !self.app) return;
    self.alpha = 0.5;
    NSDictionary *appCopy = self.app;
    void (^onTap)(NSDictionary *) = [self.onTap copy];
    [UIView animateWithDuration:0.18
                      animations:^{ self.alpha = 1.0; }
                      completion:^(BOOL done) {
        onTap(appCopy);
    }];
}

@end

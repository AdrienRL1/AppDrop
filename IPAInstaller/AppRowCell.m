#import "AppRowCell.h"
#import "AppTileView.h"

@interface AppRowCell ()
@property (nonatomic, strong) NSMutableArray *tiles;
@property (nonatomic, copy) NSArray *appsCache;
@end

@implementation AppRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.tiles = [NSMutableArray array];
        self.tilesPerRow = 4;
    }
    return self;
}

- (void)ensureTileCount {
    while ((NSInteger)self.tiles.count < self.tilesPerRow) {
        AppTileView *t = [[AppTileView alloc] initWithFrame:CGRectZero];
        __weak typeof(self) ws = self;
        t.onTap = ^(NSDictionary *app) {
            if (ws.onTileTap) ws.onTileTap(app);
        };
        [self.tiles addObject:t];
        [self.contentView addSubview:t];
    }
    while ((NSInteger)self.tiles.count > self.tilesPerRow) {
        AppTileView *t = [self.tiles lastObject];
        [t removeFromSuperview];
        [self.tiles removeLastObject];
    }
}

- (void)setApps:(NSArray *)apps {
    self.appsCache = apps;
    [self ensureTileCount];
    for (NSInteger i = 0; i < self.tilesPerRow; i++) {
        AppTileView *t = self.tiles[i];
        t.selectionMode = self.selectionMode;
        NSDictionary *appI = (i < (NSInteger)apps.count) ? apps[i] : nil;
        // Pull selection state from the controller's block (source of truth).
        // This re-runs on every reuse, so far-away selections are reflected
        // correctly when the cell scrolls back into view.
        t.tileSelected = appI && self.isAppSelectedBlock
            ? self.isAppSelectedBlock(appI) : NO;
        t.app = appI;  // setting last so all flags above are visible at layout time
    }
    [self setNeedsLayout];
}

- (void)setSelectionMode:(BOOL)selectionMode {
    if (_selectionMode == selectionMode) return;
    _selectionMode = selectionMode;
    for (AppTileView *t in self.tiles) t.selectionMode = selectionMode;
}

- (void)setTilesPerRow:(NSInteger)n {
    if (_tilesPerRow == n) return;
    _tilesPerRow = MAX(1, n);
    [self ensureTileCount];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat outerPad = 8;
    CGFloat gap = 8;
    CGFloat n = (CGFloat)self.tilesPerRow;
    CGFloat available = b.size.width - outerPad * 2 - gap * (n - 1);
    CGFloat tileW = available / n;
    CGFloat tileH = b.size.height - outerPad * 2;
    for (NSInteger i = 0; i < self.tilesPerRow; i++) {
        AppTileView *t = self.tiles[i];
        CGFloat x = outerPad + i * (tileW + gap);
        t.frame = CGRectMake(x, outerPad, tileW, tileH);
    }
}

@end

#import <UIKit/UIKit.h>

// One table row that holds N app tiles laid out horizontally. Used on iPad to make a grid.
@interface AppRowCell : UITableViewCell

@property (nonatomic, assign) NSInteger tilesPerRow;
@property (nonatomic, copy) void (^onTileTap)(NSDictionary *app);

// Selection support (multi-select install batch).
// In selectionMode: tiles draw a checkbox overlay and onTileTap is used as
// "toggle selection". The checkbox state is read each layout via isAppSelectedBlock
// so updates from far-away taps still reflect correctly when scrolled back.
// In default mode: onTileTap navigates to the detail screen.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, copy) BOOL (^isAppSelectedBlock)(NSDictionary *app);

- (void)setApps:(NSArray *)apps;

// Shared grid density: how many tiles fit across `w` points. iPhone always 1.
// On iPad it reads the "IPAInstall.GridDensity" pref (0…1, set by the Settings
// slider) so Catalogue and Recherche stay in sync. Default ≈ 175 pt tiles.
+ (NSInteger)tilesPerRowForWidth:(CGFloat)w;
@end

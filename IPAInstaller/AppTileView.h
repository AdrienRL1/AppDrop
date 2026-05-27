#import <UIKit/UIKit.h>

// Single app "tile" used in the iPad grid catalog.
// Designed for GPU efficiency: opaque, no offscreen rendering, no layer effects.
// Background image is pre-rendered once and shared across tiles.
@interface AppTileView : UIView

@property (nonatomic, copy) NSDictionary *app;
@property (nonatomic, copy) void (^onTap)(NSDictionary *app);

// v2.0.30: the quick-install button overlay was removed entirely. The user
// installs apps via the detail view's "Installer" button or by multi-select
// + the bottom toolbar. Selection mode still shows a check overlay.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, assign) BOOL tileSelected;

@end

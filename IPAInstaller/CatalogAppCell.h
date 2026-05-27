#import <UIKit/UIKit.h>

// Custom catalog cell (iPhone path).
//
// Layout (height 76):
//   ┌─────────────────────────────────────────────────┐
//   │ [icon]  Title                                   │
//   │   44x44 v1.0 — iOS 5.0 — 12 Mo                  │
//   │         filename.ipa                            │
//   └─────────────────────────────────────────────────┘
//
// Right-side install shortcut button was removed in v2.0.30 — users go through
// the detail screen ("Installer") for single installs, or multi-select+toolbar
// for batch installs. accessoryType=Checkmark is still used to mark cells in
// selection mode.
@interface CatalogAppCell : UITableViewCell

@property (nonatomic, strong, readonly) UIImageView *appIconView;
@property (nonatomic, strong, readonly) UILabel     *appTitleLabel;
@property (nonatomic, strong, readonly) UILabel     *appSubtitleLabel;

@end

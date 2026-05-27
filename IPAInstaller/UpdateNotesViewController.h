#import <UIKit/UIKit.h>

// Full-screen modal shown when the user taps "Install vX.Y" in Settings →
// Updates. Renders the GitHub release notes (Markdown) as HTML in a UIWebView
// so the user can read what's new before committing to the install.
//
// Layout is responsive: works on iPhone 4S (320×480 portrait) up to iPad
// landscape. Cancel + Install live in the nav bar so they're always reachable
// without scrolling.
//
// Tap "Install" → dismisses the modal and invokes installHandler. Caller
// (SettingsViewController) wires installHandler to kick off the actual
// download via InstallManager.
@interface UpdateNotesViewController : UIViewController

// Set before presenting. Required.
@property (nonatomic, copy) NSString *version;       // e.g. "1.3"
@property (nonatomic, copy) NSDate   *releaseDate;
@property (nonatomic, copy) NSString *notesMarkdown; // raw body from GitHub API

// Called on main queue when the user taps Install. The receiver is dismissed
// before the handler runs, so the handler can safely present further UI.
@property (nonatomic, copy) void (^installHandler)(void);

@end

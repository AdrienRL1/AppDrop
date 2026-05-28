#import "AppDelegate.h"
#import "RootViewController.h"
#import "IOS6Theme.h"
#import "InstallManager.h"
#import "CatalogViewController.h"
#import "SearchViewController.h"
#import "ChatViewController.h"
#import "SettingsViewController.h"
#import "Localization.h"
#import "UpdateChecker.h"

// v1.3.1: alert delegate so the AppDelegate can react to the Filza-launch
// confirmation. The dismissed-path is stored on the alert itself (via tag
// + an associated property) so we can fire filza://view/<path> at the right
// time without re-deriving anything from the notification userInfo.
@interface AppDelegate () <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *pendingFilzaPath;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self setupAppearance];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [IOS6Theme contentBackgroundColor];

    // Build the 4 tabs: Catalogue (default), IA, Installer, Réglages.
    // Each tab has its own UINavigationController stack so push/pop works inside.
    CatalogViewController *catalog = [[CatalogViewController alloc] init];
    UINavigationController *catalogNav = [[UINavigationController alloc] initWithRootViewController:catalog];
    catalogNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.catalog")
                                                            image:[UIImage imageNamed:@"tab-catalog"]
                                                              tag:0];

    SearchViewController *search = [[SearchViewController alloc] init];
    UINavigationController *searchNav = [[UINavigationController alloc] initWithRootViewController:search];
    searchNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.search")
                                                          image:[UIImage imageNamed:@"tab-search"]
                                                            tag:1];

    ChatViewController *chat = [[ChatViewController alloc] init];
    UINavigationController *chatNav = [[UINavigationController alloc] initWithRootViewController:chat];
    chatNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.ai")
                                                       image:[UIImage imageNamed:@"tab-ai"]
                                                         tag:2];

    RootViewController *install = [[RootViewController alloc] init];  // legacy URL/jobs screen
    UINavigationController *installNav = [[UINavigationController alloc] initWithRootViewController:install];
    installNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.install")
                                                          image:[UIImage imageNamed:@"tab-install"]
                                                            tag:3];

    SettingsViewController *settings = [[SettingsViewController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:T(@"tab.settings")
                                                           image:[UIImage imageNamed:@"tab-settings"]
                                                             tag:4];

    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[catalogNav, searchNav, chatNav, installNav, settingsNav];
    tabs.selectedIndex = 0;  // Catalogue first (it's the main feature)
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL) {
        [self application:application openURL:launchURL sourceApplication:nil annotation:nil];
    }

    // v1.2.1.1: red "1" badge on the Settings tab when an update is available.
    // We observe UpdateChecker so it auto-updates as the status changes
    // (e.g., user opens Settings → fresh check fires → badge flips on).
    // Cache TTL inside UpdateChecker is 1 h so the launch check is cheap
    // even if the user re-launches the app frequently.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(refreshSettingsTabBadge)
                                                  name:UpdateCheckerStatusChangedNotification
                                                object:nil];
    [self refreshSettingsTabBadge];  // initial state (probably no badge yet)
    [[UpdateChecker shared] checkForUpdates:NO];

    // v1.3.1: pop an "Open in Filza?" prompt whenever InstallManager archives
    // a .ipa. Fires for iOS 10+ (always) and iOS 6-9 when "Keep IPA after
    // install" is on. The alert is global (UIAlertView is window-level) so it
    // appears regardless of which tab the user is on.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(installManagerSaved:)
                                                  name:InstallManagerJobSavedNotification
                                                object:nil];

    // v2.0.9 — show the catalog-quality reminder at every cold launch. The upstream
    // catalog has a small fraction of rows with wrong title or icon (out of our control,
    // it's a data issue at stuffed18.github.io). The user explicitly asked for this to
    // fire on every launch so they don't forget to double-check what they install.
    // Deferred ~0.6 s so the tab bar / catalog appears first, then the alert pops over it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"onboarding.catalog_quality_title")
                                                    message:T(@"onboarding.catalog_quality_msg")
                                                   delegate:nil
                                          cancelButtonTitle:T(@"common.understood")
                                          otherButtonTitles:nil];
        [a show];
    });

    return YES;
}

// URL scheme handler. The ipainstall:// scheme is registered in Info.plist for future
// deep linking but currently has no handlers. Returns NO so the system handles the
// URL through default channels (or fails silently for unknown schemes).
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
   sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    return NO;
}

// v1.2.1.1: Sync the Settings tab's UITabBarItem badge with UpdateChecker.status.
// Called both from the UpdateCheckerStatusChangedNotification observer and once
// during didFinishLaunchingWithOptions so the badge is correct from the first
// frame even before the launch update check completes.
- (void)refreshSettingsTabBadge {
    UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
    if (![tabs isKindOfClass:[UITabBarController class]]) return;
    if (tabs.viewControllers.count < 5) return;  // sanity — should be 5 tabs
    // Settings is tab index 4 (catalog/search/ai/install/settings).
    UIViewController *settingsNav = tabs.viewControllers[4];
    UpdateChecker *uc = [UpdateChecker shared];
    settingsNav.tabBarItem.badgeValue =
        (uc.status == UpdateCheckerStatusAvailable) ? @"1" : nil;
}

// v1.3.1: hook for the "Open in Filza?" prompt. Posted by InstallManager after
// each archive save. We try filza://view/<path> on the user's tap; falls back
// silently if Filza isn't installed (UIApplication openURL: returns NO).
- (void)installManagerSaved:(NSNotification *)note {
    NSString *path = note.userInfo[@"savedPath"];
    if (!path.length) return;
    self.pendingFilzaPath = path;
    NSString *body = [NSString stringWithFormat:T(@"install.saved_alert_msg"), path];
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"install.saved_alert_title")
                                                 message:body
                                                delegate:self
                                       cancelButtonTitle:T(@"common.ok")
                                       otherButtonTitles:T(@"install.open_in_filza"), nil];
    a.tag = 200;  // distinct from any per-VC tag
    [a show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alert.tag != 200) return;
    if (buttonIndex == alert.cancelButtonIndex) {
        self.pendingFilzaPath = nil;
        return;
    }
    NSString *path = self.pendingFilzaPath;
    self.pendingFilzaPath = nil;
    if (!path.length) return;

    // Percent-encode the path for use as a URL component. Filza expects
    // filza://view/<absolute path>; spaces, ampersands, etc. must be escaped.
    NSString *encoded = [path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (!encoded) encoded = path;

    UIApplication *app = [UIApplication sharedApplication];
    NSURL *filza = [NSURL URLWithString:[@"filza://view/" stringByAppendingString:encoded]];
    NSURL *ifile = [NSURL URLWithString:[@"ifile://view/" stringByAppendingString:encoded]];
    if (filza && [app canOpenURL:filza]) {
        [app openURL:filza];
        return;
    }
    if (ifile && [app canOpenURL:ifile]) {
        [app openURL:ifile];
        return;
    }
    // Neither is installed (or LSApplicationQueriesSchemes hides them on iOS 9+).
    // Stash the path on the system pasteboard so the user can paste it into
    // whichever file manager they prefer.
    [UIPasteboard generalPasteboard].string = path;
    UIAlertView *fallback = [[UIAlertView alloc]
        initWithTitle:T(@"install.no_filza_title")
              message:T(@"install.no_filza_msg")
             delegate:nil
    cancelButtonTitle:T(@"common.ok")
    otherButtonTitles:nil];
    [fallback show];
}

// Kept as a private helper in case future code needs to surface a system-wide alert
// without owning a view controller (e.g. background notification handlers).
- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title
                                                message:msg
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

- (void)setupAppearance {
    // v1.3: on iOS 7+, skip the iOS-6 skeuomorphic UIAppearance overrides and
    // let the system flat defaults apply (white translucent bars, no text
    // shadows, system tint). Keeping the gradient PNGs + text shadows on
    // iOS 7+ makes the app look out of place. iOS 6 still gets the full
    // skeuomorphic treatment below.
    if ([IOS6Theme useFlatStyle]) {
        // Optional: set a tintColor so blue accents stay consistent with iOS 6.
        id navProxy7 = [UINavigationBar appearance];
        if ([navProxy7 respondsToSelector:@selector(setTintColor:)]) {
            [navProxy7 setTintColor:[IOS6Theme primaryBlue]];
        }
        id tabProxy7 = [UITabBar appearance];
        if ([tabProxy7 respondsToSelector:@selector(setTintColor:)]) {
            [tabProxy7 setTintColor:[IOS6Theme primaryBlue]];
        }
        return;
    }
    // UIAppearance proxy (iOS 5+) — apply once for all nav/tab bars + buttons.
    // This guarantees consistent iOS 6 chrome across every screen without per-VC setup.
    id navProxy = [UINavigationBar appearance];
    if ([navProxy respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)]) {
        UIImage *navBg = [IOS6Theme navBarBackground];
        if (navBg) [navProxy setBackgroundImage:navBg forBarMetrics:UIBarMetricsDefault];
    }
    if ([navProxy respondsToSelector:@selector(setTitleTextAttributes:)]) {
        NSDictionary *attrs = @{
            UITextAttributeTextColor: [UIColor whiteColor],
            UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.5],
            UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
            UITextAttributeFont: [UIFont boldSystemFontOfSize:18],
        };
        [navProxy setTitleTextAttributes:attrs];
    }
    if ([navProxy respondsToSelector:@selector(setTintColor:)]) {
        [navProxy setTintColor:[IOS6Theme primaryBlue]];
    }

    // Tab bar (iOS 5+)
    id tabProxy = [UITabBar appearance];
    if ([tabProxy respondsToSelector:@selector(setBackgroundImage:)]) {
        UIImage *tabBg = [IOS6Theme tabBarBackground];
        if (tabBg) [tabProxy setBackgroundImage:tabBg];
    }
    if ([tabProxy respondsToSelector:@selector(setTintColor:)]) {
        [tabProxy setTintColor:[IOS6Theme primaryBlue]];
    }

    // Default bar button items styled to match nav bar
    id barButtonProxy = [UIBarButtonItem appearance];
    if ([barButtonProxy respondsToSelector:@selector(setTitleTextAttributes:forState:)]) {
        NSDictionary *bbAttrs = @{
            UITextAttributeTextColor: [UIColor whiteColor],
            UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.4],
            UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
            UITextAttributeFont: [UIFont boldSystemFontOfSize:13],
        };
        [barButtonProxy setTitleTextAttributes:bbAttrs forState:UIControlStateNormal];
    }
}

@end

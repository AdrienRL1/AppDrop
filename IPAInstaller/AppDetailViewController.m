#import "AppDetailViewController.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "VersionsViewController.h"
#import "IOS6Theme.h"
#import "Localization.h"

@interface AppDetailViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITextView *infoView;
@end

@implementation AppDetailViewController

- (instancetype)initWithApp:(NSDictionary *)app {
    if ((self = [super init])) {
        self.app = app;
    }
    return self;
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

// Decode the `plat` bitmask. Catalog upstream (stuffed18) stores it as 1 << UIDeviceFamily,
// not as raw UIDeviceFamily values:
//   bit 1 (value 2)  = iPhone / iPod touch  (UIDeviceFamily=1 → 1<<1 = 2)
//   bit 2 (value 4)  = iPad                 (UIDeviceFamily=2 → 1<<2 = 4)
//   bit 3 (value 8)  = AppleTV              (UIDeviceFamily=3 → 1<<3 = 8)
//   bit 4 (value 16) = Watch                (UIDeviceFamily=4 → 1<<4 = 16)
// Common combinations observed in the 157k catalog: 2 (iPhone-only), 4 (iPad-only),
// 6 (universal = 2|4), 8 (TV-only), 14 (iPhone+iPad+TV), 18 (iPhone+Watch).
- (NSString *)platformDescription:(NSInteger)mask {
    NSMutableArray *p = [NSMutableArray array];
    if (mask & 2)  [p addObject:@"iPhone"];
    if (mask & 4)  [p addObject:@"iPad"];
    if (mask & 8)  [p addObject:@"AppleTV"];
    if (mask & 16) [p addObject:@"Watch"];
    if (p.count == 0) return @"?";
    return [p componentsJoinedByString:@", "];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];  // App Store white
    self.title = self.app[@"title"] ?: T(@"app.fallback_title");

    // Right bar: "Versions" if bundleId available
    NSString *bid = self.app[@"bundleId"];
    if (bid.length) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:T(@"app.versions")
                                              style:UIBarButtonItemStyleBordered
                                             target:self
                                             action:@selector(versionsTapped)];
    }

    [self buildLayout];
    [self loadIcon];
}

- (void)versionsTapped {
    NSString *bid = self.app[@"bundleId"];
    if (!bid.length) return;
    VersionsViewController *vc = [[VersionsViewController alloc] initWithBundleId:bid
                                                                              title:self.app[@"title"] ?: T(@"app.versions")];
    [self.navigationController pushViewController:vc animated:YES];
}

// v2.0.9: the per-row filename mismatch detection (normalizeForMatch: + checkFilenameMismatch
// + persistent red banner + install confirmation alert) is gone. The catalog-quality reminder
// shown by AppDelegate at every launch covers the same ground without bothering the user on
// every tap. The .ipa filename is still printed in the cell list and the detail info text so
// the user can spot mismatches manually.

- (void)buildLayout {
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 120)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = [UIColor whiteColor];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(15, 15, 90, 90)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    // No layer.cornerRadius / borderWidth (offscreen render = slow on iPad A4/A6X)
    [header addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 18, w - 135, 28)];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.text = self.app[@"title"] ?: @"?";  // ? is not a translatable string
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 50, w - 135, 16)];
    self.subtitleLabel.font = [UIFont systemFontOfSize:13];
    self.subtitleLabel.textColor = [UIColor darkGrayColor];
    long long size = [self.app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : T(@"app.size_unknown");
    self.subtitleLabel.text = [NSString stringWithFormat:T(@"app.subtitle_with_size"),
                                 self.app[@"version"] ?: @"?", sizeStr];
    self.subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.subtitleLabel];

    // v2.0.27: removed the small InstallProgressButton beside this one — redundant
    // with the title text feedback. The big button now reclaims the full width.
    self.installButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.installButton.frame = CGRectMake(120, 72, w - 135, 34);
    [self.installButton setTitle:T(@"app.install") forState:UIControlStateNormal];
    [IOS6Theme styleButton:self.installButton];
    self.installButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.installButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.installButton addTarget:self action:@selector(installTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.installButton];

    // Watch job state so the big button's TITLE reflects the live state (Téléchargement
    // 42 %, Installation…, Installé, etc.). The ring widget on catalog cells does its
    // own subscription independently.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(refreshInstallButtonTitle)
            name:InstallManagerJobsChangedNotification
          object:nil];
    [self refreshInstallButtonTitle];

    [self.view addSubview:header];

    // Info text below (offset by banner height if shown)
    CGFloat infoY = 120;
    self.infoView = [[UITextView alloc] initWithFrame:CGRectMake(0, infoY, w, b.size.height - infoY)];
    self.infoView.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.infoView.font = [UIFont systemFontOfSize:13];
    self.infoView.editable = NO;
    self.infoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // textContainerInset is iOS 7+; on iOS 5/6 use contentInset for padding
    self.infoView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);

    NSString *fname = self.app[@"fileName"] ?: @"?";
    NSURL *u = [NSURL URLWithString:self.app[@"url"] ?: @""];
    NSString *host = u.host ?: @"?";

    NSString *info = [NSString stringWithFormat:
        @"%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n%@ : %@\n\n%@ : %@\n%@ : %@\n\n%@ :\n%@",
        T(@"app.info_bundle_id"), self.app[@"bundleId"] ?: @"?",
        T(@"app.info_version"), self.app[@"version"] ?: @"?",
        T(@"app.info_min_ios"), self.app[@"minOS"] ?: @"?",
        T(@"app.info_platform"), [self platformDescription:[self.app[@"platform"] integerValue]],
        T(@"app.info_size"), sizeStr,
        T(@"app.info_file"), fname,
        T(@"app.info_mirror"), host,
        T(@"app.info_url"), self.app[@"url"] ?: @"?"];
    self.infoView.text = info;
    [self.view addSubview:self.infoView];
}

- (void)loadIcon {
    NSString *iconUrl = self.app[@"icon"];
    if (!iconUrl.length) return;
    CGSize sz = CGSizeMake(90, 90);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) { self.iconView.image = cached; return; }
    [[IconLoader shared] loadImageForURL:iconUrl
                               targetSize:sz
                                      via:nil
                               completion:^(UIImage *img) {
        if (img) self.iconView.image = img;
    }];
}

- (void)installTapped {
    NSString *url = self.app[@"url"];
    if (!url.length) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"app.no_url")
                                                    message:T(@"app.no_url_msg")
                                                   delegate:nil
                                          cancelButtonTitle:T(@"common.ok")
                                          otherButtonTitles:nil];
        [a show];
        return;
    }
    // First-install onboarding: show a one-time alert reminding the user that ipainstaller
    // is a prerequisite. Persisted in NSUserDefaults — only shown once per device install.
    NSString *onboardingKey = @"IPAInstall.onboarding.ipainstaller.shown";
    if (![[NSUserDefaults standardUserDefaults] boolForKey:onboardingKey]) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"onboarding.ipainstaller_title")
                                                    message:T(@"onboarding.ipainstaller_msg")
                                                   delegate:self
                                          cancelButtonTitle:T(@"onboarding.ipainstaller_cancel")
                                          otherButtonTitles:T(@"onboarding.ipainstaller_continue"), nil];
        a.tag = 43;
        [a show];
        return;
    }
    // v2.0.9: the per-row filename-mismatch confirmation alert (tag 42) was removed.
    // The catalog-quality reminder is now shown once per app launch by AppDelegate
    // covering the same warning territory in a less in-your-face way.
    [self doInstall];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 43) {
        // onboarding ipainstaller alert
        if (buttonIndex != alertView.cancelButtonIndex) {
            // user clicked "Yes, continue" → mark as shown and proceed to install
            [[NSUserDefaults standardUserDefaults] setBool:YES
                                                     forKey:@"IPAInstall.onboarding.ipainstaller.shown"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self doInstall];
        }
        // "Not yet" → do nothing, alert will reappear next time user taps Install
    }
}

- (void)doInstall {
    NSString *url = self.app[@"url"];
    // Dedup: if a job for this URL is already in flight, don't kick off another.
    // Otherwise tapping the button twice stacks two parallel downloads and
    // ipainstaller installs the .ipa twice.
    if ([[InstallManager shared] hasActiveJobForURL:url]) {
        // Title already reflects active state via refreshInstallButtonTitle.
        return;
    }
    self.installButton.enabled = NO;
    [self.installButton setTitle:T(@"app.starting") forState:UIControlStateNormal];
    [[InstallManager shared] startInstallWithURL:url
                                       completion:^(NSString *jobId, NSError *err) {
        self.installButton.enabled = YES;
        if (err) {
            [self.installButton setTitle:T(@"app.install") forState:UIControlStateNormal];
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"common.error")
                                                        message:err.localizedDescription
                                                       delegate:nil
                                              cancelButtonTitle:T(@"common.ok")
                                              otherButtonTitles:nil];
            [a show];
            return;
        }
        // Stay on the detail screen — title reflects progress via the notification
        // handler. The Jobs tab still works for a list view.
        [self refreshInstallButtonTitle];
    }];
}

// Update the big-button title to reflect the live state of the install job for THIS
// app. Called on every InstallManagerJobsChangedNotification, and once at view-load.
// Idle / completed states keep the standard "Installer" label so the user can re-tap
// to install again (useful if they want to redo a botched install).
- (void)refreshInstallButtonTitle {
    NSString *appURL = self.app[@"url"];
    if (!appURL.length) return;
    InstallJob *job = nil;
    for (InstallJob *j in [[InstallManager shared] jobs]) {
        if ([j.url isEqualToString:appURL]) { job = j; break; }
    }
    NSString *state = job.state ?: @"";
    NSString *title;
    if ([state isEqualToString:@"downloading"]) {
        title = [NSString stringWithFormat:T(@"app.btn.downloading"), (long)job.progress];
    } else if ([state isEqualToString:@"installing"]) {
        title = T(@"app.btn.installing");
    } else if ([state isEqualToString:@"queued"]) {
        title = T(@"app.btn.queued");
    } else if ([state isEqualToString:@"completed"]) {
        title = T(@"app.btn.installed");
    } else if ([state isEqualToString:@"failed"]) {
        title = T(@"app.btn.retry");
    } else if ([state isEqualToString:@"cancelled"]) {
        title = T(@"app.btn.retry");
    } else {
        title = T(@"app.install");
    }
    [self.installButton setTitle:title forState:UIControlStateNormal];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

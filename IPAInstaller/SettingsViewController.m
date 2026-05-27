#import "SettingsViewController.h"
#import "InstallManager.h"
#import "IconLoader.h"
#import "IOS6Theme.h"
#import "NetworkClient.h"
#import "HTTPSClient.h"
#import "Localization.h"
#import "UpdateChecker.h"
#import "UpdateNotesViewController.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef NS_ENUM(NSInteger, SettingsSection) {
    SectionLanguage = 0,
    SectionUpdates  = 1,  // v1.2 build 13 — in-app updater
    SectionDownload = 2,  // v1.2 build 9 — parallel-streams picker
    SectionArchive  = 3,  // archive.org S3 credentials (optional, can help with throttling)
    SectionDiag     = 4,  // HTTPS test + ipainstaller spawn test
    SectionCache    = 5,
    SectionAbout    = 6,
    SectionsCount
};

// Available parallel-stream choices. archive.org tolerates up to ~8 well; past
// that they tend to throttle the aggregate. 4 is the sweet spot in practice.
static const NSInteger kStreamChoices[] = { 1, 2, 4, 8 };
static const NSInteger kStreamChoicesCount = 4;
static NSString * const kPrefParallelStreams = @"IPAInstall.ParallelStreams";
// SectionLLM removed: chat AI is now Pollinations LLM (no API keys needed).

// NSUserDefaults keys for archive.org S3 credentials. The secret is technically a
// long-lived token rather than a password, so plain NSUserDefaults is acceptable
// for this scale (jailbreak utility, single-user device). Keychain would be nicer
// but is overkill here.
static NSString * const kPrefArchiveEmail     = @"IPAInstall.ArchiveEmail";
static NSString * const kPrefArchiveAccessKey = @"IPAInstall.ArchiveAccessKey";
static NSString * const kPrefArchiveSecretKey = @"IPAInstall.ArchiveSecretKey";

@interface SettingsViewController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *table;
// Which archive field the visible UIAlertView prompt is editing (0=email, 1=access, 2=secret).
@property (nonatomic, assign) NSInteger pendingArchiveFieldIndex;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"settings.title");
    self.view.backgroundColor = [IOS6Theme groupedBackgroundColor];

    // No leftBarButtonItem: Settings is a root tab (see AppDelegate), never
    // presented modally, so a "Done" button would have nothing to dismiss
    // back to. (Earlier builds had one as a leftover from when Settings was
    // a modal — removed in v1.2 build 11 after Reddit feedback.)

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    // Live-refresh the Updates section when UpdateChecker reports a new
    // state (e.g. background check completes after we already showed the
    // "Checking…" cell).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(updateCheckerChanged:)
                                                  name:UpdateCheckerStatusChangedNotification
                                                object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Kick a background check if our cached info is stale (>1h) or absent.
    // This is non-blocking — the UI shows "Tap to check" or the last-known
    // value until the response arrives.
    [[UpdateChecker shared] checkForUpdates:NO];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateCheckerChanged:(NSNotification *)note {
    // Reload just the Updates section to avoid flickering the rest of the
    // table (Archive cells, About cells, etc.).
    if (!self.table) return;
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionUpdates]
              withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SectionsCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SectionLanguage) return 1;
    if (s == SectionUpdates) return 2;   // installed version + latest release
    if (s == SectionDownload) return 1;  // parallel streams
    if (s == SectionArchive) return 3;   // email + access key + secret key
    if (s == SectionDiag) return 2;
    if (s == SectionCache) return 1;
    if (s == SectionAbout) return 6;
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == SectionLanguage) return T(@"settings.language");
    if (s == SectionUpdates) return T(@"settings.section_updates");
    if (s == SectionDownload) return T(@"settings.section_download");
    if (s == SectionArchive) return T(@"settings.section_archive");
    if (s == SectionDiag) return T(@"settings.section_diagnostics");
    if (s == SectionCache) return T(@"settings.section_cache");
    if (s == SectionAbout) return T(@"settings.section_about");
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SectionUpdates) return [self updatesSectionFooter];
    if (s == SectionDownload) return T(@"settings.parallel_streams_footer");
    if (s == SectionArchive) return T(@"settings.section_archive_footer");
    if (s == SectionDiag) return T(@"settings.section_diagnostics_footer");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"setCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:cid];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    if (ip.section == SectionLanguage) {
        cell.textLabel.text = T(@"settings.language");
        cell.textLabel.textColor = [UIColor blackColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"IPAInstall.Language"];
        if (override.length) {
            cell.detailTextLabel.text = [Localization displayNameForLanguageCode:override];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                                          T(@"settings.language_auto"),
                                          [Localization displayNameForLanguageCode:[Localization currentLanguageCode]]];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == SectionUpdates) {
        cell.textLabel.textColor = [UIColor blackColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        UpdateChecker *uc = [UpdateChecker shared];
        if (ip.row == 0) {
            // Read-only installed-version row.
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = T(@"settings.installed_version");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ (build %ld)",
                                            [uc currentVersion], (long)[uc currentBuild]];
        } else {
            // Latest-release row — dynamic based on UpdateChecker.status.
            // - Available: blue tint, "Install vX.Y" + date
            // - UpToDate:  "vX.Y (Mmm dd, yyyy) ✓"
            // - Checking:  "Checking…"
            // - Error:     "Check failed — tap to retry"
            // - Unknown:   "Tap to check"
            UpdateCheckerStatus s = uc.status;
            if (s == UpdateCheckerStatusAvailable) {
                cell.textLabel.text = [NSString stringWithFormat:T(@"settings.install_update_to"),
                                          uc.latestVersion];
                cell.textLabel.textColor = [IOS6Theme primaryBlue];
                cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
                cell.detailTextLabel.text = [self formattedDate:uc.latestReleaseDate];
            } else if (s == UpdateCheckerStatusUpToDate) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ (%@) ✓",
                                                uc.latestVersion,
                                                [self formattedDate:uc.latestReleaseDate]];
            } else if (s == UpdateCheckerStatusChecking) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.checking");
            } else if (s == UpdateCheckerStatusError) {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.check_failed");
            } else {
                cell.textLabel.text = T(@"settings.latest_release");
                cell.detailTextLabel.text = T(@"settings.tap_to_check");
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == SectionDownload) {
        cell.textLabel.text = T(@"settings.parallel_streams");
        cell.textLabel.textColor = [UIColor blackColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSInteger streams = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefParallelStreams];
        if (streams <= 0) streams = 4;  // default
        cell.detailTextLabel.text = (streams == 1)
            ? T(@"settings.streams_off")
            : [NSString stringWithFormat:T(@"settings.streams_n"), (long)streams];
    } else if (ip.section == SectionArchive) {
        cell.textLabel.textColor = [UIColor blackColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        if (ip.row == 0) {
            cell.textLabel.text = T(@"settings.archive_email");
            NSString *val = [def stringForKey:kPrefArchiveEmail];
            cell.detailTextLabel.text = val.length ? val : T(@"settings.archive_not_set");
        } else if (ip.row == 1) {
            cell.textLabel.text = T(@"settings.archive_access_key");
            NSString *val = [def stringForKey:kPrefArchiveAccessKey];
            cell.detailTextLabel.text = val.length ? val : T(@"settings.archive_not_set");
        } else {
            cell.textLabel.text = T(@"settings.archive_secret_key");
            NSString *val = [def stringForKey:kPrefArchiveSecretKey];
            // Mask the secret with bullets so a casual onlooker can't read it,
            // but still indicate whether it's set.
            if (val.length) {
                cell.detailTextLabel.text = [@"" stringByPaddingToLength:MIN(val.length, 10)
                                                              withString:@"•"
                                                         startingAtIndex:0];
            } else {
                cell.detailTextLabel.text = T(@"settings.archive_not_set");
            }
        }
    } else if (ip.section == SectionDiag) {
        cell.textLabel.textColor = [IOS6Theme primaryBlue];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
        if (ip.row == 0) cell.textLabel.text = T(@"settings.test_https");
        else cell.textLabel.text = T(@"settings.test_ipainstaller");
    } else if (ip.section == SectionCache) {
        cell.textLabel.text = T(@"settings.clear_icons");
    } else if (ip.section == SectionAbout) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSBundle *b = [NSBundle mainBundle];
        UIDevice *d = [UIDevice currentDevice];
        switch (ip.row) {
            case 0:
                cell.textLabel.text = T(@"settings.about_app");
                cell.detailTextLabel.text = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"IPA Install";
                break;
            case 1:
                cell.textLabel.text = T(@"settings.about_version");
                cell.detailTextLabel.text = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
                break;
            case 2:
                cell.textLabel.text = T(@"settings.about_bundle");
                cell.detailTextLabel.text = [b bundleIdentifier] ?: @"?";
                break;
            case 3:
                cell.textLabel.text = T(@"settings.about_min_ios");
                cell.detailTextLabel.text = @"5.0 (armv7)";
                break;
            case 4:
                cell.textLabel.text = T(@"settings.about_device_ios");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@",
                                              d.systemName ?: @"iOS", d.systemVersion ?: @"?"];
                break;
            case 5:
                cell.textLabel.text = T(@"settings.about_device_model");
                cell.detailTextLabel.text = d.model ?: @"?";
                break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SectionLanguage) {
        [self showLanguagePicker];
        return;
    }
    if (ip.section == SectionUpdates) {
        if (ip.row == 1) [self handleUpdatesRowTap];
        return;
    }
    if (ip.section == SectionDownload) {
        [self showParallelStreamsPicker];
        return;
    }
    if (ip.section == SectionArchive) {
        [self promptArchiveFieldAtIndex:ip.row];
        return;
    }
    if (ip.section == SectionDiag) {
        if (ip.row == 0) [self testDirectHTTPS];
        else [self testIpainstaller];
    } else if (ip.section == SectionCache) {
        [[IconLoader shared] clearCache];
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"settings.cache_cleared")
                                                    message:T(@"settings.cache_cleared_msg")
                                                   delegate:nil
                                          cancelButtonTitle:T(@"common.ok")
                                          otherButtonTitles:nil];
        [a show];
    }
}

#pragma mark - Archive.org S3 credentials

// Show a single-line text-input alert for an archive.org field. The index maps to
// 0=email, 1=access key, 2=secret key. Pre-fills the current value so the user
// can edit rather than retype. To clear a value, the user wipes the field and Saves.
- (void)promptArchiveFieldAtIndex:(NSInteger)idx {
    self.pendingArchiveFieldIndex = idx;
    NSString *title;
    NSString *currentValue;
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    switch (idx) {
        case 0:
            title = T(@"settings.archive_email");
            currentValue = [def stringForKey:kPrefArchiveEmail];
            break;
        case 1:
            title = T(@"settings.archive_access_key");
            currentValue = [def stringForKey:kPrefArchiveAccessKey];
            break;
        default:
            title = T(@"settings.archive_secret_key");
            currentValue = [def stringForKey:kPrefArchiveSecretKey];
            break;
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                     message:T(@"settings.archive_help")
                                                    delegate:self
                                           cancelButtonTitle:T(@"common.cancel")
                                           otherButtonTitles:T(@"settings.archive_save"), nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = 100;  // distinguish from other alerts in this VC
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.text = currentValue ?: @"";
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.spellCheckingType = UITextSpellCheckingTypeNo;
    if (idx == 0) {
        tf.keyboardType = UIKeyboardTypeEmailAddress;
    } else {
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }
    [alert show];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alert.tag == 101) {
        // Install-update confirmation
        if (buttonIndex != alert.cancelButtonIndex) {
            [self installUpdateConfirmed];
        }
        return;
    }
    if (alert.tag != 100) return;
    if (buttonIndex == alert.cancelButtonIndex) return;
    UITextField *tf = [alert textFieldAtIndex:0];
    NSString *value = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    NSString *key;
    switch (self.pendingArchiveFieldIndex) {
        case 0: key = kPrefArchiveEmail; break;
        case 1: key = kPrefArchiveAccessKey; break;
        default: key = kPrefArchiveSecretKey; break;
    }
    if (value.length) {
        [def setObject:value forKey:key];
    } else {
        [def removeObjectForKey:key];
    }
    [def synchronize];
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionArchive]
                withRowAnimation:UITableViewRowAnimationNone];
}

- (void)testIpainstaller {
    // Try to spawn /usr/bin/ipainstaller -l (list) and capture output.
    // If this works from the mobile-user app sandbox, autonomous install is feasible.
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"common.error")
                                                    message:@"pipe() a echoue"
                                                   delegate:nil cancelButtonTitle:T(@"common.ok") otherButtonTitles:nil];
        [a show]; return;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pipefd[1]);

    const char *path = "/usr/bin/ipainstaller";
    char *const argv[] = { (char *)"ipainstaller", (char *)"-l", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);

    NSString *result;
    if (rc != 0) {
        result = [NSString stringWithFormat:@"ECHEC posix_spawn rc=%d errno=%d\n%s\n\nL'app NE PEUT PAS invoquer ipainstaller depuis le sandbox.",
                  rc, errno, strerror(errno)];
        close(pipefd[0]);
    } else {
        // Read output (max 4KB)
        char buf[4096] = {0};
        ssize_t n = read(pipefd[0], buf, sizeof(buf) - 1);
        close(pipefd[0]);
        int status = 0;
        waitpid(pid, &status, 0);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

        NSString *output = (n > 0)
            ? [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding]
            : @"";
        result = [NSString stringWithFormat:@"SPAWN OK pid=%d exit=%d\n\nOutput (%ld octets):\n%@",
                  pid, exitCode, (long)n, [output substringToIndex:MIN(output.length, 500)]];
    }
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Test ipainstaller"
                                                message:result
                                               delegate:nil
                                      cancelButtonTitle:T(@"common.ok")
                                      otherButtonTitles:nil];
    [a show];
}

- (void)testDirectHTTPS {
    UIAlertView *loading = [[UIAlertView alloc] initWithTitle:@"Test en cours..."
                                                       message:@"HTTPS vers archive.org via mbedTLS bundle"
                                                      delegate:nil
                                             cancelButtonTitle:nil
                                             otherButtonTitles:nil];
    [loading show];
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
                                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    sp.center = CGPointMake(loading.bounds.size.width/2, loading.bounds.size.height-50);
    [sp startAnimating];
    [loading addSubview:sp];

    NSDate *start = [NSDate date];
    // Use bundled mbedTLS (NOT iOS native TLS which is too old for archive.org)
    [HTTPSClient getURL:@"https://archive.org/about/"
                timeout:25
             completion:^(NSData *body, NSInteger status, NSError *err) {
        NSTimeInterval elapsed = -[start timeIntervalSinceNow];
        [loading dismissWithClickedButtonIndex:0 animated:NO];
        NSString *msg;
        if (err) {
            msg = [NSString stringWithFormat:@"ECHEC (%.1fs)\n\n%@\n\nLa lib mbedTLS bundle a echoue le handshake TLS avec archive.org. A investiguer.",
                     elapsed, err.localizedDescription];
        } else if (status >= 200 && status < 400) {
            msg = [NSString stringWithFormat:@"SUCCES !\n\nStatus HTTP : %ld\nTaille body : %lu octets\nTemps : %.1fs\n\nL'app peut joindre archive.org en HTTPS direct (necessaire pour installer une IPA).",
                     (long)status, (unsigned long)body.length, elapsed];
        } else {
            msg = [NSString stringWithFormat:@"REPONSE HTTP %ld (%.1fs)\nTaille : %lu octets",
                     (long)status, elapsed, (unsigned long)body.length];
        }
        UIAlertView *result = [[UIAlertView alloc] initWithTitle:@"Test mbedTLS"
                                                          message:msg
                                                         delegate:nil
                                                cancelButtonTitle:T(@"common.ok")
                                                otherButtonTitles:nil];
        [result show];
    }];
}

#pragma mark - Updates section (v1.2 build 13)

// Footer copy below the Updates section. Either "Last checked: <relative time>"
// or instructional text when we've never checked.
- (NSString *)updatesSectionFooter {
    UpdateChecker *uc = [UpdateChecker shared];
    if (!uc.lastCheckedAt) {
        return T(@"settings.updates_footer_initial");
    }
    NSTimeInterval ago = -[uc.lastCheckedAt timeIntervalSinceNow];
    NSString *whenAgo;
    if (ago < 60) {
        whenAgo = T(@"settings.last_checked_just_now");
    } else if (ago < 3600) {
        whenAgo = [NSString stringWithFormat:T(@"settings.last_checked_minutes"),
                     (long)(ago / 60)];
    } else if (ago < 86400) {
        whenAgo = [NSString stringWithFormat:T(@"settings.last_checked_hours"),
                     (long)(ago / 3600)];
    } else {
        whenAgo = [self formattedDate:uc.lastCheckedAt];
    }
    return [NSString stringWithFormat:T(@"settings.updates_footer_checked"), whenAgo];
}

// Locale-aware medium date format ("May 27, 2026" / "27 mai 2026" / "2026年5月27日" etc.).
- (NSString *)formattedDate:(NSDate *)date {
    if (!date) return @"?";
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterNoStyle;
        // Locale defaults to user's current locale — already what we want.
    });
    return [fmt stringFromDate:date];
}

// Tap on the "Latest release" row dispatches based on current state:
//   - Available  → confirm + install
//   - Up to date → re-check (force)
//   - Error      → re-check (force)
//   - Checking   → no-op (already in flight)
//   - Unknown    → trigger first check
- (void)handleUpdatesRowTap {
    UpdateChecker *uc = [UpdateChecker shared];
    if (uc.status == UpdateCheckerStatusChecking) return;
    if (uc.status == UpdateCheckerStatusAvailable && uc.latestIpaURL.length) {
        // Present the release-notes modal (v1.2 build 14). It renders the
        // GitHub release body as HTML and offers a Cancel/Install pair in
        // the nav bar. Tapping Install fires installUpdateConfirmed via the
        // handler block.
        UpdateNotesViewController *vc = [[UpdateNotesViewController alloc] init];
        vc.version = uc.latestVersion;
        vc.releaseDate = uc.latestReleaseDate;
        vc.notesMarkdown = uc.latestReleaseNotes;
        __weak typeof(self) weakSelf = self;
        vc.installHandler = ^{
            __strong typeof(self) s = weakSelf;
            if (s) [s installUpdateConfirmed];
        };
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:vc];
        // Full-screen on iPhone (always), form-sheet (centered) on iPad
        // for a bit of breathing room on the big screen.
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
        }
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    // Any other state → re-check.
    [uc checkForUpdates:YES];
}

// Continues UIAlertView dispatch already wired for archive credentials.
// alert.tag 101 = "install update" confirmation.
- (void)installUpdateConfirmed {
    UpdateChecker *uc = [UpdateChecker shared];
    NSString *url = uc.latestIpaURL;
    if (!url.length) return;
    [[InstallManager shared] startInstallWithURL:url
                                       completion:^(NSString *jobId, NSError *err) {
        if (err) {
            UIAlertView *a = [[UIAlertView alloc]
                initWithTitle:T(@"common.error")
                      message:err.localizedDescription
                     delegate:nil
            cancelButtonTitle:T(@"common.ok")
            otherButtonTitles:nil];
            [a show];
            return;
        }
        // Tell the user where to watch progress.
        UIAlertView *a = [[UIAlertView alloc]
            initWithTitle:T(@"settings.update_started_title")
                  message:T(@"settings.update_started_msg")
                 delegate:nil
        cancelButtonTitle:T(@"common.ok")
        otherButtonTitles:nil];
        [a show];
    }];
}

#pragma mark - Parallel-streams picker (v1.2 build 9)

- (void)showParallelStreamsPicker {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:T(@"settings.parallel_streams")
                                                       delegate:self
                                              cancelButtonTitle:nil
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:nil];
    sheet.tag = 98;
    NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefParallelStreams];
    if (current <= 0) current = 4;
    for (NSInteger i = 0; i < kStreamChoicesCount; i++) {
        NSInteger n = kStreamChoices[i];
        NSString *title = (n == 1)
            ? T(@"settings.streams_off")
            : [NSString stringWithFormat:T(@"settings.streams_n"), (long)n];
        if (n == current) {
            title = [title stringByAppendingString:@" ✓"];
        }
        [sheet addButtonWithTitle:title];
    }
    [sheet addButtonWithTitle:T(@"common.cancel")];
    sheet.cancelButtonIndex = kStreamChoicesCount;
    [sheet showInView:self.view];
}

#pragma mark - Language picker

- (void)showLanguagePicker {
    // Build an action-sheet-like picker. Use UIActionSheet (iOS 5/6 compatible).
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:T(@"settings.language")
                                                       delegate:self
                                              cancelButtonTitle:nil
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:nil];
    sheet.tag = 99;
    // First option = Auto, then each supported language
    [sheet addButtonWithTitle:T(@"settings.language_auto")];
    NSArray *codes = [Localization availableLanguageCodes];
    for (NSString *code in codes) {
        NSString *display = [Localization displayNameForLanguageCode:code];
        [sheet addButtonWithTitle:display];
    }
    [sheet addButtonWithTitle:T(@"common.cancel")];
    sheet.cancelButtonIndex = (NSInteger)codes.count + 1;
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)idx {
    if (sheet.tag == 98) {
        // Parallel-streams picker
        if (idx == sheet.cancelButtonIndex) return;
        if (idx >= 0 && idx < kStreamChoicesCount) {
            NSInteger choice = kStreamChoices[idx];
            [[NSUserDefaults standardUserDefaults] setInteger:choice forKey:kPrefParallelStreams];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self.table reloadSections:[NSIndexSet indexSetWithIndex:SectionDownload]
                       withRowAnimation:UITableViewRowAnimationNone];
        }
        return;
    }
    if (sheet.tag != 99) return;
    if (idx == sheet.cancelButtonIndex) return;
    if (idx == 0) {
        [Localization setLanguageCode:nil];
    } else {
        NSArray *codes = [Localization availableLanguageCodes];
        if (idx - 1 < (NSInteger)codes.count) {
            [Localization setLanguageCode:codes[idx - 1]];
        }
    }
    // Re-create the entire tab bar with new translations and re-select the Settings tab.
    // Important: re-fetch the window AFTER the relaunch (the old `win` would be orphaned).
    [(id)[[UIApplication sharedApplication] delegate]
        application:[UIApplication sharedApplication]
        didFinishLaunchingWithOptions:nil];
    UIWindow *newWin = [[[UIApplication sharedApplication] delegate] window];
    UITabBarController *tabs = (UITabBarController *)newWin.rootViewController;
    // Settings is tab index 4 since v1.2 restored the Search tab (order: catalog,
    // search, ai, install, settings).
    if ([tabs isKindOfClass:[UITabBarController class]]) tabs.selectedIndex = 4;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

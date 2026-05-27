#import "CatalogViewController.h"
#import "Localization.h"
#import "InstallManager.h"
#import "CatalogFilter.h"
#import "FilterViewController.h"
#import "AppDetailViewController.h"
#import "IconLoader.h"
#import "AppRowCell.h"
#import "IOS6Theme.h"
#import "LocalCatalog.h"
#import "CatalogAppCell.h"
#import "SearchViewController.h"

static const CGFloat kIconSize = 44;
static const CGFloat kSelectionToolbarHeight = 44;
// Onboarding key shared with AppDetailViewController so the "ipainstaller required"
// alert only ever shows once, not twice (once per surface).
static NSString *const kOnboardingKey = @"IPAInstall.onboarding.ipainstaller.shown";

static inline BOOL kIsIPad(void) {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
}

@interface CatalogViewController () <FilterViewControllerDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) CatalogFilter *filter;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger pageOffset;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL eof;
@property (nonatomic, copy) NSString *currentQuery;

// === Selection mode (multi-select install) ==========================
// Selected apps live in a dict keyed by pk (NSNumber). We store the FULL dict
// (not just the id) so that installs still work even if the user changes
// search/filter and the now-selected entries are no longer in self.results.
// This is what makes selection robust across far scrolling: the cells are
// recycled but our backing store is independent.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, strong) NSMutableDictionary *selectedAppsByPk;
@property (nonatomic, strong) UIToolbar *selectionToolbar;
@property (nonatomic, strong) UIBarButtonItem *installSelectionItem;

// Pending batch when waiting for onboarding alert dismissal (so the user only
// sees the alert once, not once per app, when bulk-installing).
@property (nonatomic, strong) NSArray *pendingBatchInstall;
@end

@implementation CatalogViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"catalog.title");
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];  // App Store white

    self.filter = [CatalogFilter load_];
    self.results = [NSMutableArray array];
    self.selectedAppsByPk = [NSMutableDictionary dictionary];
    self.currentQuery = @"";

    [self buildUI];
    [self refreshNavBar];
    [self performSearch];
}

- (void)buildUI {
    CGFloat w = self.view.bounds.size.width;

    // v1.1: the catalog search bar moved to its own dedicated Search tab in the
    // tab bar. This screen is now just the catalog grid + filter / select / refresh.
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // iPhone: 76 — 2-line subtitle (meta + filename).
    self.tableView.rowHeight = kIsIPad() ? 170 : 76;
    self.tableView.separatorStyle = kIsIPad() ? UITableViewCellSeparatorStyleNone
                                              : UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]
                     initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 36)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor grayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.tableView.tableFooterView = self.statusLabel;

    // Selection toolbar — bottom of view, hidden by default. Shown in selection
    // mode so the user can tap "Installer (N)" without losing scroll position.
    self.selectionToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(
        0, self.view.bounds.size.height - kSelectionToolbarHeight,
        w, kSelectionToolbarHeight)];
    self.selectionToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                           | UIViewAutoresizingFlexibleTopMargin;
    self.selectionToolbar.hidden = YES;
    self.installSelectionItem = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:T(@"catalog.install_n"), 0UL]
                style:UIBarButtonItemStyleDone
               target:self action:@selector(installSelectedTapped)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];
    self.selectionToolbar.items = @[flex, self.installSelectionItem, flex];
    [self.view addSubview:self.selectionToolbar];
}

- (void)refreshNavBar {
    if (self.selectionMode) {
        // In selection mode: Cancel (left) + Done (right). No Filters/Refresh —
        // would be confusing because changing filters discards the selection.
        UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self action:@selector(exitSelectionMode)];
        self.navigationItem.rightBarButtonItems = @[doneBtn];
    } else {
        UIBarButtonItem *filtersBtn = [[UIBarButtonItem alloc]
            initWithTitle:T(@"catalog.filters")
                    style:UIBarButtonItemStyleBordered
                   target:self action:@selector(filtersTapped)];
        UIBarButtonItem *selectBtn = [[UIBarButtonItem alloc]
            initWithTitle:T(@"catalog.select")
                    style:UIBarButtonItemStyleBordered
                   target:self action:@selector(enterSelectionMode)];
        // Search button uses the same magnifying-glass system item as the
        // standard iOS search icon. Pushes SearchViewController onto the
        // catalog's nav stack; the search VC reads CatalogFilter.load_ so
        // current filters are naturally inherited.
        UIBarButtonItem *searchBtn = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                 target:self action:@selector(searchTapped)];
        UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                 target:self action:@selector(performSearch)];
        // Order is rightmost first: [filters, search, select, refresh].
        self.navigationItem.rightBarButtonItems = @[filtersBtn, searchBtn, selectBtn, refreshBtn];
    }
}

- (void)searchTapped {
    SearchViewController *svc = [[SearchViewController alloc] init];
    [self.navigationController pushViewController:svc animated:YES];
}

#pragma mark - Filters

- (void)filtersTapped {
    FilterViewController *fvc = [[FilterViewController alloc] init];
    fvc.filter = [self.filter copy];
    fvc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fvc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter {
    self.filter = filter;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self performSearch];
}

- (void)filterViewControllerDidCancel:(FilterViewController *)vc {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search

- (void)performSearch {
    self.pageOffset = 0;
    self.eof = NO;
    [self.results removeAllObjects];
    [self.tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (self.loading || self.eof) return;
    self.loading = YES;
    self.statusLabel.text = self.results.count == 0 ? T(@"catalog.loading") : T(@"catalog.loading_more");
    [self.spinner startAnimating];

    if ([[InstallManager shared] autonomousMode]) {
        [self loadMoreAutonomous];
        return;
    }

    NSString *backend = [[InstallManager shared] backendURL];
    NSString *qs = [self.filter queryStringWithSearch:self.currentQuery
                                                 offset:self.pageOffset
                                                  limit:30];
    NSString *url = [NSString stringWithFormat:@"%@/catalog?%@", backend, qs];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:20];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
        self.loading = NO;
        [self.spinner stopAnimating];
        if (e || !d) {
            self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.network_error"),
                                       e.localizedDescription ?: @""];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!json) {
            self.statusLabel.text = T(@"catalog.server_invalid");
            return;
        }
        NSArray *results = json[@"results"];
        NSInteger total = [json[@"total"] integerValue];
        self.totalCount = total;
        if ([results count] == 0) {
            self.eof = YES;
        } else {
            [self.results addObjectsFromArray:results];
            self.pageOffset += [results count];
            if (self.pageOffset >= total) self.eof = YES;
        }
        self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.apps_count"),
                                  (unsigned long)self.results.count, (long)total,
                                  self.eof ? T(@"catalog.end") : @""];
        [self.tableView reloadData];
    }];
}

- (void)loadMoreAutonomous {
    void (^doQuery)(void) = ^{
        [[LocalCatalog shared] searchAsyncWithQuery:self.currentQuery
                                              minIOS:self.filter.minIOS
                                              maxIOS:self.filter.maxIOS
                                              unique:self.filter.uniqueOnly
                                                sort:self.filter.sort
                                          descending:self.filter.sortDescending
                                         deviceClass:self.filter.deviceClass
                                              offset:self.pageOffset
                                               limit:30
                                          completion:^(NSDictionary *res) {
            self.loading = NO;
            [self.spinner stopAnimating];
            if (res[@"error"]) {
                self.statusLabel.text = [@"Local: " stringByAppendingString:res[@"error"]];
                return;
            }
            NSArray *page = res[@"results"];
            NSInteger total = [res[@"total"] integerValue];
            self.totalCount = total;
            if (!page.count) {
                self.eof = YES;
                [self.tableView reloadData];
            } else {
                [self.results addObjectsFromArray:page];
                self.pageOffset += page.count;
                if (self.pageOffset >= total) self.eof = YES;
                [UIView setAnimationsEnabled:NO];
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [self.tableView reloadData];
                [CATransaction commit];
                [UIView setAnimationsEnabled:YES];
            }
            self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.apps_count"),
                                      (unsigned long)self.results.count, (long)total,
                                      self.eof ? T(@"catalog.end") : @""];
        }];
    };

    if ([[LocalCatalog shared] isReady]) { doQuery(); return; }
    self.statusLabel.text = T(@"catalog.loading");
    [[LocalCatalog shared] loadWithProgress:^(NSString *status) {
        self.statusLabel.text = status;
    } completion:^(BOOL ok, NSError *err) {
        if (!ok) {
            self.loading = NO;
            [self.spinner stopAnimating];
            self.statusLabel.text = [NSString stringWithFormat:@"Echec chargement local : %@",
                                       err.localizedDescription ?: @""];
            return;
        }
        doQuery();
    }];
}

// v1.1: UISearchBarDelegate methods removed — search now lives in its own
// SearchViewController tab. CatalogVC's currentQuery is always @"" (the
// LocalCatalog query path still accepts it and returns the unfiltered list).

#pragma mark - Selection mode

- (void)enterSelectionMode {
    self.selectionMode = YES;
    [self refreshNavBar];
    [self updateSelectionToolbar];
    [self.tableView reloadData];
}

- (void)exitSelectionMode {
    self.selectionMode = NO;
    [self.selectedAppsByPk removeAllObjects];
    [self refreshNavBar];
    [self updateSelectionToolbar];
    [self.tableView reloadData];
}

- (void)toggleSelectionForApp:(NSDictionary *)app {
    NSNumber *pk = app[@"id"];
    if (!pk) return;
    if ([self.selectedAppsByPk objectForKey:pk]) {
        [self.selectedAppsByPk removeObjectForKey:pk];
    } else {
        // Copy because the dict in self.results may go away when the user
        // changes filter/search; we want our backing store independent.
        [self.selectedAppsByPk setObject:[app copy] forKey:pk];
    }
    [self updateSelectionToolbar];
}

- (void)updateSelectionToolbar {
    NSUInteger n = self.selectedAppsByPk.count;
    self.installSelectionItem.title = [NSString stringWithFormat:T(@"catalog.install_n"),
                                         (unsigned long)n];
    self.installSelectionItem.enabled = (n > 0);
    BOOL shouldShow = self.selectionMode;
    if (shouldShow == !self.selectionToolbar.hidden) {
        // Already in correct state — just refresh content insets if needed.
    } else {
        self.selectionToolbar.hidden = !shouldShow;
        UIEdgeInsets ci = self.tableView.contentInset;
        ci.bottom = shouldShow ? kSelectionToolbarHeight : 0;
        self.tableView.contentInset = ci;
        UIEdgeInsets si = self.tableView.scrollIndicatorInsets;
        si.bottom = shouldShow ? kSelectionToolbarHeight : 0;
        self.tableView.scrollIndicatorInsets = si;
    }
}

- (void)installSelectedTapped {
    if (self.selectedAppsByPk.count == 0) return;
    NSArray *batch = [self.selectedAppsByPk.allValues copy];

    // Show onboarding alert once if first install ever; otherwise fire immediately.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kOnboardingKey]) {
        self.pendingBatchInstall = batch;
        UIAlertView *a = [[UIAlertView alloc]
            initWithTitle:T(@"onboarding.ipainstaller_title")
                  message:T(@"onboarding.ipainstaller_msg")
                 delegate:self
        cancelButtonTitle:T(@"onboarding.ipainstaller_cancel")
        otherButtonTitles:T(@"onboarding.ipainstaller_continue"), nil];
        a.tag = 43;
        [a show];
        return;
    }
    [self fireBatchInstall:batch];
}

- (void)fireBatchInstall:(NSArray *)batch {
    NSUInteger started = 0;
    for (NSDictionary *app in batch) {
        NSString *url = app[@"url"];
        if (!url.length) continue;
        // Dedup: skip if there's already a job in flight for this URL. Otherwise
        // double-tapping the install button stacks two parallel downloads of the
        // same .ipa and ipainstaller installs the app twice.
        if ([[InstallManager shared] hasActiveJobForURL:url]) continue;
        [[InstallManager shared] startInstallWithURL:url
                                          completion:^(NSString *jobId, NSError *err) {
            // Errors surface via the Jobs tab; nothing to do per-app here.
        }];
        started++;
    }
    // Toast-style status feedback.
    self.statusLabel.text = [NSString stringWithFormat:T(@"catalog.install_started_n"),
                               (unsigned long)started];
    // Only exit selection mode if we WERE in it. Quick-install button calls this
    // path too and we don't want to disturb the catalog scroll when it does.
    if (self.selectionMode) [self exitSelectionMode];
}

#pragma mark - Quick install (single tap from list)

// quickInstallApp:/quickInstallFromButton: were removed in v2.0.30 along with
// the per-cell install shortcut. Single installs go through the detail VC;
// batch installs go through the multi-select toolbar.

#pragma mark - UIAlertViewDelegate (onboarding)

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)idx {
    if (av.tag != 43) return;
    if (idx == av.cancelButtonIndex) {
        self.pendingBatchInstall = nil;
        return;
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kOnboardingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSArray *batch = self.pendingBatchInstall;
    self.pendingBatchInstall = nil;
    if (batch.count) [self fireBatchInstall:batch];
}

#pragma mark - Table

- (NSInteger)tilesPerRowForWidth:(CGFloat)w {
    if (!kIsIPad()) return 1;
    NSInteger n = MAX(2, (NSInteger)(w / 175));
    return MIN(n, 6);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (!kIsIPad()) return self.results.count;
    NSInteger n = [self tilesPerRowForWidth:tv.bounds.size.width];
    NSInteger rows = (NSInteger)(self.results.count + n - 1) / n;
    return rows;
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld o", bytes];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f Ko", bytes/1024.0];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f Mo", bytes/(1024.0*1024)];
    return [NSString stringWithFormat:@"%.2f Go", bytes/(1024.0*1024*1024)];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ============ iPad: multi-tile row ============
    if (kIsIPad()) {
        static NSString *rowId = @"catRow";
        AppRowCell *row = [tv dequeueReusableCellWithIdentifier:rowId];
        if (!row) {
            row = [[AppRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:rowId];
        }
        NSInteger n = [self tilesPerRowForWidth:tv.bounds.size.width];
        row.tilesPerRow = n;
        __weak typeof(self) ws = self;
        row.selectionMode = self.selectionMode;
        // Selection lookup callback — runs for each tile during layout so the
        // check overlay reflects the source-of-truth dict, not stale visuals.
        row.isAppSelectedBlock = ^BOOL(NSDictionary *app) {
            NSNumber *pk = app[@"id"];
            return pk && ws.selectedAppsByPk[pk] != nil;
        };
        row.onTileTap = ^(NSDictionary *app) {
            if (ws.selectionMode) {
                [ws toggleSelectionForApp:app];
                [ws.tableView reloadData];
            } else {
                AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
                [ws.navigationController pushViewController:vc animated:YES];
            }
        };
        NSInteger start = ip.row * n;
        NSInteger end = MIN(start + n, (NSInteger)self.results.count);
        NSArray *slice = (start < (NSInteger)self.results.count)
            ? [self.results subarrayWithRange:NSMakeRange(start, end - start)]
            : @[];
        [row setApps:slice];

        if (end >= (NSInteger)self.results.count - n * 2) [self loadMore];
        return row;
    }

    // ============ iPhone: single app per row, custom cell ============
    // v2.0.29: switched to CatalogAppCell (custom UITableViewCell subclass) so
    // the install button lives in contentView, not accessoryView. Resolves the
    // iOS 6 bug where UIControl-in-accessoryView taps were stolen by the cell's
    // tap recognizer and turned into didSelectRow.
    static NSString *cellId = @"catCell";
    CatalogAppCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[CatalogAppCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellId];
    }
    NSDictionary *app = self.results[ip.row];
    cell.appTitleLabel.text = app[@"title"] ?: @"?";
    long long size = [app[@"size"] longLongValue];
    NSString *sizeStr = size > 0 ? [self humanSize:size] : @"?";
    NSString *fname = app[@"fileName"] ?: @"";
    NSString *metaLine = [NSString stringWithFormat:@"v%@ — min iOS %@ — %@",
                          app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", sizeStr];
    cell.appSubtitleLabel.text = fname.length
        ? [NSString stringWithFormat:@"%@\n%@", metaLine, fname]
        : metaLine;

    // === Right slot: checkmark in selection mode, nothing in default ===
    if (self.selectionMode) {
        NSNumber *pk = app[@"id"];
        BOOL isSel = pk && [self.selectedAppsByPk objectForKey:pk] != nil;
        cell.accessoryType = isSel ? UITableViewCellAccessoryCheckmark
                                   : UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    // Icon — async via IconLoader
    NSString *iconUrl = app[@"icon"];
    CGSize sz = CGSizeMake(kIconSize, kIconSize);
    UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
    if (cached) {
        cell.appIconView.image = cached;
    } else {
        cell.appIconView.image = nil;
        NSString *expectedTitle = app[@"title"];
        [[IconLoader shared] loadImageForURL:iconUrl
                                   targetSize:sz
                                          via:nil
                                   completion:^(UIImage *img) {
            if (!img) return;
            CatalogAppCell *visible = (CatalogAppCell *)[self.tableView cellForRowAtIndexPath:ip];
            if (![visible isKindOfClass:[CatalogAppCell class]]) return;
            if (ip.row >= (NSInteger)self.results.count) return;
            NSDictionary *appNow = self.results[ip.row];
            if (![appNow[@"title"] isEqual:expectedTitle]) return;
            visible.appIconView.image = img;
        }];
    }

    if (ip.row >= (NSInteger)self.results.count - 5) {
        [self loadMore];
    }
    return cell;
}

#pragma mark - UIScrollView (suspend icons while fast-scrolling)

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    [[IconLoader shared] suspend];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decel {
    if (!decel) [[IconLoader shared] resume];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    [[IconLoader shared] resume];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    
    if (kIsIPad()) return;  // taps on iPad handled by AppTileView's onTap
    if (ip.row >= (NSInteger)self.results.count) return;
    NSDictionary *app = self.results[ip.row];
    if (self.selectionMode) {
        [self toggleSelectionForApp:app];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)o
                                          duration:(NSTimeInterval)d {
    if (kIsIPad()) [self.tableView reloadData];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

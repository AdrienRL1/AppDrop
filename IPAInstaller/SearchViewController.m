#import "SearchViewController.h"
#import "Localization.h"
#import "LocalCatalog.h"
#import "CatalogFilter.h"
#import "CatalogAppCell.h"
#import "AppDetailViewController.h"
#import "IconLoader.h"
#import "IOS6Theme.h"
#import "AppRowCell.h"
#import "FilterViewController.h"

static inline BOOL kSearchIsIPad(void) { return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad; }

static const CGFloat kIconSize = 44;
static const NSInteger kPageLimit = 50;

@interface SearchViewController () <FilterViewControllerDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, copy)   NSString *currentQuery;
@property (nonatomic, assign) NSInteger pageOffset;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL eof;
// Monotonically-increasing token so out-of-order async responses from the
// catalog don't clobber newer results. Bump on every new query.
@property (nonatomic, assign) NSInteger queryToken;
@end

@implementation SearchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"tab.search");
    self.view.backgroundColor = [IOS6Theme contentBackgroundColor];
    self.results = [NSMutableArray array];
    self.currentQuery = @"";
    // v1.4: re-lay-out the grid when the Settings density slider changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(gridDensityDidChange)
            name:@"AppDropGridDensityChanged" object:nil];

    CGFloat w = self.view.bounds.size.width;
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    self.searchBar.placeholder = T(@"search.placeholder");
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.delegate = self;
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = kSearchIsIPad() ? 170 : 76;  // iPad: tile-grid rows like the Catalogue
    self.tableView.backgroundColor = [IOS6Theme contentBackgroundColor];
    [self.view addSubview:self.tableView];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 36)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor grayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.text = T(@"search.hint_empty");
    self.tableView.tableFooterView = self.statusLabel;

    // Filters — same screen as the Catalogue, applied to the search results.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:T(@"catalog.filters")
                style:UIBarButtonItemStyleBordered
               target:self action:@selector(filtersTapped)];
}

// Pop the keyboard as soon as the user lands on this tab — search-first UX.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.currentQuery.length == 0) {
        [self.searchBar becomeFirstResponder];
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.currentQuery = text ?: @"";
    // 150 ms debounce — feels instant while still coalescing rapid keystrokes.
    // The Catalog tab uses 400 ms because its underlying query has a heavier
    // filter+sort path; Search uses the simpler query and can afford the speed.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(runQuery)
                                               object:nil];
    [self performSelector:@selector(runQuery) withObject:nil afterDelay:0.15];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)sb {
    [sb setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)sb {
    [sb setShowsCancelButton:NO animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = @"";
    self.currentQuery = @"";
    [sb resignFirstResponder];
    [self.results removeAllObjects];
    self.statusLabel.text = T(@"search.hint_empty");
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

#pragma mark - Query

- (void)runQuery {
    self.pageOffset = 0;
    self.eof = NO;
    [self.results removeAllObjects];
    self.queryToken++;
    // CRITICAL: clear `loading` so a new query starts immediately even if a
    // previous one is still in flight on LocalCatalog's serial _searchQueue.
    // Without this, fast typing piles up the loading guard and new queries
    // never start ("Searching..." spinner hangs forever). The previous in-flight
    // query will still complete, but its response gets discarded by the
    // queryToken check below.
    self.loading = NO;
    [self.tableView reloadData];
    if (self.currentQuery.length == 0) {
        self.statusLabel.text = T(@"search.hint_empty");
        return;
    }
    [self loadMore];
}

- (void)loadMore {
    if (self.loading || self.eof || self.currentQuery.length == 0) return;
    self.loading = YES;
    self.statusLabel.text = T(@"search.searching");
    NSInteger token = self.queryToken;
    CatalogFilter *cf = [CatalogFilter load_];
    [[LocalCatalog shared] searchAsyncWithQuery:self.currentQuery
                                          minIOS:cf.minIOS
                                          maxIOS:cf.maxIOS
                                          unique:cf.uniqueOnly
                                            sort:cf.sort
                                      descending:cf.sortDescending
                                     deviceClass:cf.deviceClass
                                          offset:self.pageOffset
                                           limit:kPageLimit
                                      completion:^(NSDictionary *res) {
        self.loading = NO;
        // Drop stale responses — if the user kept typing, our queryToken moved
        // on and these results are no longer relevant.
        if (token != self.queryToken) return;
        NSArray *page = res[@"results"];
        NSInteger total = [res[@"total"] integerValue];
        self.totalCount = total;
        if (!page.count) {
            self.eof = YES;
        } else {
            [self.results addObjectsFromArray:page];
            self.pageOffset += page.count;
            if (self.pageOffset >= total) self.eof = YES;
        }
        if (self.results.count == 0) {
            self.statusLabel.text = T(@"search.no_results");
        } else {
            self.statusLabel.text = [NSString stringWithFormat:T(@"search.results_count"),
                                       (unsigned long)self.results.count, (long)total];
        }
        [self.tableView reloadData];
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (!kSearchIsIPad()) return self.results.count;
    NSInteger n = [AppRowCell tilesPerRowForWidth:tv.bounds.size.width];
    return (NSInteger)(self.results.count + n - 1) / n;  // ceil — tiles packed per row
}

- (NSString *)humanSize:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld %@", bytes, T(@"unit.b")];
    if (bytes < 1024*1024) return [NSString stringWithFormat:@"%.0f %@", bytes/1024.0, T(@"unit.kb")];
    if (bytes < 1024LL*1024*1024) return [NSString stringWithFormat:@"%.1f %@", bytes/(1024.0*1024), T(@"unit.mb")];
    return [NSString stringWithFormat:@"%.2f %@", bytes/(1024.0*1024*1024), T(@"unit.gb")];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ===== iPad: multi-tile grid row (same component as the Catalogue) =====
    if (kSearchIsIPad()) {
        static NSString *rowId = @"searchRow";
        AppRowCell *row = [tv dequeueReusableCellWithIdentifier:rowId];
        if (!row) row = [[AppRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rowId];
        NSInteger n = [AppRowCell tilesPerRowForWidth:tv.bounds.size.width];
        row.tilesPerRow = n;
        row.selectionMode = NO;
        __weak typeof(self) ws = self;
        row.onTileTap = ^(NSDictionary *app) {
            if ([ws.searchBar isFirstResponder]) [ws.searchBar resignFirstResponder];
            AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
            [ws.navigationController pushViewController:vc animated:YES];
        };
        NSInteger startIdx = ip.row * n;
        NSMutableArray *slice = [NSMutableArray array];
        for (NSInteger i = startIdx; i < startIdx + n && i < (NSInteger)self.results.count; i++) {
            [slice addObject:self.results[i]];
        }
        [row setApps:slice];
        NSInteger totalRows = (NSInteger)(self.results.count + n - 1) / n;
        if (ip.row >= totalRows - 2) [self loadMore];   // prefetch next page near the end
        return row;
    }

    // ===== iPhone: single-app list row =====
    static NSString *cellId = @"searchCell";
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
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

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
            if (![self.results[ip.row][@"title"] isEqual:expectedTitle]) return;
            visible.appIconView.image = img;
        }];
    }

    if (ip.row >= (NSInteger)self.results.count - 5) [self loadMore];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (kSearchIsIPad()) return;   // iPad taps are handled by AppRowCell tiles (onTileTap)
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
    if (ip.row >= (NSInteger)self.results.count) return;
    NSDictionary *app = self.results[ip.row];
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    [[IconLoader shared] suspend];
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decel {
    if (!decel) [[IconLoader shared] resume];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    [[IconLoader shared] resume];
}

#pragma mark - Filters

- (void)filtersTapped {
    FilterViewController *fvc = [[FilterViewController alloc] init];
    fvc.filter = [CatalogFilter load_];
    fvc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fvc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter {
    // FilterViewController already persisted it; re-run the current query so the new
    // min/max iOS, device class, unique & sort apply to the search results.
    [self dismissViewControllerAnimated:YES completion:nil];
    if (self.currentQuery.length) [self runQuery];
}

- (void)filterViewControllerDidCancel:(FilterViewController *)vc {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)gridDensityDidChange {
    [self.tableView reloadData];   // new column count from the density pref
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

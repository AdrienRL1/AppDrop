#import <UIKit/UIKit.h>

// Dedicated "Search" tab — focused, fast, keyboard-first.
//
// Why a separate VC (v1.1):
// The Catalog tab is for browsing + filtering + multi-select. Search is a
// different use case: type a few letters, see matching apps immediately, tap
// one, install. By splitting them we can give Search a much tighter feedback
// loop (150 ms debounce vs 400 ms in Catalog) and auto-focus the search bar
// when the user selects the tab.
//
// Reuses CatalogAppCell + LocalCatalog (with the current CatalogFilter for
// consistency with what's visible in the Catalog tab).
@interface SearchViewController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

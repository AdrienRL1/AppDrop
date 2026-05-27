#import <UIKit/UIKit.h>
#import "CatalogFilter.h"

@protocol FilterViewControllerDelegate;

@interface FilterViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CatalogFilter *filter;
@property (nonatomic, weak) id<FilterViewControllerDelegate> delegate;
@end

@protocol FilterViewControllerDelegate <NSObject>
- (void)filterViewController:(FilterViewController *)vc didSaveFilter:(CatalogFilter *)filter;
- (void)filterViewControllerDidCancel:(FilterViewController *)vc;
@end

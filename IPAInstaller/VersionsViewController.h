#import <UIKit/UIKit.h>

@interface VersionsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithBundleId:(NSString *)bundleId title:(NSString *)title;
@end

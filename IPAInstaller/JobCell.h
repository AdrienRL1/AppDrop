#import <UIKit/UIKit.h>
@class InstallJob;

@interface JobCell : UITableViewCell
@property (nonatomic, strong, readonly) UILabel *nameLabel;
@property (nonatomic, strong, readonly) UILabel *messageLabel;
@property (nonatomic, strong, readonly) UIProgressView *progressBar;
- (void)configureWithJob:(InstallJob *)job;
@end

#import <UIKit/UIKit.h>

@interface AppDetailViewController : UIViewController
@property (nonatomic, copy) NSDictionary *app;
- (instancetype)initWithApp:(NSDictionary *)app;
@end

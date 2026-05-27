#import <UIKit/UIKit.h>

// Single-view iOS 6 Messages-style chat bubble.
// drawRect draws the path + gradient + tail in one rasterization pass — much
// faster on iPad 1 (A4) than stacking transparent UIViews with CALayer effects.
@interface ChatBubbleView : UIView
@property (nonatomic, assign) BOOL isUser;          // YES = blue right-tail; NO = gray left-tail
@property (nonatomic, copy) NSString *messageText;  // text rendered inside the bubble
@end

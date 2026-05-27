#import "ChatBubbleView.h"
#import "IOS6Theme.h"

@implementation ChatBubbleView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Bubble itself has transparent areas (outside the path) — view can't be opaque.
        // BUT the parent cell.contentView IS opaque, so blend cost is one bubble path per cell.
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setIsUser:(BOOL)isUser {
    if (_isUser == isUser) return;
    _isUser = isUser;
    [self setNeedsDisplay];
}

- (void)setMessageText:(NSString *)messageText {
    if ([_messageText isEqualToString:messageText]) return;
    _messageText = [messageText copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [IOS6Theme drawChatBubbleInRect:self.bounds isUser:self.isUser];

    // Text inside the bubble — inset for tail + padding
    CGFloat tailW = 10.0;
    CGFloat textPad = 11.0;
    CGRect textRect;
    if (self.isUser) {
        textRect = CGRectMake(textPad,
                              textPad - 2,
                              self.bounds.size.width - 2 * textPad - tailW,
                              self.bounds.size.height - 2 * textPad);
    } else {
        textRect = CGRectMake(textPad + tailW,
                              textPad - 2,
                              self.bounds.size.width - 2 * textPad - tailW,
                              self.bounds.size.height - 2 * textPad);
    }

    UIColor *textColor = self.isUser ? [UIColor whiteColor] : [IOS6Theme labelDark];
    [textColor set];
    if (self.isUser) {
        // White text on blue — drop a subtle dark shadow for legibility (iOS 6 hallmark)
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 0,
                                     [UIColor colorWithWhite:0 alpha:0.25].CGColor);
    }
    [(self.messageText ?: @"") drawInRect:textRect
                                  withFont:[IOS6Theme bodyFont]
                              lineBreakMode:NSLineBreakByWordWrapping
                                  alignment:NSTextAlignmentLeft];
}

@end

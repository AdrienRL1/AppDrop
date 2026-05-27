#import <UIKit/UIKit.h>

// Lightweight async icon loader optimized for old armv7 devices (iPad 1 A4 / 256 MB RAM).
// - Off-main decoding (background serial queue)
// - Pre-rendered to a target size with rounded corners baked in (no offscreen render at scroll)
// - NSCache with size limit
// - Per-URL request dedup
@interface IconLoader : NSObject

+ (instancetype)shared;

// Returns cached image immediately if available. Otherwise nil and triggers async load.
// When loaded, the completion block fires on the main queue with the image.
- (UIImage *)cachedImageForURL:(NSString *)url targetSize:(CGSize)size;
- (void)loadImageForURL:(NSString *)url
              targetSize:(CGSize)size
                via:(NSString *)proxyURL
              completion:(void (^)(UIImage *image))completion;

// Suspend/resume to pause loads during fast scrolling
- (void)suspend;
- (void)resume;

- (void)clearCache;

@end

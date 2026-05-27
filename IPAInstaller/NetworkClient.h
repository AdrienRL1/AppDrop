#import <Foundation/Foundation.h>

// Wraps NSURLConnection to bypass certificate validation (iOS 6's old trust store
// cannot validate modern Let's Encrypt / archive.org certificates). Required for
// fully autonomous operation without the Unraid proxy.
@interface NetworkClient : NSObject
+ (void)getURL:(NSString *)url
       timeout:(NSTimeInterval)t
    completion:(void (^)(NSData *data, NSHTTPURLResponse *resp, NSError *err))cb;
+ (void)postURL:(NSString *)url
            body:(NSData *)body
     contentType:(NSString *)ct
         timeout:(NSTimeInterval)t
      completion:(void (^)(NSData *data, NSHTTPURLResponse *resp, NSError *err))cb;
@end

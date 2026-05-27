#import <Foundation/Foundation.h>

// Bundled-TLS HTTPS client using mbedTLS, independent from iOS root CA store.
// Required for iOS 5/6 to talk to modern archive.org HTTPS (old iOS TLS lib is unable).
@interface HTTPSClient : NSObject

// Synchronous GET. Returns body as NSData or nil on failure. Pass NULL for unused outputs.
// Currently doesn't verify server cert (accepts any). Sufficient for fetching public IPAs.
+ (NSData *)getSyncURL:(NSString *)url
               timeout:(NSTimeInterval)timeout
            statusCode:(NSInteger *)outStatusCode
                 error:(NSError **)outError;

// Async GET on background queue, completion on main queue.
+ (void)getURL:(NSString *)url
        timeout:(NSTimeInterval)timeout
     completion:(void (^)(NSData *body, NSInteger statusCode, NSError *err))completion;

// POST with custom headers + body. headers = @{@"Authorization": @"Bearer ..."} etc.
+ (void)postURL:(NSString *)url
        headers:(NSDictionary *)headers
            body:(NSData *)body
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSData *resp, NSInteger statusCode, NSError *err))completion;

// Download URL to a local file, with redirect following (max 10) and progress callbacks.
// progressBlock(bytesReceived, totalBytes) called periodically on the BACKGROUND queue (don't block).
// completion called on MAIN queue.
+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)filePath
            progress:(void (^)(long long received, long long total))progressBlock
          completion:(void (^)(BOOL success, NSInteger statusCode, NSError *err))completion;

// Same as above, but with cancellation support. Pass a block that returns YES when the
// caller wants the download to abort. The block is polled inside the recv loop (header
// read + body read) every iteration, so cancellation latency is bounded by one recv()
// (which itself is bounded by the socket timeout — currently 60 s).
// On cancellation, the partial file at filePath is removed and completion fires with
// success=NO, statusCode=-1, err.code=99 ("Annulé").
+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)filePath
         isCancelled:(BOOL (^)(void))isCancelled
            progress:(void (^)(long long received, long long total))progressBlock
          completion:(void (^)(BOOL success, NSInteger statusCode, NSError *err))completion;

@end

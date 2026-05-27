#import "IconLoader.h"
#import "HTTPSClient.h"

@interface IconLoader ()
@property (nonatomic, strong) NSCache *cache;
@property (nonatomic, strong) NSMutableDictionary *pending;
// Maps URL → NSDate of last failed attempt. When a download returns no image (404, timeout,
// decode failure), we record the timestamp. Subsequent loadImageForURL: requests within
// kFailureCooldown seconds return nil immediately without hitting the network. Without this,
// a user scrolling past 30 dead URLs would re-fetch all 30 on every redraw.
@property (nonatomic, strong) NSMutableDictionary *failedAt;
@property (nonatomic, strong) NSOperationQueue *downloadQueue;
@property (nonatomic, assign) BOOL suspended;
@end

static const NSTimeInterval kFailureCooldown = 300;  // 5 minutes

@implementation IconLoader

+ (instancetype)shared {
    static IconLoader *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IconLoader alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [[NSCache alloc] init];
        // Bumped from 80 / 8 MB to 200 / 32 MB. On iPad 4 (1 GB RAM) this is harmless;
        // on iPad 1 (256 MB) iOS will evict under memory pressure anyway. Bigger cache
        // means cells the user already scrolled past don't re-download on scroll-back.
        _cache.countLimit = 200;
        _cache.totalCostLimit = 32 * 1024 * 1024;
        _pending = [NSMutableDictionary dictionary];
        _failedAt = [NSMutableDictionary dictionary];

        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.name = @"icon-download";
        _downloadQueue.maxConcurrentOperationCount = 5;  // up from 2 — visible page fills faster
    }
    return self;
}

- (NSString *)keyForURL:(NSString *)url size:(CGSize)size {
    return [NSString stringWithFormat:@"%@@%dx%d", url, (int)size.width, (int)size.height];
}

- (UIImage *)cachedImageForURL:(NSString *)url targetSize:(CGSize)size {
    if (!url.length) return nil;
    return [_cache objectForKey:[self keyForURL:url size:size]];
}

- (void)loadImageForURL:(NSString *)url
              targetSize:(CGSize)size
                via:(NSString *)proxyURL
              completion:(void (^)(UIImage *))completion {
    if (!url.length || !completion) return;
    NSString *key = [self keyForURL:url size:size];
    UIImage *cached = [_cache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    // Cooldown : if this URL recently failed, skip the network call.
    @synchronized (self.failedAt) {
        NSDate *failedAt = self.failedAt[key];
        if (failedAt && -[failedAt timeIntervalSinceNow] < kFailureCooldown) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
    }

    // Dedup: if request already in flight, queue this completion too
    @synchronized (self.pending) {
        NSMutableArray *waiters = self.pending[key];
        if (waiters) {
            [waiters addObject:[completion copy]];
            return;
        }
        self.pending[key] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    if (self.suspended) {
        // Still queue the download but it'll be paused by the queue.suspended flag below.
    }

    NSString *finalURL = proxyURL.length ? proxyURL : url;
    // iOS 5/6 NSURLConnection can't handshake modern HTTPS (TLS 1.2+ with ECDSA certs).
    // For https://* URLs, we route through HTTPSClient (bundled mbedTLS) → bypasses iOS root CA.
    // For http://* URLs (e.g. local LAN), NSURLConnection is fine.
    BOOL isHTTPS = [[finalURL lowercaseString] hasPrefix:@"https://"];
    NSString *capturedKey = key;
    void (^onData)(NSData *) = ^(NSData *d) {
        if (!d || d.length < 100) {
            // Record this URL as failed so we don't hammer it again for 5 minutes.
            @synchronized (self.failedAt) {
                self.failedAt[capturedKey] = [NSDate date];
            }
            [self fireWaiters:capturedKey withImage:nil];
            return;
        }
        dispatch_queue_t bg = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
        dispatch_async(bg, ^{
            UIImage *resized = [self decodeAndResize:d targetSize:size];
            if (resized) {
                NSUInteger cost = (NSUInteger)(size.width * size.height * 4);
                [self.cache setObject:resized forKey:capturedKey cost:cost];
                // Decode succeeded — clear any prior failure record so a working URL
                // recovers immediately after a transient timeout.
                @synchronized (self.failedAt) {
                    [self.failedAt removeObjectForKey:capturedKey];
                }
            } else {
                // Server returned bytes but they're not a valid image (404 HTML page, etc.).
                @synchronized (self.failedAt) {
                    self.failedAt[capturedKey] = [NSDate date];
                }
            }
            [self fireWaiters:capturedKey withImage:resized];
        });
    };

    // Timeout: 30 s is generous but mbedTLS handshake on iPad 1 can take 3-5 s by itself,
    // and stuffed18.github.io has high latency for first-hit (cold Fastly cache). 15 s was
    // too tight and dropped ~10 % of icons on slow WiFi.
    NSTimeInterval timeout = 30;
    if (isHTTPS) {
        // mbedTLS path — handles modern TLS / SNI / ECDSA that iOS 5/6 can't do natively.
        [HTTPSClient getURL:finalURL
                    timeout:timeout
                 completion:^(NSData *d, NSInteger code, NSError *err) {
            // Treat non-2xx HTTP status as failure (404, 503, etc.) — server returned a body
            // but it's not a real image. Without this check we'd try to decode HTML and waste
            // time before failing.
            if (code != 0 && (code < 200 || code >= 300)) {
                onData(nil);
            } else {
                onData(d);
            }
        }];
    } else {
        NSURL *u = [NSURL URLWithString:finalURL];
        if (!u) { onData(nil); return; }
        NSURLRequest *req = [NSURLRequest requestWithURL:u
                                             cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                         timeoutInterval:timeout];
        [NSURLConnection sendAsynchronousRequest:req
                                           queue:self.downloadQueue
                               completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
            onData(d);
        }];
    }
}

- (void)fireWaiters:(NSString *)key withImage:(UIImage *)img {
    NSArray *waiters = nil;
    @synchronized (self.pending) {
        waiters = self.pending[key];
        [self.pending removeObjectForKey:key];
    }
    for (void (^cb)(UIImage *) in waiters) {
        dispatch_async(dispatch_get_main_queue(), ^{ cb(img); });
    }
}

- (UIImage *)decodeAndResize:(NSData *)data targetSize:(CGSize)targetSize {
    UIImage *src = [UIImage imageWithData:data];
    if (!src) return nil;

    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize px = CGSizeMake(targetSize.width * scale, targetSize.height * scale);
    CGFloat radius = targetSize.width * 0.21 * scale;  // iOS app icon corner radius ratio

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)px.width, (size_t)px.height,
                                              8, (size_t)px.width * 4, colorSpace,
                                              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { CGColorSpaceRelease(colorSpace); return nil; }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);

    // Pre-round the icon by clipping the bitmap context to a rounded rect path.
    // Result: UIImage has rounded corners baked into pixels → no CALayer cornerRadius
    // needed at display time → no offscreen rendering → smooth scrolling on iPad 1/4.
    CGRect rect = CGRectMake(0, 0, px.width, px.height);
    UIBezierPath *roundPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGContextAddPath(ctx, roundPath.CGPath);
    CGContextClip(ctx);

    CGContextDrawImage(ctx, rect, src.CGImage);
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    UIImage *out = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);
    return out;
}

- (void)suspend {
    self.suspended = YES;
    self.downloadQueue.suspended = YES;
}

- (void)resume {
    self.suspended = NO;
    self.downloadQueue.suspended = NO;
}

- (void)clearCache {
    [self.cache removeAllObjects];
    @synchronized (self.failedAt) {
        [self.failedAt removeAllObjects];
    }
}

@end

#import "UpdateChecker.h"
#import "HTTPSClient.h"

NSString *const UpdateCheckerStatusChangedNotification =
    @"UpdateCheckerStatusChangedNotification";

// GitHub's "latest release" endpoint — returns the most recent non-prerelease
// for the repo. Unauthenticated requests are 60/hr per IP, plenty for our use.
static NSString *const kReleasesAPIURL =
    @"https://api.github.com/repos/AdrienRL1/AppDrop/releases/latest";

// How fresh the cached result has to be for `force=NO` checks to skip the
// network. Settings re-opens within this window won't re-hit the API.
static const NSTimeInterval kCacheTTL = 3600;  // 1 hour

@interface UpdateChecker ()
@property (nonatomic, assign, readwrite) UpdateCheckerStatus status;
@property (nonatomic, copy,   readwrite) NSString *latestVersion;
@property (nonatomic, copy,   readwrite) NSDate   *latestReleaseDate;
@property (nonatomic, copy,   readwrite) NSString *latestIpaURL;
@property (nonatomic, copy,   readwrite) NSString *latestReleaseNotes;
@property (nonatomic, copy,   readwrite) NSString *errorMessage;
@property (nonatomic, copy,   readwrite) NSDate   *lastCheckedAt;
@property (nonatomic, assign) BOOL isChecking;
@end

@implementation UpdateChecker

+ (instancetype)shared {
    static UpdateChecker *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[UpdateChecker alloc] init]; });
    return s;
}

#pragma mark - Installed version (cached, never changes at runtime)

- (NSString *)currentVersion {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
}

- (NSInteger)currentBuild {
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    return v.integerValue;
}

#pragma mark - Public check entry point

- (void)checkForUpdates:(BOOL)force {
    if (self.isChecking) return;  // already in flight
    if (!force && self.lastCheckedAt
        && -[self.lastCheckedAt timeIntervalSinceNow] < kCacheTTL) {
        // Cached result still fresh — no-op. (Caller will see the existing
        // status / version / date properties unchanged.)
        return;
    }

    self.isChecking = YES;
    self.status = UpdateCheckerStatusChecking;
    [self postChanged];

    [HTTPSClient getURL:kReleasesAPIURL
                timeout:15
             completion:^(NSData *body, NSInteger statusCode, NSError *err) {
        [self handleResponseWithBody:body statusCode:statusCode error:err];
    }];
}

- (void)handleResponseWithBody:(NSData *)body
                    statusCode:(NSInteger)statusCode
                         error:(NSError *)err {
    self.isChecking = NO;
    self.lastCheckedAt = [NSDate date];

    if (err || !body.length || statusCode < 200 || statusCode >= 300) {
        self.status = UpdateCheckerStatusError;
        self.errorMessage = err.localizedDescription
            ?: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode];
        [self postChanged];
        return;
    }

    NSError *jsonErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonErr];
    if (jsonErr || ![parsed isKindOfClass:[NSDictionary class]]) {
        self.status = UpdateCheckerStatusError;
        self.errorMessage = jsonErr.localizedDescription ?: @"Invalid JSON";
        [self postChanged];
        return;
    }
    NSDictionary *json = parsed;

    NSString *tag = json[@"tag_name"];
    if (![tag isKindOfClass:[NSString class]] || !tag.length) {
        self.status = UpdateCheckerStatusError;
        self.errorMessage = @"No tag_name in response";
        [self postChanged];
        return;
    }

    // Tag is "v1.2" — strip the leading "v" for comparison + display.
    NSString *latest = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
    self.latestVersion = latest;

    // ISO 8601 "2026-05-27T18:07:54Z" → NSDate.
    NSString *publishedStr = json[@"published_at"];
    if ([publishedStr isKindOfClass:[NSString class]]) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        // Force POSIX locale so the ISO parser isn't tripped by e.g. Arabic numerals.
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        self.latestReleaseDate = [fmt dateFromString:publishedStr];
    }

    // Release notes — the markdown body of the GitHub release. May be nil/empty
    // on very old releases that had no description. (Use a distinct variable
    // name to avoid shadowing `body` from the HTTP response NSData *.)
    NSString *notesBody = json[@"body"];
    self.latestReleaseNotes = [notesBody isKindOfClass:[NSString class]] ? notesBody : @"";

    // Pick the first .ipa asset. v1.0+ releases ship a single AppDrop-vX.Y.ipa.
    NSArray *assets = json[@"assets"];
    if ([assets isKindOfClass:[NSArray class]]) {
        for (NSDictionary *a in assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = a[@"name"];
            NSString *url  = a[@"browser_download_url"];
            if ([name isKindOfClass:[NSString class]]
                && [url isKindOfClass:[NSString class]]
                && [name.lowercaseString hasSuffix:@".ipa"]) {
                self.latestIpaURL = url;
                break;
            }
        }
    }

    // Compare versions. Anything > current → update available.
    NSComparisonResult cmp = [UpdateChecker compareVersion:latest
                                              withVersion:[self currentVersion]];
    self.status = (cmp == NSOrderedDescending)
        ? UpdateCheckerStatusAvailable
        : UpdateCheckerStatusUpToDate;
    self.errorMessage = nil;
    [self postChanged];
}

#pragma mark - Version comparison

// Numeric component-wise comparison. "1.10" > "1.2" (not lexicographic).
// Missing components are treated as 0 so "1.2" == "1.2.0".
+ (NSComparisonResult)compareVersion:(NSString *)a withVersion:(NSString *)b {
    if (!a.length && !b.length) return NSOrderedSame;
    if (!a.length) return NSOrderedAscending;
    if (!b.length) return NSOrderedDescending;
    NSArray *aParts = [a componentsSeparatedByString:@"."];
    NSArray *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger maxParts = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < maxParts; i++) {
        NSInteger aVal = (i < aParts.count) ? [aParts[i] integerValue] : 0;
        NSInteger bVal = (i < bParts.count) ? [bParts[i] integerValue] : 0;
        if (aVal < bVal) return NSOrderedAscending;
        if (aVal > bVal) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark - Notification

- (void)postChanged {
    if ([NSThread isMainThread]) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UpdateCheckerStatusChangedNotification
                          object:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UpdateCheckerStatusChangedNotification
                              object:self];
        });
    }
}

@end

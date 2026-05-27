#import <Foundation/Foundation.h>

// Posted on the main queue whenever any of (status / latestVersion /
// latestReleaseDate / errorMessage / lastCheckedAt) changes. Settings VC
// listens to this to refresh its Updates section.
extern NSString *const UpdateCheckerStatusChangedNotification;

typedef NS_ENUM(NSInteger, UpdateCheckerStatus) {
    UpdateCheckerStatusUnknown   = 0,  // Never checked, or no data yet
    UpdateCheckerStatusChecking,       // Network call in flight
    UpdateCheckerStatusUpToDate,       // Latest release matches CFBundleShortVersionString
    UpdateCheckerStatusAvailable,      // Latest release > installed version
    UpdateCheckerStatusError,          // Network / parsing failure
};

// Polls the GitHub Releases API for the latest AppDrop version. Singleton so
// the network call is shared across Settings visits and not duplicated.
// All network I/O happens on a background queue (HTTPSClient handles that);
// completion fires on main, then UpdateCheckerStatusChangedNotification posts.
@interface UpdateChecker : NSObject

+ (instancetype)shared;

// Latest known state. Read on main thread only (or accept the staleness).
@property (nonatomic, assign, readonly) UpdateCheckerStatus status;
@property (nonatomic, copy,   readonly) NSString *latestVersion;       // e.g. "1.2"
@property (nonatomic, copy,   readonly) NSDate   *latestReleaseDate;
@property (nonatomic, copy,   readonly) NSString *latestIpaURL;        // browser_download_url of the .ipa asset
@property (nonatomic, copy,   readonly) NSString *errorMessage;
@property (nonatomic, copy,   readonly) NSDate   *lastCheckedAt;

// Convenience accessors for the *installed* version (read from Info.plist
// at first call; the values are constant for the lifetime of the process).
- (NSString *)currentVersion;   // CFBundleShortVersionString — "1.2"
- (NSInteger)currentBuild;      // CFBundleVersion — 13

// Kick off a check. If `force` is NO and we have a cached result younger
// than 1 hour, this is a no-op (we don't want to spam api.github.com — its
// unauthenticated rate limit is 60 requests/hr per IP). If `force` is YES
// the cache is ignored.
- (void)checkForUpdates:(BOOL)force;

@end

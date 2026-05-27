#import <Foundation/Foundation.h>

extern NSString *const InstallManagerJobsChangedNotification;

@interface InstallJob : NSObject
@property (nonatomic, copy) NSString *jobId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *state;     // queued, downloading, installing, completed, failed, cancelled
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) NSInteger progress;
@property (nonatomic, strong) NSDate *startedAt;
// For ETA: track byte progress
@property (nonatomic, assign) long long lastBytes;
@property (nonatomic, strong) NSDate *lastBytesAt;
@property (nonatomic, assign) double bytesPerSec;   // computed
@property (nonatomic, assign) long long totalBytes; // parsed from message if available
@property (nonatomic, assign) long long currentBytes;
// Cancellation: written from main thread, polled by the background download loop.
// Atomic for memory ordering (BOOL writes are word-aligned so already atomic on ARMv7,
// but the keyword documents intent and adds a barrier).
@property (atomic, assign) BOOL cancelRequested;
@end

@interface InstallManager : NSObject

+ (instancetype)shared;
- (void)setBackendURL:(NSString *)backendURL;
- (NSString *)backendURL;
@property (nonatomic, assign) BOOL autonomousMode;  // YES = local download via mbedTLS + ipainstaller
- (NSArray *)jobs;
- (void)startInstallWithURL:(NSString *)url
                 completion:(void (^)(NSString *jobId, NSError *error))completion;
- (void)removeJob:(NSString *)jobId;
- (void)clearCompletedJobs;

// Cancel a single job. Idempotent. No-op if the job is already terminal (completed/failed/cancelled).
- (void)cancelJob:(NSString *)jobId;

// Cancel every job that's still active (queued/downloading/installing).
// Returns the number of jobs that were actually cancelled.
- (NSInteger)cancelAllActiveJobs;

// Convenience: YES if at least one job is in a non-terminal state.
- (BOOL)hasActiveJobs;

// v2.0.27: dedup helper. Returns YES if there's a job for this URL currently in
// queued/downloading/installing state. Caller uses this to skip re-launching
// installs the user fat-fingered on the install button.
- (BOOL)hasActiveJobForURL:(NSString *)url;

@end

#import "InstallManager.h"
#import "HTTPSClient.h"
#import "ParallelDownloader.h"
#import "Localization.h"
#import "MachOInspector.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

NSString *const InstallManagerJobsChangedNotification = @"InstallManagerJobsChangedNotification";
// Legacy keys kept so old preference values are silently ignored (no migration needed):
// IPAInstall.BackendURL, IPAInstall.AutonomousMode — both unused since v1.5.3.

@implementation InstallJob
@end

@interface InstallManager ()
@property (nonatomic, strong) NSMutableDictionary *jobsById;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy) NSString *cachedBackendURL;
- (void)attemptDownloadForJob:(InstallJob *)job
                    localPath:(NSString *)localPath
                      attempt:(int)attempt;
@end

@implementation InstallManager

+ (instancetype)shared {
    static InstallManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[InstallManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobsById = [[NSMutableDictionary alloc] init];
        [self loadJobsFromDisk];
        [self sweepOrphanTempFiles];        // v2.0.28
        [self sweepDocumentsAppDropFolder]; // v1.2: cap saved-for-Filza .ipas
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(pollAllActiveJobs)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(saveJobsToDisk)
                                                      name:UIApplicationDidEnterBackgroundNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(saveJobsToDisk)
                                                      name:UIApplicationWillTerminateNotification
                                                    object:nil];
    }
    return self;
}

// Defensive cleanup on app launch. The happy paths (cancel, error, success) all
// call removeItemAtPath: when the download/install loop finishes. But if the app
// crashes mid-download (v2.0.25/26 hit this), the partial `_inst_<jobid>.ipa` file
// is left behind in NSTemporaryDirectory. Over time this can fill the sandbox.
//
// Each app reinstall via ipainstaller gets a new sandbox UUID, so this isn't a long-term
// hoarder — but better safe than sorry, and it gives us a clean baseline every launch.
// Documents/AppDrop/ collects .ipa files that couldn't be auto-installed (iOS 10+
// where ipainstaller is broken). Cap the directory at 14-day age + 500 MB total
// so a user who downloads dozens of apps doesn't slowly fill up their device.
//   Pass 1: delete anything older than 14 days
//   Pass 2: if still over 500 MB, delete oldest-first until under cap
- (void)sweepDocumentsAppDropFolder {
    NSString *docsRoot = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docsRoot stringByAppendingPathComponent:@"AppDrop"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!names.count) return;

    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-14 * 24 * 3600];
    const long long kSizeCap = 500LL * 1024 * 1024;

    NSMutableArray *items = [NSMutableArray array];
    long long totalSize = 0;
    for (NSString *name in names) {
        if (![name.lowercaseString hasSuffix:@".ipa"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        long long size = [attrs[NSFileSize] longLongValue];
        if (!mtime) continue;
        [items addObject:@{ @"path": path, @"mtime": mtime, @"size": @(size) }];
        totalSize += size;
    }

    // Pass 1: age-based
    NSMutableArray *remaining = [NSMutableArray array];
    NSInteger ageDeleted = 0;
    long long ageBytes = 0;
    for (NSDictionary *it in items) {
        if ([it[@"mtime"] compare:cutoff] == NSOrderedAscending) {
            if ([fm removeItemAtPath:it[@"path"] error:nil]) {
                ageDeleted++;
                ageBytes += [it[@"size"] longLongValue];
                totalSize -= [it[@"size"] longLongValue];
            }
        } else {
            [remaining addObject:it];
        }
    }

    // Pass 2: cap-based (oldest first)
    NSArray *sorted = [remaining sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"mtime"] compare:b[@"mtime"]];
    }];
    NSInteger capDeleted = 0;
    long long capBytes = 0;
    for (NSDictionary *it in sorted) {
        if (totalSize <= kSizeCap) break;
        if ([fm removeItemAtPath:it[@"path"] error:nil]) {
            long long s = [it[@"size"] longLongValue];
            totalSize -= s;
            capDeleted++;
            capBytes += s;
        }
    }

    if (ageDeleted + capDeleted > 0) {
        NSLog(@"[InstallManager] Documents/AppDrop sweep: %ld old (%.1f MB) + %ld over-cap (%.1f MB)",
              (long)ageDeleted, ageBytes / 1048576.0,
              (long)capDeleted, capBytes / 1048576.0);
    }
}

- (void)sweepOrphanTempFiles {
    NSString *tmpDir = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
    NSInteger n = 0;
    long long bytes = 0;
    for (NSString *name in entries) {
        if (![name hasPrefix:@"_inst_"]) continue;
        // Match both `_inst_<uuid>.ipa` (legacy + final files) and the
        // `.partN` sidecars created by ParallelDownloader (build 9). Both
        // come from a previous crashed/interrupted install and are unsafe
        // to keep across launches — they belong to job UUIDs we no longer
        // know about and a new install will allocate a fresh UUID anyway.
        BOOL isIPA = [name hasSuffix:@".ipa"];
        BOOL isPart = ([name rangeOfString:@".ipa.part"].location != NSNotFound);
        BOOL isProbe = [name hasPrefix:@"_probe_"];  // shouldn't be _inst_ but defensive
        if (!isIPA && !isPart && !isProbe) continue;
        NSString *path = [tmpDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        bytes += [attrs[NSFileSize] longLongValue];
        if ([fm removeItemAtPath:path error:nil]) n++;
    }
    if (n > 0) {
        NSLog(@"[InstallManager] swept %ld orphan _inst_*.{ipa,partN} files (%.1f MB total)",
              (long)n, bytes / 1048576.0);
    }
}

// Delete every chunk sidecar (<localPath>.part0, .part1, …) associated with
// `localPath`. Called from terminal failure / user-cancel paths so partial
// chunks don't pile up in /tmp between abandoned downloads.
- (void)deleteChunkSidecarsFor:(NSString *)localPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [localPath stringByDeletingLastPathComponent];
    NSString *base = [localPath lastPathComponent];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *prefix = [base stringByAppendingString:@".part"];
    for (NSString *name in entries) {
        if ([name hasPrefix:prefix]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    }
}

- (NSString *)jobsCachePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"jobs.plist"];
}

- (void)loadJobsFromDisk {
    NSArray *arr = [NSArray arrayWithContentsOfFile:[self jobsCachePath]];
    if (![arr isKindOfClass:[NSArray class]]) return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-24*3600]; // expire 24h
    for (NSDictionary *d in arr) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSDate *started = d[@"startedAt"];
        if ([started isKindOfClass:[NSDate class]] && [started compare:cutoff] == NSOrderedAscending) continue;
        InstallJob *j = [[InstallJob alloc] init];
        j.jobId = d[@"jobId"];
        j.name = d[@"name"];
        j.url = d[@"url"];
        j.state = d[@"state"];
        j.message = d[@"message"];
        j.progress = [d[@"progress"] integerValue];
        j.startedAt = started ?: [NSDate date];
        if (j.jobId) _jobsById[j.jobId] = j;
    }
}

- (void)saveJobsToDisk {
    NSMutableArray *arr = [NSMutableArray array];
    for (InstallJob *j in [_jobsById allValues]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"jobId"] = j.jobId ?: @"";
        d[@"name"] = j.name ?: @"";
        d[@"url"] = j.url ?: @"";
        d[@"state"] = j.state ?: @"unknown";
        d[@"message"] = j.message ?: @"";
        d[@"progress"] = @(j.progress);
        d[@"startedAt"] = j.startedAt ?: [NSDate date];
        [arr addObject:d];
    }
    [arr writeToFile:[self jobsCachePath] atomically:YES];
}

// Backend / autonomousMode are now legacy no-ops — the app is fully autonomous.
// All catalog / install / LLM / TTS calls go direct to GitHub Pages, archive.org, Groq, DeepSeek
// and translate.google.com. No backend at all.
- (NSString *)backendURL {
    return @"";  // Empty → any `[backend stringByAppendingString:...]` produces a path-only URL
                 // that NSURL rejects. Code paths that branch on autonomousMode never hit these.
}

- (void)setBackendURL:(NSString *)backendURL { /* no-op, kept for binary compat */ }

- (BOOL)autonomousMode {
    return YES;  // Hard-coded ON. The app no longer supports a backend.
}

- (void)setAutonomousMode:(BOOL)autonomousMode { /* no-op */ }

- (NSArray *)jobs {
    NSArray *all = [_jobsById allValues];
    return [all sortedArrayUsingComparator:^NSComparisonResult(InstallJob *a, InstallJob *b) {
        return [b.startedAt compare:a.startedAt];
    }];
}

- (NSString *)shortNameFromURL:(NSString *)url {
    NSString *path = [[NSURL URLWithString:url] path];
    NSString *last = [path lastPathComponent];
    NSString *decoded = [last stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return decoded ?: (last ?: url);
}

- (void)startInstallWithURL:(NSString *)url
                 completion:(void (^)(NSString *, NSError *))completion {
    if (self.autonomousMode) {
        [self startAutonomousInstallWithURL:url completion:completion];
        return;
    }
    NSString *endpoint = [[self backendURL] stringByAppendingString:@"/install"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"url": url};
    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) {
        if (completion) completion(nil, jsonErr);
        return;
    }
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:30];

    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        if (err) { if (completion) completion(nil, err); return; }
        NSError *parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr) { if (completion) completion(nil, parseErr); return; }
        NSString *jobId = json[@"jobId"];
        if (!jobId) {
            NSString *msg = json[@"error"] ?: @"unknown error";
            NSError *e = [NSError errorWithDomain:@"IPAInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
            if (completion) completion(nil, e);
            return;
        }
        InstallJob *job = [[InstallJob alloc] init];
        job.jobId = jobId;
        job.url = url;
        job.name = [self shortNameFromURL:url];
        job.state = @"queued";
        job.message = T(@"install.state.queued");
        job.progress = 0;
        job.startedAt = [NSDate date];
        self.jobsById[jobId] = job;
        [self postChanged];
        if (completion) completion(jobId, nil);
    }];
}

#pragma mark - Autonomous install (HTTPSClient + posix_spawn ipainstaller)

- (void)startAutonomousInstallWithURL:(NSString *)url
                            completion:(void (^)(NSString *, NSError *))completion {
    NSString *jobId = [NSString stringWithFormat:@"local-%@",
                         [[NSUUID UUID] UUIDString] ?: [NSString stringWithFormat:@"%lu", (unsigned long)[NSDate date].timeIntervalSince1970]];

    InstallJob *job = [[InstallJob alloc] init];
    job.jobId = jobId;
    job.url = url;
    job.name = [self shortNameFromURL:url];
    job.state = @"queued";
    job.message = T(@"install.state.preparing");
    job.progress = 0;
    job.startedAt = [NSDate date];
    self.jobsById[jobId] = job;
    [self postChanged];

    if (completion) completion(jobId, nil);

    // Run download + install on background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runAutonomousJob:job];
    });
}

// Save a downloaded .ipa into our app's Documents folder so the user can
// recover it (open in Filza/iFile) when auto-install can't run. Used in two
// cases: (1) iOS 10+ where ipainstaller is broken, (2) install failure on
// any iOS so the .ipa isn't lost. Returns the absolute destination path, or
// nil on copy failure.
+ (NSString *)saveIPAToDocuments:(NSString *)sourcePath originalURL:(NSString *)url {
    NSString *docsRoot = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *destDir = [docsRoot stringByAppendingPathComponent:@"AppDrop"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES
                    attributes:nil error:nil];
    // v1.3 fix: [NSURL URLWithString:url] returns nil for URLs with unencoded
    // spaces (very common on archive.org: "iOS 5/App With Spaces.ipa"), which
    // collapsed every such file to "app.ipa" and overwrote previous downloads.
    // Use NSString's lastPathComponent (a path-style split on '/', does not
    // validate the URL) then percent-decode whatever escapes are in there.
    NSString *lastComp = [url lastPathComponent];
    NSString *decoded = [lastComp stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSString *filename = decoded.length ? decoded : (lastComp.length ? lastComp : @"app.ipa");
    NSString *destPath = [destDir stringByAppendingPathComponent:filename];
    // If a previous copy exists with same name, remove it before moving the new one.
    [fm removeItemAtPath:destPath error:nil];
    NSError *moveErr = nil;
    if (![fm moveItemAtPath:sourcePath toPath:destPath error:&moveErr]) {
        // Move failed (e.g. cross-volume) — try copy as fallback.
        if (![fm copyItemAtPath:sourcePath toPath:destPath error:&moveErr]) {
            NSLog(@"[InstallManager] saveIPAToDocuments failed: %@", moveErr);
            return nil;
        }
        [fm removeItemAtPath:sourcePath error:nil];
    }
    return destPath;
}

// Major iOS version on the running device (e.g. 6 for iOS 6.1.3, 10 for 10.3.4).
// Used to skip ipainstaller on iOS 10+ where it's broken.
+ (NSInteger)iosMajorVersion {
    NSString *v = [[UIDevice currentDevice] systemVersion];
    NSString *firstPart = [[v componentsSeparatedByString:@"."] firstObject];
    return [firstPart integerValue];
}

- (void)runAutonomousJob:(InstallJob *)job {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *localPath = [tmpDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"_inst_%@.ipa",
                             [job.jobId substringFromIndex:6]]];

    // Phase 1: download with progress + slow-mirror retry.
    dispatch_async(dispatch_get_main_queue(), ^{
        job.state = @"downloading";
        job.message = T(@"install.state.connecting");
        job.progress = 0;
        [self postChanged];
    });

    [self attemptDownloadForJob:job localPath:localPath attempt:0];
}

// One download attempt against archive.org. On slow-mirror abort, recursively retries
// (up to kMaxMirrorAttempts total). HTTPSClient preserves the partial .ipa between
// attempts and sends Range: bytes=N- so we resume rather than restart — the retry's
// real benefit is that archive.org's load-balancer typically routes the new TCP
// connection to a different CDN node, hopefully a faster one.
- (void)attemptDownloadForJob:(InstallJob *)job
                    localPath:(NSString *)localPath
                      attempt:(int)attempt {
    // 3 attempts total: original + 2 retries. Each retry is ~30s+ apart (the time it
    // takes to detect the stall), so worst case the user waits ~90s before we give up.
    static const int kMaxMirrorAttempts = 3;
    static const double kSlowThresholdBytesPerSec = 100.0 * 1024.0;  // 100 KB/s
    static const NSTimeInterval kSlowCheckWindow = 30.0;             // observe over 30s

    __block long long lastReceived = 0;
    __block NSDate *lastTick = [NSDate date];
    // Slow-mirror detection state. We sample the byte counter every kSlowCheckWindow
    // seconds; if avg throughput in that window is under the threshold AND we have
    // retry budget, we trip slowAbort which the isCancelled block returns YES for.
    __block NSDate *windowStart = [NSDate date];
    __block long long windowStartBytes = 0;
    __block BOOL slowAbort = NO;

    // Stream count from Settings (default 4). 1 disables parallelism and
    // ParallelDownloader transparently falls back to the legacy single-stream
    // path. Anything else triggers probe → chunk split → concurrent downloads.
    NSInteger streams = [[NSUserDefaults standardUserDefaults] integerForKey:@"IPAInstall.ParallelStreams"];
    if (streams <= 0) streams = 4;
    if (streams > 8) streams = 8;

    __weak InstallJob *weakJob = job;
    [ParallelDownloader downloadURL:job.url
                              toFile:localPath
                         streamCount:streams
                         isCancelled:^BOOL{
        InstallJob *j = weakJob;
        if (!j || j.cancelRequested) return YES;
        // Only consider slow-mirror abort if we still have retry budget — otherwise
        // there's no point dropping the connection.
        if (attempt < kMaxMirrorAttempts - 1) {
            NSTimeInterval elapsed = -[windowStart timeIntervalSinceNow];
            if (elapsed >= kSlowCheckWindow) {
                long long delta = lastReceived - windowStartBytes;
                double bps = elapsed > 0 ? delta / elapsed : 0;
                if (bps < kSlowThresholdBytesPerSec) {
                    NSLog(@"[InstallManager] Mirror slow (%.1f KB/s avg over %.0fs) — abort to retry (attempt %d/%d)",
                          bps / 1024.0, elapsed, attempt + 1, kMaxMirrorAttempts);
                    slowAbort = YES;
                    return YES;
                }
                // Healthy speed — reset the window and keep going.
                windowStart = [NSDate date];
                windowStartBytes = lastReceived;
            }
        }
        return NO;
    }
                     progress:^(long long received, long long total) {
        NSDate *now = [NSDate date];
        NSTimeInterval dt = [now timeIntervalSinceDate:lastTick];
        double bps = dt > 0 ? (received - lastReceived) / dt : 0;
        lastReceived = received;
        lastTick = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            InstallJob *j = weakJob;
            if (!j) return;
            j.currentBytes = received;
            j.totalBytes = total;
            if (bps > 0) j.bytesPerSec = j.bytesPerSec * 0.5 + bps * 0.5;
            NSInteger pct = total > 0 ? (NSInteger)(received * 100 / total) : 0;
            j.progress = pct;
            j.message = total > 0
                ? [NSString stringWithFormat:T(@"install.state.downloading_full"),
                     received/1048576.0, total/1048576.0, (long)pct]
                : [NSString stringWithFormat:T(@"install.state.downloading_partial"),
                     received/1048576.0];
            [self postChanged];
        });
    }
                   completion:^(BOOL ok, NSInteger status, NSError *err) {
        if (!ok) {
            // Slow-mirror retry: don't surface the failure, just kick off a new attempt.
            // The partial .ipa stays on disk; HTTPSClient will send Range: bytes=N-.
            if (slowAbort && !job.cancelRequested && attempt < kMaxMirrorAttempts - 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    InstallJob *j = weakJob;
                    if (!j || j.cancelRequested) return;
                    j.message = [NSString stringWithFormat:T(@"install.state.retrying_mirror"),
                                   attempt + 2, kMaxMirrorAttempts];
                    [self postChanged];
                });
                // Tiny delay before the retry so the progress message is visible and so
                // we don't hammer archive.org if something is very wrong server-side.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self attemptDownloadForJob:job localPath:localPath attempt:attempt + 1];
                });
                return;
            }
            BOOL wasCancelled = job.cancelRequested || err.code == 99;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (wasCancelled) {
                    job.state = @"cancelled";
                    job.message = T(@"install.state.cancelled_user");
                } else {
                    job.state = @"failed";
                    NSString *humanReason;
                    if (status == 404) {
                        humanReason = T(@"install.error.404");
                    } else if (status == 403) {
                        humanReason = T(@"install.error.403");
                    } else if (status == 503 || status == 502 || status == 504) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.5xx_archive"), (long)status];
                    } else if (status >= 500) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.5xx_generic"), (long)status];
                    } else if (status > 0) {
                        humanReason = [NSString stringWithFormat:T(@"install.error.http_generic"), (long)status];
                    } else {
                        humanReason = err.localizedDescription ?: T(@"install.error.network");
                    }
                    job.message = [NSString stringWithFormat:T(@"install.error.failed_prefix"), humanReason];
                }
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                [self deleteChunkSidecarsFor:localPath];
            });
            return;
        }
        // Last-chance cancellation check: download finished but user clicked Annuler in
        // the brief moment between download-done and install-spawn.
        if (job.cancelRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                job.state = @"cancelled";
                job.message = T(@"install.state.cancelled_user");
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                [self deleteChunkSidecarsFor:localPath];
            });
            return;
        }

        // FairPlay encryption check (v1.2 build 8).
        // archive.org hosts a mix of cracked .ipas (cryptid=0, runs on any
        // jailbreak) and raw iTunes-purchase dumps that someone forgot to
        // crack (cryptid=1, only runs on the original buyer's Apple ID).
        // Calling ipainstaller on the latter wastes time and slot — the
        // app either silently refuses to launch or crashes on dyld load.
        // We peek the Mach-O header here, before any iOS-version branching,
        // and fail-fast with a clear message so the user can try another
        // mirror. Inspector returns Unknown on any parse / read error,
        // which we treat as "proceed" (false-negative ≪ false-positive).
        MachOInspectionResult enc = [MachOInspector inspectIPA:localPath];
        if (enc == MachOInspectionResultEncrypted) {
            NSLog(@"[InstallManager] FairPlay-encrypted .ipa detected: %@", job.url);
            dispatch_async(dispatch_get_main_queue(), ^{
                job.state = @"failed";
                job.message = T(@"install.error.fairplay");
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
            });
            return;
        }

        // iOS 10+ branch: ipainstaller is broken on iOS 10 (silent failures with
        // "Installed successfully" stdout but no actual app appearing on the home
        // screen). Skip it entirely and save the .ipa to our Documents folder so
        // the user can install it manually via Filza or iFile.
        if ([InstallManager iosMajorVersion] >= 10) {
            NSString *saved = [InstallManager saveIPAToDocuments:localPath
                                                       originalURL:job.url];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (saved) {
                    job.state = @"completed";  // really "saved" but using completed for UI parity
                    job.progress = 100;
                    job.message = [NSString stringWithFormat:T(@"install.modern_ios_msg"), saved];
                } else {
                    job.state = @"failed";
                    job.message = [NSString stringWithFormat:T(@"install.error.failed_prefix"),
                                     @"Could not save .ipa to Documents"];
                }
                [self postChanged];
            });
            return;
        }

        // Phase 2: invoke ipainstaller via posix_spawn
        dispatch_async(dispatch_get_main_queue(), ^{
            job.state = @"installing";
            job.progress = 100;
            job.message = T(@"install.state.installing");
            [self postChanged];
        });
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *out = nil;
            int exitCode = [self runIpainstallerOnFile:localPath capturedOutput:&out];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL success = (exitCode == 0) || (out && [out.lowercaseString rangeOfString:@"successfully"].location != NSNotFound);
                if (success) {
                    job.state = @"completed";
                    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:
                        @"Installed (.+?) successfully" options:0 error:nil];
                    NSTextCheckingResult *m = r ? [r firstMatchInString:out
                                                                  options:0
                                                                    range:NSMakeRange(0, out.length)] : nil;
                    NSString *name = (m && m.numberOfRanges >= 2)
                        ? [out substringWithRange:[m rangeAtIndex:1]]
                        : @"app";
                    job.message = [NSString stringWithFormat:T(@"install.state.installed_prefix"), name];
                    // Success: delete the temp .ipa, we no longer need it.
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                } else {
                    // Install failure: delete the .ipa (user feedback v1.2 — they don't
                    // want failed-install .ipas accumulating in Documents/). Users on
                    // iOS 10+ get their .ipa saved automatically via the early-return
                    // branch above, so they're covered. iOS 6-9 users typically just
                    // need to retry, no point keeping garbage around.
                    job.state = @"failed";
                    job.message = [NSString stringWithFormat:T(@"install.error.install_failed"),
                                     exitCode,
                                     out.length > 300 ? [out substringFromIndex:out.length-300] : out];
                    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
                }
                [self postChanged];
            });
        });
    }];
}

// Run ipainstaller <path>, capture output, return exit code.
// Tries multiple known install paths in order. Returns -1 if no installer is found,
// in which case outOutput contains a user-friendly explanation.
- (int)runIpainstallerOnFile:(NSString *)path capturedOutput:(NSString **)outOutput {
    // Candidate installer paths, in priority order:
    //   - /usr/bin/ipainstaller        (legacy / iOS 5-9 jailbreaks: autopear's package)
    //   - /usr/bin/appinst             (newer alias used by some repos)
    //   - /var/jb/usr/bin/ipainstaller (rootless jailbreaks: Dopamine, palera1n)
    //   - /var/jb/usr/bin/appinst
    //   - /opt/procursus/bin/ipainstaller (Procursus bootstrap)
    static const char *kInstallerCandidates[] = {
        "/usr/bin/ipainstaller",
        "/usr/bin/appinst",
        "/var/jb/usr/bin/ipainstaller",
        "/var/jb/usr/bin/appinst",
        "/opt/procursus/bin/ipainstaller",
        NULL
    };
    const char *exec = NULL;
    for (int i = 0; kInstallerCandidates[i]; i++) {
        if (access(kInstallerCandidates[i], X_OK) == 0) {
            exec = kInstallerCandidates[i];
            break;
        }
    }
    if (!exec) {
        if (outOutput) {
            *outOutput = T(@"install.error.no_ipainstaller");
        }
        return -1;
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        if (outOutput) *outOutput = @"pipe() failed";
        return -1;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    posix_spawn_file_actions_addclose(&fa, pipefd[1]);

    const char *pathC = [path fileSystemRepresentation];
    // Pass the basename matching the chosen exec as argv[0] so the binary's own usage/log
    // messages stay coherent.
    const char *base = strrchr(exec, '/');
    char *const argv[] = { (char *)(base ? base + 1 : exec), (char *)pathC, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exec, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);

    if (rc != 0) {
        close(pipefd[0]);
        // posix_spawn returns the errno value directly (NOT via the global errno).
        if (outOutput) *outOutput = [NSString stringWithFormat:T(@"install.error.spawn_failed"),
                                         exec, strerror(rc)];
        return -1;
    }

    // Read output (up to ~10 KB; ipainstaller is concise)
    NSMutableData *buf = [NSMutableData data];
    char chunk[1024];
    while (1) {
        ssize_t n = read(pipefd[0], chunk, sizeof(chunk));
        if (n <= 0) break;
        [buf appendBytes:chunk length:n];
        if (buf.length > 30000) break;  // cap
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -2;

    if (outOutput) {
        *outOutput = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    }
    return exitCode;
}

- (void)pollAllActiveJobs {
    for (InstallJob *job in [self.jobsById allValues]) {
        if ([InstallManager isTerminalState:job.state]) continue;
        // Local autonomous jobs update themselves via callbacks — no backend to poll
        if ([job.jobId hasPrefix:@"local-"]) continue;
        [self pollJob:job.jobId];
    }
}

- (void)pollJob:(NSString *)jobId {
    NSString *endpoint = [NSString stringWithFormat:@"%@/install/status?id=%@",
                          [self backendURL], jobId];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:endpoint]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:10];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        InstallJob *job = self.jobsById[jobId];
        if (!job) return;
        // Detect HTTP error (e.g. 404 job not found = backend restart)
        NSInteger statusCode = 200;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)resp statusCode];
        }
        if (err || !data) {
            if (![job.state isEqualToString:@"completed"] &&
                ![job.state isEqualToString:@"failed"]) {
                job.state = @"failed";
                job.message = [NSString stringWithFormat:@"Reseau : %@",
                                 err.localizedDescription ?: @"timeout"];
                [self postChanged];
            }
            return;
        }
        if (statusCode == 404) {
            job.state = @"failed";
            job.message = @"Job perdu (backend redemarre?)";
            [self postChanged];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;
        NSString *state = json[@"status"] ?: json[@"state"];
        if (state) job.state = state;
        NSNumber *prog = json[@"progress"];
        if (prog) job.progress = [prog integerValue];
        NSString *msg = json[@"message"];
        if (msg) job.message = msg;

        // Parse bytes from messages like "Telechargement: 25.3 MB / 349.0 MB (7%)"
        if (msg.length) {
            NSError *re_err = nil;
            NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:
                @"([0-9.]+)\\s*MB\\s*/\\s*([0-9.]+)\\s*MB"
                options:0 error:&re_err];
            if (r) {
                NSTextCheckingResult *m = [r firstMatchInString:msg
                                                          options:0
                                                            range:NSMakeRange(0, msg.length)];
                if (m && m.numberOfRanges >= 3) {
                    NSString *curStr = [msg substringWithRange:[m rangeAtIndex:1]];
                    NSString *totStr = [msg substringWithRange:[m rangeAtIndex:2]];
                    long long cur = (long long)([curStr doubleValue] * 1024 * 1024);
                    long long tot = (long long)([totStr doubleValue] * 1024 * 1024);
                    job.totalBytes = tot;
                    // Compute speed
                    NSDate *now = [NSDate date];
                    if (job.lastBytesAt && cur > job.lastBytes) {
                        NSTimeInterval dt = [now timeIntervalSinceDate:job.lastBytesAt];
                        if (dt > 0.5) {
                            double bps = (double)(cur - job.lastBytes) / dt;
                            job.bytesPerSec = job.bytesPerSec > 0
                                ? (job.bytesPerSec * 0.6 + bps * 0.4)  // EMA
                                : bps;
                            job.lastBytes = cur;
                            job.lastBytesAt = now;
                        }
                    } else {
                        job.lastBytes = cur;
                        job.lastBytesAt = now;
                    }
                    job.currentBytes = cur;
                }
            }
        }
        [self postChanged];
    }];
}

- (void)removeJob:(NSString *)jobId {
    [self.jobsById removeObjectForKey:jobId];
    [self postChanged];
}

- (void)clearCompletedJobs {
    NSMutableArray *toRemove = [NSMutableArray array];
    for (InstallJob *j in [self.jobsById allValues]) {
        if ([j.state isEqualToString:@"completed"]
            || [j.state isEqualToString:@"failed"]
            || [j.state isEqualToString:@"cancelled"]) {
            [toRemove addObject:j.jobId];
        }
    }
    for (NSString *jid in toRemove) [self.jobsById removeObjectForKey:jid];
    [self postChanged];
}

// Job is terminal if no more work will happen against it.
+ (BOOL)isTerminalState:(NSString *)state {
    return [state isEqualToString:@"completed"]
        || [state isEqualToString:@"failed"]
        || [state isEqualToString:@"cancelled"];
}

- (void)cancelJob:(NSString *)jobId {
    InstallJob *job = self.jobsById[jobId];
    if (!job) return;
    if ([InstallManager isTerminalState:job.state]) return;
    job.cancelRequested = YES;
    // Reflect intent immediately in the UI; the actual download loop will exit on its
    // next iteration and we'll get the final state update from the completion block.
    // We still set state=cancelled here so the UI doesn't show "downloading..." while
    // we wait for the loop to notice. The completion block will overwrite with the
    // same value if it runs first.
    job.state = @"cancelled";
    job.message = T(@"install.state.cancelling");
    [self postChanged];
}

- (NSInteger)cancelAllActiveJobs {
    NSInteger count = 0;
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![InstallManager isTerminalState:j.state]) {
            j.cancelRequested = YES;
            j.state = @"cancelled";
            j.message = T(@"install.state.cancelling");
            count++;
        }
    }
    if (count > 0) [self postChanged];
    return count;
}

- (BOOL)hasActiveJobs {
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![InstallManager isTerminalState:j.state]) return YES;
    }
    return NO;
}

- (BOOL)hasActiveJobForURL:(NSString *)url {
    if (!url.length) return NO;
    for (InstallJob *j in [self.jobsById allValues]) {
        if (![j.url isEqualToString:url]) continue;
        if ([InstallManager isTerminalState:j.state]) continue;
        return YES;
    }
    return NO;
}

- (void)postChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:InstallManagerJobsChangedNotification
                                                        object:self];
}

@end

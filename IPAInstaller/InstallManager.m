#import "InstallManager.h"
#import "HTTPSClient.h"
#import "Localization.h"
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
        [self sweepOrphanTempFiles];   // v2.0.28
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
- (void)sweepOrphanTempFiles {
    NSString *tmpDir = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
    NSInteger n = 0;
    long long bytes = 0;
    for (NSString *name in entries) {
        if (![name hasPrefix:@"_inst_"] || ![name hasSuffix:@".ipa"]) continue;
        NSString *path = [tmpDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        bytes += [attrs[NSFileSize] longLongValue];
        if ([fm removeItemAtPath:path error:nil]) n++;
    }
    if (n > 0) {
        NSLog(@"[InstallManager] swept %ld orphan _inst_*.ipa files (%.1f MB total)",
              (long)n, bytes / 1048576.0);
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

- (void)runAutonomousJob:(InstallJob *)job {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *localPath = [tmpDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"_inst_%@.ipa",
                             [job.jobId substringFromIndex:6]]];

    // Phase 1: download with progress
    dispatch_async(dispatch_get_main_queue(), ^{
        job.state = @"downloading";
        job.message = T(@"install.state.connecting");
        job.progress = 0;
        [self postChanged];
    });

    __block long long lastReceived = 0;
    __block NSDate *lastTick = [NSDate date];

    // Cancellation: poll job.cancelRequested from the background download loop.
    // job is captured weakly through a __weak ref to avoid retain cycles if the user
    // wipes the jobs dictionary mid-download.
    __weak InstallJob *weakJob = job;
    [HTTPSClient downloadURL:job.url
                       toFile:localPath
                  isCancelled:^BOOL{
        InstallJob *j = weakJob;
        return j == nil || j.cancelRequested;
    }
                     progress:^(long long received, long long total) {
        NSDate *now = [NSDate date];
        NSTimeInterval dt = [now timeIntervalSinceDate:lastTick];
        double bps = dt > 0 ? (received - lastReceived) / dt : 0;
        lastReceived = received;
        lastTick = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            job.currentBytes = received;
            job.totalBytes = total;
            if (bps > 0) job.bytesPerSec = job.bytesPerSec * 0.5 + bps * 0.5;
            NSInteger pct = total > 0 ? (NSInteger)(received * 100 / total) : 0;
            job.progress = pct;
            job.message = total > 0
                ? [NSString stringWithFormat:T(@"install.state.downloading_full"),
                     received/1048576.0, total/1048576.0, (long)pct]
                : [NSString stringWithFormat:T(@"install.state.downloading_partial"),
                     received/1048576.0];
            [self postChanged];
        });
    }
                   completion:^(BOOL ok, NSInteger status, NSError *err) {
        if (!ok) {
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
                } else {
                    job.state = @"failed";
                    job.message = [NSString stringWithFormat:T(@"install.error.install_failed"),
                                     exitCode,
                                     out.length > 300 ? [out substringFromIndex:out.length-300] : out];
                }
                [self postChanged];
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
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

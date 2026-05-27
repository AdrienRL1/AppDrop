#import <Foundation/Foundation.h>

// Multi-stream download orchestrator.
//
// archive.org throttles per TCP connection rather than per IP, so a single
// stream often plateaus around 300 KB/s even on a fast network. Splitting the
// .ipa into N byte ranges and downloading them over N parallel connections
// typically yields 3-4× the effective throughput.
//
// Behaviour:
//   1. Probe the URL (Range: bytes=0-0) to learn the total file size and
//      verify the server supports byte ranges.
//   2. If probe fails OR Range unsupported OR streamCount <= 1 → fall back
//      to single-stream HTTPSClient.downloadURL: (no change from build 8).
//   3. Otherwise: split into N contiguous chunks, launch N concurrent
//      HTTPSClient.downloadChunk: calls writing to `<finalPath>.part<i>`,
//      aggregate progress across chunks (~3 times/sec), concatenate to
//      finalPath when all chunks succeed, delete the chunk temps.
//
// Resume: each chunk file persists between attempts. If the parallel download
// fails partway (slow-mirror retry, app crash, etc.), the next call resumes
// each chunk from the bytes already on disk via HTTPSClient's Range support.
//
// Cancellation: the caller's isCancelled block is propagated to every chunk.
// If any chunk errors permanently, the others are signaled to abort.
@interface ParallelDownloader : NSObject

+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)finalPath
         streamCount:(NSInteger)streamCount
         isCancelled:(BOOL (^)(void))isCancelled
            progress:(void (^)(long long received, long long total))progressBlock
          completion:(void (^)(BOOL success, NSInteger statusCode, NSError *err))completion;

@end

#import <Foundation/Foundation.h>

// On-device catalog: downloads ipa.json + urls.json from stuffed18.github.io
// (GitHub Pages public CDN — no private backend involved) once, caches locally, then
// provides search/filter without any backend round-trip.
// Memory: ~50 MB held in memory after parse. OK on iPad 4 (1 GB), tight on iPad 1 (256 MB).
@interface LocalCatalog : NSObject

+ (instancetype)shared;

// Returns YES if catalog data is loaded and ready for queries.
- (BOOL)isReady;

// Load the catalog (downloads from stuffed18.github.io if not cached, else loads from disk).
// Completion called on main queue. Idempotent — subsequent calls return immediately.
- (void)loadWithProgress:(void (^)(NSString *status))progressBlock
              completion:(void (^)(BOOL ok, NSError *err))completion;

// Filtered search. Returns NSArray of NSDictionary entries matching the same shape as backend.
// SYNCHRONOUS — call only from background queue, or use searchAsyncWithQuery:... below.
// `deviceClass`: nil/@"all" = no filter, @"iphone" = apps with iPhone support (plat & 2),
//                @"ipad" = apps with iPad support (plat & 4).
// `descending`: YES = ORDER BY ... DESC, NO = ASC.
- (NSDictionary *)searchWithQuery:(NSString *)q
                            minIOS:(NSString *)minIOSStr  // "5.0" etc., nil for none
                            maxIOS:(NSString *)maxIOSStr  // nil for none
                             unique:(BOOL)unique
                               sort:(NSString *)sortKey   // "recent"/"name"/"size"/"minos"
                        descending:(BOOL)descending
                       deviceClass:(NSString *)deviceClass
                             offset:(NSInteger)offset
                              limit:(NSInteger)limit;

// Async search — runs on background queue, calls completion on main.
- (void)searchAsyncWithQuery:(NSString *)q
                       minIOS:(NSString *)minIOSStr
                       maxIOS:(NSString *)maxIOSStr
                        unique:(BOOL)unique
                          sort:(NSString *)sortKey
                   descending:(BOOL)descending
                  deviceClass:(NSString *)deviceClass
                        offset:(NSInteger)offset
                         limit:(NSInteger)limit
                    completion:(void (^)(NSDictionary *result))completion;

// All entries for a given bundle id.
- (NSArray *)versionsForBundleId:(NSString *)bundleId;

@end

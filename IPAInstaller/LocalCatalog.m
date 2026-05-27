#import "LocalCatalog.h"
#import "Localization.h"
#import <sqlite3.h>

// SQLite-backed catalog: bundled catalog.db in the IPA contains:
//   - entries        (157k rows, all versions)
//   - entries_unique (~50k rows, latest version per bundle id)
//   - urls           (27k url base prefixes)
// All tables indexed on pk DESC, minos, title_lower, bid_lower for instant queries.
// Memory footprint: ~3-5 MB (SQLite's page cache), vs ~80 MB for the in-memory NSArray approach.
// Startup: ~10ms to open the db + first SELECT, vs 3-5s for NSPropertyListSerialization.

@interface LocalCatalog ()
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, strong) NSDictionary *urls;  // cached at open (only 27k entries, ~2 MB)
@property (nonatomic, assign) BOOL loaded;
@end

@implementation LocalCatalog {
    dispatch_queue_t _searchQueue;
    NSString *_dbPath;
}

+ (instancetype)shared {
    static LocalCatalog *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LocalCatalog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _searchQueue = dispatch_queue_create("LocalCatalog.search", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (BOOL)isReady { return self.loaded; }

// Helper: encode "5.0" → 50000, "6.1.3" → 60103 (matches Python build script).
- (NSInteger)encodeIOSVersion:(NSString *)v {
    if (!v.length) return -1;
    NSArray *parts = [v componentsSeparatedByString:@"."];
    NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 0;
    NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;
    NSInteger patch = parts.count > 2 ? [parts[2] integerValue] : 0;
    return major * 10000 + minor * 100 + patch;
}

- (NSString *)decodeIOSVersion:(NSInteger)n {
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)(n/10000), (long)((n/100)%100), (long)(n%100)];
}

#pragma mark - Load

- (void)loadWithProgress:(void (^)(NSString *))progressBlock
              completion:(void (^)(BOOL, NSError *))completion {
    if (self.loaded) {
        if (completion) completion(YES, nil);
        return;
    }
    dispatch_async(_searchQueue, ^{
        if (self.loaded) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(YES, nil); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock(T(@"catalog.loading"));
        });

        // Bundled DB lives in Resources/catalog.db — read-only, mmap-backed.
        NSString *bundledPath = [[NSBundle mainBundle] pathForResource:@"catalog" ofType:@"db"];
        if (!bundledPath) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO,
                    [NSError errorWithDomain:@"LocalCatalog" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"catalog.db introuvable dans le bundle"}]);
            });
            return;
        }
        _dbPath = [bundledPath copy];

        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2([_dbPath UTF8String], &db,
                                   SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                                   NULL);
        if (rc != SQLITE_OK) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO,
                    [NSError errorWithDomain:@"LocalCatalog" code:rc
                                    userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"sqlite3_open: %s",
                                                  sqlite3_errmsg(db)]}]);
            });
            if (db) sqlite3_close(db);
            return;
        }
        // mmap-backed reads for faster random access on large pages
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", NULL, NULL, NULL);  // 256 MB max mmap window
        sqlite3_exec(db, "PRAGMA cache_size = -8000", NULL, NULL, NULL);     // 8 MB page cache
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", NULL, NULL, NULL);

        // Pre-load all urls.
        NSMutableDictionary *urls = [NSMutableDictionary dictionaryWithCapacity:30000];
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT idx, url FROM urls", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                int idx = sqlite3_column_int(st, 0);
                const unsigned char *u = sqlite3_column_text(st, 1);
                if (!u) continue;
                NSString *urlStr = [NSString stringWithUTF8String:(const char *)u];
                if (!urlStr.length) continue;  // invalid UTF-8 or empty — skip the row
                urls[[NSString stringWithFormat:@"%d", idx]] = urlStr;
            }
        }
        sqlite3_finalize(st);

        // Count for status reporting
        long long entryCount = 0;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries_unique", -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) entryCount = sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);

        self.db = db;
        self.urls = urls;
        self.loaded = YES;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock([NSString stringWithFormat:@"Catalogue : %lld apps", entryCount]);
            if (completion) completion(YES, nil);
        });
    });
}

#pragma mark - Search

- (void)searchAsyncWithQuery:(NSString *)q
                       minIOS:(NSString *)minIOSStr
                       maxIOS:(NSString *)maxIOSStr
                        unique:(BOOL)unique
                          sort:(NSString *)sortKey
                   descending:(BOOL)descending
                  deviceClass:(NSString *)deviceClass
                        offset:(NSInteger)offset
                         limit:(NSInteger)limit
                    completion:(void (^)(NSDictionary *))completion {
    dispatch_async(_searchQueue, ^{
        NSDictionary *res = [self searchWithQuery:q minIOS:minIOSStr maxIOS:maxIOSStr
                                            unique:unique sort:sortKey
                                        descending:descending
                                       deviceClass:deviceClass
                                            offset:offset limit:limit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(res);
        });
    });
}

- (NSDictionary *)searchWithQuery:(NSString *)q
                            minIOS:(NSString *)minIOSStr
                            maxIOS:(NSString *)maxIOSStr
                             unique:(BOOL)unique
                               sort:(NSString *)sortKey
                        descending:(BOOL)descending
                       deviceClass:(NSString *)deviceClass
                             offset:(NSInteger)offset
                              limit:(NSInteger)limit {
    if (!self.loaded || !self.db) {
        return @{@"error": @"catalog not loaded", @"results": @[], @"total": @0};
    }

    NSString *table = unique ? @"entries_unique" : @"entries";
    NSString *qLower = [[q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    NSString *qLike = qLower.length ? [NSString stringWithFormat:@"%%%@%%", qLower] : nil;
    NSInteger minMin = [self encodeIOSVersion:minIOSStr];
    NSInteger maxMin = [self encodeIOSVersion:maxIOSStr];

    NSMutableString *whereClause = [NSMutableString string];
    if (qLike) [whereClause appendString:@" AND (title_lower LIKE ?1 OR bid_lower LIKE ?1)"];
    if (minMin >= 0) [whereClause appendString:[NSString stringWithFormat:@" AND minos >= %ld", (long)minMin]];
    if (maxMin >= 0) [whereClause appendString:[NSString stringWithFormat:@" AND minos <= %ld", (long)maxMin]];
    // Device class : bitmask plat field. iPhone bit = 2, iPad bit = 4.
    // "iphone" = app supports iPhone (works on iPhone+iPod and on iPad in compat mode).
    // "ipad"   = app supports iPad (works on iPad only).
    if ([deviceClass isEqualToString:@"iphone"]) {
        [whereClause appendString:@" AND (plat & 2) != 0"];
    } else if ([deviceClass isEqualToString:@"ipad"]) {
        [whereClause appendString:@" AND (plat & 4) != 0"];
    }
    // (Suspect-file SQL filter removed in v2.0.8 — too many false positives.
    //  See AppDetailViewController for per-row install-time mismatch alert.)

    // ORDER BY honors the user-selected direction. Column choice depends on `sortKey`.
    NSString *dir = descending ? @"DESC" : @"ASC";
    NSString *orderCol = @"pk";  // default = recent ordering (by primary key)
    if ([sortKey isEqualToString:@"name"]) orderCol = @"title_lower";
    else if ([sortKey isEqualToString:@"size"]) orderCol = @"size_kb";
    else if ([sortKey isEqualToString:@"minos"]) orderCol = @"minos";
    NSString *orderBy = [NSString stringWithFormat:@"%@ %@", orderCol, dir];

    // Count + data in two queries — both indexed, so each is sub-millisecond.
    long long total = 0;
    NSString *countSQL = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@ WHERE 1=1%@",
                                                       table, whereClause];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, [countSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) total = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st);

    NSString *dataSQL = [NSString stringWithFormat:
        @"SELECT pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk "
        @"FROM %@ WHERE 1=1%@ ORDER BY %@ LIMIT %ld OFFSET %ld",
        table, whereClause, orderBy, (long)limit, (long)offset];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:limit];
    st = NULL;
    if (sqlite3_prepare_v2(self.db, [dataSQL UTF8String], -1, &st, NULL) == SQLITE_OK) {
        if (qLike) sqlite3_bind_text(st, 1, [qLike UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            [results addObject:[self dictFromRow:st]];
        }
    }
    sqlite3_finalize(st);

    return @{
        @"total": @(total),
        @"offset": @(offset),
        @"limit": @(limit),
        @"results": results,
    };
}

// Convert one sqlite3 row to the NSDictionary shape the UI expects.
- (NSDictionary *)dictFromRow:(sqlite3_stmt *)st {
    NSInteger pk = sqlite3_column_int(st, 0);
    NSInteger plat = sqlite3_column_int(st, 1);
    NSInteger minOS = sqlite3_column_int(st, 2);
    const unsigned char *title = sqlite3_column_text(st, 3);
    const unsigned char *bid = sqlite3_column_text(st, 4);
    const unsigned char *version = sqlite3_column_text(st, 5);
    NSInteger baseIdx = sqlite3_column_int(st, 6);
    const unsigned char *filename = sqlite3_column_text(st, 7);
    long long sizeKB = sqlite3_column_int64(st, 8);
    NSInteger imgPk = sqlite3_column_int(st, 9);

    // stringWithUTF8String returns nil on invalid UTF-8 → would crash on @{...nil...} below.
    // Always coerce to empty string.
    NSString *titleStr = (title ? [NSString stringWithUTF8String:(const char *)title] : nil) ?: @"";
    NSString *bidStr = (bid ? [NSString stringWithUTF8String:(const char *)bid] : nil) ?: @"";
    NSString *versionStr = (version ? [NSString stringWithUTF8String:(const char *)version] : nil) ?: @"";
    NSString *filenameStr = (filename ? [NSString stringWithUTF8String:(const char *)filename] : nil) ?: @"";

    NSString *baseURL = self.urls[[NSString stringWithFormat:@"%ld", (long)baseIdx]] ?: @"";
    if (baseURL.length && ![baseURL hasSuffix:@"/"]) baseURL = [baseURL stringByAppendingString:@"/"];
    NSString *ipaURL = (baseURL.length && filenameStr.length)
        ? [baseURL stringByAppendingString:filenameStr] : @"";
    NSString *iconURL = [NSString stringWithFormat:@"https://stuffed18.github.io/ipa-archive-updated/data/%ld/%ld.jpg",
                          (long)(imgPk / 1000), (long)imgPk];

    return @{
        @"id": @(pk),
        @"title": titleStr,
        @"bundleId": bidStr,
        @"version": versionStr,
        @"minOS": [self decodeIOSVersion:minOS],
        @"platform": @(plat),
        @"size": @(sizeKB * 1024),
        @"url": ipaURL,
        @"fileName": filenameStr,
        @"icon": iconURL,
    };
}

#pragma mark - versionsForBundleId

- (NSArray *)versionsForBundleId:(NSString *)bundleId {
    if (!self.loaded || !bundleId.length || !self.db) return @[];
    NSMutableArray *out = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    NSString *sql = @"SELECT pk, plat, minos, title, bid, version, base_idx, filename, size_kb, img_pk "
                    @"FROM entries WHERE bid = ?1 ORDER BY version DESC, pk DESC";
    if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, [bundleId UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            [out addObject:[self dictFromRow:st]];
        }
    }
    sqlite3_finalize(st);
    return out;
}

@end

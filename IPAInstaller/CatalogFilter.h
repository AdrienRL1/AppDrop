#import <Foundation/Foundation.h>

@interface CatalogFilter : NSObject <NSCopying>
@property (nonatomic, copy) NSString *minIOS;   // "" = none, "3.0", "5.0", etc.
@property (nonatomic, copy) NSString *maxIOS;   // "" = none, "6.1.3", "7.1", etc.
@property (nonatomic, assign) BOOL uniqueOnly;
@property (nonatomic, copy) NSString *sort;     // "recent" / "name" / "size" / "minos"
@property (nonatomic, copy) NSString *deviceClass;  // "all" / "iphone" / "ipad"
                                                     // iPhone-only apps run on iPhone+iPad
                                                     // iPad-only apps DO NOT run on iPhone/iPod
// Sort direction: YES = high-to-low / Z-to-A, NO = low-to-high / A-to-Z.
// Default depends on `sort` key (e.g. recent=YES, name=NO, size=YES, minos=NO).
@property (nonatomic, assign) BOOL sortDescending;

+ (instancetype)defaultFilter;
+ (instancetype)load_;
// Sensible default direction for a given sort key. Used when user switches sort key.
+ (BOOL)defaultDescendingForSort:(NSString *)sort;
- (void)save;
- (NSString *)queryStringWithSearch:(NSString *)q offset:(NSInteger)offset limit:(NSInteger)limit;
- (NSString *)humanDescription;
@end

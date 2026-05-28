#import <Foundation/Foundation.h>

// Maps the raw hardware identifier (hw.machine, e.g. "iPad4,4") to a precise,
// human-readable model name + chip + RAM. Covers every device that can plausibly
// run iOS 6 through iOS 10 — including community / unofficially-upgraded ones
// (iPod touch 3G on iOS 6, iPad 1 on iOS 6/7, etc.).
//
// Used in two places:
//   • Settings → About: show the user EXACTLY what the app thinks it runs on.
//   • AI device context: so suggestions account for the real model, chip and RAM.
@interface DeviceInfo : NSObject

+ (NSString *)hardwareIdentifier;   // "iPad4,4"      (raw, from sysctl hw.machine)
+ (NSString *)modelName;            // "iPad mini 2"  (falls back to the raw id if unknown)
+ (NSString *)chip;                 // "Apple A7"     ("?" if unknown)
+ (NSString *)ram;                  // "1 GB"         ("?" if unknown)
+ (BOOL)isKnown;                    // YES if the identifier was found in our table

// One compact line for the AI prompt, e.g.:
//   "iPad mini 2 (iPad4,4), Apple A7, 1 GB RAM, iOS 10.3.3"
+ (NSString *)aiSummaryWithIOSVersion:(NSString *)iosVersion;

// Same, but reads the running iOS version itself (convenience).
+ (NSString *)aiSummary;

@end

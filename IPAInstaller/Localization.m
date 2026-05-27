#import "Localization.h"

NSString *AppDropT(NSString *key) {
    if (!key) return @"";
    NSString *v = [[Localization currentBundle] localizedStringForKey:key value:key table:nil];
    return v ?: key;
}

NSString *const kLocalizationDidChangeNotification = @"LocalizationDidChange";

static NSString *const kUserDefaultsKey = @"IPAInstall.Language";
static NSBundle *_cachedBundle = nil;
static NSString *_cachedCode = nil;

@implementation Localization

+ (NSString *)currentLanguageCode {
    if (_cachedCode) return _cachedCode;

    // 1. Manual override (Settings → Language)
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:kUserDefaultsKey];
    if (override.length) {
        _cachedCode = [override copy];
        return _cachedCode;
    }

    // 2. iOS device preferred language. Strip region for matching ("fr-CA" → "fr").
    NSArray *preferred = [NSLocale preferredLanguages];
    NSArray *supported = [self availableLanguageCodes];
    for (NSString *pref in preferred) {
        if ([supported containsObject:pref]) {
            _cachedCode = [pref copy];
            return _cachedCode;
        }
        NSString *base = [[pref componentsSeparatedByString:@"-"] firstObject];
        if (base.length && [supported containsObject:base]) {
            _cachedCode = [base copy];
            return _cachedCode;
        }
    }

    // 3. Default to English
    _cachedCode = @"en";
    return _cachedCode;
}

+ (NSBundle *)currentBundle {
    if (_cachedBundle) return _cachedBundle;
    NSString *code = [self currentLanguageCode];
    NSString *path = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    if (!path) {
        // "pt-BR" → try base "pt"
        NSString *base = [[code componentsSeparatedByString:@"-"] firstObject];
        path = [[NSBundle mainBundle] pathForResource:base ofType:@"lproj"];
    }
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    _cachedBundle = [NSBundle bundleWithPath:path] ?: [NSBundle mainBundle];
    return _cachedBundle;
}

+ (void)setLanguageCode:(NSString *)code {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (code.length) {
        [d setObject:code forKey:kUserDefaultsKey];
    } else {
        [d removeObjectForKey:kUserDefaultsKey];
    }
    [d synchronize];
    _cachedBundle = nil;
    _cachedCode = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:kLocalizationDidChangeNotification
                                                         object:nil];
}

+ (NSArray *)availableLanguageCodes {
    // Scan .lproj folders directly. [[NSBundle mainBundle] localizations] returns BOTH
    // the .lproj folders AND any CFBundleLocalizations declared in Info.plist, causing
    // duplicates ("en" + "en" etc.). Direct scan is the source of truth.
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *file in contents) {
        if (![file hasSuffix:@".lproj"]) continue;
        NSString *code = [file stringByDeletingPathExtension];
        if ([code isEqualToString:@"Base"]) continue;
        if ([seen containsObject:code]) continue;
        [seen addObject:code];
        [out addObject:code];
    }
    // Stable order: en first, then alpha
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"en"]) return NSOrderedAscending;
        if ([b isEqualToString:@"en"]) return NSOrderedDescending;
        return [a compare:b];
    }];
    return out;
}

+ (NSString *)displayNameForLanguageCode:(NSString *)code {
    static NSDictionary *names = nil;
    if (!names) {
        names = @{
            @"en":      @"English",
            @"fr":      @"Français",
            @"es":      @"Español",
            @"de":      @"Deutsch",
            @"pt-BR":   @"Português (BR)",
            @"pt":      @"Português",
            @"ja":      @"日本語",
            @"zh-Hans": @"简体中文",
            @"zh":      @"中文",
            @"zh-Hant": @"繁體中文",
            @"it":      @"Italiano",
            @"ko":      @"한국어",
            @"ru":      @"Русский",
        };
    }
    return names[code] ?: code;
}

@end

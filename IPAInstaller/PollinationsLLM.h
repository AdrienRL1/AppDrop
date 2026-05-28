#import <Foundation/Foundation.h>

// Free LLM gateway via text.pollinations.ai — OpenAI-compatible endpoint, no API key,
// no signup, multilingual. Anonymous tier model: GPT-OSS 20B (openai-fast).
//
// Used to identify vintage iOS apps (2008-2014, pre-iOS 7) from user descriptions in
// any language. The LLM's training knowledge already covers this era well, so we
// don't need real web search — we just need a very directive prompt that constrains
// it to the right era.
//
// Response shape (v2.0.24):
//   titles   — array of SPECIFIC app titles (e.g. "Cut the Rope") for exact-ish match
//   keywords — array of short English search terms (e.g. "rope", "candy") for broad match
//   reply    — 1-2 sentence intro in the user's language
//
// `titles` is new in v2.0.24 — the older signature returned only `keywords` and `reply`.
@interface PollinationsLLM : NSObject

+ (instancetype)shared;

// Identify candidate vintage iOS apps from a free-form user description.
//
// titles   — 3-6 specific titles the LLM thinks the user is describing
// keywords — 4-6 broader search terms for catalog fallback
// reply    — natural-language reply in user's language (multilingual)
//
// completion is called on main queue. On any failure, all 4 args may be nil.
- (void)askForKeywordsAndReply:(NSString *)userText
                    completion:(void (^)(NSArray *titles, NSArray *keywords,
                                          NSString *replyText, NSError *err))completion;

// Second-pass retry: caller has searched the catalog with the first pass's titles +
// keywords and found nothing (or too few hits). Asks the LLM for ALTERNATIVE candidates
// that are different from the first batch. Used when the first guess was off.
//
// alreadyTried — array of NSString (titles that didn't pan out) to give the LLM context
// completion   — same shape as askForKeywordsAndReply
- (void)askForAlternativeTitles:(NSString *)userText
                     alreadyTried:(NSArray *)alreadyTried
                       completion:(void (^)(NSArray *titles, NSArray *keywords,
                                              NSString *replyText, NSError *err))completion;

// v1.4 GROUNDING STEP — the key anti-hallucination pass.
//
// After we've searched the catalog and have a list of apps that ACTUALLY EXIST,
// we hand that numbered list back to the model and ask it to pick ONLY the ones
// that genuinely match the user's description, and to write its reply referencing
// only those. The model selects by number, so it physically cannot invent an app
// that isn't in the catalog. If nothing matches it must say so honestly.
//
// candidateLines — array of NSString, each "N. Title — vX — devices — iOS Y+ — size"
// (The user's exact device + iOS is injected automatically into every call's system
//  prompt, so the model already knows the hardware here.)
// completion (main queue):
//   matchNumbers — array of NSNumber, the 1-based indices the model chose (may be empty)
//   reply        — grounded reply in the user's language
//   found        — NO when nothing in the list matches (caller shows an honest empty state)
//   err          — non-nil on transport/parse failure (caller falls back gracefully)
- (void)selectMatchingCandidates:(NSArray *)candidateLines
                         userText:(NSString *)userText
                       completion:(void (^)(NSArray *matchNumbers, NSString *reply,
                                              BOOL found, NSError *err))completion;

@end

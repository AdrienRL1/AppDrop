#import "PollinationsLLM.h"
#import "HTTPSClient.h"

static NSString *const kEndpoint = @"https://text.pollinations.ai/openai";

// The shared "vintage iOS expert" system prompt. Drilled in: pre-iOS 7 era only,
// specific titles, structured JSON output, multilingual intro. Examples are critical
// because GPT-OSS-20B is a small model — without concrete examples it tends to
// suggest modern (post-2015) apps that aren't in our catalog.
static NSString *const kSystemPromptBase =
    @"You are an expert on vintage iOS apps from 2008-2014 — the pre-iOS 7 \n"
    @"skeuomorphic era when the App Store had Doodle Jump, Cut the Rope, Angry \n"
    @"Birds, Plants vs Zombies, Fruit Ninja, Tiny Wings, Temple Run, Where's My \n"
    @"Water, Bejeweled, Tap Tap Revenge, Talking Tom, Subway Surfers, Infinity \n"
    @"Blade, Real Racing, Flight Control, Bubble Ball, Bad Piggies, Jetpack \n"
    @"Joyride, Tiny Tower, Pou, etc.\n"
    @"\n"
    @"The user describes an app they remember (any language). Identify the SPECIFIC \n"
    @"title(s) they likely mean. The catalog only contains apps from this era \n"
    @"(roughly 2008 through 2014). DO NOT suggest apps released after 2015 — they \n"
    @"won't be in the catalog.\n"
    @"\n"
    @"Be specific. 'Puzzle game with green creature' → 'Cut the Rope'. 'Bird game with \n"
    @"slingshot' → 'Angry Birds'. Use your knowledge of titles, characters, art style, \n"
    @"gameplay, developer studios, era trends.\n"
    @"\n"
    @"Output a single JSON object — NO markdown, NO code fences, NO preamble:\n"
    @"{\n"
    @"  \"titles\":   [\"App Title 1\", \"App Title 2\", ...],   // 3-6 specific titles\n"
    @"  \"keywords\": [\"word1\", \"word2\", ...],                // 4-6 short English search terms\n"
    @"  \"reply\":    \"1-2 sentence reply in the user's language\"\n"
    @"}\n"
    @"\n"
    @"Examples:\n"
    @"\n"
    @"User: \"There was a game where you cut ropes to feed candy to a green creature\"\n"
    @"{\"titles\":[\"Cut the Rope\",\"Cut the Rope: Experiments\",\"Cut the Rope Free\"],\n"
    @" \"keywords\":[\"cut\",\"rope\",\"candy\",\"om nom\"],\n"
    @" \"reply\":\"That's Cut the Rope, the 2010 puzzle hit from ZeptoLab where you feed candy to the green creature Om Nom.\"}\n"
    @"\n"
    @"User: \"Un jeu où on lance des oiseaux sur des cochons verts\"\n"
    @"{\"titles\":[\"Angry Birds\",\"Angry Birds Seasons\",\"Angry Birds Rio\",\"Angry Birds Space\"],\n"
    @" \"keywords\":[\"angry birds\",\"slingshot\",\"pigs\"],\n"
    @" \"reply\":\"C'est Angry Birds, le classique de Rovio (2009) où tu utilises une fronde pour lancer des oiseaux sur des cochons verts.\"}\n"
    @"\n"
    @"User: \"Un jeu où un chat parle et répète ce que tu dis\"\n"
    @"{\"titles\":[\"Talking Tom Cat\",\"Talking Tom Cat 2\",\"Talking Tom Cat Free\"],\n"
    @" \"keywords\":[\"talking tom\",\"cat\",\"voice\"],\n"
    @" \"reply\":\"Tu parles de Talking Tom Cat (2010), où un chat répète ce que tu dis avec une voix amusante.\"}\n"
    @"\n"
    @"User: \"うろ覚えだけど、岩の上を跳ねるピンクのキャラクター\"\n"
    @"{\"titles\":[\"Doodle Jump\",\"Tiny Wings\"],\n"
    @" \"keywords\":[\"doodle\",\"jump\",\"bounce\"],\n"
    @" \"reply\":\"おそらく Doodle Jump（2009年、Lima Sky）のことだと思います — 落ちないように上に跳ね続けるアーケードゲームです。\"}\n";

// Internal worker that performs ONE LLM round-trip with the given system + user.
// All callbacks hop to main.
static void callLLM(NSString *systemPrompt, NSString *userMsg, float temperature,
                    void (^completion)(NSArray *titles, NSArray *keywords,
                                        NSString *reply, NSError *err)) {
    NSDictionary *payload = @{
        @"model": @"openai",  // alias → openai-fast (GPT-OSS 20B)
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user",   @"content": userMsg},
        ],
        @"private": @YES,
        @"temperature": @(temperature),
    };
    NSError *je = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&je];
    if (je) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, nil, je); });
        return;
    }

    void (^cb)(NSArray *, NSArray *, NSString *, NSError *) =
        ^(NSArray *t, NSArray *k, NSString *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(t, k, r, e); });
    };

    [HTTPSClient postURL:kEndpoint
                  headers:@{@"Content-Type": @"application/json",
                            @"Accept": @"application/json"}
                     body:bodyData
                  timeout:35
               completion:^(NSData *resp, NSInteger code, NSError *err) {
        if (err || code != 200 || !resp.length) {
            NSLog(@"[Pollinations] error: code=%ld err=%@", (long)code, err);
            cb(nil, nil, nil,
                err ?: [NSError errorWithDomain:@"Pollinations" code:code
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"HTTP %ld", (long)code]}]);
            return;
        }
        // OpenAI-compatible payload
        NSDictionary *outer = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
        NSString *content = nil;
        if ([outer isKindOfClass:[NSDictionary class]]) {
            NSArray *choices = outer[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count) {
                content = [[choices firstObject] valueForKeyPath:@"message.content"];
            }
            if (!content.length) content = outer[@"content"];
        }
        if (!content.length) {
            content = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
        }
        if (!content.length) {
            cb(nil, nil, nil,
                [NSError errorWithDomain:@"Pollinations" code:2
                                userInfo:@{NSLocalizedDescriptionKey: @"Empty content"}]);
            return;
        }
        // Strip ``` code fences if present
        NSString *clean = content;
        NSRange fenceStart = [clean rangeOfString:@"```"];
        if (fenceStart.location != NSNotFound) {
            NSRange afterFence = NSMakeRange(NSMaxRange(fenceStart),
                                              clean.length - NSMaxRange(fenceStart));
            NSRange newLine = [clean rangeOfString:@"\n" options:0 range:afterFence];
            if (newLine.location != NSNotFound) {
                clean = [clean substringFromIndex:NSMaxRange(newLine)];
            }
            NSRange fenceEnd = [clean rangeOfString:@"```" options:NSBackwardsSearch];
            if (fenceEnd.location != NSNotFound) {
                clean = [clean substringToIndex:fenceEnd.location];
            }
        }
        NSRange jsonStart = [clean rangeOfString:@"{"];
        NSRange jsonEnd = [clean rangeOfString:@"}" options:NSBackwardsSearch];
        if (jsonStart.location == NSNotFound || jsonEnd.location == NSNotFound
            || jsonEnd.location <= jsonStart.location) {
            NSLog(@"[Pollinations] no JSON in: %@", content);
            cb(nil, nil, nil,
                [NSError errorWithDomain:@"Pollinations" code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"No JSON in response"}]);
            return;
        }
        NSString *jsonStr = [clean substringWithRange:NSMakeRange(jsonStart.location,
                                                                    jsonEnd.location - jsonStart.location + 1)];
        NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:
                                  [jsonStr dataUsingEncoding:NSUTF8StringEncoding]
                                                                options:0 error:nil];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            cb(nil, nil, nil,
                [NSError errorWithDomain:@"Pollinations" code:4
                                userInfo:@{NSLocalizedDescriptionKey:
                                           [@"Bad JSON: " stringByAppendingString:jsonStr]}]);
            return;
        }
        NSArray *titles   = parsed[@"titles"];
        NSArray *keywords = parsed[@"keywords"];
        NSString *reply   = parsed[@"reply"];
        if (![titles isKindOfClass:[NSArray class]])    titles   = nil;
        if (![keywords isKindOfClass:[NSArray class]])  keywords = nil;
        if (![reply isKindOfClass:[NSString class]])    reply    = nil;
        NSLog(@"[Pollinations] titles=%@ keywords=%@ reply='%@'",
              [titles componentsJoinedByString:@" | "],
              [keywords componentsJoinedByString:@","], reply);
        cb(titles, keywords, reply, nil);
    }];
}

@implementation PollinationsLLM

+ (instancetype)shared {
    static PollinationsLLM *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)askForKeywordsAndReply:(NSString *)userText
                    completion:(void (^)(NSArray *, NSArray *, NSString *, NSError *))completion {
    if (!userText.length) {
        if (completion) completion(nil, nil, nil, nil);
        return;
    }
    // Temperature 0.7: we want creativity for vague descriptions, but not full
    // randomness. The system prompt with examples keeps it grounded.
    callLLM(kSystemPromptBase, userText, 0.7f, completion);
}

- (void)askForAlternativeTitles:(NSString *)userText
                     alreadyTried:(NSArray *)alreadyTried
                       completion:(void (^)(NSArray *, NSArray *, NSString *, NSError *))completion {
    if (!userText.length) {
        if (completion) completion(nil, nil, nil, nil);
        return;
    }
    // Build a follow-up prompt that explicitly excludes the previously-tried titles.
    NSString *triedJoined = alreadyTried.count
        ? [alreadyTried componentsJoinedByString:@", "]
        : @"(none)";
    NSString *altPrompt = [kSystemPromptBase stringByAppendingFormat:
        @"\nCATALOG MISS: the previous candidates [%@] were NOT found in the catalog. \n"
        @"Suggest DIFFERENT vintage iOS apps (also 2008-2014, also pre-iOS 7) that could \n"
        @"match the same description. Think of less famous but plausible alternatives, \n"
        @"clones, or similar genre titles. Do NOT repeat any title from the list above.",
        triedJoined];
    // Higher temperature on retry — first guess was wrong, push for variety.
    callLLM(altPrompt, userText, 0.9f, completion);
}

@end

#import "ChatViewController.h"
#import "ChatMessage.h"
#import "LocalCatalog.h"
#import "InstallManager.h"
#import "CatalogFilter.h"
#import "AppDetailViewController.h"
#import "IOS6Theme.h"
#import "IconLoader.h"
#import "ChatBubbleView.h"
#import "Localization.h"
#import "PollinationsLLM.h"
#import <objc/runtime.h>

@interface ChatViewController ()
@property (nonatomic, strong) NSMutableArray *messages;           // ChatMessage instances
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *inputBar;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL waiting;
// Cached content view per displayable message — built once, re-attached to cell on scroll.
// Avoids the ~60 subviews/cell rebuild on every cellForRow which kills scroll smoothness on iPad 1.
@property (nonatomic, strong) NSMutableArray *cachedRowViews;
@end

@implementation ChatViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"chat.title");
    self.view.backgroundColor = [IOS6Theme chatBackgroundColor];
    self.messages = [NSMutableArray array];

    // System prompt: tells LLM about its role and how to use tools.
    NSString *systemPrompt =
        @"You are an assistant who finds old iOS apps in the IPA Archive catalog (157000 apps, 2008-2014).\n\n"
        @"USER LANGUAGE: French. The user types in French. The catalog data is in ENGLISH (titles, bundle IDs).\n"
        @"Your final text response must be in French. But all your search_catalog queries MUST be in English.\n\n"
        @"=== MANDATORY WORKFLOW ===\n"
        @"For EVERY user request asking for an app:\n"
        @"1. Translate the French intent into 3 to 5 short English keywords (1-2 words each).\n"
        @"2. Call search_catalog ONCE PER KEYWORD (3 to 5 tool calls minimum). Do them in sequence.\n"
        @"3. Only AFTER all those searches, write your final French response.\n"
        @"4. NEVER conclude 'no app found' after fewer than 3 searches with different keywords.\n\n"
        @"=== TRANSLATION CHEAT SHEET ===\n"
        @"  visage / face → face, morph, warp, deform, fat, aging, booth, goo, swap\n"
        @"  photo manipulation → photo, image, edit, filter, lab\n"
        @"  jeu de course → racing, race, driving, drift, car\n"
        @"  jeu de tir → shooter, gun, sniper, war\n"
        @"  jeu de plateforme → platformer, jump, runner\n"
        @"  puzzle / casse-tete → puzzle, brain, sudoku, match\n"
        @"  musique → music, piano, guitar, sound, beat\n"
        @"  cuisine / recettes → recipe, cooking, food, chef\n"
        @"  meditation / sommeil → sleep, meditation, calm, relax\n"
        @"  apprendre les langues → learn, english, spanish, vocabulary\n"
        @"  productivité → notes, task, todo, calendar\n"
        @"  dessin / peinture → draw, paint, sketch, color\n"
        @"  fitness / sport → workout, fitness, run, gym\n"
        @"  bebe / enfant → kids, baby, child, learn\n\n"
        @"=== EXAMPLE ===\n"
        @"User: 'trouve une app qui deforme les visages depuis une photo'\n"
        @"You: call search_catalog(query='face') → 10 results\n"
        @"     call search_catalog(query='morph') → 5 results\n"
        @"     call search_catalog(query='warp') → 3 results\n"
        @"     call search_catalog(query='booth') → 6 results\n"
        @"     call search_catalog(query='deform') → 2 results\n"
        @"     final French response: 'Voici plusieurs apps de morphing facial trouvees dans le catalogue. "
        @"     Les premieres sont les plus connues comme FaceGoo et Photo Deformer.'\n"
        @"(The code automatically displays found apps as tappable cards below your text — do NOT list them in text.)\n\n"
        @"=== RULES ===\n"
        @"  R1: NEVER pass French words to search_catalog. Always translate first.\n"
        @"  R2: Try AT LEAST 3 different English keywords per user request.\n"
        @"  R3: If search returns 0 and has a _hint field, FOLLOW the hint and retry.\n"
        @"  R4: Final French response: 2-4 sentences, no lists, no numbering. Just a fluid description.\n"
        @"  R5: If after 5 different keyword attempts you genuinely found nothing, say so politely.";
    [self.messages addObject:[ChatMessage system:systemPrompt]];

    self.cachedRowViews = [NSMutableArray array];
    [self buildUI];
    [self.tableView reloadData];
}

- (void)buildUI {
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width;
    CGFloat inputH = 50;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, w, b.size.height - inputH)
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [IOS6Theme chatBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.opaque = YES;
    [self.view addSubview:self.tableView];

    // Input bar — brushed metal style with subtle gradient (gray button image stretched as bg)
    self.inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - inputH, w, inputH)];
    self.inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.inputBar.opaque = YES;
    // Use a UIImageView with stretchable tabBarBackground-ish gradient inverted (light to slightly darker)
    UIImageView *barBg = [[UIImageView alloc] initWithFrame:self.inputBar.bounds];
    barBg.image = [IOS6Theme grayButtonNormal];  // light metallic gradient
    barBg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    barBg.contentMode = UIViewContentModeScaleToFill;
    [self.inputBar addSubview:barBg];
    // Top hairline (dark line above input bar)
    UIView *topBorder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0.5)];
    topBorder.backgroundColor = [UIColor colorWithWhite:0.40 alpha:1.0];
    topBorder.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.inputBar addSubview:topBorder];
    [self.view addSubview:self.inputBar];

    CGFloat sendW = 64;
    CGFloat padding = 6;
    CGFloat fieldH = inputH - 2 * padding;

    // (Mic button removed: voice input handled by the iOS keyboard's native dictation key,
    // which works iOS 5.1+ in every keyboard language, no extra setup, no API key needed.)
    // Text field — rounded with subtle inset shadow
    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(padding, padding,
                                                                       w - sendW - 3*padding,
                                                                       fieldH)];
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.placeholder = T(@"chat.placeholder");
    self.inputField.font = [IOS6Theme bodyFont];
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.delegate = self;
    self.inputField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.inputBar addSubview:self.inputField];

    // Send button — primary blue glossy
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sendBtn.frame = CGRectMake(w - sendW - padding, padding, sendW, fieldH);
    self.sendBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.sendBtn setTitle:T(@"chat.send") forState:UIControlStateNormal];
    [IOS6Theme styleButton:self.sendBtn];
    self.sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.sendBtn addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:self.sendBtn];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    // Voice mode toggle removed — voice input via iOS keyboard, voice output via AVFoundation
    // (no longer auto-triggered after each reply).
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:self.spinner];

    // Keyboard handling for input field
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(keyboardWillShow:)
                                                  name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(keyboardWillHide:)
                                                  name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)n {
    NSDictionary *u = n.userInfo;
    CGRect endScreen = [u[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // Convert from window/screen coords into our view's coords — in landscape on iOS 5/6,
    // the raw keyboard rect is in screen orientation (portrait), so width and height
    // are swapped from what we want. convertRect:fromView:nil does the right thing.
    CGRect endInView = [self.view convertRect:endScreen fromView:nil];
    // The keyboard's "visible portion" inside our view = intersection with our bounds.
    CGRect intersection = CGRectIntersection(self.view.bounds, endInView);
    CGFloat kbH = CGRectIsNull(intersection) ? 0 : intersection.size.height;
    CGRect b = self.view.bounds;
    CGFloat inputH = self.inputBar.frame.size.height;
    self.inputBar.frame = CGRectMake(0, b.size.height - inputH - kbH, b.size.width, inputH);
    self.tableView.frame = CGRectMake(0, 0, b.size.width, b.size.height - inputH - kbH);
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)n {
    CGRect b = self.view.bounds;
    CGFloat inputH = self.inputBar.frame.size.height;
    self.inputBar.frame = CGRectMake(0, b.size.height - inputH, b.size.width, inputH);
    self.tableView.frame = CGRectMake(0, 0, b.size.width, b.size.height - inputH);
}

#pragma mark - Send

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self sendTapped];
    return NO;
}

- (void)sendTapped {
    NSString *text = [self.inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!text.length || self.waiting) return;
    self.inputField.text = @"";
    [self.inputField resignFirstResponder];

    [self.messages addObject:[ChatMessage user:text]];
    [self reloadAndScroll];
    [self runHeuristicSearchForText:text];
}

// Multi-language LLM-driven search. Pollinations is the only chat backend.
// v2.0.24 flow:
//   1) Call LLM with vintage-iOS expert prompt. LLM returns titles + keywords + reply.
//   2) Search catalog by BOTH titles (boosted score) and keywords (broader).
//   3) If catalog returns < 3 hits → call LLM again with "alternative titles" prompt,
//      excluding the titles we already tried. Search again, merge results.
- (void)runHeuristicSearchForText:(NSString *)text {
    self.waiting = YES;
    self.sendBtn.enabled = NO;
    [self.spinner startAnimating];

    [[PollinationsLLM shared] askForKeywordsAndReply:text
                completion:^(NSArray *titles, NSArray *keywords, NSString *reply, NSError *err) {
        if (err || (!titles.count && !keywords.count)) {
            [self finishChatWithApps:@[] reply:T(@"chat.llm_error")];
            return;
        }
        [self runCatalogSearchWithTitles:titles
                                  keywords:keywords
                                 replyText:reply
                          originalUserText:text];
    }];
}

// Catalog search with two signal sources:
//   titles   — boost weight ×3 because they're specific LLM guesses
//   keywords — broader matches at normal weight
// If too few results, kick off a retry pass with alternative titles.
- (void)runCatalogSearchWithTitles:(NSArray *)titles
                            keywords:(NSArray *)keywords
                           replyText:(NSString *)reply
                    originalUserText:(NSString *)userText {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *appsByBid = [NSMutableDictionary dictionary];
        NSMutableDictionary *scoreByBid = [NSMutableDictionary dictionary];
        CatalogFilter *cf = [CatalogFilter load_];

        // Pass 1: titles (specific guesses) — high weight.
        for (NSString *t in titles) {
            if (![t isKindOfClass:[NSString class]] || !t.length) continue;
            NSDictionary *res = [[LocalCatalog shared] searchWithQuery:t
                                                                  minIOS:nil
                                                                  maxIOS:nil
                                                                  unique:YES
                                                                    sort:@"recent"
                                                              descending:YES
                                                             deviceClass:cf.deviceClass
                                                                  offset:0
                                                                   limit:10];
            for (NSDictionary *app in res[@"results"] ?: @[]) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                if (!appsByBid[bid]) appsByBid[bid] = app;
                // Title matches count 3× — they're specific guesses, not vocab.
                scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 3);
            }
        }
        // Pass 2: keywords — broader, low weight.
        for (NSString *kw in keywords) {
            if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
            NSDictionary *res = [[LocalCatalog shared] searchWithQuery:kw
                                                                  minIOS:nil
                                                                  maxIOS:nil
                                                                  unique:YES
                                                                    sort:@"recent"
                                                              descending:YES
                                                             deviceClass:cf.deviceClass
                                                                  offset:0
                                                                   limit:15];
            for (NSDictionary *app in res[@"results"] ?: @[]) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                if (!appsByBid[bid]) appsByBid[bid] = app;
                scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 1);
            }
        }
        // Sort by score (DESC), then pk (DESC for newer-first within tie).
        NSArray *bids = [appsByBid.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSComparisonResult c = [scoreByBid[b] compare:scoreByBid[a]];
            if (c != NSOrderedSame) return c;
            return [appsByBid[b][@"id"] compare:appsByBid[a][@"id"]];
        }];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *bid in bids) {
            [out addObject:appsByBid[bid]];
            if (out.count >= 12) break;
        }

        // Few hits? Retry with alternative titles from the LLM.
        // Threshold tuned: 3 because the catalog is so noisy that 1-2 results often
        // turn out to be coincidental keyword matches, not the real app.
        BOOL needRetry = (out.count < 3 && userText.length);
        if (needRetry) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self retryWithAlternativesForUserText:userText
                                          previousTitles:titles
                                       firstPassResults:out
                                              replyText:reply];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishChatWithApps:out reply:reply];
        });
    });
}

// Second LLM round when first pass had too few catalog hits. We tell the LLM the
// previous guesses didn't work and ask for different alternatives, then re-search.
- (void)retryWithAlternativesForUserText:(NSString *)userText
                            previousTitles:(NSArray *)previousTitles
                          firstPassResults:(NSArray *)firstPassResults
                                  replyText:(NSString *)reply {
    NSLog(@"[chat] first pass %lu hits — retrying with alternative titles",
          (unsigned long)firstPassResults.count);
    [[PollinationsLLM shared] askForAlternativeTitles:userText
                                           alreadyTried:previousTitles
                                             completion:^(NSArray *titles2, NSArray *kws2,
                                                            NSString *reply2, NSError *err) {
        if (err || (!titles2.count && !kws2.count)) {
            // Retry itself failed — fall back to whatever the first pass turned up,
            // even if it's slim. Better than an error message.
            [self finishChatWithApps:firstPassResults reply:reply];
            return;
        }
        // Merge first-pass + alternative-pass results.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableDictionary *appsByBid = [NSMutableDictionary dictionary];
            NSMutableDictionary *scoreByBid = [NSMutableDictionary dictionary];
            CatalogFilter *cf = [CatalogFilter load_];
            // Seed with first-pass hits (preserve them, lower priority).
            for (NSDictionary *app in firstPassResults) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                appsByBid[bid] = app;
                scoreByBid[bid] = @1;
            }
            // Alternative titles — high weight (these are LLM's "rethought" guesses).
            for (NSString *t in titles2) {
                if (![t isKindOfClass:[NSString class]] || !t.length) continue;
                NSDictionary *res = [[LocalCatalog shared] searchWithQuery:t
                                                                      minIOS:nil maxIOS:nil
                                                                      unique:YES sort:@"recent"
                                                                  descending:YES
                                                                 deviceClass:cf.deviceClass
                                                                      offset:0 limit:10];
                for (NSDictionary *app in res[@"results"] ?: @[]) {
                    NSString *bid = app[@"bundleId"];
                    if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                    if (!appsByBid[bid]) appsByBid[bid] = app;
                    scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 3);
                }
            }
            for (NSString *kw in kws2) {
                if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
                NSDictionary *res = [[LocalCatalog shared] searchWithQuery:kw
                                                                      minIOS:nil maxIOS:nil
                                                                      unique:YES sort:@"recent"
                                                                  descending:YES
                                                                 deviceClass:cf.deviceClass
                                                                      offset:0 limit:15];
                for (NSDictionary *app in res[@"results"] ?: @[]) {
                    NSString *bid = app[@"bundleId"];
                    if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                    if (!appsByBid[bid]) appsByBid[bid] = app;
                    scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 1);
                }
            }
            NSArray *bids = [appsByBid.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSComparisonResult c = [scoreByBid[b] compare:scoreByBid[a]];
                if (c != NSOrderedSame) return c;
                return [appsByBid[b][@"id"] compare:appsByBid[a][@"id"]];
            }];
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *bid in bids) {
                [out addObject:appsByBid[bid]];
                if (out.count >= 12) break;
            }
            // Prefer the SECOND reply because it reflects the LLM's revised guess.
            NSString *finalReply = reply2.length ? reply2 : reply;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishChatWithApps:out reply:finalReply];
            });
        });
    }];
}

- (void)finishChatWithApps:(NSArray *)apps reply:(NSString *)reply {
    self.waiting = NO;
    [self.spinner stopAnimating];
    self.sendBtn.enabled = YES;

    ChatMessage *am = [[ChatMessage alloc] init];
    am.role = @"assistant";
    am.content = reply.length
        ? reply
        : [NSString stringWithFormat:T(@"chat.found_apps"), (unsigned long)apps.count];
    am.attachedApps = apps;
    [self.messages addObject:am];
    [self reloadAndScroll];
}

// v1.9.0: removed tool-call chat path (requestAssistantTurn/executeToolCalls/searchCatalogTool/
// runTool:), voice recording (micDown/micUp/micCancel + AVAudioRecorder), voice mode
// (toggleVoiceMode/speakText:/hideSpeakingLabel/interruptSpeech/autoStartListening + AVAudioPlayer),
// and AVAudioPlayerDelegate. Chat is now Pollinations-only via runHeuristicSearchForText:.

#pragma mark - Table

- (void)reloadAndScroll {
    [self.tableView reloadData];
    [self scrollToBottom];
}

- (void)scrollToBottom {
    NSInteger n = [self displayableMessageCount];
    if (n == 0) return;
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:n - 1 inSection:0]
                            atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

// Tool messages are now hidden from UI — they were just noise. The apps from search_catalog
// appear as tappable cards under the assistant reply that references them.
- (NSInteger)displayableMessageCount {
    NSInteger n = 0;
    for (ChatMessage *m in self.messages) {
        if ([m.role isEqualToString:@"user"] ||
            ([m.role isEqualToString:@"assistant"] && m.content.length)) n++;
    }
    return n;
}

- (ChatMessage *)displayableMessageAtIndex:(NSInteger)idx {
    NSInteger i = 0;
    for (ChatMessage *m in self.messages) {
        BOOL displayable = [m.role isEqualToString:@"user"] ||
            ([m.role isEqualToString:@"assistant"] && m.content.length);
        if (!displayable) continue;
        if (i == idx) return m;
        i++;
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self displayableMessageCount];
}

#define kChatBubblePadding 12.0
#define kChatHMargin      14.0
#define kChatAppCardH     72.0
#define kChatAppCardGap   6.0

- (CGFloat)bubbleHeightForText:(NSString *)text width:(CGFloat)maxW {
    if (!text.length) return 0;
    CGSize sz = [text sizeWithFont:[IOS6Theme bodyFont]
                  constrainedToSize:CGSizeMake(maxW - 2 * kChatBubblePadding - 10, 5000)
                      lineBreakMode:NSLineBreakByWordWrapping];
    return sz.height + 2 * kChatBubblePadding;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    ChatMessage *m = [self displayableMessageAtIndex:ip.row];
    if (!m) return 44;
    CGFloat maxBubbleW = tv.bounds.size.width * 0.80;
    CGFloat h = [self bubbleHeightForText:m.content ?: @"" width:maxBubbleW];
    // Add app cards below if attached
    NSInteger nApps = m.attachedApps.count;
    if (nApps > 0) {
        h += 10 + nApps * (kChatAppCardH + kChatAppCardGap);
    }
    return MAX(50, h + 12);  // top + bottom padding
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"chatCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.contentView.backgroundColor = [IOS6Theme chatBackgroundColor];
        cell.contentView.opaque = YES;
        cell.backgroundColor = [IOS6Theme chatBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    ChatMessage *m = [self displayableMessageAtIndex:ip.row];
    if (!m) {
        for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];
        return cell;
    }

    // Fast path: lookup the cached content view for this displayable index.
    // If already built, just re-attach it to the (possibly new) cell.contentView.
    while ((NSInteger)self.cachedRowViews.count <= ip.row) {
        [self.cachedRowViews addObject:[NSNull null]];
    }
    id cached = self.cachedRowViews[ip.row];
    UIView *content = nil;
    if ([cached isKindOfClass:[UIView class]]) {
        content = (UIView *)cached;
    } else {
        content = [self buildContentViewForMessage:m width:tv.bounds.size.width];
        self.cachedRowViews[ip.row] = content;
    }

    // Detach the cell's previous subviews (may belong to another message after reuse).
    // We do NOT destroy them — they're owned by their respective cached entries.
    for (UIView *v in [cell.contentView.subviews copy]) {
        [v removeFromSuperview];
    }
    [cell.contentView addSubview:content];
    return cell;
}

// Build the full content view (bubble + app cards) for a message ONCE.
// All subviews (bubble drawRect, card UIImageView × N, labels × N) are created here
// and never touched again — just re-parented as cells scroll in/out.
- (UIView *)buildContentViewForMessage:(ChatMessage *)m width:(CGFloat)w {
    CGFloat maxBubbleW = w * 0.78;
    BOOL isUser = [m.role isEqualToString:@"user"];
    CGFloat bubbleH = [self bubbleHeightForText:m.content ?: @"" width:maxBubbleW];
    CGSize sz = [(m.content ?: @"") sizeWithFont:[IOS6Theme bodyFont]
                                 constrainedToSize:CGSizeMake(maxBubbleW - 2 * kChatBubblePadding - 10, 5000)
                                     lineBreakMode:NSLineBreakByWordWrapping];
    CGFloat bubbleW = sz.width + 2 * kChatBubblePadding + 10;
    if (bubbleW < 70) bubbleW = 70;
    CGFloat bubbleX = isUser ? (w - bubbleW - kChatHMargin) : kChatHMargin;

    // Compute total height (matches tableView:heightForRowAtIndexPath:)
    CGFloat totalH = MAX(50, bubbleH + 12);
    if (m.attachedApps.count) {
        totalH = bubbleH + 10 + m.attachedApps.count * (kChatAppCardH + kChatAppCardGap) + 12;
    }
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, totalH)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.opaque = YES;
    container.backgroundColor = [IOS6Theme chatBackgroundColor];

    ChatBubbleView *bubble = [[ChatBubbleView alloc] initWithFrame:CGRectMake(bubbleX, 6, bubbleW, bubbleH)];
    bubble.isUser = isUser;
    bubble.messageText = m.content ?: @"";
    [container addSubview:bubble];

    if (m.attachedApps.count) {
        CGFloat y = 6 + bubbleH + 10;
        for (NSDictionary *app in m.attachedApps) {
            UIView *card = [self buildAppCard:app width:w - 2 * kChatHMargin y:y];
            [container addSubview:card];
            y += kChatAppCardH + kChatAppCardGap;
        }
    }
    return container;
}

// Build a tappable iOS 6-style app card: pre-rendered card-bg PNG + icon + title/subtitle/cta.
// No runtime cornerRadius — the PNG already has rounded corners + border baked in.
- (UIView *)buildAppCard:(NSDictionary *)app width:(CGFloat)width y:(CGFloat)y {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(kChatHMargin, y, width, kChatAppCardH)];
    card.userInteractionEnabled = YES;
    card.opaque = NO;  // pixels outside the rounded card are transparent

    // Stretchable card background PNG (white gradient + border + 12pt rounded corners baked)
    UIImageView *bg = [[UIImageView alloc] initWithFrame:card.bounds];
    bg.image = [IOS6Theme cardBackground];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [card addSubview:bg];

    CGFloat iconSize = 52;
    CGFloat pad = 10;

    // Icon — IconLoader returns pre-rounded pixels (radius baked into the bitmap),
    // so we DON'T set cornerRadius on the layer (which would force offscreen rendering and
    // kill scroll perf on iPad 1/4).
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(pad, pad, iconSize, iconSize)];
    iv.backgroundColor = [UIColor clearColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.opaque = NO;
    [card addSubview:iv];

    NSString *iconUrl = app[@"icon"];
    if (iconUrl.length) {
        CGSize sz = CGSizeMake(iconSize, iconSize);
        UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
        if (cached) {
            iv.image = cached;
        } else {
            [[IconLoader shared] loadImageForURL:iconUrl
                                       targetSize:sz
                                              via:nil
                                       completion:^(UIImage *img) { if (img) iv.image = img; }];
        }
    }

    CGFloat textX = pad + iconSize + pad;
    CGFloat textW = width - iconSize - 3 * pad - 22;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(textX, pad + 2, textW, 20)];
    title.text = app[@"title"] ?: @"?";
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = [IOS6Theme labelDark];
    title.backgroundColor = [UIColor clearColor];
    [card addSubview:title];

    long long sizeBytes = [app[@"size"] longLongValue];
    NSString *sizeStr;
    if (sizeBytes <= 0) sizeStr = @"?";
    else if (sizeBytes < 1024LL*1024) sizeStr = [NSString stringWithFormat:@"%.0f Ko", sizeBytes / 1024.0];
    else if (sizeBytes < 1024LL*1024*1024) sizeStr = [NSString stringWithFormat:@"%.1f Mo", sizeBytes / (1024.0*1024)];
    else sizeStr = [NSString stringWithFormat:@"%.2f Go", sizeBytes / (1024.0*1024*1024)];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(textX, 27, textW, 16)];
    sub.text = [NSString stringWithFormat:@"v%@  •  iOS %@+  •  %@",
                  app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", sizeStr];
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [IOS6Theme labelGray];
    sub.backgroundColor = [UIColor clearColor];
    [card addSubview:sub];

    UILabel *cta = [[UILabel alloc] initWithFrame:CGRectMake(textX, 45, textW, 16)];
    cta.text = @"Tappez pour installer";
    cta.font = [UIFont boldSystemFontOfSize:11];
    cta.textColor = [IOS6Theme primaryBlue];
    cta.backgroundColor = [UIColor clearColor];
    [card addSubview:cta];

    // Disclosure indicator
    UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectMake(width - 22, 26, 14, 20)];
    arrow.text = @"›";
    arrow.font = [UIFont boldSystemFontOfSize:24];
    arrow.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    arrow.backgroundColor = [UIColor clearColor];
    [card addSubview:arrow];

    NSDictionary *appCapture = app;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(appCardTapped:)];
    [card addGestureRecognizer:tap];
    objc_setAssociatedObject(card, "ipa.appdict", appCapture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return card;
}

- (void)appCardTapped:(UITapGestureRecognizer *)gr {
    NSDictionary *app = objc_getAssociatedObject(gr.view, "ipa.appdict");
    if (!app) return;
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - Rotation: invalidate cached row views

// On rotation, the cached row views were built for the old screen width — their bubbles
// + app cards now overflow or have huge gaps. Drop the cache so cells rebuild at the new width.
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                 duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.cachedRowViews removeAllObjects];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    // Rebuild table cells (and bubble + app card content views) at the new orientation width.
    [UIView setAnimationsEnabled:NO];
    [self.tableView reloadData];
    [UIView setAnimationsEnabled:YES];
    [self scrollToBottom];
}

@end

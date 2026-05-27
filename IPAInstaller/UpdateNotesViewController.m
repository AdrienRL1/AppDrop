#import "UpdateNotesViewController.h"
#import "Localization.h"
#import "IOS6Theme.h"

@interface UpdateNotesViewController () <UIWebViewDelegate>
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UILabel *headerLabel;
@end

@implementation UpdateNotesViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = T(@"update_notes.title");

    // Nav bar buttons. UIBarButtonSystemItemCancel auto-localizes via iOS.
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
    UIBarButtonItem *install =
        [[UIBarButtonItem alloc] initWithTitle:T(@"update_notes.install")
                                          style:UIBarButtonItemStyleDone
                                         target:self
                                         action:@selector(installTapped)];
    self.navigationItem.rightBarButtonItem = install;

    // Header strip: "v1.3 — released May 30, 2026"
    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.numberOfLines = 0;
    self.headerLabel.font = [UIFont systemFontOfSize:13];
    self.headerLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.headerLabel.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    self.headerLabel.textAlignment = NSTextAlignmentCenter;
    self.headerLabel.text = [self headerText];
    [self.view addSubview:self.headerLabel];

    // Body web view — UIWebView is the only thing that works on iOS 6.
    self.webView = [[UIWebView alloc] init];
    self.webView.delegate = self;
    self.webView.opaque = YES;
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.scalesPageToFit = NO;  // we control sizing via CSS
    [self.view addSubview:self.webView];

    [self.webView loadHTMLString:[self renderHTML] baseURL:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // Manual layout — works on iPhone 4S (320×480 portrait) through iPad
    // landscape (1024×768). Nav controller already accounts for nav bar
    // height, so self.view.bounds excludes that.
    CGRect b = self.view.bounds;
    CGFloat headerHeight = 36;
    self.headerLabel.frame = CGRectMake(0, 0, b.size.width, headerHeight);
    self.webView.frame = CGRectMake(0, headerHeight,
                                     b.size.width,
                                     b.size.height - headerHeight);
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)installTapped {
    void (^handler)(void) = [self.installHandler copy];
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler();
    }];
}

#pragma mark - Header text

- (NSString *)headerText {
    NSString *dateStr = @"";
    if (self.releaseDate) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterNoStyle;
        dateStr = [fmt stringFromDate:self.releaseDate];
    }
    // "v1.3 — released May 30, 2026"
    if (dateStr.length) {
        return [NSString stringWithFormat:T(@"update_notes.header_with_date"),
                  self.version ?: @"?", dateStr];
    }
    return [NSString stringWithFormat:T(@"update_notes.header_no_date"),
              self.version ?: @"?"];
}

#pragma mark - Markdown → HTML

// We don't bundle a markdown parser to stay light. Hand-rolled conversion is
// enough for our release notes (no nested lists, no tables, no images).
- (NSString *)renderHTML {
    NSMutableString *html = [NSMutableString string];

    // CSS:
    // - System sans-serif (Helvetica Neue on iOS 6, falls back to default on
    //   iOS 7+ via -apple-system).
    // - 14 pt body, comfortable line-height for reading on phone screens.
    // - Bold h2 a bit larger; code spans get a subtle background; links the
    //   AppDrop blue.
    [html appendString:@"<html><head><style>"];
    [html appendString:@"html,body{margin:0;padding:0;}"];
    [html appendString:@"body{"
                       @"font-family:-apple-system,'Helvetica Neue',Helvetica,sans-serif;"
                       @"font-size:14px;line-height:1.45;color:#222;"
                       @"padding:14px 16px 24px 16px;"
                       @"-webkit-text-size-adjust:100%;}"];
    [html appendString:@"h2{font-size:17px;margin:18px 0 6px 0;color:#111;}"];
    [html appendString:@"p{margin:8px 0;}"];
    [html appendString:@"ul{margin:6px 0 10px 0;padding-left:22px;}"];
    [html appendString:@"li{margin:3px 0;}"];
    [html appendString:@"code{font-family:Menlo,Courier,monospace;font-size:12px;"
                       @"background:#f1f1f3;padding:1px 5px;border-radius:3px;}"];
    [html appendString:@"strong,b{font-weight:600;}"];
    [html appendString:@"a{color:#137dd6;text-decoration:none;}"];
    [html appendString:@"em,i{font-style:italic;}"];
    [html appendString:@"</style></head><body>"];

    if (!self.notesMarkdown.length) {
        [html appendString:@"<p><em>"];
        [html appendString:[self htmlEscape:T(@"update_notes.empty")]];
        [html appendString:@"</em></p>"];
    } else {
        [html appendString:[self markdownToHTML:self.notesMarkdown]];
    }

    [html appendString:@"</body></html>"];
    return html;
}

- (NSString *)markdownToHTML:(NSString *)md {
    NSMutableString *out = [NSMutableString string];
    NSArray *lines = [md componentsSeparatedByString:@"\n"];
    BOOL inList = NO;
    BOOL pendingBlank = NO;

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];

        if (line.length == 0) {
            // Blank lines close any open list and act as paragraph separators.
            if (inList) {
                [out appendString:@"</ul>"];
                inList = NO;
            }
            pendingBlank = YES;
            continue;
        }

        // Heading: "## Foo" → <h2>Foo</h2>
        if ([line hasPrefix:@"## "]) {
            if (inList) { [out appendString:@"</ul>"]; inList = NO; }
            NSString *content = [line substringFromIndex:3];
            [out appendFormat:@"<h2>%@</h2>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }
        if ([line hasPrefix:@"# "]) {
            if (inList) { [out appendString:@"</ul>"]; inList = NO; }
            NSString *content = [line substringFromIndex:2];
            [out appendFormat:@"<h2>%@</h2>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }

        // Bullet: "- Foo" → <li>Foo</li> (wraps in <ul>)
        if ([line hasPrefix:@"- "]) {
            if (!inList) { [out appendString:@"<ul>"]; inList = YES; }
            NSString *content = [line substringFromIndex:2];
            [out appendFormat:@"<li>%@</li>", [self inlineMarkdown:content]];
            pendingBlank = NO;
            continue;
        }

        // Plain paragraph line.
        if (inList) { [out appendString:@"</ul>"]; inList = NO; }
        if (pendingBlank) {
            // Use <p> for proper paragraph spacing after a blank line.
            [out appendFormat:@"<p>%@</p>", [self inlineMarkdown:line]];
        } else {
            // Continuation — just append with a space.
            [out appendFormat:@" %@", [self inlineMarkdown:line]];
        }
        pendingBlank = NO;
    }
    if (inList) [out appendString:@"</ul>"];
    return out;
}

// Inline transforms: **bold**, `code`, [text](url). Escape HTML special chars
// AFTER these regex passes so the substitutions can use <b>/<code>/<a> tags
// without being escaped, but anything else stays safe.
- (NSString *)inlineMarkdown:(NSString *)s {
    // 1. HTML-escape first, but only the chars that conflict (we keep < and > out)
    s = [self htmlEscape:s];

    NSError *err = nil;
    // **bold** → <b>bold</b>
    NSRegularExpression *re;
    re = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*([^*]+)\\*\\*"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<b>$1</b>"];
    // `code` → <code>code</code>
    re = [NSRegularExpression regularExpressionWithPattern:@"`([^`]+)`"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<code>$1</code>"];
    // [text](url) → <a href="url">text</a>
    re = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]\\(([^)]+)\\)"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<a href=\"$2\">$1</a>"];
    // *italic* → <em>italic</em> (single asterisks, AFTER ** to avoid conflict)
    re = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\w*])\\*([^*]+)\\*(?![\\w*])"
                                                    options:0 error:&err];
    s = [re stringByReplacingMatchesInString:s options:0
                                        range:NSMakeRange(0, s.length)
                                  withTemplate:@"<em>$1</em>"];
    return s;
}

- (NSString *)htmlEscape:(NSString *)s {
    if (!s) return @"";
    NSMutableString *out = [s mutableCopy];
    // Order matters: & first so we don't double-escape.
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;"
                             options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;"
                             options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;"
                             options:0 range:NSMakeRange(0, out.length)];
    return out;
}

#pragma mark - UIWebViewDelegate

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request
                                            navigationType:(UIWebViewNavigationType)navigationType {
    // Allow the initial loadHTMLString to render; intercept any user-initiated
    // link tap and open it in mobile Safari instead of inside our modal.
    if (navigationType == UIWebViewNavigationTypeLinkClicked) {
        [[UIApplication sharedApplication] openURL:request.URL];
        return NO;
    }
    return YES;
}

#pragma mark - Rotation (iOS 6)

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

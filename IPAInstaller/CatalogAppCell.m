#import "CatalogAppCell.h"

@interface CatalogAppCell ()
@property (nonatomic, strong, readwrite) UIImageView *appIconView;
@property (nonatomic, strong, readwrite) UILabel     *appTitleLabel;
@property (nonatomic, strong, readwrite) UILabel     *appSubtitleLabel;
@end

@implementation CatalogAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                      reuseIdentifier:reuseIdentifier])) {
        // App icon — 44×44 thumbnail, left edge.
        self.appIconView = [[UIImageView alloc] init];
        self.appIconView.contentMode = UIViewContentModeScaleAspectFit;
        self.appIconView.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        [self.contentView addSubview:self.appIconView];

        // Title — bold, single line.
        self.appTitleLabel = [[UILabel alloc] init];
        self.appTitleLabel.font = [UIFont boldSystemFontOfSize:14];
        self.appTitleLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:self.appTitleLabel];

        // Subtitle — two lines, meta + filename.
        self.appSubtitleLabel = [[UILabel alloc] init];
        self.appSubtitleLabel.font = [UIFont systemFontOfSize:11];
        self.appSubtitleLabel.textColor = [UIColor darkGrayColor];
        self.appSubtitleLabel.numberOfLines = 2;
        self.appSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        self.appSubtitleLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:self.appSubtitleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat pad = 10;
    CGFloat iconSize = 44;

    // Left: icon, vertically centred.
    self.appIconView.frame = CGRectMake(pad,
                                          (b.size.height - iconSize) / 2,
                                          iconSize, iconSize);

    // Right: nothing (used to be the install button). The cell's accessoryType
    // (Checkmark in selection mode) is still drawn by UITableViewCell itself
    // in the trailing slot.
    CGFloat trailingInset = pad;
    if (self.accessoryType != UITableViewCellAccessoryNone) {
        trailingInset = 36;  // leave room for the system-drawn checkmark
    }

    // Center: text, taking the remaining width.
    CGFloat textX = pad + iconSize + pad;
    CGFloat textW = b.size.width - textX - trailingInset;
    self.appTitleLabel.frame    = CGRectMake(textX, 8,  textW, 18);
    self.appSubtitleLabel.frame = CGRectMake(textX, 28, textW, 40);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.appIconView.image = nil;
    self.appTitleLabel.text = nil;
    self.appSubtitleLabel.text = nil;
    self.accessoryType = UITableViewCellAccessoryNone;
}

@end

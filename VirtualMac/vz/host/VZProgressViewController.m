#import "VZProgressViewController.h"
#import "VZLocalization.h"

@interface VZProgressViewController ()
@property(nonatomic, retain) UILabel *statusLabel;
@property(nonatomic, retain) UILabel *detailLabel;
@property(nonatomic, retain) UIProgressView *progressView;
@property(nonatomic, retain) UIActivityIndicatorView *activity;
@property(nonatomic, retain) UITextView *consoleView;
@property(nonatomic, retain) UIImageView *heroImageView;
@property(nonatomic, retain) UILabel *heroTitleLabel;
@property(nonatomic, retain) UIView *tipContainer;
@property(nonatomic, retain) UILabel *tipLabel;
@end

@implementation VZProgressViewController

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super init])) {
        self.title = title;
        _statusText = [VZL(@"Preparing…") copy];
        _indeterminate = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
        action:@selector(cancel:)] autorelease];

    self.statusLabel = [[[UILabel alloc] init] autorelease];
    UIFont *headlineFont = [UIFont preferredFontForTextStyle:
        UIFontTextStyleHeadline];
    self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:
        headlineFont.pointSize weight:UIFontWeightSemibold];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel = [[[UILabel alloc] init] autorelease];
    UIFont *subheadlineFont = [UIFont preferredFontForTextStyle:
        UIFontTextStyleSubheadline];
    self.detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:
        subheadlineFont.pointSize weight:UIFontWeightRegular];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.numberOfLines = 0;
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView = [[[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault] autorelease];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.activity = [[[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium] autorelease];
    self.activity.translatesAutoresizingMaskIntoConstraints = NO;
    self.consoleView = [[[UITextView alloc] init] autorelease];
    self.consoleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.consoleView.editable = NO;
    self.consoleView.selectable = YES;
    self.consoleView.alwaysBounceVertical = YES;
    self.consoleView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.consoleView.textColor = UIColor.labelColor;
    self.consoleView.font = [UIFont monospacedSystemFontOfSize:10
        weight:UIFontWeightRegular];
    self.consoleView.layer.cornerRadius = 10;
    self.consoleView.layer.cornerCurve = kCACornerCurveContinuous;
    self.consoleView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.heroImageView = [[[UIImageView alloc] initWithImage:self.heroImage]
        autorelease];
    self.heroImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.heroTitleLabel = [[[UILabel alloc] init] autorelease];
    self.heroTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIFont *heroTitleFont = [UIFont preferredFontForTextStyle:
        UIFontTextStyleTitle3];
    self.heroTitleLabel.font = [UIFont systemFontOfSize:heroTitleFont.pointSize
                                                weight:UIFontWeightSemibold];
    self.heroTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.heroTitleLabel.numberOfLines = 2;
    for (UIView *view in @[self.statusLabel, self.detailLabel, self.progressView,
                           self.activity, self.consoleView])
        [self.view addSubview:view];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    if (self.heroImage) {
        self.statusLabel.hidden = YES;
        UIFont *detailFont = [UIFont preferredFontForTextStyle:
            UIFontTextStyleSubheadline];
        self.detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:
            detailFont.pointSize weight:UIFontWeightRegular];
        UIView *artworkContainer = [[[UIView alloc] init] autorelease];
        artworkContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [artworkContainer addSubview:self.heroImageView];
        self.tipContainer = [[[UIView alloc] init] autorelease];
        self.tipContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.tipContainer.backgroundColor = UIColor.quaternarySystemFillColor;
        self.tipContainer.layer.cornerRadius = 10.0;
        self.tipContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.tipLabel = [[[UILabel alloc] init] autorelease];
        self.tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.tipLabel.font = [UIFont preferredFontForTextStyle:
            UIFontTextStyleFootnote];
        self.tipLabel.textColor = UIColor.secondaryLabelColor;
        self.tipLabel.textAlignment = NSTextAlignmentCenter;
        self.tipLabel.numberOfLines = 0;
        [self.tipContainer addSubview:self.tipLabel];
        UIStackView *stack = [[[UIStackView alloc] initWithArrangedSubviews:
            @[artworkContainer, self.heroTitleLabel, self.progressView,
              self.detailLabel, self.tipContainer]] autorelease];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 8.0;
        [stack setCustomSpacing:14.0 afterView:artworkContainer];
        [stack setCustomSpacing:18.0 afterView:self.heroTitleLabel];
        [stack setCustomSpacing:16.0 afterView:self.progressView];
        [stack setCustomSpacing:24.0 afterView:self.detailLabel];
        [self.view addSubview:stack];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.detailLabel.textAlignment = NSTextAlignmentCenter;
        self.detailLabel.numberOfLines = 1;
        self.detailLabel.adjustsFontSizeToFitWidth = YES;
        self.detailLabel.minimumScaleFactor = 0.75;
        NSLayoutConstraint *adaptiveWidth = [stack.widthAnchor
            constraintEqualToAnchor:guide.widthAnchor constant:-48.0];
        adaptiveWidth.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor constant:-8.0],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:24.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-24.0],
            [stack.topAnchor constraintGreaterThanOrEqualToAnchor:guide.topAnchor constant:16.0],
            [stack.bottomAnchor constraintLessThanOrEqualToAnchor:guide.bottomAnchor constant:-20.0],
            [stack.widthAnchor constraintLessThanOrEqualToConstant:420.0],
            adaptiveWidth,
            [artworkContainer.heightAnchor constraintEqualToConstant:220.0],
            [self.heroImageView.centerXAnchor constraintEqualToAnchor:artworkContainer.centerXAnchor],
            [self.heroImageView.centerYAnchor constraintEqualToAnchor:artworkContainer.centerYAnchor
                                                            constant:-30.0],
            [self.heroImageView.widthAnchor constraintEqualToConstant:212.0],
            [self.heroImageView.heightAnchor constraintEqualToConstant:212.0],
            [self.tipLabel.leadingAnchor constraintEqualToAnchor:self.tipContainer.leadingAnchor
                                                        constant:14.0],
            [self.tipLabel.trailingAnchor constraintEqualToAnchor:self.tipContainer.trailingAnchor
                                                         constant:-14.0],
            [self.tipLabel.topAnchor constraintEqualToAnchor:self.tipContainer.topAnchor
                                                   constant:10.0],
            [self.tipLabel.bottomAnchor constraintEqualToAnchor:self.tipContainer.bottomAnchor
                                                      constant:-10.0],
            [self.activity.centerXAnchor constraintEqualToAnchor:self.progressView.centerXAnchor],
            [self.activity.centerYAnchor constraintEqualToAnchor:self.progressView.centerYAnchor],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [self.statusLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
            [self.statusLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],
            [self.statusLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
            [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
            [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
            [self.detailLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
            [self.progressView.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
            [self.progressView.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
            [self.progressView.topAnchor constraintEqualToAnchor:self.detailLabel.bottomAnchor constant:18],
            [self.activity.centerXAnchor constraintEqualToAnchor:self.progressView.centerXAnchor],
            [self.activity.centerYAnchor constraintEqualToAnchor:self.progressView.centerYAnchor],
            [self.consoleView.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
            [self.consoleView.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
            [self.consoleView.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:18],
            [self.consoleView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-20],
        ]];
    }
    self.preferredContentSize = CGSizeMake(620, 560);
    [self refresh];
}

- (void)cancel:(id)sender
{
    (void)sender;
    if (self.cancellationHandler) self.cancellationHandler();
}

- (void)refresh
{
    if (!self.isViewLoaded) return;
    self.statusLabel.text = self.statusText;
    self.heroImageView.image = self.heroImage;
    self.heroTitleLabel.text = self.heroTitleText;
    self.tipLabel.text = self.tipText;
    self.tipContainer.hidden = !self.tipText.length;
    self.detailLabel.text = self.detailText;
    self.detailLabel.hidden = !self.detailText.length;
    // The artwork layout reserves the progress track and metrics row before
    // the first response arrives, so presenting the sheet never recenters its
    // content when a determinate download begins.
    self.progressView.hidden = self.isIndeterminate && !self.heroImage;
    self.activity.hidden = !self.isIndeterminate;
    if (self.isIndeterminate) [self.activity startAnimating];
    else [self.activity stopAnimating];
    [self.progressView setProgress:self.progress animated:YES];
    self.consoleView.hidden = self.consoleHidden;
    if (![self.consoleView.text isEqualToString:self.consoleText]) {
        BOOL followsTail = self.consoleView.contentSize.height <= self.consoleView.bounds.size.height + 1 ||
            self.consoleView.contentOffset.y + self.consoleView.bounds.size.height >=
            self.consoleView.contentSize.height - 24;
        self.consoleView.text = self.consoleText ?: @"";
        if (followsTail && self.consoleText.length)
            [self.consoleView scrollRangeToVisible:NSMakeRange(self.consoleText.length - 1, 1)];
    }
}

- (void)setStatusText:(NSString *)value { if (_statusText != value) { [_statusText release]; _statusText = [value copy]; [self refresh]; } }
- (void)setDetailText:(NSString *)value { if (_detailText != value) { [_detailText release]; _detailText = [value copy]; [self refresh]; } }
- (void)setConsoleText:(NSString *)value { if (_consoleText != value) { [_consoleText release]; _consoleText = [value copy]; [self refresh]; } }
- (void)setProgress:(float)value { _progress = value; [self refresh]; }
- (void)setIndeterminate:(BOOL)value { _indeterminate = value; [self refresh]; }
- (void)setConsoleHidden:(BOOL)value { _consoleHidden = value; [self refresh]; }
- (void)setHeroImage:(UIImage *)value { if (_heroImage != value) { [_heroImage release]; _heroImage = [value retain]; [self refresh]; } }
- (void)setHeroTitleText:(NSString *)value { if (_heroTitleText != value) { [_heroTitleText release]; _heroTitleText = [value copy]; [self refresh]; } }
- (void)setTipText:(NSString *)value { if (_tipText != value) { [_tipText release]; _tipText = [value copy]; [self refresh]; } }

- (void)dealloc
{
    [_statusText release]; [_detailText release]; [_consoleText release];
    [_cancellationHandler release]; [_statusLabel release]; [_detailLabel release];
    [_progressView release]; [_activity release]; [_consoleView release];
    [_heroImage release]; [_heroTitleText release]; [_tipText release];
    [_heroImageView release]; [_heroTitleLabel release];
    [_tipContainer release]; [_tipLabel release];
    [super dealloc];
}
@end

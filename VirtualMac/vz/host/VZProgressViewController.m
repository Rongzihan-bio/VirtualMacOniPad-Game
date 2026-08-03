#import "VZProgressViewController.h"

@interface VZProgressViewController ()
@property(nonatomic, retain) UILabel *statusLabel;
@property(nonatomic, retain) UILabel *detailLabel;
@property(nonatomic, retain) UIProgressView *progressView;
@property(nonatomic, retain) UIActivityIndicatorView *activity;
@property(nonatomic, retain) UITextView *consoleView;
@end

@implementation VZProgressViewController

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super init])) {
        self.title = title;
        _statusText = [@"Preparing…" copy];
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
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel = [[[UILabel alloc] init] autorelease];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
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
    self.consoleView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    for (UIView *view in @[self.statusLabel, self.detailLabel, self.progressView,
                           self.activity, self.consoleView])
        [self.view addSubview:view];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
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
    self.detailLabel.text = self.detailText;
    self.detailLabel.hidden = !self.detailText.length;
    self.progressView.hidden = self.isIndeterminate;
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

- (void)dealloc
{
    [_statusText release]; [_detailText release]; [_consoleText release];
    [_cancellationHandler release]; [_statusLabel release]; [_detailLabel release];
    [_progressView release]; [_activity release]; [_consoleView release];
    [super dealloc];
}
@end

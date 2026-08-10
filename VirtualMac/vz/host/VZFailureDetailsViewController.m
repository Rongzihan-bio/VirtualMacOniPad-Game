#import "VZFailureDetailsViewController.h"
#import "VZDiagnostics.h"
#import "VZLocalization.h"
#import "VZSupport.h"

@interface VZFailureDetailsViewController ()
@property(nonatomic, copy) NSString *details;
@end

@implementation VZFailureDetailsViewController

- (instancetype)initWithTitle:(NSString *)title details:(NSString *)details
{
    if ((self = [super init])) {
        self.title = title;
        self.details = details;
    }
    return self;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:
        UIFontTextStyleHeadline];
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 10.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action
        forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
        action:@selector(done:)] autorelease];

    UITextView *detailsView = [[[UITextView alloc] init] autorelease];
    detailsView.translatesAutoresizingMaskIntoConstraints = NO;
    detailsView.editable = NO;
    detailsView.selectable = YES;
    detailsView.alwaysBounceVertical = YES;
    detailsView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    detailsView.font = [UIFont monospacedSystemFontOfSize:11.0
        weight:UIFontWeightRegular];
    detailsView.text = self.details;
    detailsView.layer.cornerRadius = 12.0;
    detailsView.layer.cornerCurve = kCACornerCurveContinuous;
    detailsView.textContainerInset = UIEdgeInsetsMake(14, 14, 14, 14);
    [self.view addSubview:detailsView];

    UIButton *export = [self actionButtonWithTitle:VZL(@"Export Diagnostics")
        action:@selector(exportDiagnostics:)];
    UIButton *help = [self actionButtonWithTitle:VZL(@"Get Help")
        action:@selector(getHelp:)];
    UIButton *report = [self actionButtonWithTitle:VZL(@"Report Issue")
        action:@selector(reportIssue:)];
    UIStackView *actions = [[[UIStackView alloc]
        initWithArrangedSubviews:@[export, help, report]] autorelease];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisVertical;
    actions.alignment = UIStackViewAlignmentFill;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 10.0;
    [self.view addSubview:actions];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [detailsView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor
                                                  constant:20.0],
        [detailsView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor
                                                   constant:-20.0],
        [detailsView.topAnchor constraintEqualToAnchor:guide.topAnchor
                                              constant:16.0],
        [detailsView.bottomAnchor constraintEqualToAnchor:actions.topAnchor
                                                 constant:-16.0],
        [actions.leadingAnchor constraintEqualToAnchor:detailsView.leadingAnchor],
        [actions.trailingAnchor constraintEqualToAnchor:detailsView.trailingAnchor],
        [actions.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor
                                             constant:-20.0],
        [actions.heightAnchor constraintEqualToConstant:158.0],
    ]];
    self.preferredContentSize = CGSizeMake(640, 620);
}

- (void)done:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)exportDiagnostics:(id)sender
{
    (void)sender;
    NSError *error = nil;
    NSURL *archive = VZCreateDiagnosticsArchive(&error);
    if (!archive) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:VZL(@"Couldn’t Export Diagnostics")
                             message:error.localizedDescription
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIDocumentPickerViewController *picker =
        [[[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[archive] asCopy:YES] autorelease];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)getHelp:(id)sender
{
    (void)sender;
    VZOpenSupportURL(VZGetHelpURLString);
}

- (void)reportIssue:(id)sender
{
    (void)sender;
    VZOpenSupportURL(VZReportIssueURLString);
}

- (void)dealloc
{
    [_details release];
    [super dealloc];
}

@end

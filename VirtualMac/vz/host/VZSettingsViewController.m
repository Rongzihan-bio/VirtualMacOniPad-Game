#import "VZSettingsViewController.h"
#import "VZAppSettings.h"
#import "VZDiagnostics.h"
#import "VZGamepadSettingsViewController.h"
#import "VZGamepadBridge.h"
#import "VZLocalization.h"
#import "VZSupport.h"
#import "VZVMLibraryViewController.h"

@interface VZContributorChip : UIControl
@property(nonatomic, copy) NSString *urlString;
- (instancetype)initWithName:(NSString *)name imageName:(NSString *)imageName
                          url:(NSString *)url;
@end

@implementation VZContributorChip
- (instancetype)initWithName:(NSString *)name imageName:(NSString *)imageName
                          url:(NSString *)url
{
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.urlString = url;
    self.backgroundColor = UIColor.clearColor;
    NSString *path = [NSBundle.mainBundle pathForResource:
        imageName.stringByDeletingPathExtension ofType:imageName.pathExtension
        inDirectory:@"Developers"];
    UIImageView *avatar = [[[UIImageView alloc] initWithImage:
        [UIImage imageWithContentsOfFile:path]] autorelease];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.layer.cornerRadius = 14.0;
    avatar.layer.masksToBounds = YES;
    [avatar.widthAnchor constraintEqualToConstant:28].active = YES;
    [avatar.heightAnchor constraintEqualToConstant:28].active = YES;
    UILabel *label = [[[UILabel alloc] init] autorelease];
    label.text = name;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    UIStackView *stack = [[[UIStackView alloc] initWithArrangedSubviews:
        @[avatar, label]] autorelease];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 7;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.userInteractionEnabled = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
    ]];
    [self addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)open:(id)sender { (void)sender; VZOpenSupportURL(self.urlString); }
- (void)dealloc { [_urlString release]; [super dealloc]; }
@end

@interface VZSettingsViewController ()
@property(nonatomic, retain) NSArray<NSDictionary *> *machines;
@end

@implementation VZSettingsViewController

- (instancetype)initWithMachines:(NSArray<NSDictionary *> *)machines
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
        _machines = [machines copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = VZL(@"Settings");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44.0;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
        action:@selector(done:)] autorelease];
}

- (void)done:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 7;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 2 : section == 1 ? 11 : section == 2 ? 3 :
        section == 3 ? 3 : section == 4 ? 2 : section == 5 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return @[VZL(@"General"), VZL(@"Input While a Virtual Mac Is Running"),
             VZL(@"Compatibility"), VZL(@"Storage"), VZL(@"About"),
             VZL(@"Support"), VZL(@"Developers")][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 5)
        return [NSString stringWithFormat:VZL(@"Virtual Mac devices are stored in %@."), VZVMLibraryPath()];
    if (section == 1)
        return VZL(@"These options affect iPadOS only while Virtual Mac is frontmost and a Virtual Mac is running.");
    if (section == 2)
        return VZL(@"Keyboard Crash Workaround takes effect the next time Virtual Mac opens. Debug Logging takes effect the next time a Virtual Mac starts.");
    return nil;
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView identifier:(NSString *)identifier
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
            reuseIdentifier:identifier] autorelease];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VZAppSettings *settings = VZAppSettings.sharedSettings;
    UITableViewCell *cell = [self baseCellForTableView:tableView identifier:@"setting"];
    if (indexPath.section == 6) {
        NSArray *people = @[
            @{@"name": @"nfzerox", @"url": @"https://github.com/nfzerox", @"image": @"nfzerox.png"},
            @{@"name": @"qwqVictor", @"url": @"https://github.com/qwqVictor", @"image": @"qwqVictor.jpg"},
            @{@"name": @"jamesy0ung", @"url": @"https://github.com/jamesy0ung", @"image": @"jamesy0ung.jpg"}
        ];
        cell = [self baseCellForTableView:tableView identifier:@"contributors"];
        for (UIView *view in cell.contentView.subviews)
            if (view.tag == 1101) [view removeFromSuperview];
        NSMutableArray *chips = [NSMutableArray array];
        for (NSDictionary *person in people) {
            VZContributorChip *chip = [[[VZContributorChip alloc]
                initWithName:person[@"name"] imageName:person[@"image"]
                url:person[@"url"]] autorelease];
            [chips addObject:chip];
        }
        UIStackView *stack = [[[UIStackView alloc]
            initWithArrangedSubviews:chips] autorelease];
        stack.tag = 1101;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.spacing = 12;
        stack.distribution = UIStackViewDistributionFill;
        [cell.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Start on Launch");
        NSString *path = [settings stringForKey:VZAutoBootVMPathKey];
        NSString *identifier = [settings stringForKey:VZAutoBootVMIdentifierKey];
        NSDictionary *selected = nil;
        for (NSDictionary *machine in self.machines)
            if ([machine[@"path"] isEqualToString:path] ||
                (identifier.length && [VZVMStableIdentifier(machine[@"path"])
                    isEqualToString:identifier])) selected = machine;
        cell.detailTextLabel.text = selected[@"name"] ?: VZL(@"Show Library");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = VZL(@"Virtual Mac Display");
        cell.detailTextLabel.text = [[settings stringForKey:VZDisplayScalingKey]
            isEqualToString:@"fill"] ? VZL(@"Fill Window") : VZL(@"Fit in Window");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row < 8) {
        NSArray *titles = @[VZL(@"Mac Keyboard Shortcuts"), VZL(@"Suppress iPadOS System Edge Gestures"),
                   VZL(@"Suppress iPadOS Multitasking Gestures"), VZL(@"Suppress iPadOS Home Indicator"),
                   VZL(@"Accommodate Finger Double-Taps"), VZL(@"Two-Finger Touch Scrolling"),
                   VZL(@"Two-Finger Tap for Secondary Click"), VZL(@"Touch and Hold for Secondary Click")];
        NSArray *keys = @[VZKeyboardShortcutCaptureKey, VZSystemGestureSuppressionKey,
                          VZMultitaskingGestureSuppressionKey, VZHomeIndicatorSuppressionKey,
                          VZTouchDoubleTapAccommodationKey, VZTouchTwoFingerScrollingKey,
                          VZTouchTwoFingerRightClickKey, VZTouchLongPressRightClickKey];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = indexPath.row;
        toggle.on = [settings boolForKey:keys[indexPath.row]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row == 8) {
        cell.textLabel.text = [NSString stringWithUTF8String:
            "Network Gamepad Relay"];
        NSDictionary *state = [[VZGamepadBridge sharedBridge] stateSnapshot];
        cell.detailTextLabel.text = [state[@"controllerConnected"] boolValue]
            ? [NSString stringWithUTF8String:"Controller Connected"]
            : [NSString stringWithUTF8String:"No Controller"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row == 9) {
        cell.textLabel.text = VZL(@"Virtual Mac Controls");
        NSDictionary *names = @{@"automatic": VZL(@"Automatic"), @"always": VZL(@"Always Visible"),
                                @"hidden": VZL(@"Always Hidden")};
        cell.detailTextLabel.text = names[[settings stringForKey:VZHUDVisibilityKey]] ?: VZL(@"Automatic");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = VZL(@"Controls Opacity");
        UISlider *slider = [[[UISlider alloc] initWithFrame:
            CGRectMake(0, 0, 180, 32)] autorelease];
        slider.minimumValue = 0.0;
        slider.maximumValue = 1.0;
        slider.value = [[settings stringForKey:VZHUDOpacityKey] floatValue];
        [slider addTarget:self action:@selector(hudOpacityChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2 && indexPath.row < 3) {
        NSArray *titles = @[VZL(@"Keyboard Crash Workaround"),
                            VZL(@"Recover Networking After Sleep"),
                            VZL(@"Debug Logging")];
        NSArray *keys = @[VZIPadOS162KeyboardWorkaroundKey,
                          VZNetworkResumeRecoveryKey,
                          VZDebugLoggingKey];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = 100 + indexPath.row;
        toggle.on = [settings boolForKey:keys[indexPath.row]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = VZL(@"Delete IPSW After Successful Installation");
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [settings boolForKey:VZAutoDeleteRestoreImageKey];
        [toggle addTarget:self action:@selector(autoDeleteToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 3) {
        NSArray *paths = indexPath.row == 1 ? VZInstallationArtifactPaths()
                                            : VZCachedRestoreImagePaths();
        cell.textLabel.text = indexPath.row == 1 ? VZL(@"Delete Temporary Installation Files")
                                                 : VZL(@"Delete Cached Install Images");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)paths.count];
        cell.textLabel.textColor = paths.count ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = paths.count ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *version = info[@"CFBundleShortVersionString"] ?: @"—";
        NSString *build = info[@"CFBundleVersion"] ?: @"—";
        cell.textLabel.text = VZL(@"Version");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
            version, build];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 4) {
        cell.textLabel.text = VZL(@"Reset Settings");
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    } else if (indexPath.section == 5) {
        NSArray *titles = @[VZL(@"Copy Library Path"), VZL(@"Export Diagnostics"),
                            VZL(@"Get Help"), VZL(@"Report Issue")];
        NSArray *images = @[@"doc.on.doc", @"square.and.arrow.up",
                            @"questionmark.circle", @"exclamationmark.bubble"];
        cell.textLabel.text = titles[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:images[indexPath.row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)inputToggleChanged:(UISwitch *)sender
{
    NSArray *keys = @[VZKeyboardShortcutCaptureKey, VZSystemGestureSuppressionKey,
                      VZMultitaskingGestureSuppressionKey, VZHomeIndicatorSuppressionKey,
                      VZTouchDoubleTapAccommodationKey, VZTouchTwoFingerScrollingKey,
                      VZTouchTwoFingerRightClickKey, VZTouchLongPressRightClickKey];
    NSArray *compatibilityKeys = @[VZIPadOS162KeyboardWorkaroundKey,
                                   VZNetworkResumeRecoveryKey,
                                   VZDebugLoggingKey];
    NSString *key = sender.tag >= 100 ? compatibilityKeys[sender.tag - 100]
                                      : keys[sender.tag];
    [VZAppSettings.sharedSettings setBool:sender.on forKey:key];
}

- (void)chooseDisplayScalingFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:VZL(@"Virtual Mac Display")
        message:VZL(@"Fit in Window shows the entire display. Fill Window crops its edges when the window has a different shape.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[VZL(@"Fit in Window"), VZL(@"Fill Window")];
    NSArray *values = @[@"fit", @"fill"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index]
                    forKey:VZDisplayScalingKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)autoDeleteToggleChanged:(UISwitch *)sender
{
    [VZAppSettings.sharedSettings setBool:sender.on forKey:VZAutoDeleteRestoreImageKey];
}

- (void)hudOpacityChanged:(UISlider *)sender
{
    [VZAppSettings.sharedSettings setString:
        [NSString stringWithFormat:@"%.2f", sender.value]
        forKey:VZHUDOpacityKey];
}

- (void)chooseHUDVisibilityFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:VZL(@"Virtual Mac Controls")
        message:VZL(@"Automatic hides the controls when an external keyboard and pointing device are connected.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[VZL(@"Automatic"), VZL(@"Always Visible"), VZL(@"Always Hidden")];
    NSArray *values = @[@"automatic", @"always", @"hidden"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index] forKey:VZHUDVisibilityKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseAutoBootFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:VZL(@"Start on Launch")
        message:VZL(@"Choose whether Virtual Mac opens its library or starts a Virtual Mac.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Show Library")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMIdentifierKey];
            [self.tableView reloadData];
        }]];
    for (NSDictionary *machine in self.machines) {
        [picker addAction:[UIAlertAction actionWithTitle:machine[@"name"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:machine[@"path"] forKey:VZAutoBootVMPathKey];
                [VZAppSettings.sharedSettings setString:VZVMStableIdentifier(machine[@"path"])
                                                   forKey:VZAutoBootVMIdentifierKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmDeletePaths:(NSArray<NSString *> *)paths title:(NSString *)title
{
    if (!paths.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:VZL(@"Complete Virtual Mac devices and restore images outside Virtual Mac are not removed.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Delete") style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            VZRemovePaths(paths);
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmResetSettings
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Reset Settings?")
        message:VZL(@"This restores all Virtual Mac settings to their defaults. Virtual Macs, restore images, and installation files won’t be removed.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Reset")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings resetToDefaults];
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportDiagnosticsFrom:(UITableViewCell *)cell
{
    UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]
        autorelease];
    cell.accessoryView = spinner;
    cell.userInteractionEnabled = NO;
    [spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *archive = VZCreateDiagnosticsArchive(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.userInteractionEnabled = YES;
            if (!archive) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:VZL(@"Couldn’t Export Diagnostics")
                    message:error.localizedDescription ?:
                        VZL(@"The diagnostics archive could not be created.")
                    preferredStyle:UIAlertControllerStyleAlert];
                VZAddFailureSupportActions(alert);
                [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            // The activity sheet initializes Core Image to draw the AirDrop
            // activity icon. That crashes on iPadOS 16 while Virtual Mac's
            // extracted graphics stack is loaded. The Files exporter is the
            // native file-save UI and does not enter that unsafe code path.
            UIDocumentPickerViewController *picker =
                [[[UIDocumentPickerViewController alloc]
                  initForExportingURLs:@[archive] asCopy:YES] autorelease];
            [self presentViewController:picker animated:YES completion:nil];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 0)
        [self chooseAutoBootFrom:cell];
    else if (indexPath.section == 0 && indexPath.row == 1)
        [self chooseDisplayScalingFrom:cell];
    else if (indexPath.section == 5 && indexPath.row == 0) {
        UIPasteboard.generalPasteboard.string = VZVMLibraryPath();
        UINotificationFeedbackGenerator *feedback = [[[UINotificationFeedbackGenerator alloc] init] autorelease];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (indexPath.section == 1 && indexPath.row == 8) {
        VZGamepadSettingsViewController *gamepad =
            [[[VZGamepadSettingsViewController alloc] init] autorelease];
        [self.navigationController pushViewController:gamepad animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 9)
        [self chooseHUDVisibilityFrom:cell];
    else if (indexPath.section == 3 && indexPath.row == 1)
        [self confirmDeletePaths:VZInstallationArtifactPaths() title:VZL(@"Delete Temporary Installation Files?")];
    else if (indexPath.section == 3 && indexPath.row == 2)
        [self confirmDeletePaths:VZCachedRestoreImagePaths() title:VZL(@"Delete Cached Install Images?")];
    else if (indexPath.section == 5 && indexPath.row == 1)
        [self exportDiagnosticsFrom:cell];
    else if (indexPath.section == 4 && indexPath.row == 1)
        [self confirmResetSettings];
    else if (indexPath.section == 5 && indexPath.row >= 2)
        VZOpenSupportURL(indexPath.row == 2 ? VZGetHelpURLString : VZReportIssueURLString);
}

- (void)dealloc
{
    [_machines release];
    [super dealloc];
}

@end

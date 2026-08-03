#import "VZSettingsViewController.h"
#import "VZAppSettings.h"
#import "VZVMLibraryViewController.h"

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
    self.title = @"Settings";
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
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 3 : section == 1 ? 5 : section == 2 ? 1 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return @[@"General", @"Input While a Virtual Mac Is Running", @"Diagnostics", @"Storage"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0)
        return [NSString stringWithFormat:@"Virtual Mac devices are stored in %@.", VZVMLibraryPath()];
    if (section == 1)
        return @"These options affect iPadOS only while Virtual Mac is frontmost and a virtual Mac is running.";
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
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Start on Launch";
        NSString *path = [settings stringForKey:VZAutoBootVMPathKey];
        NSString *identifier = [settings stringForKey:VZAutoBootVMIdentifierKey];
        NSDictionary *selected = nil;
        for (NSDictionary *machine in self.machines)
            if ([machine[@"path"] isEqualToString:path] ||
                (identifier.length && [VZVMStableIdentifier(machine[@"path"])
                    isEqualToString:identifier])) selected = machine;
        cell.detailTextLabel.text = selected[@"name"] ?: @"Show Library";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"Virtual Mac Display";
        cell.detailTextLabel.text = [[settings stringForKey:VZDisplayScalingKey]
            isEqualToString:@"fill"] ? @"Fill Window" : @"Fit in Window";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Copy Library Path";
        cell.imageView.image = [UIImage systemImageNamed:@"doc.on.doc"];
    } else if (indexPath.section == 1 && indexPath.row < 4) {
        NSArray *titles = @[@"Mac Keyboard Shortcuts", @"Suppress iPadOS System Edge Gestures",
                            @"Suppress iPadOS Multitasking Gestures", @"Suppress iPadOS Home Indicator"];
        NSArray *keys = @[VZKeyboardShortcutCaptureKey, VZSystemGestureSuppressionKey,
                          VZMultitaskingGestureSuppressionKey, VZHomeIndicatorSuppressionKey];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.tag = indexPath.row;
        toggle.on = [settings boolForKey:keys[indexPath.row]];
        [toggle addTarget:self action:@selector(inputToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Virtual Mac Controls";
        NSDictionary *names = @{@"automatic": @"Automatic", @"always": @"Always Visible",
                                @"hidden": @"Always Hidden"};
        cell.detailTextLabel.text = names[[settings stringForKey:VZHUDVisibilityKey]] ?: @"Automatic";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"Show Virtual Mac Status Overlay";
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [settings boolForKey:VZShowStatusLabelKey];
        [toggle addTarget:self action:@selector(statusToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Delete IPSW After Installation";
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [settings boolForKey:VZAutoDeleteRestoreImageKey];
        [toggle addTarget:self action:@selector(autoDeleteToggleChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray *paths = indexPath.row == 1 ? VZInstallationArtifactPaths()
                                            : VZCachedRestoreImagePaths();
        cell.textLabel.text = indexPath.row == 1 ? @"Delete Installation Artifacts"
                                                 : @"Delete Cached Restore Images";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)paths.count];
        cell.textLabel.textColor = paths.count ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = paths.count ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)inputToggleChanged:(UISwitch *)sender
{
    NSArray *keys = @[VZKeyboardShortcutCaptureKey, VZSystemGestureSuppressionKey,
                      VZMultitaskingGestureSuppressionKey, VZHomeIndicatorSuppressionKey];
    [VZAppSettings.sharedSettings setBool:sender.on forKey:keys[sender.tag]];
}

- (void)chooseDisplayScalingFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:@"Virtual Mac Display"
        message:@"Fit in Window shows the entire display. Fill Window crops its edges when the window has a different shape."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"Fit in Window", @"Fill Window"];
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
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)statusToggleChanged:(UISwitch *)sender
{
    [VZAppSettings.sharedSettings setBool:sender.on forKey:VZShowStatusLabelKey];
}

- (void)autoDeleteToggleChanged:(UISwitch *)sender
{
    [VZAppSettings.sharedSettings setBool:sender.on forKey:VZAutoDeleteRestoreImageKey];
}

- (void)chooseHUDVisibilityFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Virtual Mac Controls"
        message:@"Automatic hides the controls when an external keyboard and pointing device are connected."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"Automatic", @"Always Visible", @"Always Hidden"];
    NSArray *values = @[@"automatic", @"always", @"hidden"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [picker addAction:[UIAlertAction actionWithTitle:titles[index]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [VZAppSettings.sharedSettings setString:values[index] forKey:VZHUDVisibilityKey];
                [self.tableView reloadData];
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseAutoBootFrom:(UITableViewCell *)cell
{
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Start on Launch"
        message:@"Choose whether Virtual Mac opens its library or starts a virtual Mac."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [picker addAction:[UIAlertAction actionWithTitle:@"Show Library"
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
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = cell;
    picker.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmDeletePaths:(NSArray<NSString *> *)paths title:(NSString *)title
{
    if (!paths.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"Complete virtual Mac devices and restore images outside Virtual Mac are not removed."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            VZRemovePaths(paths);
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 0)
        [self chooseAutoBootFrom:cell];
    else if (indexPath.section == 0 && indexPath.row == 1)
        [self chooseDisplayScalingFrom:cell];
    else if (indexPath.section == 0 && indexPath.row == 2) {
        UIPasteboard.generalPasteboard.string = VZVMLibraryPath();
        UINotificationFeedbackGenerator *feedback = [[[UINotificationFeedbackGenerator alloc] init] autorelease];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (indexPath.section == 1 && indexPath.row == 4)
        [self chooseHUDVisibilityFrom:cell];
    else if (indexPath.section == 3 && indexPath.row == 1)
        [self confirmDeletePaths:VZInstallationArtifactPaths() title:@"Delete Installation Artifacts?"];
    else if (indexPath.section == 3 && indexPath.row == 2)
        [self confirmDeletePaths:VZCachedRestoreImagePaths() title:@"Delete Cached Restore Images?"];
}

- (void)dealloc
{
    [_machines release];
    [super dealloc];
}

@end

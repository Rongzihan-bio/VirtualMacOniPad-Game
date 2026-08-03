#import "VZNewVMViewController.h"
#import "VZRestoreCatalog.h"

@interface VZRestoreCatalogViewController : UITableViewController
@property(nonatomic, retain) NSArray<NSDictionary *> *images;
@property(nonatomic, retain) NSArray<NSString *> *groups;
@property(nonatomic, copy) void (^selection)(NSDictionary *image);
@property(nonatomic, assign) BOOL showMinorReleases;
@property(nonatomic, assign) BOOL showDeveloperBetas;
@end

@implementation VZRestoreCatalogViewController
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.groups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; NSString *group = self.groups[section];
    return [[self imagesForGroup:group] count];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[self filterMenu]] autorelease];
}
- (UIMenu *)filterMenu {
    UIAction *minor = [UIAction actionWithTitle:@"Show Minor Releases"
        image:nil identifier:nil handler:^(__kindof UIAction *action) {
        (void)action; self.showMinorReleases = !self.showMinorReleases;
        self.navigationItem.rightBarButtonItem.menu = [self filterMenu];
        [self.tableView reloadData];
    }];
    minor.state = self.showMinorReleases ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *betas = [UIAction actionWithTitle:@"Show Developer Betas"
        image:nil identifier:nil handler:^(__kindof UIAction *action) {
        (void)action; self.showDeveloperBetas = !self.showDeveloperBetas;
        self.navigationItem.rightBarButtonItem.menu = [self filterMenu];
        [self.tableView reloadData];
    }];
    betas.state = self.showDeveloperBetas ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"Available Restore Images"
        children:@[minor, betas]];
}
- (NSArray *)imagesForGroup:(NSString *)group {
    if ([group isEqualToString:@"recommended"]) {
        NSDictionary *recommended = [VZRestoreCatalog
            recommendedImageFromImages:self.images];
        return recommended ? @[recommended] : @[];
    }
    NSArray *matches = [self.images filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *image, NSDictionary *bindings) {
            (void)bindings;
            NSDictionary *recommended = [VZRestoreCatalog
                recommendedImageFromImages:self.images];
            return [image[@"group"] isEqualToString:group] &&
                ![image[@"url"] isEqualToString:recommended[@"url"]];
        }]];
    NSArray *sorted = [matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL leftRelease = [left[@"channel"] isEqualToString:@"regular"];
        BOOL rightRelease = [right[@"channel"] isEqualToString:@"regular"];
        if (leftRelease != rightRelease) return leftRelease ? NSOrderedAscending : NSOrderedDescending;
        return [right[@"version"] compare:left[@"version"] options:NSNumericSearch];
    }];
    NSMutableArray *releases = [NSMutableArray array];
    NSMutableArray *betas = [NSMutableArray array];
    for (NSDictionary *image in sorted) {
        NSMutableArray *bucket = [image[@"channel"] isEqualToString:@"regular"] ? releases : betas;
        [bucket addObject:image];
    }
    NSMutableArray *visible = [NSMutableArray array];
    if (self.showMinorReleases)
        [visible addObjectsFromArray:releases];
    else if (releases.count)
        [visible addObject:releases.firstObject];
    if (self.showDeveloperBetas)
        [visible addObjectsFromArray:betas];
    else if (!releases.count && betas.count)
        [visible addObject:betas.firstObject];
    return visible;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; NSString *group = self.groups[section];
    if ([group isEqualToString:@"recommended"])
        return @"Recommended";
    NSDictionary *names = @{@"sequoia":@"macOS Sequoia", @"sonoma":@"macOS Sonoma",
        @"ventura":@"macOS Ventura", @"monterey":@"macOS Monterey",
        @"tahoe":@"macOS Tahoe — Experimental", @"goldengate":@"macOS Golden Gate — Experimental"};
    return names[group] ?: group.capitalizedString;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"image"];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"image"] autorelease];
    NSDictionary *image = [self imagesForGroup:self.groups[indexPath.section]][indexPath.row];
    cell.imageView.image = nil;
    cell.textLabel.text = image[@"name"];
    NSByteCountFormatter *formatter = [[[NSByteCountFormatter alloc] init] autorelease];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    NSString *channel = [image[@"channel"] isEqualToString:@"regular"] ? @"Release" : @"Developer Beta";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Build %@ · %@ · %@", image[@"build"], channel,
        [formatter stringFromByteCount:[image[@"downloadSize"] longLongValue]]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *image = [self imagesForGroup:self.groups[indexPath.section]][indexPath.row];
    if (self.selection) self.selection(image);
}
- (void)dealloc { [_images release]; [_groups release]; [_selection release]; [super dealloc]; }
@end

@interface VZNewVMViewController ()
@property(nonatomic, retain) NSArray<NSDictionary *> *catalog;
@property(nonatomic, retain) UIActivityIndicatorView *activity;
@end

@implementation VZNewVMViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"New Virtual Mac";
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemCancel target:self action:@selector(cancel:)] autorelease];
    self.activity = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium] autorelease];
    [self.activity startAnimating];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithCustomView:self.activity] autorelease];
    [VZRestoreCatalog loadWithCompletion:^(NSArray<NSDictionary *> *images, NSError *error) {
        self.catalog = images;
        [self.activity stopAnimating];
        self.navigationItem.rightBarButtonItem = nil;
        [self.tableView reloadData];
        if (error) NSLog(@"Virtual Mac restore catalog fallback failed: %@", error);
    }];
}
- (void)cancel:(id)sender { (void)sender; [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section; return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"You can also copy an existing Virtual Mac bundle to /var/mobile/Media/VirtualMac using an app such as iMazing or Filza.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice"];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"choice"] autorelease];
    NSArray *titles = @[@"Install Recommended macOS", @"Install macOS", @"Choose an IPSW"];
    NSArray *details = @[@"Download and install the latest macOS Sequoia release",
        @"Choose a macOS release or developer beta", @"Use an IPSW on this iPad"];
    NSArray *icons = @[@"checkmark.seal.fill", @"arrow.down.circle", @"doc.badge.plus"];
    cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row];
    cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = (indexPath.row < 2 && !self.catalog.count) ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.textLabel.enabled = cell.selectionStyle != UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        NSDictionary *recommended = [VZRestoreCatalog recommendedImageFromImages:self.catalog];
        if (recommended) [self.delegate newVMController:self downloadRestoreImage:recommended];
    } else if (indexPath.row == 1 && self.catalog.count) {
        VZRestoreCatalogViewController *catalog = [[[VZRestoreCatalogViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] autorelease];
        catalog.title = @"Install macOS"; catalog.images = self.catalog;
        NSMutableArray *groups = [NSMutableArray arrayWithObject:@"recommended"];
        [groups addObjectsFromArray:[VZRestoreCatalog orderedGroupsForImages:self.catalog]];
        catalog.groups = groups;
        catalog.selection = ^(NSDictionary *image) { [self.delegate newVMController:self downloadRestoreImage:image]; };
        [self.navigationController pushViewController:catalog animated:YES];
    } else if (indexPath.row == 2) [self.delegate newVMControllerChooseLocalRestoreImage:self];
}
- (void)dealloc { [_catalog release]; [_activity release]; [super dealloc]; }
@end

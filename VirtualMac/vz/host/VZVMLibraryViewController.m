#import "VZVMLibraryViewController.h"
#import "VZAppSettings.h"
#import "VZSettingsViewController.h"
#import "VZNewVMViewController.h"
#import "VZProgressViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <ifaddrs.h>
#include <errno.h>
#include <netinet/in.h>
#include <net/if.h>
#include <limits.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern char **environ;

NSString * const VZVMConfigurationFileName = @"VirtualMac.plist";

static NSString * const VZCPUCountKey = @"CPUCount";
static NSString * const VZMemorySizeKey = @"MemorySize";
static NSString * const VZStorageSizeKey = @"StorageSize";
static NSString * const VZNetworkModeKey = @"NetworkMode";
static NSString * const VZBridgeInterfaceKey = @"BridgeInterface";
static NSString * const VZBootRecoveryKey = @"BootRecovery";
static NSString * const VZSharedDirectoriesKey = @"SharedDirectories";
static NSString * const VZPointingDeviceKey = @"PointingDevice";
static NSString * const VZKeyboardDeviceKey = @"KeyboardDevice";
static NSString * const VZAudioOutputEnabledKey = @"AudioOutputEnabled";
static NSString * const VZAudioInputEnabledKey = @"AudioInputEnabled";
static NSString * const VZVideoToolboxEnabledKey = @"VideoToolboxEnabled";
static NSString * const VZDisplayModeKey = @"DisplayMode";
static NSString * const VZDisplayWidthKey = @"DisplayWidth";
static NSString * const VZDisplayHeightKey = @"DisplayHeight";
static NSString * const VZDisplayPPIKey = @"DisplayPixelsPerInch";
static NSString * const VZMACAddressKey = @"MACAddress";
static NSString * const VZVMNameKey = @"VMName";

static uint64_t GiB(uint64_t value)
{
    return value << 30;
}

NSString *VZVMLibraryPath(void)
{
    return VZVMSupportPath();
}

NSString *VZVMSupportPath(void)
{
    return @"/var/mobile/Media/VirtualMac";
}

NSString *VZRestoreImagesPath(void)
{
    return [VZVMSupportPath() stringByAppendingPathComponent:@"Restore Images"];
}

NSString *VZInstallationsPath(void)
{
    return [VZVMSupportPath() stringByAppendingPathComponent:@"Installations"];
}

static uint64_t VZDeviceMemoryLimit(void)
{
    uint64_t physical = NSProcessInfo.processInfo.physicalMemory;
    return physical >= GiB(12) ? GiB(8) : GiB(6);
}

static uint64_t VZDefaultStorageSize(void)
{
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZVMLibraryPath() error:nil];
    uint64_t total = [attributes[NSFileSystemSize] unsignedLongLongValue];
    return total && total <= GiB(64) ? GiB(32) : GiB(64);
}

static uint64_t VZAvailableStorageSize(void)
{
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZVMLibraryPath() error:nil];
    return [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
}

static NSString *VZMACStringFromBytes(const uint8_t bytes[6])
{
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
}

static NSString *VZRandomMACAddress(void)
{
    uint8_t bytes[6];
    arc4random_buf(bytes, sizeof(bytes));
    bytes[0] = (bytes[0] | 0x02) & 0xfe;
    return VZMACStringFromBytes(bytes);
}

static NSString *VZMACAddressForBundle(NSString *bundlePath)
{
    NSData *identifier = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"MachineIdentifier"]];
    const uint8_t *contents = identifier.bytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger index = 0; index < identifier.length; index++) {
        hash ^= contents[index];
        hash *= UINT64_C(1099511628211);
    }
    if (!identifier.length) {
        const char *path = bundlePath.fileSystemRepresentation;
        for (; path && *path; path++) {
            hash ^= (uint8_t)*path;
            hash *= UINT64_C(1099511628211);
        }
    }
    uint8_t bytes[6];
    for (NSUInteger index = 0; index < sizeof(bytes); index++)
        bytes[index] = (uint8_t)(hash >> (index * 8));
    bytes[0] = (bytes[0] | 0x02) & 0xfe;
    return VZMACStringFromBytes(bytes);
}

static NSArray *VZBridgeInterfaceNames(void)
{
    NSMutableSet *names = [NSMutableSet set];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_name || !(item->ifa_flags & IFF_UP) ||
                (item->ifa_flags & IFF_LOOPBACK))
                continue;
            NSString *name = [NSString stringWithUTF8String:item->ifa_name];
            if ([name hasPrefix:@"en"] || [name hasPrefix:@"bridge"])
                [names addObject:name];
        }
        freeifaddrs(interfaces);
    }
    if (!names.count)
        [names addObject:@"en0"];
    return [names.allObjects sortedArrayUsingSelector:
        @selector(localizedStandardCompare:)];
}

static NSString *VZInterfaceDisplayName(NSString *interface)
{
    if ([interface isEqualToString:@"en0"])
        return @"Wi-Fi";
    if ([interface hasPrefix:@"pdp_ip"])
        return @"Cellular";
    if ([interface hasPrefix:@"bridge"])
        return [NSString stringWithFormat:@"Network Bridge (%@)", interface];
    if ([interface hasPrefix:@"en"])
        return [NSString stringWithFormat:@"Ethernet (%@)", interface];
    return interface;
}

static NSString *VZActiveInternetDisplayName(void)
{
    NSString *candidate = nil;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_name || !item->ifa_addr ||
                item->ifa_addr->sa_family != AF_INET ||
                !(item->ifa_flags & IFF_UP) ||
                (item->ifa_flags & IFF_LOOPBACK))
                continue;
            NSString *name = [NSString stringWithUTF8String:item->ifa_name];
            if ([name isEqualToString:@"en0"]) {
                candidate = name;
                break;
            }
            if (!candidate && ([name hasPrefix:@"pdp_ip"] ||
                               [name hasPrefix:@"utun"]))
                candidate = name;
        }
        freeifaddrs(interfaces);
    }
    if ([candidate hasPrefix:@"utun"])
        return @"VPN";
    return candidate ? VZInterfaceDisplayName(candidate)
                     : @"iPad Internet Connection";
}

BOOL VZRestoreImageUsesMontereyProfile(NSString *path)
{
    // Match both friendly bundle names and Apple's restore-image convention,
    // for example UniversalMac_12.6_21G115_Restore.ipsw. Requiring a
    // non-digit boundary avoids treating 112.x as Monterey.
    NSString *name = path.lastPathComponent.lowercaseString ?: @"";
    if ([name containsString:@"monterey"] ||
        [name containsString:@"macos 12"] ||
        [name containsString:@"macos_12"] ||
        [name containsString:@"macos-12"])
        return YES;
    NSRange search = NSMakeRange(0, name.length);
    while (search.length) {
        NSRange version = [name rangeOfString:@"12." options:0 range:search];
        if (version.location == NSNotFound)
            break;
        BOOL leftBoundary = version.location == 0 ||
            ![NSCharacterSet.decimalDigitCharacterSet
                characterIsMember:[name characterAtIndex:version.location - 1]];
        NSUInteger digitIndex = NSMaxRange(version);
        BOOL hasMinor = digitIndex < name.length &&
            [NSCharacterSet.decimalDigitCharacterSet
                characterIsMember:[name characterAtIndex:digitIndex]];
        if (leftBoundary && hasMinor)
            return YES;
        NSUInteger next = NSMaxRange(version);
        search = NSMakeRange(next, name.length - next);
    }
    return NO;
}

static NSString *VZDefaultPointingDeviceForPath(NSString *path)
{
    return VZRestoreImageUsesMontereyProfile(path) ? @"USBMouse" : @"MacTrackpad";
}

static NSString *VZDefaultKeyboardDeviceForPath(NSString *path)
{
    return VZRestoreImageUsesMontereyProfile(path) ? @"USBKeyboard" : @"MacKeyboard";
}

NSDictionary *VZVMDefaultOptions(void)
{
    NSUInteger processors = MAX((NSUInteger)2,
        MIN((NSUInteger)4, NSProcessInfo.processInfo.activeProcessorCount));
    return @{
        VZCPUCountKey: @(processors),
        VZMemorySizeKey: @(VZDeviceMemoryLimit()),
        VZStorageSizeKey: @(VZDefaultStorageSize()),
        VZNetworkModeKey: @"NAT",
        VZBridgeInterfaceKey: @"en0",
        VZBootRecoveryKey: @NO,
        VZSharedDirectoriesKey: @[],
        VZPointingDeviceKey: @"MacTrackpad",
        VZKeyboardDeviceKey: @"MacKeyboard",
        VZAudioOutputEnabledKey: @YES,
        VZAudioInputEnabledKey: @YES,
        VZVideoToolboxEnabledKey: @YES,
        VZDisplayModeKey: @"NativeRetina",
        VZDisplayWidthKey: @1920,
        VZDisplayHeightKey: @1200,
        VZDisplayPPIKey: @264,
        VZMACAddressKey: VZRandomMACAddress(),
    };
}

NSDictionary *VZVMOptionsForBundle(NSString *bundlePath)
{
    NSMutableDictionary *options =
        [NSMutableDictionary dictionaryWithDictionary:VZVMDefaultOptions()];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:VZVMConfigurationFileName]];
    if ([saved isKindOfClass:NSDictionary.class])
        [options addEntriesFromDictionary:saved];
    if (![saved[VZPointingDeviceKey] isKindOfClass:NSString.class])
        options[VZPointingDeviceKey] =
            VZDefaultPointingDeviceForPath(bundlePath);
    if (![saved[VZKeyboardDeviceKey] isKindOfClass:NSString.class])
        options[VZKeyboardDeviceKey] =
            VZDefaultKeyboardDeviceForPath(bundlePath);
    NSString *savedMAC = saved[VZMACAddressKey];
    if (![savedMAC isKindOfClass:NSString.class] ||
        [savedMAC isEqualToString:@"d6:a7:58:8e:78:d5"])
        options[VZMACAddressKey] = VZMACAddressForBundle(bundlePath);
    return options;
}

BOOL VZWriteVMOptions(NSDictionary *options, NSString *bundlePath,
                      NSError **error)
{
    NSString *path =
        [bundlePath stringByAppendingPathComponent:VZVMConfigurationFileName];
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:options format:NSPropertyListXMLFormat_v1_0
                     options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

BOOL VZIsValidVMBundle(NSString *path)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&directory] || !directory)
        return NO;
    for (NSString *name in @[@"Disk.img", @"AuxiliaryStorage",
                              @"HardwareModel", @"MachineIdentifier"]) {
        BOOL itemDirectory = NO;
        if (![manager fileExistsAtPath:[path stringByAppendingPathComponent:name]
                           isDirectory:&itemDirectory] || itemDirectory)
            return NO;
    }
    return YES;
}

NSString *VZVMStableIdentifier(NSString *path)
{
    NSData *identifier = [NSData dataWithContentsOfFile:
        [path stringByAppendingPathComponent:@"MachineIdentifier"]];
    return identifier.length ? [identifier base64EncodedStringWithOptions:0] : nil;
}

NSArray<NSDictionary *> *VZDiscoverVirtualMachines(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *library = VZVMLibraryPath();
    [manager createDirectoryAtPath:library withIntermediateDirectories:YES
                        attributes:nil error:nil];
    [manager createDirectoryAtPath:VZRestoreImagesPath()
       withIntermediateDirectories:YES attributes:nil error:nil];
    [manager createDirectoryAtPath:VZInstallationsPath()
       withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *readme = [library stringByAppendingPathComponent:@"README.md"];
    if (![manager fileExistsAtPath:readme]) {
        NSString *text =
            @"# Virtual Mac\n\n"
             "Use Add in Virtual Mac to install a restore image, or copy a "
             "complete `.bundle` here. A bundle contains `Disk.img`, "
             "`AuxiliaryStorage`, `HardwareModel`, and `MachineIdentifier`.\n";
        [text writeToFile:readme atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    }

    NSMutableArray *machines = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^append)(NSString *, NSString *) =
        ^(NSString *path, NSString *name) {
        if (!VZIsValidVMBundle(path))
            return;
        NSString *identity = path.stringByResolvingSymlinksInPath;
        if ([seen containsObject:identity])
            return;
        [seen addObject:identity];
        [machines addObject:@{@"name": name, @"path": path}];
    };
    for (NSString *name in [manager contentsOfDirectoryAtPath:library
                                                        error:nil]) {
        if ([name.pathExtension caseInsensitiveCompare:@"bundle"] !=
                NSOrderedSame)
            continue;
        NSString *path = [library stringByAppendingPathComponent:name];
        NSString *display = name.stringByDeletingPathExtension;
        append(path, display);
    }
    [machines sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    return machines;
}

static NSString *VZMarketingNameForRestoreImage(NSURL *url)
{
    NSString *base = url.lastPathComponent.stringByDeletingPathExtension;
    NSString *lower = base.lowercaseString;
    NSDictionary *named = @{
        @"monterey": @"Monterey", @"ventura": @"Ventura",
        @"sonoma": @"Sonoma", @"sequoia": @"Sequoia",
        @"tahoe": @"Tahoe", @"golden gate": @"Golden Gate",
        @"goldengate": @"Golden Gate",
    };
    for (NSString *token in named)
        if ([lower containsString:token])
            return named[token];

    NSRegularExpression *version = [NSRegularExpression
        regularExpressionWithPattern:@"(?:^|[^0-9])([0-9]{2})(?:\\.[0-9]+)(?:[^0-9]|$)"
                              options:0 error:nil];
    NSTextCheckingResult *match = [version firstMatchInString:base options:0
        range:NSMakeRange(0, base.length)];
    if (match.numberOfRanges > 1) {
        NSString *major = [base substringWithRange:[match rangeAtIndex:1]];
        NSDictionary *marketing = @{
            @"12": @"Monterey", @"13": @"Ventura",
            @"14": @"Sonoma", @"15": @"Sequoia",
            @"26": @"Tahoe", @"27": @"Golden Gate",
        };
        return marketing[major] ?: [@"macOS " stringByAppendingString:major];
    }
    return base.length ? base : @"macOS";
}

static BOOL VZVMNameIsOccupied(NSString *name)
{
    NSString *bundleName = [name stringByAppendingPathExtension:@"bundle"];
    NSString *installingName = [bundleName
        stringByAppendingPathExtension:@"installing"];
    for (NSString *entry in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:VZVMLibraryPath() error:nil]) {
        if ([entry caseInsensitiveCompare:bundleName] == NSOrderedSame ||
            [entry caseInsensitiveCompare:installingName] == NSOrderedSame)
            return YES;
    }
    return NO;
}

static NSString *VZUniqueVMName(NSString *requested)
{
    NSString *base = requested.length ? requested : @"macOS";
    if (!VZVMNameIsOccupied(base))
        return base;
    for (NSUInteger suffix = 2; suffix < NSUIntegerMax; suffix++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %lu", base,
            (unsigned long)suffix];
        if (!VZVMNameIsOccupied(candidate))
            return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

static NSString *VZSanitizedVMName(NSString *requested)
{
    NSCharacterSet *invalid = [NSCharacterSet
        characterSetWithCharactersInString:@"/:\n\r"];
    NSString *name = [[[requested ?: @"" componentsSeparatedByCharactersInSet:
        invalid] componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : @"macOS";
}

static NSString *VZUniqueVMNameExcludingPath(NSString *requested,
                                              NSString *excludedPath)
{
    NSString *base = VZSanitizedVMName(requested);
    NSString *excluded = excludedPath.stringByStandardizingPath;
    for (NSUInteger suffix = 1; suffix < NSUIntegerMax; suffix++) {
        NSString *candidate = suffix == 1 ? base :
            [NSString stringWithFormat:@"%@ %lu", base,
             (unsigned long)suffix];
        NSString *path = [VZVMLibraryPath() stringByAppendingPathComponent:
            [candidate stringByAppendingPathExtension:@"bundle"]];
        if ([path.stringByStandardizingPath isEqualToString:excluded] ||
            ![NSFileManager.defaultManager fileExistsAtPath:path])
            return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

NSArray<NSString *> *VZInstallationArtifactPaths(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [manager
            contentsOfDirectoryAtPath:VZInstallationsPath() error:nil])
        [paths addObject:[VZInstallationsPath()
            stringByAppendingPathComponent:name]];

    return paths;
}

NSArray<NSString *> *VZCachedRestoreImagePaths(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray *paths = [NSMutableArray array];
    NSString *directory = VZRestoreImagesPath();
    for (NSString *name in [manager
            contentsOfDirectoryAtPath:directory error:nil])
        [paths addObject:[directory stringByAppendingPathComponent:name]];
    return paths;
}

void VZRemovePaths(NSArray<NSString *> *paths)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        NSError *error = nil;
        if ([manager removeItemAtPath:path error:&error])
            continue;
        // Restore helpers run as root and can leave diagnostics or staging
        // files that the UIKit process cannot unlink. The setuid launcher
        // accepts only descendants of the two artifact directories.
        const char *launcher =
            "/var/root/VirtualMac/install/install-launcher";
        char *arguments[] = {(char *)launcher, "--delete-artifact",
            (char *)path.fileSystemRepresentation, NULL};
        pid_t child = 0;
        int spawned = posix_spawn(&child, launcher, NULL, NULL,
                                  arguments, environ);
        int status = 0;
        if (spawned == 0)
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        if (spawned != 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
            NSLog(@"Virtual Mac cleanup could not remove %@: %@", path, error);
    }
}

@interface VZVMConfigurationViewController : UITableViewController
    <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *bundlePath;
@property(nonatomic, copy) NSString *vmName;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, retain) NSMutableDictionary *options;
@property(nonatomic, copy) void (^completion)(NSDictionary *options);
@property(nonatomic, copy) void (^deletion)(void);
@end

@implementation VZVMConfigurationViewController

- (instancetype)initWithBundlePath:(NSString *)bundlePath
                            options:(NSDictionary *)options
                         completion:(void (^)(NSDictionary *))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.bundlePath = bundlePath;
        self.vmName = bundlePath.lastPathComponent.stringByDeletingPathExtension;
        self.options = [NSMutableDictionary dictionaryWithDictionary:options];
        self.completion = completion;
        self.title = bundlePath ? @"Virtual Mac" : @"New Virtual Mac";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
        action:@selector(cancel:)] autorelease];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
        action:@selector(done:)] autorelease];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.bundlePath ? 6 : 5;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        NSInteger resourceRows = self.bundlePath ? 2 : 3;
        return 1 + resourceRows + 1 +
            [self.options[VZSharedDirectoriesKey] count];
    }
    if (section == 1)
        return self.bundlePath ? 3 : 2;
    if (section == 2)
        return 2;
    if (section == 3)
        return [self.options[VZDisplayModeKey] isEqualToString:@"Custom"]
            ? 4 : 1;
    if (section == 4)
        return 3;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section
{
    if (section == 5)
        return nil;
    return @[@"Resources",
             self.bundlePath ? @"Boot and Network" : @"Network",
             @"Input", @"Display", @"Audio and Acceleration"][section];
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (self.running && section == 0)
        return @"Configuration changes take effect after the virtual Mac is shut down and started again. Renaming and deletion are unavailable while it is running.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"];
    if (!cell)
        cell = [[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"]
            autorelease];
    // Every section shares this reuse identifier. Clear all state that a
    // switch-backed row can leave behind before configuring the new row.
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.imageView.image = nil;
    cell.userInteractionEnabled = YES;
    if (indexPath.section == 0) {
        NSInteger resourceRows = self.bundlePath ? 2 : 3;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = self.vmName;
            if (self.running) {
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.textLabel.textColor = UIColor.secondaryLabelColor;
            }
            return cell;
        }
        NSInteger resourceIndex = indexPath.row - 1;
        if (resourceIndex == resourceRows) {
            cell.textLabel.text = @"Add Shared Folder";
            cell.detailTextLabel.text = nil;
            return cell;
        }
        if (resourceIndex > resourceRows) {
            NSDictionary *share = self.options[VZSharedDirectoriesKey]
                [resourceIndex - resourceRows - 1];
            cell.textLabel.text = [share[@"Path"] lastPathComponent];
            cell.detailTextLabel.text = [share[@"ReadOnly"] boolValue]
                ? @"Read Only" : @"Read & Write";
            return cell;
        }
        NSArray *names = self.bundlePath ? @[@"Processors", @"Memory"]
                                         : @[@"Processors", @"Memory", @"Storage"];
        NSString *key = @[VZCPUCountKey, VZMemorySizeKey,
                           VZStorageSizeKey][resourceIndex];
        cell.textLabel.text = names[resourceIndex];
        uint64_t value = [self.options[key] unsignedLongLongValue];
        cell.detailTextLabel.text = resourceIndex == 0
            ? [NSString stringWithFormat:@"%llu", value]
            : [NSString stringWithFormat:@"%llu GB", value >> 30];
    } else if (indexPath.section == 1 && self.bundlePath &&
               indexPath.row == 0) {
        cell.textLabel.text = @"Start in Recovery";
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [self.options[VZBootRecoveryKey] boolValue];
        [toggle addTarget:self action:@selector(recoveryChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else if (indexPath.section == 1 &&
               indexPath.row == (self.bundlePath ? 1 : 0)) {
        cell.textLabel.text = @"Network";
        NSString *mode = self.options[VZNetworkModeKey];
        NSString *interface = self.options[VZBridgeInterfaceKey];
        cell.detailTextLabel.text = [mode isEqualToString:@"Bridge"]
            ? [NSString stringWithFormat:@"Bridge via %@",
                VZInterfaceDisplayName(interface)]
            : [mode isEqualToString:@"NAT"]
                ? [NSString stringWithFormat:@"Shared via %@",
                    VZActiveInternetDisplayName()] : mode;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"MAC Address";
        cell.detailTextLabel.text = self.options[VZMACAddressKey];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        cell.textLabel.text = @"Keyboard";
        cell.detailTextLabel.text =
            [self.options[VZKeyboardDeviceKey] isEqualToString:@"USBKeyboard"]
            ? @"USB Keyboard" : @"Mac Keyboard";
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"Pointing Device";
        cell.detailTextLabel.text =
            [self.options[VZPointingDeviceKey] isEqualToString:@"USBMouse"]
            ? @"USB Mouse" : @"Mac Trackpad";
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = @"Resolution";
        cell.detailTextLabel.text =
            [self.options[VZDisplayModeKey] isEqualToString:@"Custom"]
            ? @"Custom" : @"Native Retina";
    } else if (indexPath.section == 3) {
        NSArray *names = @[@"Width", @"Height", @"Pixels Per Inch"];
        NSArray *keys = @[VZDisplayWidthKey, VZDisplayHeightKey,
                          VZDisplayPPIKey];
        cell.textLabel.text = names[indexPath.row - 1];
        cell.detailTextLabel.text = [self.options[keys[indexPath.row - 1]]
            stringValue];
    } else if (indexPath.section == 4) {
        NSArray *names = @[@"Audio Output", @"Microphone Input",
                           @"VideoToolbox Acceleration"];
        NSArray *keys = @[VZAudioOutputEnabledKey, VZAudioInputEnabledKey,
                          VZVideoToolboxEnabledKey];
        cell.textLabel.text = names[indexPath.row];
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease];
        toggle.on = [self.options[keys[indexPath.row]] boolValue];
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(deviceToggleChanged:)
           forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;
    } else {
        cell.textLabel.text = @"Delete Virtual Mac";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = self.running
            ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = self.running ? UITableViewCellSelectionStyleNone
                                           : UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)chooseTitle:(NSString *)title message:(NSString *)message
            choices:(NSArray<NSDictionary *> *)choices key:(NSString *)key
           fromCell:(UITableViewCell *)cell
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:title message:message
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *choice in choices) {
        [sheet addAction:[UIAlertAction actionWithTitle:choice[@"title"]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            self.options[key] = choice[@"value"];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)editMACAddress
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"MAC Address"
                         message:@"Enter six hexadecimal octets separated by colons."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.options[VZMACAddressKey];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *value = alert.textFields.firstObject.text.lowercaseString;
        NSRegularExpression *pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^([0-9a-f]{2}:){5}[0-9a-f]{2}$"
                                  options:0 error:nil];
        if ([pattern numberOfMatchesInString:value options:0
                                       range:NSMakeRange(0, value.length)] == 1)
            self.options[VZMACAddressKey] = value;
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editNumberForKey:(NSString *)key title:(NSString *)title
                      min:(uint64_t)minimum max:(uint64_t)maximum
                    bytes:(BOOL)bytes
{
    NSString *range = maximum
        ? [NSString stringWithFormat:@"Allowed: %llu–%llu%@",
            bytes ? minimum >> 30 : minimum,
            bytes ? maximum >> 30 : maximum, bytes ? @" GB" : @""]
        : [NSString stringWithFormat:
            @"Minimum: %llu GB. The upper limit is determined by the filesystem.",
            minimum >> 30];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:range
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        uint64_t value = [self.options[key] unsignedLongLongValue];
        field.text = [NSString stringWithFormat:@"%llu",
                      bytes ? value >> 30 : value];
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        uint64_t entered = strtoull(
            alert.textFields.firstObject.text.UTF8String, NULL, 10);
        uint64_t value = entered;
        if (bytes) {
            uint64_t maximumGiB = (uint64_t)LLONG_MAX >> 30;
            value = entered > maximumGiB ? (uint64_t)LLONG_MAX : GiB(entered);
        }
        value = MAX(minimum, maximum ? MIN(maximum, value) : value);
        self.options[key] = @(value);
        [self.tableView reloadData];
        if ([key isEqualToString:VZStorageSizeKey] &&
            value > VZAvailableStorageSize()) {
            uint64_t available = VZAvailableStorageSize() >> 30;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                UIAlertController *warning = [UIAlertController
                    alertControllerWithTitle:@"Disk Exceeds Available Storage"
                    message:[NSString stringWithFormat:
                        @"Only about %llu GB is currently available. The disk image is sparse, but installation or later use can fail when storage fills up.",
                        available]
                    preferredStyle:UIAlertControllerStyleAlert];
                [warning addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:warning animated:YES completion:nil];
            });
        }
    }]];
    [self presentViewController:alert animated:YES completion:^{
        UITextField *field = alert.textFields.firstObject;
        [field selectAll:nil];
        [field becomeFirstResponder];
    }];
}

- (void)editVMName
{
    if (self.running)
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Name"
                         message:@"Choose a name for this virtual Mac."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.vmName;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        self.vmName = VZUniqueVMNameExcludingPath(
            alert.textFields.firstObject.text, self.bundlePath);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:^{
        [alert.textFields.firstObject selectAll:nil];
        [alert.textFields.firstObject becomeFirstResponder];
    }];
}

- (void)confirmDeleteVirtualMac
{
    if (!self.bundlePath.length || self.running)
        return;
    NSString *name = self.vmName.length ? self.vmName : @"this virtual Mac";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete Virtual Mac?"
                         message:[NSString stringWithFormat:
                            @"“%@” and all files stored in it will be permanently deleted.",
                            name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSString *path = [[self.bundlePath copy] autorelease];
        VZRemovePaths(@[path]);
        if ([[VZAppSettings.sharedSettings stringForKey:VZAutoBootVMPathKey]
                isEqualToString:path]) {
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMIdentifierKey];
        }
        void (^deletion)(void) = [[self.deletion copy] autorelease];
        [self dismissViewControllerAnimated:YES completion:^{
            if (deletion) deletion();
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NSInteger resourceRows = self.bundlePath ? 2 : 3;
        if (indexPath.row == 0) {
            [self editVMName];
            return;
        }
        NSInteger resourceIndex = indexPath.row - 1;
        if (resourceIndex == resourceRows) {
            UIDocumentPickerViewController *picker =
                [[[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO]
                    autorelease];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        } else if (resourceIndex > resourceRows) {
            NSInteger shareIndex = resourceIndex - resourceRows - 1;
            NSDictionary *saved =
                self.options[VZSharedDirectoriesKey][shareIndex];
            NSString *path = saved[@"Path"];
            UIAlertController *sheet = [UIAlertController
                alertControllerWithTitle:path.lastPathComponent message:path
                    preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSNumber *readOnly in @[@NO, @YES]) {
                NSString *title = readOnly.boolValue
                    ? @"Read Only" : @"Read & Write";
                [sheet addAction:[UIAlertAction actionWithTitle:title
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                    (void)action;
                    NSMutableArray *shares = [NSMutableArray arrayWithArray:
                        self.options[VZSharedDirectoriesKey]];
                    shares[shareIndex] =
                        @{@"Path": path, @"ReadOnly": readOnly};
                    self.options[VZSharedDirectoriesKey] = shares;
                    [self.tableView reloadData];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"Remove"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                (void)action;
                NSMutableArray *shares = [NSMutableArray arrayWithArray:
                    self.options[VZSharedDirectoriesKey]];
                [shares removeObjectAtIndex:shareIndex];
                self.options[VZSharedDirectoriesKey] = shares;
                [self.tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView =
                [tableView cellForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        } else if (resourceIndex == 0) {
            NSUInteger maxCPU = MAX((NSUInteger)2,
                MIN((NSUInteger)8, NSProcessInfo.processInfo.activeProcessorCount));
            [self editNumberForKey:VZCPUCountKey title:@"Processors"
                              min:2 max:maxCPU bytes:NO];
        } else if (resourceIndex == 1) {
            [self editNumberForKey:VZMemorySizeKey title:@"Memory"
                              min:GiB(2) max:VZDeviceMemoryLimit() bytes:YES];
        } else if (resourceIndex == 2) {
            [self editNumberForKey:VZStorageSizeKey title:@"Storage"
                              min:GiB(32) max:0 bytes:YES];
        }
    } else if (indexPath.section == 1 &&
               indexPath.row == (self.bundlePath ? 1 : 0)) {
        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"Network Attachment" message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *mode in @[@"NAT", @"Disabled"]) {
            NSString *title = [mode isEqualToString:@"NAT"]
                ? [NSString stringWithFormat:@"NAT: Share %@",
                    VZActiveInternetDisplayName()] : mode;
            [sheet addAction:[UIAlertAction actionWithTitle:title
                style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                self.options[VZNetworkModeKey] = mode;
                [self.tableView reloadData];
            }]];
        }
        for (NSString *interface in VZBridgeInterfaceNames()) {
            NSString *title = [NSString stringWithFormat:@"Bridge: %@",
                VZInterfaceDisplayName(interface)];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                self.options[VZNetworkModeKey] = @"Bridge";
                self.options[VZBridgeInterfaceKey] = interface;
                [self.tableView reloadData];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView =
            [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.section == 1 &&
               indexPath.row == (self.bundlePath ? 2 : 1)) {
        [self editMACAddress];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        [self chooseTitle:@"Keyboard" message:
            @"Use USB Keyboard for macOS Monterey. Newer guests support the Mac keyboard device."
            choices:@[
                @{@"title": @"Mac Keyboard", @"value": @"MacKeyboard"},
                @{@"title": @"USB Keyboard", @"value": @"USBKeyboard"},
            ] key:VZKeyboardDeviceKey
            fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        [self chooseTitle:@"Pointing Device" message:
            @"Use USB Mouse for macOS Monterey. Newer guests support the Mac trackpad device."
            choices:@[
            @{@"title": @"Mac Trackpad", @"value": @"MacTrackpad"},
            @{@"title": @"USB Mouse", @"value": @"USBMouse"},
            ] key:VZPointingDeviceKey
            fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        [self chooseTitle:@"Display Resolution" message:nil choices:@[
            @{@"title": @"Native Retina", @"value": @"NativeRetina"},
            @{@"title": @"Custom", @"value": @"Custom"},
        ] key:VZDisplayModeKey
          fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == 3 && indexPath.row > 0) {
        NSArray *keys = @[VZDisplayWidthKey, VZDisplayHeightKey,
                          VZDisplayPPIKey];
        NSArray *titles = @[@"Display Width", @"Display Height",
                            @"Pixels Per Inch"];
        uint64_t minimum = indexPath.row == 3 ? 72 : 800;
        uint64_t maximum = indexPath.row == 3 ? 600 : 7680;
        [self editNumberForKey:keys[indexPath.row - 1]
                         title:titles[indexPath.row - 1]
                           min:minimum max:maximum bytes:NO];
    } else if (indexPath.section == 5) {
        [self confirmDeleteVirtualMac];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url)
        return;
    [url startAccessingSecurityScopedResource];
    NSMutableArray *shares = [NSMutableArray arrayWithArray:
        self.options[VZSharedDirectoriesKey]];
    [shares addObject:@{@"Path": url.path, @"ReadOnly": @NO}];
    self.options[VZSharedDirectoriesKey] = shares;
    [self.tableView reloadData];
}

- (void)recoveryChanged:(UISwitch *)sender
{
    self.options[VZBootRecoveryKey] = @(sender.on);
}

- (void)deviceToggleChanged:(UISwitch *)sender
{
    NSArray *keys = @[VZAudioOutputEnabledKey, VZAudioInputEnabledKey,
                      VZVideoToolboxEnabledKey];
    if (sender.tag < (NSInteger)keys.count)
        self.options[keys[sender.tag]] = @(sender.on);
}

- (void)done:(id)sender
{
    (void)sender;
    if (self.bundlePath) {
        NSError *error = nil;
        NSString *newName = VZUniqueVMNameExcludingPath(
            self.vmName, self.bundlePath);
        NSString *oldName = self.bundlePath.lastPathComponent
            .stringByDeletingPathExtension;
        if (!self.running && ![newName isEqualToString:oldName]) {
            NSString *destination = [VZVMLibraryPath()
                stringByAppendingPathComponent:
                    [newName stringByAppendingPathExtension:@"bundle"]];
            if (![NSFileManager.defaultManager moveItemAtPath:self.bundlePath
                toPath:destination error:&error]) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Could Not Rename Virtual Mac"
                    message:error.localizedDescription
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            NSString *autoBoot = [VZAppSettings.sharedSettings
                stringForKey:VZAutoBootVMPathKey];
            if ([autoBoot isEqualToString:self.bundlePath])
                [VZAppSettings.sharedSettings setString:destination
                    forKey:VZAutoBootVMPathKey];
            self.bundlePath = destination;
            self.vmName = newName;
        }
        if (!VZWriteVMOptions(self.options, self.bundlePath, &error)) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Could Not Save"
                                 message:error.localizedDescription
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
    }
    void (^completion)(NSDictionary *) = [[self.completion copy] autorelease];
    NSMutableDictionary *result = [NSMutableDictionary
        dictionaryWithDictionary:self.options];
    result[VZVMNameKey] = VZSanitizedVMName(self.vmName);
    NSDictionary *options = [[result copy] autorelease];
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion)
            completion(options);
    }];
}

- (void)cancel:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc
{
    [_bundlePath release];
    [_vmName release];
    [_options release];
    [_completion release];
    [_deletion release];
    [super dealloc];
}
@end

@interface VZLibraryControlsView : UICollectionReusableView
@property(nonatomic, retain) UISearchBar *searchBar;
@property(nonatomic, retain) UISegmentedControl *layoutControl;
@end

@implementation VZLibraryControlsView
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.searchBar = [[[UISearchBar alloc] initWithFrame:CGRectZero]
            autorelease];
        self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.searchBar.placeholder = @"Search Virtual Mac";
        self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
        [self addSubview:self.searchBar];
        self.layoutControl = [[[UISegmentedControl alloc] initWithItems:@[
            [UIImage systemImageNamed:@"square.grid.2x2"],
            [UIImage systemImageNamed:@"list.bullet"]]] autorelease];
        self.layoutControl.translatesAutoresizingMaskIntoConstraints = NO;
        self.layoutControl.accessibilityLabel = @"Library Appearance";
        [self addSubview:self.layoutControl];
        [NSLayoutConstraint activateConstraints:@[
            [self.searchBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
            [self.searchBar.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [self.searchBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [self.layoutControl.leadingAnchor constraintEqualToAnchor:
                self.searchBar.trailingAnchor constant:12],
            [self.layoutControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
            [self.layoutControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.layoutControl.widthAnchor constraintEqualToConstant:112],
        ]];
    }
    return self;
}
- (void)dealloc
{
    [_searchBar release];
    [_layoutControl release];
    [super dealloc];
}
@end

@interface VZVMLibraryViewController () <UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout, UISearchBarDelegate,
    VZNewVMViewControllerDelegate>
@property(nonatomic, retain) NSArray *machines;
@property(nonatomic, retain) NSArray *filteredMachines;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic, retain) NSURL *pendingIPSWURL;
@property(nonatomic, retain) UICollectionView *collectionView;
@property(nonatomic, retain) UIView *emptyView;
@property(nonatomic, assign) CGFloat lastCollectionWidth;
@property(nonatomic, retain) NSURLSessionDownloadTask *downloadTask;
@property(nonatomic, retain) NSTimer *downloadTimer;
@property(nonatomic, retain) VZProgressViewController *downloadController;
@property(nonatomic, copy) NSString *downloadDestination;
@property(nonatomic, copy) NSString *downloadMarkerPath;
@property(nonatomic, assign) int64_t downloadLastBytes;
@property(nonatomic, retain) NSDate *downloadLastSample;
@property(nonatomic, assign) BOOL downloadCancelled;
@property(nonatomic, assign) BOOL didCheckInterruptedDownloads;
@end

@implementation VZVMLibraryViewController

- (void)showSettings:(UIBarButtonItem *)sender
{
    (void)sender;
    VZSettingsViewController *settings = [[[VZSettingsViewController alloc]
        initWithMachines:self.machines] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:settings] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.preferredContentSize = CGSizeMake(620, 720);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentSettings
{
    [self showSettings:nil];
}

- (void)presentConfiguration:(VZVMConfigurationViewController *)configuration
{
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:configuration] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = CGSizeMake(620, 760);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Virtual Mac";
        self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"gearshape"]
            style:UIBarButtonItemStylePlain target:self
            action:@selector(showSettings:)] autorelease];
        self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
            action:@selector(addVM:)] autorelease];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UICollectionViewFlowLayout *layout = [[[UICollectionViewFlowLayout alloc] init] autorelease];
    layout.sectionInset = UIEdgeInsetsMake(22, 24, 30, 24);
    layout.minimumInteritemSpacing = 18;
    layout.minimumLineSpacing = 18;
    self.collectionView = [[[UICollectionView alloc] initWithFrame:self.view.bounds
        collectionViewLayout:layout] autorelease];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:UICollectionViewCell.class
        forCellWithReuseIdentifier:@"item"];
    [self.collectionView registerClass:VZLibraryControlsView.class
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
        withReuseIdentifier:@"controls"];
    UIRefreshControl *refresh = [[[UIRefreshControl alloc] init] autorelease];
    [refresh addTarget:self action:@selector(reloadLibrary)
        forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = refresh;
    [self.view addSubview:self.collectionView];

    UIView *empty = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"macbook.and.ipad"]] autorelease];
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = @"No Virtual Mac";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *message = [[[UILabel alloc] init] autorelease];
    message.text = @"Install macOS from an Apple restore image.";
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    message.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *create = [UIButton buttonWithType:UIButtonTypeSystem];
    [create setTitle:@"Create Virtual Mac" forState:UIControlStateNormal];
    create.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    create.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [create addTarget:self action:@selector(addVM:) forControlEvents:UIControlEventTouchUpInside];
    create.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIView *view in @[icon, title, message, create]) [empty addSubview:view];
    [self.view addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],
        [empty.widthAnchor constraintLessThanOrEqualToConstant:430],
        [icon.topAnchor constraintEqualToAnchor:empty.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:76],
        [icon.heightAnchor constraintEqualToConstant:62],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor],
        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [message.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor],
        [message.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor],
        [create.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:22],
        [create.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
        [create.bottomAnchor constraintEqualToAnchor:empty.bottomAnchor],
    ]];
    self.emptyView = empty;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(settingsChanged:) name:VZSettingsDidChangeNotification object:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = self.collectionView.bounds.size.width;
    if (ABS(width - self.lastCollectionWidth) > 0.5) {
        self.lastCollectionWidth = width;
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadLibrary];
    if (!self.didCheckInterruptedDownloads) {
        self.didCheckInterruptedDownloads = YES;
        NSMutableArray *markers = [NSMutableArray array];
        for (NSString *name in [NSFileManager.defaultManager
                contentsOfDirectoryAtPath:VZRestoreImagesPath() error:nil])
            if ([name hasSuffix:@".download.plist"])
                [markers addObject:[VZRestoreImagesPath() stringByAppendingPathComponent:name]];
        if (markers.count) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:markers.count == 1 ? @"Incomplete Download" : @"Incomplete Downloads"
                             message:@"A previous restore-image download did not finish. You can delete its marker and download it again."
                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Keep"
                style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                (void)action; VZRemovePaths(markers);
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }
}

- (void)reloadLibrary
{
    self.machines = VZDiscoverVirtualMachines();
    [self applySearchFilter];
    self.emptyView.hidden = self.machines.count > 0;
    self.collectionView.hidden = self.machines.count == 0;
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
    [self.collectionView.refreshControl endRefreshing];
}

- (void)applySearchFilter
{
    if (!self.searchText.length) {
        self.filteredMachines = self.machines;
        return;
    }
    NSString *query = self.searchText;
    self.filteredMachines = [self.machines filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *machine,
                                               NSDictionary *bindings) {
        (void)bindings;
        return [machine[@"name"] localizedCaseInsensitiveContainsString:query];
    }]];
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar
    textDidChange:(NSString *)searchText
{
    (void)searchBar;
    self.searchText = searchText;
    [self applySearchFilter];
    [self.collectionView reloadData];
}

- (void)libraryLayoutChanged:(UISegmentedControl *)sender
{
    [VZAppSettings.sharedSettings setString:
        sender.selectedSegmentIndex == 1 ? @"list" : @"grid"
        forKey:VZLibraryLayoutKey];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
    viewForSupplementaryElementOfKind:(NSString *)kind
    atIndexPath:(NSIndexPath *)indexPath
{
    (void)indexPath;
    VZLibraryControlsView *controls = (id)[collectionView
        dequeueReusableSupplementaryViewOfKind:kind
        withReuseIdentifier:@"controls" forIndexPath:indexPath];
    controls.searchBar.delegate = self;
    controls.searchBar.text = self.searchText;
    controls.layoutControl.selectedSegmentIndex =
        [[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey]
            isEqualToString:@"list"] ? 1 : 0;
    [controls.layoutControl removeTarget:nil action:NULL
        forControlEvents:UIControlEventValueChanged];
    [controls.layoutControl addTarget:self action:@selector(libraryLayoutChanged:)
        forControlEvents:UIControlEventValueChanged];
    return controls;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
    layout:(UICollectionViewLayout *)layout
    referenceSizeForHeaderInSection:(NSInteger)section
{
    (void)layout; (void)section;
    return CGSizeMake(collectionView.bounds.size.width, 58);
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    (void)collectionView; (void)section;
    return self.filteredMachines.count + 1;
}

- (NSString *)activeVMBundlePath
{
    if ([self.delegate respondsToSelector:
            @selector(activeVMBundlePathForLibrary:)])
        return [self.delegate activeVMBundlePathForLibrary:self];
    return nil;
}

- (BOOL)isMachineActive:(NSDictionary *)machine
{
    return [[[self activeVMBundlePath] stringByStandardizingPath]
        isEqualToString:[machine[@"path"] stringByStandardizingPath]];
}

- (void)startMachine:(NSDictionary *)machine
{
    NSString *activePath = [self activeVMBundlePath];
    if (activePath.length) {
        if ([self isMachineActive:machine]) {
            if ([self.delegate respondsToSelector:
                    @selector(vmLibraryResumeActiveVM:)])
                [self.delegate vmLibraryResumeActiveVM:self];
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Another Virtual Mac Is Running"
            message:@"Switch to the running virtual Mac and shut it down before starting another one."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Switch to Running Virtual Mac"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            if ([self.delegate respondsToSelector:
                    @selector(vmLibraryResumeActiveVM:)])
                [self.delegate vmLibraryResumeActiveVM:self];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:machine[@"path"]
        forKey:@"VZSelectedVMPath"];
    [self.delegate vmLibrary:self bootBundleAtPath:machine[@"path"]
        options:VZVMOptionsForBundle(machine[@"path"])];
}

- (void)confirmDeleteMachine:(NSDictionary *)machine
{
    if ([self isMachineActive:machine])
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete Virtual Mac?"
        message:[NSString stringWithFormat:
            @"“%@” and all files stored in it will be permanently deleted.",
            machine[@"name"]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        VZRemovePaths(@[machine[@"path"]]);
        if ([[VZAppSettings.sharedSettings stringForKey:VZAutoBootVMPathKey]
                isEqualToString:machine[@"path"]]) {
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMPathKey];
            [VZAppSettings.sharedSettings setString:nil
                forKey:VZAutoBootVMIdentifierKey];
        }
        [self reloadLibrary];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)configureMachineAtIndex:(NSUInteger)index
{
    if (index >= self.filteredMachines.count)
        return;
    NSDictionary *machine = self.filteredMachines[index];
    BOOL running = [self isMachineActive:machine];
    VZVMConfigurationViewController *configuration =
        [[[VZVMConfigurationViewController alloc]
          initWithBundlePath:machine[@"path"]
                     options:VZVMOptionsForBundle(machine[@"path"])
                  completion:^(NSDictionary *options) {
            (void)options;
            [self reloadLibrary];
        }] autorelease];
    configuration.title = machine[@"name"];
    configuration.vmName = machine[@"name"];
    configuration.running = running;
    configuration.deletion = ^{ [self reloadLibrary]; };
    [self presentConfiguration:configuration];
}

- (void)forceShutdownMachine:(NSDictionary *)machine
{
    if (![self isMachineActive:machine] ||
        ![self.delegate respondsToSelector:
            @selector(vmLibraryForceShutdownActiveVM:)])
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Force Shut Down Virtual Mac?"
        message:@"Unsaved changes in macOS may be lost."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Shut Down"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [self.delegate vmLibraryForceShutdownActiveVM:self];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentActionsForMachine:(NSDictionary *)machine
                        fromView:(UIView *)source
{
    BOOL active = [self isMachineActive:machine];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:machine[@"name"] message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:active ? @"Resume" : @"Start"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self startMachine:machine];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Options"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSUInteger index = [self.filteredMachines indexOfObject:machine];
        if (index != NSNotFound) [self configureMachineAtIndex:index];
    }]];
    if (active)
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force Shut Down"
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self forceShutdownMachine:machine];
        }]];
    else
        [sheet addAction:[UIAlertAction actionWithTitle:@"Delete"
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self confirmDeleteMachine:machine];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds :
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
    cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"item"
        forIndexPath:indexPath];
    for (UIView *view in cell.contentView.subviews) [view removeFromSuperview];
    for (UIGestureRecognizer *gesture in
            [[[cell gestureRecognizers] copy] autorelease])
        if ([gesture isKindOfClass:UISwipeGestureRecognizer.class])
            [cell removeGestureRecognizer:gesture];
    cell.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.layer.cornerRadius = 14;
    cell.contentView.layer.borderWidth = 0.5;
    cell.contentView.layer.borderColor = UIColor.separatorColor.CGColor;
    cell.contentView.clipsToBounds = YES;
    BOOL list = [[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey] isEqualToString:@"list"];
    UIView *selected = [[[UIView alloc] initWithFrame:cell.bounds] autorelease];
    selected.backgroundColor = UIColor.tertiarySystemFillColor;
    selected.layer.cornerRadius = 14;
    cell.selectedBackgroundView = selected;
    UIImageView *image = [[[UIImageView alloc] init] autorelease];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    image.contentMode = UIViewContentModeScaleAspectFill;
    image.clipsToBounds = YES;
    // The grid card already clips to its rounded outer edge. A second rounded
    // image mask leaves a visible seam above solid-color artwork such as the
    // Create card; only standalone list thumbnails need their own rounding.
    image.layer.cornerRadius = list ? 10 : 0;
    image.layer.maskedCorners = list ?
        (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
         kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner) :
        (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    image.backgroundColor = UIColor.tertiarySystemFillColor;
    [cell.contentView addSubview:image];
    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:list ? UIFontTextStyleHeadline : UIFontTextStyleTitle3];
    title.numberOfLines = 1;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell.contentView addSubview:title];
    UILabel *detail = [[[UILabel alloc] init] autorelease];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detail.textColor = UIColor.secondaryLabelColor;
    [cell.contentView addSubview:detail];
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    more.tag = indexPath.item;
    [more addTarget:self action:@selector(moreButton:)
        forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:more];
    if (indexPath.item == 0) {
        NSString *art = [[NSBundle mainBundle] pathForResource:@"new"
            ofType:@"png" inDirectory:@"Wallpapers"];
        image.image = [UIImage imageWithContentsOfFile:art];
        title.text = @"Create Virtual Mac";
        detail.text = @"Install macOS";
        more.hidden = YES;
    } else {
        NSDictionary *machine = self.filteredMachines[indexPath.item - 1];
        NSDictionary *options = VZVMOptionsForBundle(machine[@"path"]);
        title.text = machine[@"name"];
        detail.text = [NSString stringWithFormat:@"%@ CPUs · %@ GB · %@%@",
            options[VZCPUCountKey], @([options[VZMemorySizeKey] unsignedLongLongValue] >> 30),
            options[VZNetworkModeKey], [machine[@"legacy"] boolValue] ? @" · Legacy" : @""];
        NSString *wallpaperName = [self wallpaperNameForMachineName:machine[@"name"]];
        NSString *art = [[NSBundle mainBundle] pathForResource:wallpaperName
            ofType:@"jpg" inDirectory:@"Wallpapers"];
        image.image = [UIImage imageWithContentsOfFile:art];
        image.tag = indexPath.item;
        image.userInteractionEnabled = YES;
        UITapGestureRecognizer *start = [[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(machineArtworkTapped:)] autorelease];
        [image addGestureRecognizer:start];
        image.isAccessibilityElement = YES;
        image.accessibilityLabel = [NSString stringWithFormat:@"Start %@", machine[@"name"]];
        image.accessibilityTraits = UIAccessibilityTraitButton;
        [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        more.accessibilityLabel = [NSString stringWithFormat:@"Configure %@", machine[@"name"]];
        if (!list) {
            UIVisualEffectView *playBackground = [[[UIVisualEffectView alloc]
                initWithEffect:[UIBlurEffect effectWithStyle:
                    UIBlurEffectStyleSystemUltraThinMaterialDark]] autorelease];
            playBackground.translatesAutoresizingMaskIntoConstraints = NO;
            playBackground.userInteractionEnabled = YES;
            playBackground.layer.cornerRadius = 36;
            playBackground.clipsToBounds = YES;
            UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
            play.translatesAutoresizingMaskIntoConstraints = NO;
            play.tag = indexPath.item;
            play.tintColor = UIColor.whiteColor;
            NSString *symbolName = [self isMachineActive:machine]
                ? @"rectangle.portrait.and.arrow.right" : @"play.fill";
            UIImage *playImage = [[UIImage systemImageNamed:symbolName]
                imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration
                    configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold]];
            [play setImage:playImage forState:UIControlStateNormal];
            [play addTarget:self action:@selector(startButton:)
                forControlEvents:UIControlEventTouchUpInside];
            [playBackground.contentView addSubview:play];
            [cell.contentView addSubview:playBackground];
            [NSLayoutConstraint activateConstraints:@[
                [playBackground.centerXAnchor constraintEqualToAnchor:image.centerXAnchor],
                [playBackground.centerYAnchor constraintEqualToAnchor:image.centerYAnchor],
                [playBackground.widthAnchor constraintEqualToConstant:72],
                [playBackground.heightAnchor constraintEqualToConstant:72],
                [play.centerXAnchor constraintEqualToAnchor:playBackground.contentView.centerXAnchor],
                [play.centerYAnchor constraintEqualToAnchor:playBackground.contentView.centerYAnchor],
                [play.widthAnchor constraintEqualToAnchor:playBackground.widthAnchor],
                [play.heightAnchor constraintEqualToAnchor:playBackground.heightAnchor],
            ]];
        }
    }
    if (list) {
        cell.tag = indexPath.item;
        UISwipeGestureRecognizer *swipe = [[[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleMachineSwipe:)] autorelease];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [cell addGestureRecognizer:swipe];
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [image.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:104], [image.heightAnchor constraintEqualToConstant:62],
            [title.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:14],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-8],
            [title.bottomAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor constant:-2],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-8],
            [detail.topAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor constant:3],
            [more.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
            [more.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [more.widthAnchor constraintEqualToConstant:48],
            [more.heightAnchor constraintEqualToConstant:48],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [image.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [image.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [image.heightAnchor constraintEqualToAnchor:cell.contentView.widthAnchor multiplier:0.56],
            [title.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:14],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-6],
            [title.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:12],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
            [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
            [more.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [more.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
            [more.widthAnchor constraintEqualToConstant:48],
            [more.heightAnchor constraintEqualToConstant:48],
        ]];
    }
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title.text, detail.text];
    return cell;
}

- (NSString *)wallpaperNameForMachineName:(NSString *)name
{
    NSString *lower = name.lowercaseString;
    for (NSString *candidate in @[@"monterey", @"ventura", @"sonoma", @"sequoia", @"tahoe", @"golden-gate"])
        if ([lower containsString:[candidate stringByReplacingOccurrencesOfString:@"-" withString:@" "]] ||
            [lower containsString:[candidate stringByReplacingOccurrencesOfString:@"-" withString:@""]]) return candidate;
    NSDictionary *versions = @{@"macos 12":@"monterey", @"macos 13":@"ventura",
        @"macos 14":@"sonoma", @"macos 15":@"sequoia", @"macos 26":@"tahoe",
        @"macos 27":@"golden-gate"};
    for (NSString *token in versions) if ([lower containsString:token]) return versions[token];
    return @"tiger";
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    (void)layout; (void)indexPath;
    CGFloat width = collectionView.bounds.size.width - 48;
    if ([[VZAppSettings.sharedSettings stringForKey:VZLibraryLayoutKey] isEqualToString:@"list"])
        return CGSizeMake(width, 82);
    NSUInteger columns = width >= 900 ? 3 : 2;
    CGFloat itemWidth = floor((width - 18 * (columns - 1)) / columns);
    return CGSizeMake(itemWidth, itemWidth * 0.56 + 76);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if (indexPath.item == 0) { [self presentNewVMFlow]; return; }
    if (indexPath.item > self.filteredMachines.count) return;
    NSDictionary *machine = self.filteredMachines[indexPath.item - 1];
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    [self presentActionsForMachine:machine fromView:cell];
}

- (void)machineArtworkTapped:(UITapGestureRecognizer *)recognizer
{
    NSInteger item = recognizer.view.tag;
    if (item <= 0 || item > (NSInteger)self.filteredMachines.count) return;
    [self startMachine:self.filteredMachines[item - 1]];
}

- (void)startButton:(UIButton *)sender
{
    if (sender.tag == 0 || sender.tag > self.filteredMachines.count) return;
    [self startMachine:self.filteredMachines[sender.tag - 1]];
}

- (void)moreButton:(UIButton *)sender
{
    if (sender.tag == 0 || sender.tag > self.filteredMachines.count) return;
    [self configureMachineAtIndex:sender.tag - 1];
}

- (void)handleMachineSwipe:(UISwipeGestureRecognizer *)recognizer
{
    UICollectionViewCell *cell = (id)recognizer.view;
    if (cell.tag == 0 || cell.tag > (NSInteger)self.filteredMachines.count)
        return;
    NSDictionary *machine = self.filteredMachines[cell.tag - 1];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:machine[@"name"] message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Options"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self configureMachineAtIndex:cell.tag - 1];
    }]];
    if (![self isMachineActive:machine])
        [sheet addAction:[UIAlertAction actionWithTitle:@"Delete"
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action; [self confirmDeleteMachine:machine];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point
{
    (void)collectionView; (void)point;
    if (indexPath.item == 0 || indexPath.item > self.filteredMachines.count)
        return nil;
    NSDictionary *machine = self.filteredMachines[indexPath.item - 1];
    BOOL active = [self isMachineActive:machine];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        (void)suggested;
        UIAction *start = [UIAction actionWithTitle:active ? @"Resume" : @"Start"
            image:[UIImage systemImageNamed:active ? @"rectangle.portrait.and.arrow.right" : @"play.fill"]
            identifier:nil handler:^(__kindof UIAction *action) {
            (void)action; [self startMachine:machine];
        }];
        UIAction *options = [UIAction actionWithTitle:@"Options"
            image:[UIImage systemImageNamed:@"gearshape"] identifier:nil
            handler:^(__kindof UIAction *action) {
            (void)action;
            NSUInteger index = [self.filteredMachines indexOfObject:machine];
            if (index != NSNotFound) [self configureMachineAtIndex:index];
        }];
        UIAction *power = [UIAction actionWithTitle:
            active ? @"Force Shut Down" : @"Delete"
            image:[UIImage systemImageNamed:active ? @"power" : @"trash"]
            identifier:nil handler:^(__kindof UIAction *action) {
            (void)action;
            if (active) [self forceShutdownMachine:machine];
            else [self confirmDeleteMachine:machine];
        }];
        power.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"" children:@[start, options, power]];
    }];
}

- (void)addVM:(id)sender
{
    (void)sender;
    [self presentNewVMFlow];
}

- (void)presentNewVMFlow
{
    VZNewVMViewController *controller = [[[VZNewVMViewController alloc] init] autorelease];
    controller.delegate = self;
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:controller] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = CGSizeMake(650, 700);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentRestoreImagePicker
{
    UIDocumentPickerViewController *picker = [[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:NO] autorelease];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)newVMControllerChooseLocalRestoreImage:(VZNewVMViewController *)controller
{
    [controller dismissViewControllerAnimated:YES completion:^{
        [self presentRestoreImagePicker];
    }];
}

- (void)cancelDownload
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Cancel Download?"
                         message:@"The partial restore image will be deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Downloading"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel Download"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        self.downloadCancelled = YES;
        [self.downloadTask cancel];
        [self.downloadTimer invalidate];
        self.downloadTimer = nil;
        if (self.downloadDestination.length)
            [NSFileManager.defaultManager removeItemAtPath:self.downloadDestination error:nil];
        if (self.downloadMarkerPath.length)
            [NSFileManager.defaultManager removeItemAtPath:self.downloadMarkerPath error:nil];
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        [self.downloadController.navigationController dismissViewControllerAnimated:YES
            completion:^{
                self.downloadController.cancellationHandler = nil;
                self.downloadController = nil;
                self.downloadTask = nil;
                self.downloadDestination = nil;
                self.downloadMarkerPath = nil;
            }];
    }]];
    [self.downloadController presentViewController:alert animated:YES completion:nil];
}

- (void)newVMController:(VZNewVMViewController *)controller
    downloadRestoreImage:(NSDictionary *)image
{
    NSURL *remoteURL = [NSURL URLWithString:image[@"url"]];
    if (!remoteURL) return;
    [controller dismissViewControllerAnimated:YES completion:^{
        NSString *destination = [VZRestoreImagesPath() stringByAppendingPathComponent:
            remoteURL.lastPathComponent ?: @"Restore.ipsw"];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:destination error:nil];
        uint64_t expected = [image[@"downloadSize"] unsignedLongLongValue];
        if (attributes && (!expected || [attributes[NSFileSize] unsignedLongLongValue] == expected)) {
            [self documentPicker:(id)self didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:destination]]];
            return;
        }
        [NSFileManager.defaultManager createDirectoryAtPath:VZRestoreImagesPath()
            withIntermediateDirectories:YES attributes:nil error:nil];
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        self.downloadCancelled = NO;
        self.downloadDestination = destination;
        self.downloadMarkerPath = [VZRestoreImagesPath() stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.download.plist", destination.lastPathComponent]];
        [@{ @"Name": image[@"name"] ?: destination.lastPathComponent,
             @"URL": remoteURL.absoluteString ?: @"",
             @"Destination": destination,
             @"StartedAt": NSDate.date }
            writeToFile:self.downloadMarkerPath atomically:YES];
        self.downloadController = [[[VZProgressViewController alloc]
            initWithTitle:@"Downloading macOS"] autorelease];
        self.downloadController.statusText = image[@"name"] ?: @"Downloading restore image";
        self.downloadController.detailText = @"Keep Virtual Mac open. The iPad will remain awake until the download finishes.";
        self.downloadController.consoleHidden = YES;
        self.downloadController.indeterminate = expected == 0;
        self.downloadController.cancellationHandler = ^{ [self cancelDownload]; };
        UINavigationController *navigation = [[[UINavigationController alloc]
            initWithRootViewController:self.downloadController] autorelease];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        navigation.modalInPresentation = YES;
        navigation.preferredContentSize = CGSizeMake(620, 300);
        [self presentViewController:navigation animated:YES completion:nil];
        self.downloadTask = [NSURLSession.sharedSession downloadTaskWithURL:remoteURL
            completionHandler:^(NSURL *temporaryURL, NSURLResponse *response, NSError *error) {
            (void)response;
            NSError *moveError = nil;
            if (temporaryURL && !self.downloadCancelled) {
                [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
                [NSFileManager.defaultManager moveItemAtURL:temporaryURL
                    toURL:[NSURL fileURLWithPath:destination] error:&moveError];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.downloadTimer invalidate]; self.downloadTimer = nil;
                self.downloadTask = nil;
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                NSError *failure = error ?: moveError;
                BOOL cancelled = self.downloadCancelled;
                if (!failure)
                    [NSFileManager.defaultManager removeItemAtPath:self.downloadMarkerPath error:nil];
                if (!self.downloadController) return;
                [self.downloadController.navigationController dismissViewControllerAnimated:YES completion:^{
                    self.downloadController.cancellationHandler = nil;
                    self.downloadController = nil;
                    self.downloadDestination = nil;
                    self.downloadMarkerPath = nil;
                    if (failure && !cancelled) {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                            message:failure.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                    } else {
                        [self documentPicker:(id)self didPickDocumentsAtURLs:@[[NSURL fileURLWithPath:destination]]];
                    }
                }];
            });
        }];
        [self.downloadTask resume];
        self.downloadLastBytes = 0;
        self.downloadLastSample = NSDate.date;
        self.downloadTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            int64_t total = self.downloadTask.countOfBytesExpectedToReceive;
            int64_t received = self.downloadTask.countOfBytesReceived;
            if (total > 0) {
                float progress = (float)received / (float)total;
                self.downloadController.indeterminate = NO;
                self.downloadController.progress = progress;
                NSByteCountFormatter *formatter = [[[NSByteCountFormatter alloc] init] autorelease];
                formatter.countStyle = NSByteCountFormatterCountStyleFile;
                NSTimeInterval elapsed = -[self.downloadLastSample timeIntervalSinceNow];
                int64_t delta = received - self.downloadLastBytes;
                NSString *speed = elapsed > 0.05 && delta >= 0
                    ? [NSString stringWithFormat:@"%@/s",
                        [formatter stringFromByteCount:(int64_t)(delta / elapsed)]] : @"Calculating speed…";
                self.downloadController.statusText = [NSString stringWithFormat:
                    @"%.1f%% complete", progress * 100.0];
                self.downloadController.detailText = [NSString stringWithFormat:
                    @"%@ of %@ · %@\nKeep Virtual Mac open. The iPad will remain awake until the download finishes.",
                    [formatter stringFromByteCount:received],
                    [formatter stringFromByteCount:total], speed];
                self.downloadLastBytes = received;
                self.downloadLastSample = NSDate.date;
            }
        }];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url)
        return;
    NSString *extension = url.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"ipsw"]) {
        UIAlertController *invalid = [UIAlertController
            alertControllerWithTitle:@"Unsupported Restore Image"
            message:@"Choose a macOS IPSW restore image."
            preferredStyle:UIAlertControllerStyleAlert];
        [invalid addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:invalid animated:YES completion:nil];
        return;
    }
    [url startAccessingSecurityScopedResource];
    self.pendingIPSWURL = url;
    NSString *suggested = VZUniqueVMName(
        VZMarketingNameForRestoreImage(url));
    NSMutableDictionary *defaults = [NSMutableDictionary
        dictionaryWithDictionary:VZVMDefaultOptions()];
    defaults[VZPointingDeviceKey] =
        VZDefaultPointingDeviceForPath(self.pendingIPSWURL.path);
    defaults[VZKeyboardDeviceKey] =
        VZDefaultKeyboardDeviceForPath(self.pendingIPSWURL.path);
    VZVMConfigurationViewController *configuration =
        [[[VZVMConfigurationViewController alloc]
          initWithBundlePath:nil options:defaults
          completion:^(NSDictionary *result) {
            NSMutableDictionary *options = [NSMutableDictionary
                dictionaryWithDictionary:result];
            NSString *name = VZUniqueVMName(options[VZVMNameKey]);
            [options removeObjectForKey:VZVMNameKey];
            [self.delegate vmLibrary:self
                installRestoreImageAtURL:self.pendingIPSWURL
                name:name options:options];
        }] autorelease];
    configuration.vmName = suggested;
    [self presentConfiguration:configuration];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_machines release];
    [_filteredMachines release];
    [_searchText release];
    [_pendingIPSWURL release];
    [_collectionView release];
    [_emptyView release];
    [_downloadTask cancel];
    [_downloadTask release];
    [_downloadTimer invalidate];
    [_downloadTimer release];
    _downloadController.cancellationHandler = nil;
    [_downloadController release];
    [_downloadDestination release];
    [_downloadMarkerPath release];
    [_downloadLastSample release];
    [super dealloc];
}
@end

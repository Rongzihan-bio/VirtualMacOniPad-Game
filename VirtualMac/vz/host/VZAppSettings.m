#import "VZAppSettings.h"

NSString * const VZSettingsDidChangeNotification = @"VZSettingsDidChange";
NSString * const VZLibraryLayoutKey = @"LibraryLayout";
NSString * const VZAutoBootVMPathKey = @"AutoBootVMPath";
NSString * const VZAutoBootVMIdentifierKey = @"AutoBootVMIdentifier";
NSString * const VZKeyboardShortcutCaptureKey = @"KeyboardShortcutCapture";
NSString * const VZSystemGestureSuppressionKey = @"SystemGestureSuppression";
NSString * const VZMultitaskingGestureSuppressionKey = @"MultitaskingGestureSuppression";
NSString * const VZHomeIndicatorSuppressionKey = @"HomeIndicatorSuppression";
NSString * const VZShowStatusLabelKey = @"ShowDebugStatusOverlay";
NSString * const VZAutoDeleteRestoreImageKey = @"AutoDeleteRestoreImage";
NSString * const VZHUDVisibilityKey = @"HUDVisibility";
NSString * const VZHUDCornerKey = @"HUDCorner";
NSString * const VZExternalDisplayEnabledKey = @"ExternalDisplayEnabled";
NSString * const VZDisplayScalingKey = @"DisplayScaling";
NSString * const VZTouchDoubleTapAccommodationKey = @"TouchDoubleTapAccommodation";
NSString * const VZTouchTwoFingerScrollingKey = @"TouchTwoFingerScrolling";
NSString * const VZTouchTwoFingerRightClickKey = @"TouchTwoFingerRightClick";
NSString * const VZTouchLongPressRightClickKey = @"TouchLongPressRightClick";
NSString * const VZIPadOS162KeyboardWorkaroundKey = @"IPadOS162KeyboardWorkaround";
NSString * const VZNetworkResumeRecoveryKey = @"NetworkResumeRecovery";
NSString * const VZHUDOpacityKey = @"HUDOpacity";
NSString * const VZDebugLoggingKey = @"DebugLogging";

static NSString * const VZSettingsPath = @"/var/mobile/Media/VirtualMac/Settings.plist";
static CFStringRef const VZSettingsDarwinNotification =
    CFSTR("com.mac.virtual.settings-changed");

@interface VZAppSettings ()
@property(nonatomic, retain) NSMutableDictionary *values;
@end

@implementation VZAppSettings

+ (instancetype)sharedSettings
{
    static VZAppSettings *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [[self alloc] init]; });
    return settings;
}

- (instancetype)init
{
    if ((self = [super init])) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:VZSettingsPath];
        _values = [[NSMutableDictionary alloc] initWithDictionary:
            [saved isKindOfClass:NSDictionary.class] ? saved : @{}];
    }
    return self;
}

- (NSDictionary *)defaults
{
    return @{
        VZLibraryLayoutKey: @"grid",
        VZKeyboardShortcutCaptureKey: @YES,
        VZSystemGestureSuppressionKey: @NO,
        VZMultitaskingGestureSuppressionKey: @NO,
        VZHomeIndicatorSuppressionKey: @YES,
        VZShowStatusLabelKey: @NO,
        VZAutoDeleteRestoreImageKey: @YES,
        VZHUDVisibilityKey: @"automatic",
        VZHUDCornerKey: @"top-right",
        VZExternalDisplayEnabledKey: @NO,
        VZDisplayScalingKey: @"fit",
        VZTouchDoubleTapAccommodationKey: @YES,
        VZTouchTwoFingerScrollingKey: @YES,
        VZTouchTwoFingerRightClickKey: @YES,
        VZTouchLongPressRightClickKey: @NO,
        VZIPadOS162KeyboardWorkaroundKey: @NO,
        VZNetworkResumeRecoveryKey: @NO,
        VZHUDOpacityKey: @"0.55",
        VZDebugLoggingKey: @NO,
    };
}

- (BOOL)boolForKey:(NSString *)key
{
    id value = self.values[key];
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class])
        value = [self defaults][key];
    return [value respondsToSelector:@selector(boolValue)] ?
        [value boolValue] : NO;
}

- (NSString *)stringForKey:(NSString *)key
{
    id value = self.values[key];
    if (![value isKindOfClass:NSString.class])
        value = [self defaults][key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)save
{
    NSString *directory = VZSettingsPath.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    [self.values writeToFile:VZSettingsPath atomically:YES];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        VZSettingsDarwinNotification, NULL, NULL, YES);
    [NSNotificationCenter.defaultCenter postNotificationName:
        VZSettingsDidChangeNotification object:self];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key
{
    self.values[key] = @(value);
    [self save];
}

- (void)setString:(NSString *)value forKey:(NSString *)key
{
    if ([value isKindOfClass:NSString.class] && value.length)
        self.values[key] = value;
    else
        [self.values removeObjectForKey:key];
    [self save];
}

- (void)resetToDefaults
{
    [self.values removeAllObjects];
    [self save];
}

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    [result addEntriesFromDictionary:self.values];
    return result;
}

- (void)dealloc
{
    [_values release];
    [super dealloc];
}

@end

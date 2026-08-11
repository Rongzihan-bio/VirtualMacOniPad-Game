#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString * const VZLibraryLayoutKey;
FOUNDATION_EXPORT NSString * const VZAutoBootVMPathKey;
FOUNDATION_EXPORT NSString * const VZAutoBootVMIdentifierKey;
FOUNDATION_EXPORT NSString * const VZKeyboardShortcutCaptureKey;
FOUNDATION_EXPORT NSString * const VZSystemGestureSuppressionKey;
FOUNDATION_EXPORT NSString * const VZMultitaskingGestureSuppressionKey;
FOUNDATION_EXPORT NSString * const VZHomeIndicatorSuppressionKey;
FOUNDATION_EXPORT NSString * const VZShowStatusLabelKey;
FOUNDATION_EXPORT NSString * const VZAutoDeleteRestoreImageKey;
FOUNDATION_EXPORT NSString * const VZHUDVisibilityKey;
FOUNDATION_EXPORT NSString * const VZHUDCornerKey;
FOUNDATION_EXPORT NSString * const VZExternalDisplayEnabledKey;
FOUNDATION_EXPORT NSString * const VZDisplayScalingKey;
FOUNDATION_EXPORT NSString * const VZTouchDoubleTapAccommodationKey;
FOUNDATION_EXPORT NSString * const VZTouchTwoFingerScrollingKey;
FOUNDATION_EXPORT NSString * const VZTouchTwoFingerRightClickKey;
FOUNDATION_EXPORT NSString * const VZTouchLongPressRightClickKey;
FOUNDATION_EXPORT NSString * const VZIPadOS162KeyboardWorkaroundKey;
FOUNDATION_EXPORT NSString * const VZNetworkResumeRecoveryKey;
FOUNDATION_EXPORT NSString * const VZHUDOpacityKey;
FOUNDATION_EXPORT NSString * const VZDebugLoggingKey;

@interface VZAppSettings : NSObject
+ (instancetype)sharedSettings;
- (BOOL)boolForKey:(NSString *)key;
- (nullable NSString *)stringForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setString:(nullable NSString *)value forKey:(NSString *)key;
- (void)resetToDefaults;
- (NSDictionary *)dictionaryRepresentation;
@end

NS_ASSUME_NONNULL_END

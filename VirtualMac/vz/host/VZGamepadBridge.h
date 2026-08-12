#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZGamepadBridgeStateDidChangeNotification;

// Development bridge from one iPadOS GCController to the guest-side UDP HID
// receiver. It deliberately has no discovery or authentication yet; the user
// supplies a trusted IPv4 destination in Settings.
@interface VZGamepadBridge : NSObject
+ (instancetype)sharedBridge;
- (void)start;
- (void)setForegroundActive:(BOOL)active;
- (void)neutralize;
- (void)sendTestState;
- (NSDictionary *)stateSnapshot;
@end

NS_ASSUME_NONNULL_END

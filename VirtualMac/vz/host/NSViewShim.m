#import "NSViewShim.h"

NSString *const NSApplicationWillTerminateNotification =
    @"NSApplicationWillTerminateNotification";
NSString *const NSWindowDidBecomeKeyNotification =
    @"NSWindowDidBecomeKeyNotification";
NSString *const NSWindowDidChangeOcclusionStateNotification =
    @"NSWindowDidChangeOcclusionStateNotification";
NSString *const NSWindowDidResignKeyNotification =
    @"NSWindowDidResignKeyNotification";

static BOOL gVZSuppressFrameRequests;

// VZ's macOS trackpad haptic callback asks CoreGraphics Services to actuate
// the host trackpad. iPadOS has no CGS connection or equivalent host haptic
// device, and the extracted weak imports otherwise remain null and crash on
// the first guest click. A successful no-op preserves input semantics.
uint32_t CGSMainConnectionID(void)
{
    return 0;
}

int CGSActuateDeviceWithPattern(uint32_t connection,
                                uint64_t device,
                                uint32_t pattern,
                                uint64_t options)
{
    (void)connection;
    (void)device;
    (void)pattern;
    (void)options;
    return 0;
}

void VZSetNSViewFrameRequestsSuppressed(BOOL suppressed)
{
    gVZSuppressFrameRequests = suppressed;
}

@implementation NSView
- (void)setWantsLayer:(BOOL)wantsLayer
{
    // UIView is always layer-backed.
    (void)wantsLayer;
}

- (BOOL)wantsLayer
{
    return YES;
}

- (void)setLayer:(CALayer *)layer
{
    if (_appKitLayer == layer)
        return;
    [_appKitLayer removeFromSuperlayer];
    [_appKitLayer release];
    _appKitLayer = [layer retain];
    _appKitLayer.frame = self.bounds;
    [[super layer] addSublayer:_appKitLayer];
}

- (CALayer *)layer
{
    return _appKitLayer ?: [super layer];
}

- (UIWindow *)window
{
    UIWindow *window = [super window];
    if (window)
        return window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
            if (candidate.isKeyWindow)
                return candidate;
    }
    return nil;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _appKitLayer.frame = self.bounds;
    if ([self respondsToSelector:@selector(layout)])
        [self performSelector:@selector(layout)];
}

- (void)layout
{
    // AppKit layout hook; UIView drives layout through layoutSubviews.
}

- (void)dealloc
{
    [_appKitLayer release];
    [super dealloc];
}
@end

@implementation UIWindow (VZAppKitOcclusion)
- (NSUInteger)occlusionState
{
    // NSWindowOcclusionStateVisible.
    return self.hidden || gVZSuppressFrameRequests ? 0 : 2;
}
@end

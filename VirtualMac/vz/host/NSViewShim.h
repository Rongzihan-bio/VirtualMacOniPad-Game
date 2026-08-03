#import <UIKit/UIKit.h>

// The extracted macOS Virtualization framework weak-links AppKit. Providing the
// NSView class symbol lets dyld register VZVirtualMachineView and
// _VZFramebufferView on iOS. UIView supplies geometry, hierarchy, window, and
// a backing CALayer; these additions cover the AppKit layer-backed view API.
@interface NSView : UIView
{
    CALayer *_appKitLayer;
}
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic, retain) CALayer *layer;
@end

@interface UIWindow (VZAppKitOcclusion)
- (NSUInteger)occlusionState;
@end

// Weak AppKit globals referenced by VZVirtualMachineView and
// _VZFramebufferView. Export matching NSString constants before the extracted
// framework is loaded so its flat-namespace bindings are non-null.
FOUNDATION_EXPORT NSString *const NSApplicationWillTerminateNotification;
FOUNDATION_EXPORT NSString *const NSWindowDidBecomeKeyNotification;
FOUNDATION_EXPORT NSString *const NSWindowDidChangeOcclusionStateNotification;
FOUNDATION_EXPORT NSString *const NSWindowDidResignKeyNotification;

// A framebuffer observer must be registered before VZ finishes wiring its XPC
// handlers, but the shim window reports itself occluded until the VM starts so
// that registration does not request frames prematurely.
void VZSetNSViewFrameRequestsSuppressed(BOOL suppressed);

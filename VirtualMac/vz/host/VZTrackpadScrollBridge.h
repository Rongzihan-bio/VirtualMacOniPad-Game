#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*VZTrackpadScrollEmitter)(CGVector rawDelta,
                                        CGVector acceleratedDelta,
                                        NSUInteger phase,
                                        NSUInteger momentumPhase,
                                        void *context);

// Reconstructs the macOS trackpad scroll pipeline which is absent from the
// iPad UIScrollEvent stream. The implementation mirrors the Ventura
// MultitouchHID momentum estimator followed by IOHID's scroll accelerator.
// All entry points and the emitter run on the main thread.
void VZTrackpadScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                     void * _Nullable context);
void VZTrackpadScrollBridgeHandle(CGVector rawDelta,
                                  NSUInteger phase,
                                  CFTimeInterval timestamp);
// Magic Mouse surface input has a trackpad-like contact lifecycle on iPadOS,
// but it does not receive macOS momentum from the host. Keep it in a separate
// pipeline so its acceleration and momentum history cannot affect a trackpad.
void VZSurfaceMouseScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                         void * _Nullable context);
void VZSurfaceMouseScrollBridgeHandle(CGVector rawDelta,
                                      NSUInteger phase,
                                      CFTimeInterval timestamp);
// Direct touch does not provide macOS trackpad mickeys or momentum packets.
// Run it through an independent copy of the same state machine so touch and
// hardware-trackpad gestures cannot contaminate one another's history.
void VZTouchScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                  void * _Nullable context);
void VZTouchScrollBridgeHandle(CGVector translationDelta,
                               NSUInteger phase,
                               CFTimeInterval timestamp,
                               CGFloat speed);
void VZTrackpadScrollBridgeReset(void);

NS_ASSUME_NONNULL_END

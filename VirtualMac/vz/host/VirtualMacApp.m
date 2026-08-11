#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import "NSViewShim.h"
#import "VZVMLibraryViewController.h"
#import "VZAppSettings.h"
#import "VZDiagnostics.h"
#import "VZFailureDetailsViewController.h"
#import "VZProgressViewController.h"
#import "VZLocalization.h"
#import "VZSupport.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach-o/loader.h>
#include <errno.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static id gVirtualMachine;
static id gVirtualMachineDelegate;
static UIView *gFramebufferView;
static id gFramebuffer;
static id gKeyboard;
static id gPointingDevice;
static UIView *gInputView;
static UIView *gDisplayContainer;
static CALayer *gDisplayLayer;
static UIImageView *gCursorView;
static UILabel *gStatusLabel;
static UIView *gHUDView;
static UIPanGestureRecognizer *gTouchScrollRecognizer;
static UIPinchGestureRecognizer *gPinchRecognizer;
static UIRotationGestureRecognizer *gRotationRecognizer;
static UITapGestureRecognizer *gSmartMagnifyRecognizer;
static BOOL gSoftwareKeyboardRequested;
static BOOL gHUDHiddenForBoot;
static BOOL gHUDForcedVisibleForBoot;
static NSLayoutConstraint *gHUDHorizontalConstraint;
static NSLayoutConstraint *gHUDVerticalConstraint;
static IMP gOriginalFrameUpdate;
static IMP gOriginalCursorUpdate;
static uint64_t gFrameUpdateCount;
static uint64_t gCursorUpdateCount;
static uint64_t gPointerEventCount;
static uint64_t gPointerButtonEventCount;
static uint64_t gScrollEventCount;
static uint64_t gKeyEventCount;
static BOOL gDebugLogging;
// Globe-held state, tracked from the Darwin relay (the tweak reports the
// globe's raw HID press, which is reliable and prompt). The tweak translates
// globe+<key> chords at the HID layer and relays the translated key; this flag
// only lets the app drop raw chord keys that also reach its press path, so the
// guest never sees both the raw key and the translated key.
static BOOL gGlobeDown;
static uint64_t gLastHealthFrameCount;
static uint64_t gLastHealthInteractionCount;
static NSUInteger gFrameStallIntervals;
static CGPoint gMouseLocation;
// UIKit's pointer has its own absolute coordinate that cannot be warped when
// a direct touchscreen tap moves the guest cursor. Track raw host motion
// separately and apply its deltas to the guest coordinate so the next click
// remains at the touchscreen-selected location.
static CGPoint gHostPointerLocation;
static BOOL gHostPointerLocationValid;
static BOOL gUIKitHoverActive;
static CGSize gLastInputBoundsSize;
static CGFloat gLastPinchScale = 1.0;
static CGFloat gLastRotation;
// UIKit reports an indirect-pointer click as a touch while GameController
// reports the same physical click independently. Keep both lifetimes and send
// their union so either source releasing first cannot break a drag.
static NSUInteger gHardwareMouseButtons;
static NSUInteger gTouchButtons;
static CGPoint gLastPointerLocation = {NAN, NAN};
static NSUInteger gLastPointerButtons = NSUIntegerMax;
static CGSize gDisplayPixelSize = {1920, 1440};
static CGSize gCursorPixelSize;
static CGPoint gCursorHotspot;
static CFTimeInterval gLastPredictedCursorTime;
static void (*gHostVMStarted)(void);
static SEL S(const char *name);
static void setObj(id object, const char *selector, id value);
static void sendKey(UIKeyboardHIDUsage usage, BOOL pressed);
static void sendPointer(CGPoint point, CGRect bounds, NSUInteger pressedButtons);
static void setStatus(NSString *status);
// External display (Keynote-style: UIWindow.screen = externalScreen)
static UIWindow *gExternalWindow;
static UIView *gExternalMirrorView;

static void updateDisplayGeometry(void);
static void logFramebufferState(id view, id framebuffer, const char *phase);
static BOOL externalDisplayEnabled(void);
static void connectExternalDisplay(void);
static void disconnectExternalDisplay(void);
static void startVirtualMachine(UIView *container, id delegate,
                                NSString *bundlePath,
                                NSDictionary *options);

static NSString *VZInstallationFailureExplanation(NSString *failure)
{
    if ([failure containsString:@"Unexpected device state 'DFU'"] ||
        [failure containsString:@"Code=4014"] ||
        [failure containsString:@"error: 4014"]) {
        return VZL(@"Another usbmuxd service took control of the virtual DFU device before it entered RestoreOS. Uninstall usbmuxd from Sileo and try again.");
    }
    if ([failure containsString:@"AMRestorePerformRestoreModeRestoreWithError failed with error: 100"] ||
        [failure containsString:@"error: 100"]) {
        return VZL(@"Verify your iPad has sufficient free storage and try again.");
    }
    return nil;
}

// On iPadOS 15 and 16.2, CoreUI's candidate bar artwork can ask CoreImage for
// its legacy EAGL backend. Platform/unsandboxed apps receive a null GL entry
// point and crash in CI::GLContext before Virtual Mac code runs. CoreUI only
// requires an ordinary CIContext here, so use the supported Metal backend.
static id VZCoreUISharedMetalContext(id object, SEL selector) {
    (void)object; (void)selector;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        context = [[CIContext contextWithMTLDevice:device] retain];
    });
    return context;
}

static NSString *VZLatestKeyboardRenderingCrash(void) {
    NSString *root = @"/var/mobile/Library/Logs/CrashReporter";
    NSArray *directoryNames = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *name in directoryNames) {
        if ([name hasPrefix:@"VirtualMac-"] &&
            [name.pathExtension.lowercaseString isEqualToString:@"ips"])
            [candidates addObject:name];
    }
    NSArray *names = candidates;
    names = [names sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            NSString *leftPath = [root stringByAppendingPathComponent:left];
            NSString *rightPath = [root stringByAppendingPathComponent:right];
            NSDate *leftDate = [[NSFileManager.defaultManager
                attributesOfItemAtPath:leftPath error:nil]
                fileModificationDate] ?: NSDate.distantPast;
            NSDate *rightDate = [[NSFileManager.defaultManager
                attributesOfItemAtPath:rightPath error:nil]
                fileModificationDate] ?: NSDate.distantPast;
            return [rightDate compare:leftDate];
        }];
    NSUInteger examined = 0;
    for (NSString *name in names) {
        if (++examined > 8)
            break;
        NSString *path = [root stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:nil];
        NSString *report = data.length
            ? [[[NSString alloc] initWithData:data
                encoding:NSUTF8StringEncoding] autorelease] : nil;
        if ([report containsString:@"CI::GLContext::GLContext"] &&
            [report containsString:@"CUIShapeEffectStack sharedCIContext"])
            return name;
    }
    return nil;
}

static void VZEnableKeyboardRenderingFixAfterCrash(void) {
    static NSString * const processedCrashKey =
        @"LastKeyboardRenderingCrashReport";
    NSString *crash = VZLatestKeyboardRenderingCrash();
    if (!crash.length || [crash isEqualToString:
        [VZAppSettings.sharedSettings stringForKey:processedCrashKey]])
        return;
    [VZAppSettings.sharedSettings setString:crash forKey:processedCrashKey];
    [VZAppSettings.sharedSettings setBool:YES
        forKey:VZIPadOS162KeyboardWorkaroundKey];
    printf("[VirtualMac] enabled keyboard-rendering fix after crash %s\n",
        crash.UTF8String);
}

static void installKeyboardRenderingFix(void) {
    // This preference is either enabled explicitly or after the exact CoreUI
    // crash is observed on a previous launch. Do not guess from the OS version.
    if (![VZAppSettings.sharedSettings
            boolForKey:VZIPadOS162KeyboardWorkaroundKey])
        return;
    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI",
           RTLD_LAZY | RTLD_LOCAL);
    Class shapeEffects = objc_getClass("CUIShapeEffectStack");
    Method method = class_getClassMethod(shapeEffects,
        sel_registerName("sharedCIContext"));
    if (!method)
        return;
    class_replaceMethod(object_getClass(shapeEffects),
        method_getName(method), (IMP)VZCoreUISharedMetalContext,
        method_getTypeEncoding(method));
    printf("[VirtualMac] installed Metal keyboard-rendering fix\n");
}

static NSUInteger activePointerButtons(void) {
    return gHardwareMouseButtons | gTouchButtons;
}

static BOOL shouldShowStatusLabel(void) {
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if ([processInfo.arguments containsObject:@"--show-status-label"])
        return YES;
    return [VZAppSettings.sharedSettings boolForKey:VZShowStatusLabelKey];
}

static void resetPointerSession(BOOL releaseButtons) {
    gHostPointerLocationValid = NO;
    gUIKitHoverActive = NO;
    if (releaseButtons && (gTouchButtons || gHardwareMouseButtons)) {
        gTouchButtons = 0;
        gHardwareMouseButtons = 0;
        if (gInputView)
            sendPointer(gMouseLocation, gInputView.bounds, 0);
    }
}

static void startHealthMonitor(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        NSInteger state = gVirtualMachine
            ? ((NSInteger(*)(id, SEL))objc_msgSend)(
                  gVirtualMachine, S("state"))
            : -1;
        uint64_t frames = __atomic_load_n(
            &gFrameUpdateCount, __ATOMIC_RELAXED);
        uint64_t interactions = __atomic_load_n(
            &gPointerButtonEventCount, __ATOMIC_RELAXED) +
            __atomic_load_n(&gScrollEventCount, __ATOMIC_RELAXED) +
            __atomic_load_n(&gKeyEventCount, __ATOMIC_RELAXED);
        if (gDebugLogging) {
            printf("[VirtualMac] health state=%ld frames=%llu cursors=%llu "
                   "pointer=%llu scroll=%llu keys=%llu\n",
                   (long)state,
                   (unsigned long long)frames,
                   (unsigned long long)__atomic_load_n(
                       &gCursorUpdateCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gPointerEventCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gScrollEventCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gKeyEventCount, __ATOMIC_RELAXED));
        }
        if (state == 1 && frames != 0 && frames == gLastHealthFrameCount &&
            interactions != gLastHealthInteractionCount) {
            gFrameStallIntervals++;
            if (gFrameStallIntervals == 3 ||
                gFrameStallIntervals % 6 == 0) {
                printf("[VirtualMac] display stall intervals=%lu frames=%llu\n",
                       (unsigned long)gFrameStallIntervals,
                       (unsigned long long)frames);
                logFramebufferState(
                    gFramebufferView, gFramebuffer, "stalled");
            }
        } else {
            gFrameStallIntervals = 0;
        }
        gLastHealthFrameCount = frames;
        gLastHealthInteractionCount = interactions;
    });
    dispatch_resume(timer);
}

typedef struct {
    const void *object;
    const void *control;
} VZFrameUpdateSharedPtr;

static id CLS(const char *name) { return (id)objc_getClass(name); }
static SEL S(const char *name) { return sel_registerName(name); }
static id m0(id object, const char *selector) {
    return ((id(*)(id, SEL))objc_msgSend)(object, S(selector));
}
static id NEW(const char *className) {
    return m0(m0(CLS(className), "alloc"), "init");
}
static void setObj(id object, const char *selector, id value) {
    ((void(*)(id, SEL, id))objc_msgSend)(object, S(selector), value);
}
static NSURL *fileURL(NSString *path) {
    return [NSURL fileURLWithPath:path];
}

static CGPoint clampPointerLocation(CGPoint point, CGRect bounds) {
    return CGPointMake(
        fmin(CGRectGetMaxX(bounds), fmax(CGRectGetMinX(bounds), point.x)),
        fmin(CGRectGetMaxY(bounds), fmax(CGRectGetMinY(bounds), point.y)));
}

static void sendPointer(CGPoint point, CGRect bounds,
                        NSUInteger pressedButtons) {
    if (!gPointingDevice || bounds.size.width <= 0 ||
        bounds.size.height <= 0)
        return;
    point = clampPointerLocation(point, bounds);
    gMouseLocation = point;
    CGPoint normalized = CGPointMake(
        fmin(1.0, fmax(0.0, point.x / bounds.size.width)),
        fmin(1.0, fmax(0.0, point.y / bounds.size.height)));
    // Draw the already-decoded guest cursor at the host event location now.
    // Waiting for the pointer round-trip through VMM/PVG adds a very visible
    // frame or two of latency on an iPad trackpad.
    if (gCursorView && !gCursorView.hidden && gCursorView.image) {
        CGFloat scaleX = bounds.size.width / gDisplayPixelSize.width;
        CGFloat scaleY = bounds.size.height / gDisplayPixelSize.height;
        CGSize size = CGSizeMake(gCursorPixelSize.width * scaleX,
                                 gCursorPixelSize.height * scaleY);
        CGPoint origin = CGPointMake(
            gInputView.frame.origin.x + point.x - gCursorHotspot.x * scaleX,
            gInputView.frame.origin.y + point.y - gCursorHotspot.y * scaleY);
        gCursorView.frame = (CGRect){origin, size};
        gLastPredictedCursorTime = CACurrentMediaTime();
    }
    BOOL buttonsChanged = pressedButtons != gLastPointerButtons;
    if (!buttonsChanged && CGPointEqualToPoint(normalized,
                                               gLastPointerLocation))
        return;
    gLastPointerLocation = normalized;
    gLastPointerButtons = pressedButtons;
    if (buttonsChanged)
        __sync_add_and_fetch(&gPointerButtonEventCount, 1);
    id event = ((id(*)(id, SEL, CGPoint, NSInteger))objc_msgSend)(
        m0(CLS("_VZScreenCoordinatePointerEvent"), "alloc"),
        S("initWithLocation:pressedButtons:"),
        normalized, (NSInteger)pressedButtons);
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendPointerEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gPointerEventCount, 1);
    if (count <= 8 || buttonsChanged)
        printf("[VirtualMac] input pointer=%llu location=%.4f,%.4f buttons=0x%lx\n",
               (unsigned long long)count, normalized.x, normalized.y,
               (unsigned long)pressedButtons);
}

static void sendIndirectPointerLocation(CGPoint hostPoint, CGRect bounds) {
    // Trackpad coordinates are already absolute in the input view. Prefer reliable native absolute tracking; 
    // after touching the screen, the next trackpad movement/click simply uses its own location.
    sendPointer(hostPoint, bounds, activePointerButtons());
}

static void sendMagnification(double magnification, NSUInteger phase) {
    if (!gPointingDevice)
        return;
    id event = ((id(*)(id, SEL, double, NSUInteger))objc_msgSend)(
        m0(CLS("_VZMagnifyEvent"), "alloc"),
        S("initWithMagnification:phase:"), magnification, phase);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendMagnifyEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input magnify delta=%.4f phase=0x%lx\n",
               magnification, (unsigned long)phase);
}

static void sendRotation(double rotation, NSUInteger phase) {
    if (!gPointingDevice)
        return;
    id event = ((id(*)(id, SEL, double, NSUInteger))objc_msgSend)(
        m0(CLS("_VZRotationEvent"), "alloc"),
        S("initWithRotation:phase:"), rotation, phase);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendRotationEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input rotate delta=%.4f phase=0x%lx\n",
               rotation, (unsigned long)phase);
}

static void sendSmartMagnification(void) {
    if (!gPointingDevice)
        return;
    id event = NEW("_VZSmartMagnifyEvent");
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendSmartMagnifyEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input smart magnify\n");
}

static void sendMouseDelta(float deltaX, float deltaY) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect bounds = gInputView.bounds;
        gMouseLocation.x =
            fmin(CGRectGetMaxX(bounds), fmax(CGRectGetMinX(bounds),
                                             gMouseLocation.x + deltaX));
        gMouseLocation.y =
            fmin(CGRectGetMaxY(bounds), fmax(CGRectGetMinY(bounds),
                                             gMouseLocation.y - deltaY));
        sendPointer(gMouseLocation, bounds, activePointerButtons());
    });
}

static void sendMouseButton(NSUInteger mask, BOOL pressed) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (pressed)
            gHardwareMouseButtons |= mask;
        else
            gHardwareMouseButtons &= ~mask;
        sendPointer(gMouseLocation, gInputView.bounds,
                    activePointerButtons());
    });
}

static void sendScrollWheel(CGVector rawDelta, CGVector acceleratedDelta,
                            BOOL directionInvertedFromDevice,
                            NSUInteger deviceCategory,
                            NSUInteger phase) {
    if (!gPointingDevice)
        return;
    id event = ((id(*)(id, SEL, double, double, double, double,
                       NSUInteger, NSUInteger))objc_msgSend)(
        m0(CLS("_VZScrollWheelEvent"), "alloc"),
        S("initWithScrollingDeltaX:scrollingDeltaY:"
          "acceleratedScrollingDeltaX:acceleratedScrollingDeltaY:"
          "scrollPhase:momentumPhase:"),
        -rawDelta.dy, rawDelta.dx,
        -rawDelta.dy, rawDelta.dx, phase, 0);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendScrollWheelEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gScrollEventCount, 1);
    if (count <= 12 || (gDebugLogging && phase != 4))
        printf("[VirtualMac] input scroll=%llu raw=%.3f,%.3f "
               "accelerated=%.3f,%.3f inverted=%d device=%lu "
               "phase=0x%lx\n",
               (unsigned long long)count, rawDelta.dx, rawDelta.dy,
               acceleratedDelta.dx, acceleratedDelta.dy,
               directionInvertedFromDevice, (unsigned long)deviceCategory,
               (unsigned long)phase);
}

static void installGCMouse(void) {
    GCMouse *mouse = GCMouse.current;
    printf("[VirtualMac] GC mouse current=%p input=%p\n",
           mouse, mouse.mouseInput);
    if (!mouse)
        return;
    mouse.mouseInput.mouseMovedHandler =
        ^(GCMouseInput *input, float deltaX, float deltaY) {
        (void)input;
        // UIKit hover is the authoritative absolute path for a trackpad.
        // Some devices also appear as GCMouse; accepting both makes motion
        // jump or hit artificial edges after system UI steals the pointer.
        if (gUIKitHoverActive)
            return;
        sendMouseDelta(deltaX, deltaY);
    };
    mouse.mouseInput.leftButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(1, pressed);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(2, pressed);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(4, pressed);
    };
}

static void recoverNetworkingAfterResume(void)
{
    if (!gVirtualMachine || ![VZAppSettings.sharedSettings
            boolForKey:VZNetworkResumeRecoveryKey])
        return;
    NSInteger hostMajor =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    const char *launchctl = hostMajor == 14
        ? "/usr/bin/launchctl"
        : (access("/var/jb/usr/bin/launchctl", X_OK) == 0
            ? "/var/jb/usr/bin/launchctl" : "/var/jb/bin/launchctl");
    if (access(launchctl, X_OK) != 0)
        return;
    const char *labels[] = {
        hostMajor <= 15 ? "system/com.apple.NetworkSharing"
                        : "user/501/com.apple.NetworkSharing",
        hostMajor <= 15 ? "system/vzi.apple.bootpd"
                        : "user/501/vzi.apple.bootpd",
        NULL};
    for (NSUInteger index = 0; labels[index]; index++) {
        const char *label = labels[index];
        char *arguments[] = {(char *)launchctl, "kickstart",
                             (char *)label, NULL};
        pid_t process = 0;
        int result = posix_spawn(&process, launchctl, NULL, NULL,
                                 arguments, environ);
        printf("[VirtualMac] network resume kickstart label=%s result=%d pid=%d\n",
               label, result, process);
    }
}

static void scheduleInputSelfTest(void) {
    if (unlink("/tmp/vz-input-self-test") != 0)
        return;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        CGRect bounds = gInputView.bounds;
        CGPoint point = CGPointMake(
            CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.75,
            CGRectGetMidY(bounds));
        printf("[VirtualMac] input self-test begin\n");
        sendPointer(point, bounds, 0);
        sendKey((UIKeyboardHIDUsage)0x39, YES);  // Caps Lock
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            sendKey((UIKeyboardHIDUsage)0x39, NO);
            printf("[VirtualMac] input self-test sent pointer and Caps Lock\n");
        });
    });
}

static void pollInputCommand(void) {
    NSString *path = @"/tmp/vz-input-command";
    NSString *command = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (command.length && unlink(path.fileSystemRepresentation) == 0) {
        NSArray<NSString *> *fields = [command
            componentsSeparatedByCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *field in fields) {
            if (field.length)
                [tokens addObject:field];
        }
        if (tokens.count == 2 && [tokens[0] isEqualToString:@"tapkey"]) {
            UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)tokens[1].intValue;
            printf("[VirtualMac] input command tapkey HID=0x%x\n",
                   (unsigned int)usage);
            sendKey(usage, YES);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ sendKey(usage, NO); });
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"key"]) {
            UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)tokens[1].intValue;
            BOOL pressed = tokens[2].boolValue;
            printf("[VirtualMac] input command key HID=0x%x pressed=%d\n",
                   (unsigned int)usage, pressed);
            sendKey(usage, pressed);
        } else if (tokens.count == 4 &&
                   [tokens[0] isEqualToString:@"click"]) {
            CGFloat x = MAX(0, MIN(1, tokens[1].doubleValue));
            CGFloat y = MAX(0, MIN(1, tokens[2].doubleValue));
            NSUInteger button = MAX(1, MIN(4, tokens[3].integerValue));
            CGRect bounds = gInputView.bounds;
            CGPoint point = CGPointMake(CGRectGetWidth(bounds) * x,
                                        CGRectGetHeight(bounds) * y);
            printf("[VirtualMac] input command click %.3f,%.3f button=0x%lx\n",
                   x, y, (unsigned long)button);
            sendPointer(point, bounds, button);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ sendPointer(point, bounds, 0); });
        } else if (tokens.count == 4 &&
                   [tokens[0] isEqualToString:@"scroll"]) {
            double x = tokens[1].doubleValue;
            double y = tokens[2].doubleValue;
            NSUInteger phase = tokens[3].integerValue;
            printf("[VirtualMac] input command scroll %.3f,%.3f phase=0x%lx\n",
                   x, y, (unsigned long)phase);
            sendScrollWheel(CGVectorMake(x, y), CGVectorMake(x, y),
                            NO, 0, phase);
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"magnify"]) {
            double delta = tokens[1].doubleValue;
            NSUInteger phase = tokens[2].integerValue;
            printf("[VirtualMac] input command magnify %.4f phase=0x%lx\n",
                   delta, (unsigned long)phase);
            sendMagnification(delta, phase);
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"rotate"]) {
            double delta = tokens[1].doubleValue;
            NSUInteger phase = tokens[2].integerValue;
            printf("[VirtualMac] input command rotate %.4f phase=0x%lx\n",
                   delta, (unsigned long)phase);
            sendRotation(delta, phase);
        } else if (tokens.count == 1 &&
                   [tokens[0] isEqualToString:@"smartmagnify"]) {
            printf("[VirtualMac] input command smart magnify\n");
            sendSmartMagnification();
        } else {
            printf("[VirtualMac] invalid input command: %s\n",
                   command.UTF8String);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ pollInputCommand(); });
}

static void scheduleRecoveryDialogDismissal(void) {
    if (unlink("/tmp/vz-dismiss-restart-alert") != 0)
        return;
    printf("[VirtualMac] recovery dialog auto-dismiss armed\n");
    for (int attempt = 0; attempt < 10; attempt++) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (4 + attempt) * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            printf("[VirtualMac] recovery dialog Return attempt=%d\n",
                   attempt + 1);
            sendKey((UIKeyboardHIDUsage)0x28, YES);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                sendKey((UIKeyboardHIDUsage)0x28, NO);
            });
        });
    }
}

static BOOL gForceStopPending;
static dispatch_source_t gControlTimer;

static void writeStopMarker(const char *path, const char *message) {
    FILE *marker = fopen(path, "w");
    if (!marker)
        return;
    fputs(message, marker);
    fputc('\n', marker);
    fclose(marker);
}

static void forceStopVirtualMachine(void) {
    if (!gVirtualMachine || gForceStopPending)
        return;

    NSInteger state = ((NSInteger(*)(id, SEL))objc_msgSend)(
        gVirtualMachine, S("state"));
    if (state == 0) {
        writeStopMarker("/tmp/vz-guest-stopped", "already stopped");
        return;
    }
    if (![gVirtualMachine respondsToSelector:S("stopWithCompletionHandler:")]) {
        writeStopMarker("/tmp/vz-force-stop-failed",
                        "stopWithCompletionHandler: unavailable");
        return;
    }

    gForceStopPending = YES;
    printf("[VirtualMac] direct virtual machine stop requested state=%ld\n",
           (long)state);
    void (^completion)(NSError *) = ^(NSError *error) {
        gForceStopPending = NO;
        if (error) {
            const char *description = [[error description] UTF8String];
            writeStopMarker("/tmp/vz-force-stop-failed",
                            description ?: "unknown direct stop error");
            printf("[VirtualMac] direct virtual machine stop failed: %s\n",
                   description ?: "unknown error");
            return;
        }
        writeStopMarker("/tmp/vz-guest-stopped", "direct stop complete");
        printf("[VirtualMac] direct virtual machine stop complete\n");
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([gVirtualMachineDelegate respondsToSelector:
                    S("finishVMAndShowLibraryWithError:")])
                ((void(*)(id, SEL, id))objc_msgSend)(
                    gVirtualMachineDelegate,
                    S("finishVMAndShowLibraryWithError:"), nil);
        });
    };
    ((void(*)(id, SEL, id))objc_msgSend)(
        gVirtualMachine, S("stopWithCompletionHandler:"), completion);
}

static void startControlMonitor(void) {
    gControlTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        gControlTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(gControlTimer, ^{
        if (unlink("/tmp/vz-request-guest-stop") == 0)
            forceStopVirtualMachine();
        if (unlink("/tmp/vz-request-force-stop") == 0)
            forceStopVirtualMachine();
    });
    dispatch_resume(gControlTimer);
}

// Translate USB HID usages reported by UIKit to the macOS virtual key codes
// consumed by _VZKeyEvent. Cover the standard alphanumeric, navigation,
// function, and modifier keys used by the built-in iPad keyboard.
static NSInteger macVirtualKeyCode(UIKeyboardHIDUsage usage) {
    static const int16_t alphaAndNumberRow[] = {
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,
    };
    NSInteger raw = (NSInteger)usage;
    if (raw >= 0x04 && raw <= 0x27)
        return alphaAndNumberRow[raw - 0x04];
    switch (raw) {
    case 0x28: return 36;  // Return
    case 0x29: return 53;  // Escape
    case 0x2a: return 51;  // Delete / Backspace
    case 0x2b: return 48;  // Tab
    case 0x2c: return 49;  // Space
    case 0x2d: return 27;  // -
    case 0x2e: return 24;  // =
    case 0x2f: return 33;  // [
    case 0x30: return 30;  // ]
    case 0x31: return 42;  // Backslash
    case 0x33: return 41;  // ;
    case 0x34: return 39;  // Quote
    case 0x35: return 50;  // Grave
    case 0x36: return 43;  // Comma
    case 0x37: return 47;  // Period
    case 0x38: return 44;  // Slash
    case 0x39: return 57;  // Caps Lock
    case 0x3a: return 122; // F1
    case 0x3b: return 120; // F2
    case 0x3c: return 99;  // F3
    case 0x3d: return 118; // F4
    case 0x3e: return 96;  // F5
    case 0x3f: return 97;  // F6
    case 0x40: return 98;  // F7
    case 0x41: return 100; // F8
    case 0x42: return 101; // F9
    case 0x43: return 109; // F10
    case 0x44: return 103; // F11
    case 0x45: return 111; // F12
    case 0x46: return 105; // Print Screen / F13
    case 0x47: return 107; // Scroll Lock / F14
    case 0x48: return 113; // Pause / F15
    case 0x49: return 114; // Insert / Help
    case 0x4a: return 115; // Home
    case 0x4b: return 116; // Page Up
    case 0x4c: return 117; // Forward Delete
    case 0x4d: return 119; // End
    case 0x4e: return 121; // Page Down
    case 0x4f: return 124; // Right Arrow
    case 0x50: return 123; // Left Arrow
    case 0x51: return 125; // Down Arrow
    case 0x52: return 126; // Up Arrow
    case 0x53: return 71;  // Keypad Clear / Num Lock
    case 0x54: return 75;  // Keypad /
    case 0x55: return 67;  // Keypad *
    case 0x56: return 78;  // Keypad -
    case 0x57: return 69;  // Keypad +
    case 0x58: return 76;  // Keypad Enter
    case 0x59: return 83;  // Keypad 1
    case 0x5a: return 84;  // Keypad 2
    case 0x5b: return 85;  // Keypad 3
    case 0x5c: return 86;  // Keypad 4
    case 0x5d: return 87;  // Keypad 5
    case 0x5e: return 88;  // Keypad 6
    case 0x5f: return 89;  // Keypad 7
    case 0x60: return 91;  // Keypad 8
    case 0x61: return 92;  // Keypad 9
    case 0x62: return 82;  // Keypad 0
    case 0x63: return 65;  // Keypad decimal
    case 0x64: return 10;  // ISO non-US backslash
    case 0x67: return 81;  // Keypad =
    case 0x87: return 94;  // JIS underscore / Ro
    case 0x89: return 93;  // JIS Yen
    case 0x8a: return 104; // JIS Kana / conversion
    case 0x8b: return 102; // JIS Eisu / non-conversion
    case 0x8c: return 95;  // JIS keypad comma
    case 0x90: return 104; // LANG1 / Kana
    case 0x91: return 102; // LANG2 / Eisu
    case 0xe0: return 59;  // Left Control
    case 0xe1: return 56;  // Left Shift
    case 0xe2: return 58;  // Left Option
    case 0xe3: return 55;  // Left Command
    case 0xe4: return 62;  // Right Control
    case 0xe5: return 60;  // Right Shift
    case 0xe6: return 61;  // Right Option
    case 0xe7: return 54;  // Right Command
    default: return -1;
    }
}

static void sendKey(UIKeyboardHIDUsage usage, BOOL pressed) {
    if (!gKeyboard)
        return;
    NSInteger keyCode = macVirtualKeyCode(usage);
    if (keyCode < 0) {
        printf("[VirtualMac] input unmapped HID usage=0x%lx\n",
               (unsigned long)usage);
        return;
    }
    id event = ((id(*)(id, SEL, NSInteger, unsigned short))objc_msgSend)(
        m0(CLS("_VZKeyEvent"), "alloc"), S("initWithType:keyCode:"),
        pressed ? 0 : 1, (unsigned short)keyCode);
    ((void(*)(id, SEL, id))objc_msgSend)(
        gKeyboard, S("sendKeyEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gKeyEventCount, 1);
    if (count <= 12)
        printf("[VirtualMac] input key=%llu HID=0x%lx mac=%ld pressed=%d\n",
               (unsigned long long)count, (unsigned long)usage,
               (long)keyCode, pressed);
}

// The tweak translates globe+<key> chords at the HID layer (lines mirror a
// MacBook's Fn+arrow / Fn+Delete) and relays the translated key. When a raw
// chord key still reaches the app's press path — the globe does, so others may
// — drop it while the globe is held so the guest never gets the raw key on top
// of the translated one. Deliberately NOT a translation: iPadOS's input-method
// switcher eats globe+arrow before the app ever sees it, so the tweak must own
// the translation.
static BOOL VZIsGlobeChordSource(UIKeyboardHIDUsage usage)
{
    return usage == 0x52 || usage == 0x51 || usage == 0x50 ||
        usage == 0x4f || usage == 0x2a || usage == 0x28;
}

static BOOL sendPresses(NSSet<UIPress *> *presses, BOOL pressed) {
    // When no guest keyboard is active, UIKit owns hardware key events (for
    // example numeric input in the VM configuration alert). Treating a press
    // as handled merely because it has a HID key swallowed those keystrokes.
    if (!gKeyboard || !gInputView || gInputView.hidden || !gInputView.window)
        return NO;
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (!press.key)
            continue;
        UIKeyboardHIDUsage usage = press.key.keyCode;
        // The globe/Fn key reaches the app's press path as a Consumer-page
        // usage (0x29D on-device). The tweak already swallows it system-wide;
        // swallow the app's own copy too so it never reaches the guest.
        if (usage == 0x29d || usage == 0x22d || usage == 0x18a) {
            handled = YES;
            continue;
        }
        if (gGlobeDown && VZIsGlobeChordSource(usage)) {
            // Tweak relays the translated key; drop the raw chord key.
            handled = YES;
            continue;
        }
        sendKey(usage, pressed);
        handled = YES;
    }
    return handled;
}

static void shellShortcutNotification(CFNotificationCenterRef center,
                                      void *observer, CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)object;
    (void)userInfo;
    NSString *notification = (NSString *)name;
    BOOL pressed = [notification hasSuffix:@".down"];
    UIKeyboardHIDUsage usage = 0;
    if ([notification containsString:@"command-space"])
        usage = (UIKeyboardHIDUsage)0x2c;
    else if ([notification containsString:@"command-tab"])
        usage = (UIKeyboardHIDUsage)0x2b;
    else if ([notification containsString:@"command-grave"])
        usage = (UIKeyboardHIDUsage)0x35;
    else if ([notification containsString:@"globe"]) {
        // The tweak tracks held state from raw HID; the app mirrors it here so
        // sendPresses can drop raw chord keys while the globe is held. Nothing
        // is injected for the globe itself.
        gGlobeDown = pressed;
        printf("[VirtualMac] SpringBoard globe relay pressed=%d\n", pressed);
        return;
    } else if ([notification containsString:@"pageup"])
        usage = (UIKeyboardHIDUsage)0x4b;
    else if ([notification containsString:@"pagedown"])
        usage = (UIKeyboardHIDUsage)0x4e;
    else if ([notification containsString:@"home"])
        usage = (UIKeyboardHIDUsage)0x4a;
    else if ([notification containsString:@"end"])
        usage = (UIKeyboardHIDUsage)0x4d;
    else if ([notification containsString:@"forward-delete"])
        usage = (UIKeyboardHIDUsage)0x4c;
    else if ([notification containsString:@"keypad-enter"])
        usage = (UIKeyboardHIDUsage)0x58;
    if (usage) {
        printf("[VirtualMac] SpringBoard shortcut relay usage=0x%lx pressed=%d\n",
               (unsigned long)usage, pressed);
        sendKey(usage, pressed);
    }
}

static void installShellShortcutRelay(void) {
    CFNotificationCenterRef center =
        CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *shortcut in @[@"command-space", @"command-tab",
                                  @"command-grave", @"globe",
                                  @"pageup", @"pagedown", @"home", @"end",
                                  @"forward-delete", @"keypad-enter"]) {
        for (NSString *state in @[@"down", @"up"]) {
            NSString *name = [NSString stringWithFormat:
                @"com.mac.virtual.%@.%@", shortcut, state];
            CFNotificationCenterAddObserver(
                center, NULL, shellShortcutNotification,
                (CFStringRef)name, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}

@interface NSObject (VZScrollEventSPI)
- (CGVector)nonAcceleratedDelta;
- (CGVector)acceleratedDelta;
- (BOOL)directionInvertedFromDevice;
@end

@interface UIPanGestureRecognizer (VZScrollEventSPI)
- (void)_scrollingChangedWithEvent:(id)event;
@end

@interface VZRawScrollRecognizer : UIPanGestureRecognizer {
    CGVector _vzRawDelta;
    CGVector _vzAcceleratedDelta;
    BOOL _vzDirectionInverted;
}
- (CGVector)vzRawDelta;
- (CGVector)vzAcceleratedDelta;
- (BOOL)vzDirectionInverted;
@end

@implementation VZRawScrollRecognizer

- (void)_scrollingChangedWithEvent:(id)event
{
    _vzRawDelta = [event nonAcceleratedDelta];
    _vzAcceleratedDelta = [event acceleratedDelta];
    _vzDirectionInverted = [event directionInvertedFromDevice];
    [super _scrollingChangedWithEvent:event];
}

- (CGVector)vzRawDelta { return _vzRawDelta; }
- (CGVector)vzAcceleratedDelta { return _vzAcceleratedDelta; }
- (BOOL)vzDirectionInverted { return _vzDirectionInverted; }

@end

static void sendSoftwareKey(UIKeyboardHIDUsage usage, BOOL shifted);

@interface VZInputView : UIView <UIPointerInteractionDelegate, UIKeyInput> {
    UIInputView *_vzAccessoryView;
    UIStackView *_vzAccessoryStack;
    NSMutableSet<NSNumber *> *_vzHeldSoftwareModifiers;
    CGPoint _vzDirectTouchStart;
    CGPoint _vzLastDirectTap;
    NSTimeInterval _vzLastDirectTapTime;
    BOOL _vzDirectTouchActive;
    BOOL _vzDirectTouchDragging;
    NSMutableDictionary<NSValue *, NSValue *> *_vzDirectTouchOrigins;
    NSMutableDictionary<NSValue *, NSValue *> *_vzDirectTouchPositions;
    NSMutableSet<NSValue *> *_vzActiveDirectTouchKeys;
    NSTimeInterval _vzDirectGestureStartTime;
    CGFloat _vzDirectGestureMaximumMovement;
    NSUInteger _vzDirectGestureGeneration;
    BOOL _vzTwoFingerCandidate;
    BOOL _vzLongPressConsumed;
    BOOL _vzDirectPrimaryPressed;
}
@end

@implementation VZInputView

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (BOOL)hasText { return YES; }

- (UIView *)inputAccessoryView
{
    if (GCKeyboard.coalescedKeyboard)
        return nil;
    if (_vzAccessoryView)
        return _vzAccessoryView;
    _vzHeldSoftwareModifiers = [[NSMutableSet alloc] init];
    _vzAccessoryView = [[UIInputView alloc]
        initWithFrame:CGRectMake(0, 0, 0, 52)
        inputViewStyle:UIInputViewStyleKeyboard];
    UIScrollView *scroll = [[[UIScrollView alloc] init] autorelease];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.showsHorizontalScrollIndicator = YES;
    scroll.directionalLockEnabled = YES;
    UIStackView *stack = [[[UIStackView alloc] init] autorelease];
    _vzAccessoryStack = [stack retain];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 6;
    NSArray *keys = @[
        @[@"esc", @0x29, @NO],
        @[@"tab", @0x2b, @NO],
        @[@"⇧", @0xe1, @YES], @[@"⌃", @0xe0, @YES],
        @[@"⌥", @0xe2, @YES], @[@"⌘", @0xe3, @YES],
        @[@"←", @0x50, @NO], @[@"↓", @0x51, @NO],
        @[@"↑", @0x52, @NO], @[@"→", @0x4f, @NO],
        @[@"home", @0x4a, @NO], @[@"end", @0x4d, @NO],
        @[@"pg up", @0x4b, @NO], @[@"pg dn", @0x4e, @NO],
        @[@"F1", @0x3a, @NO], @[@"F2", @0x3b, @NO],
        @[@"F3", @0x3c, @NO], @[@"F4", @0x3d, @NO],
        @[@"F5", @0x3e, @NO], @[@"F6", @0x3f, @NO],
        @[@"F7", @0x40, @NO], @[@"F8", @0x41, @NO],
        @[@"F9", @0x42, @NO], @[@"F10", @0x43, @NO],
        @[@"F11", @0x44, @NO], @[@"F12", @0x45, @NO],
    ];
    for (NSArray *key in keys) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:key[0] forState:UIControlStateNormal];
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:17
            weight:UIFontWeightSemibold];
        button.tag = [key[1] integerValue];
        button.accessibilityHint = [key[2] boolValue]
            ? VZL(@"Double-tap to hold or release this modifier") : nil;
        [button addTarget:self action:@selector(accessoryKeyPressed:)
            forControlEvents:UIControlEventTouchUpInside];
        button.layer.cornerRadius = 7;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.layer.borderWidth = 0.5;
        button.layer.borderColor = UIColor.separatorColor.CGColor;
        button.backgroundColor = UIColor.secondarySystemBackgroundColor;
        CGFloat width = [key[0] length] > 3 ? 62 : 48;
        [button.widthAnchor constraintEqualToConstant:width].active = YES;
        [stack addArrangedSubview:button];
    }
    [scroll addSubview:stack];
    [_vzAccessoryView addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:_vzAccessoryView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_vzAccessoryView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_vzAccessoryView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_vzAccessoryView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.topAnchor constant:5],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.bottomAnchor constant:-5],
    ]];
    return _vzAccessoryView;
}

- (void)accessoryKeyPressed:(UIButton *)sender
{
    UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)sender.tag;
    BOOL modifier = usage >= 0xe0 && usage <= 0xe7;
    if (modifier) {
        NSNumber *key = @(usage);
        BOOL hold = ![_vzHeldSoftwareModifiers containsObject:key];
        if (hold) [_vzHeldSoftwareModifiers addObject:key];
        else [_vzHeldSoftwareModifiers removeObject:key];
        sender.backgroundColor = hold ? UIColor.systemGray3Color
                                      : UIColor.secondarySystemBackgroundColor;
        [sender setTitleColor:UIColor.labelColor
                     forState:UIControlStateNormal];
        sender.accessibilityTraits = hold
            ? (sender.accessibilityTraits | UIAccessibilityTraitSelected)
            : (sender.accessibilityTraits & ~UIAccessibilityTraitSelected);
        sendKey(usage, hold);
    } else {
        sendSoftwareKey(usage, NO);
    }
}

- (void)releaseSoftwareModifiers
{
    for (NSNumber *usage in _vzHeldSoftwareModifiers)
        sendKey((UIKeyboardHIDUsage)usage.unsignedIntegerValue, NO);
    [_vzHeldSoftwareModifiers removeAllObjects];
    for (UIView *view in _vzAccessoryStack.arrangedSubviews) {
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (id)view;
            button.backgroundColor = UIColor.secondarySystemBackgroundColor;
            [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
            button.accessibilityTraits &= ~UIAccessibilityTraitSelected;
        }
    }
}

- (BOOL)resignFirstResponder
{
    [self releaseSoftwareModifiers];
    return [super resignFirstResponder];
}

static void sendSoftwareKey(UIKeyboardHIDUsage usage, BOOL shifted)
{
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, YES);
    sendKey(usage, YES);
    sendKey(usage, NO);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, NO);
}

static void sendSoftwareChord(UIKeyboardHIDUsage usage, BOOL shifted,
                              BOOL option)
{
    if (option) sendKey((UIKeyboardHIDUsage)0xE2, YES);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, YES);
    sendKey(usage, YES);
    sendKey(usage, NO);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, NO);
    if (option) sendKey((UIKeyboardHIDUsage)0xE2, NO);
}

- (void)insertText:(NSString *)text
{
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character >= 'a' && character <= 'z')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x04 + character - 'a'), NO);
        else if (character >= 'A' && character <= 'Z')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x04 + character - 'A'), YES);
        else if (character >= '1' && character <= '9')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x1e + character - '1'), NO);
        else if (character == '0') sendSoftwareKey((UIKeyboardHIDUsage)0x27, NO);
        else if (character == ' ') sendSoftwareKey((UIKeyboardHIDUsage)0x2c, NO);
        else if (character == '\t') sendSoftwareKey((UIKeyboardHIDUsage)0x2b, NO);
        else if (character == '\n' || character == '\r') sendSoftwareKey((UIKeyboardHIDUsage)0x28, NO);
        else {
            NSString *shiftedNumbers = @"!@#$%^&*()";
            NSString *oneCharacter = [NSString stringWithCharacters:&character length:1];
            NSUInteger numberPosition = [shiftedNumbers rangeOfString:oneCharacter].location;
            if (numberPosition != NSNotFound) {
                UIKeyboardHIDUsage usage = numberPosition == 9
                    ? (UIKeyboardHIDUsage)0x27
                    : (UIKeyboardHIDUsage)(0x1e + numberPosition);
                sendSoftwareKey(usage, YES);
                continue;
            }
            switch (character) {
            case 0x00a3: // £: Option-3 on the macOS U.S. layout.
                sendSoftwareChord((UIKeyboardHIDUsage)0x20, NO, YES); continue;
            case 0x20ac: // €: Option-Shift-2.
                sendSoftwareChord((UIKeyboardHIDUsage)0x1f, YES, YES); continue;
            case 0x00a5: case 0xffe5: // ¥ / full-width yen: Option-Y.
                sendSoftwareChord((UIKeyboardHIDUsage)0x1c, NO, YES); continue;
            case 0x2026: // …: Option-semicolon.
                sendSoftwareChord((UIKeyboardHIDUsage)0x33, NO, YES); continue;
            case 0x2018: // ‘: Option-right bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x30, NO, YES); continue;
            case 0x2019: // ’: Option-Shift-right bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x30, YES, YES); continue;
            case 0x201c: // “: Option-left bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x2f, NO, YES); continue;
            case 0x201d: // ”: Option-Shift-left bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x2f, YES, YES); continue;
            default: break;
            }
            NSString *plain = @"-=[]\\;',./`";
            NSString *shift = @"_+{}|:\"<>?~";
            NSUInteger position = [plain rangeOfString:oneCharacter].location;
            BOOL shifted = NO;
            if (position == NSNotFound) {
                position = [shift rangeOfString:oneCharacter].location;
                shifted = position != NSNotFound;
            }
            static const UIKeyboardHIDUsage usages[] = {0x2d,0x2e,0x2f,0x30,0x31,0x33,0x34,0x36,0x37,0x38,0x35};
            if (position != NSNotFound)
                sendSoftwareKey(usages[position], shifted);
        }
    }
}

- (void)deleteBackward { sendSoftwareKey((UIKeyboardHIDUsage)0x2a, NO); }

- (void)dealloc
{
    [self releaseSoftwareModifiers];
    [_vzAccessoryView release];
    [_vzAccessoryStack release];
    [_vzHeldSoftwareModifiers release];
    [_vzDirectTouchOrigins release];
    [_vzDirectTouchPositions release];
    [_vzActiveDirectTouchKeys release];
    [super dealloc];
}

- (void)handleHover:(UIHoverGestureRecognizer *)recognizer
{
    CGPoint location = [recognizer locationInView:self];
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        gUIKitHoverActive = YES;
        sendIndirectPointerLocation(location, self.bounds);
        break;
    case UIGestureRecognizerStateChanged:
        gUIKitHoverActive = YES;
        sendIndirectPointerLocation(location, self.bounds);
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        // A UIKit hover session can end while an indirect-pointer touch still
        // owns the physical button. Releasing buttons here truncated every
        // trackpad click-drag. Lifecycle and touch cancellation paths own
        // stuck-button cleanup instead.
        gUIKitHoverActive = NO;
        gHostPointerLocationValid = NO;
        break;
    default:
        break;
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    double delta = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        gLastPinchScale = recognizer.scale;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        // Indirect trackpad pinch scale is cumulative and, unlike direct
        // touch pinch, does not honor assigning scale=1 as a delta reset.
        // VZ/NSEvent magnification is incremental, so derive the frame delta.
        delta = recognizer.scale - gLastPinchScale;
        gLastPinchScale = recognizer.scale;
        break;
    case UIGestureRecognizerStateEnded: phase = 8; break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: phase = 16; break;
    default: return;
    }
    sendMagnification(delta, phase);
}

- (void)handleRotation:(UIRotationGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    double delta = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        gLastRotation = recognizer.rotation;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        delta = recognizer.rotation - gLastRotation;
        gLastRotation = recognizer.rotation;
        break;
    case UIGestureRecognizerStateEnded: phase = 8; break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: phase = 16; break;
    default: return;
    }
    sendRotation(delta, phase);
}

- (void)handleSmartMagnify:(UITapGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateRecognized)
        sendSmartMagnification();
}

- (void)handleScroll:(VZRawScrollRecognizer *)recognizer
{
    // NSEventPhase and the private VZ event use the same bit values:
    // began=1, changed=4, ended=8, cancelled=16. The recognizer captures the
    // incremental hardware deltas before UIKit builds cumulative translation.
    NSUInteger phase = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        break;
    case UIGestureRecognizerStateEnded:
        phase = 8;
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = 16;
        break;
    default:
        return;
    }
    sendScrollWheel(recognizer.vzRawDelta,
                    recognizer.vzAcceleratedDelta,
                    recognizer.vzDirectionInverted,
                    0,
                    phase);
}

- (void)handleTouchScroll:(UIPanGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    CGPoint delta = CGPointZero;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        delta = [recognizer translationInView:self];
        [recognizer setTranslation:CGPointZero inView:self];
        break;
    case UIGestureRecognizerStateEnded:
        phase = 8;
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = 16;
        break;
    default:
        return;
    }
    // A direct two-finger pan follows the content under the fingers (natural
    // scrolling), while captured hardware-wheel deltas describe wheel
    // rotation. Rotate and invert the UIKit translation before entering the
    // shared VZ event mapping. This intentionally affects direct touch only.
    CGVector raw = CGVectorMake(-delta.y, delta.x);
    sendScrollWheel(raw, raw, YES, 1, phase);
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion
{
    (void)interaction;
    (void)request;
    (void)defaultRegion;
    // Do not mutate guest input from this delegate. UIKit calls it during
    // region invalidation and system-UI transitions, not only real motion.
    return [UIPointerRegion regionWithRect:self.bounds identifier:@"VirtualMacDisplay"];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction
                        styleForRegion:(UIPointerRegion *)region
{
    (void)interaction;
    (void)region;
    return [UIPointerStyle hiddenPointerStyle];
}

- (BOOL)usesDeferredDirectTouchClicks
{
    VZAppSettings *settings = VZAppSettings.sharedSettings;
    return [settings boolForKey:VZTouchTwoFingerRightClickKey] ||
        [settings boolForKey:VZTouchLongPressRightClickKey];
}

- (NSValue *)directTouchKey:(UITouch *)touch
{
    return [NSValue valueWithNonretainedObject:touch];
}

- (void)ensureDirectTouchTracking
{
    if (!_vzDirectTouchOrigins)
        _vzDirectTouchOrigins = [[NSMutableDictionary alloc] init];
    if (!_vzDirectTouchPositions)
        _vzDirectTouchPositions = [[NSMutableDictionary alloc] init];
    if (!_vzActiveDirectTouchKeys)
        _vzActiveDirectTouchKeys = [[NSMutableSet alloc] init];
}

- (CGPoint)directTouchMidpoint
{
    if (!_vzDirectTouchPositions.count)
        return _vzDirectTouchStart;
    CGFloat x = 0;
    CGFloat y = 0;
    for (NSValue *value in _vzDirectTouchPositions.allValues) {
        CGPoint point = value.CGPointValue;
        x += point.x;
        y += point.y;
    }
    return CGPointMake(x / _vzDirectTouchPositions.count,
                       y / _vzDirectTouchPositions.count);
}

- (void)emitDirectClickAtPoint:(CGPoint)point button:(NSUInteger)button
{
    // Move first, matching the native indirect-pointer path. The down/up pair
    // is emitted together only after the direct-touch gesture is known, so a
    // two-finger tap never leaks a primary click into the guest.
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
    gTouchButtons = button;
    sendPointer(point, self.bounds, activePointerButtons());
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
}

- (void)resetDeferredDirectTouch
{
    _vzDirectGestureGeneration++;
    _vzDirectTouchActive = NO;
    _vzDirectTouchDragging = NO;
    _vzTwoFingerCandidate = NO;
    _vzLongPressConsumed = NO;
    _vzDirectPrimaryPressed = NO;
    _vzDirectGestureMaximumMovement = 0;
    [_vzDirectTouchOrigins removeAllObjects];
    [_vzDirectTouchPositions removeAllObjects];
    [_vzActiveDirectTouchKeys removeAllObjects];
}

- (void)beginDeferredDirectTouches:(NSSet<UITouch *> *)touches
                         withEvent:(UIEvent *)event
{
    (void)event;
    [self ensureDirectTouchTracking];
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        if (!_vzDirectTouchOrigins[key])
            _vzDirectTouchOrigins[key] = [NSValue valueWithCGPoint:point];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        [_vzActiveDirectTouchKeys addObject:key];
        if (!_vzDirectTouchActive) {
            _vzDirectTouchActive = YES;
            _vzDirectTouchDragging = NO;
            _vzTwoFingerCandidate = NO;
            _vzLongPressConsumed = NO;
            // Preserve the original fast-path double-tap semantics: decide
            // the accommodated guest coordinate at touch-down, before the
            // guest observes any pointer movement.  Applying it at touch-up
            // made the pointer visit the second physical coordinate between
            // clicks, which defeats AppKit's double-click hit testing.
            BOOL accommodate = [VZAppSettings.sharedSettings
                boolForKey:VZTouchDoubleTapAccommodationKey];
            if (accommodate &&
                touch.timestamp - _vzLastDirectTapTime <= 0.20) {
                CGFloat dx = point.x - _vzLastDirectTap.x;
                CGFloat dy = point.y - _vzLastDirectTap.y;
                if (hypot(dx, dy) <= 30.0)
                    point = _vzLastDirectTap;
            }
            _vzDirectTouchStart = point;
            _vzDirectGestureStartTime = touch.timestamp;
            _vzDirectGestureMaximumMovement = 0;
            _vzDirectGestureGeneration++;
        }
    }

    NSUInteger count = _vzActiveDirectTouchKeys.count;
    if (count == 2) {
        if (_vzDirectPrimaryPressed) {
            gTouchButtons = 0;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
            _vzDirectPrimaryPressed = NO;
        }
        _vzTwoFingerCandidate = YES;
        // Invalidate a pending one-finger long press as soon as the second
        // finger arrives. Two-finger scrolling remains owned by its pan
        // recognizer and cancels this candidate after actual movement.
        _vzDirectGestureGeneration++;
    } else if (count > 2) {
        _vzTwoFingerCandidate = NO;
        _vzDirectGestureGeneration++;
    }

    CGPoint point = count > 1 ? [self directTouchMidpoint]
                              : _vzDirectTouchStart;
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());

    if (count == 1 && [VZAppSettings.sharedSettings
            boolForKey:VZTouchLongPressRightClickKey]) {
        NSUInteger generation = _vzDirectGestureGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!_vzDirectTouchActive || _vzDirectTouchDragging ||
                _vzTwoFingerCandidate || _vzLongPressConsumed ||
                _vzActiveDirectTouchKeys.count != 1 ||
                generation != _vzDirectGestureGeneration)
                return;
            _vzLongPressConsumed = YES;
            [self emitDirectClickAtPoint:[self directTouchMidpoint] button:2];
        });
    } else if (count == 1) {
        // Waiting until touch-up made every tap feel laggy and changed drag
        // timing.  Keep only a very short arbitration window for a second
        // finger, then restore the normal touch-down press while the finger
        // is still held.
        NSUInteger generation = _vzDirectGestureGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!_vzDirectTouchActive || _vzDirectTouchDragging ||
                _vzTwoFingerCandidate || _vzLongPressConsumed ||
                _vzActiveDirectTouchKeys.count != 1 ||
                generation != _vzDirectGestureGeneration)
                return;
            _vzDirectPrimaryPressed = YES;
            gTouchButtons = 1;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
        });
    }
}

- (void)moveDeferredDirectTouches:(NSSet<UITouch *> *)touches
                         withEvent:(UIEvent *)event
{
    (void)event;
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        CGPoint origin = [_vzDirectTouchOrigins[key] CGPointValue];
        _vzDirectGestureMaximumMovement = MAX(
            _vzDirectGestureMaximumMovement,
            hypot(point.x - origin.x, point.y - origin.y));
    }

    if (_vzActiveDirectTouchKeys.count != 1) {
        if (_vzActiveDirectTouchKeys.count > 2)
            _vzTwoFingerCandidate = NO;
        return;
    }
    if (_vzLongPressConsumed)
        return;

    CGPoint point = [self directTouchMidpoint];
    if (!_vzDirectTouchDragging) {
        CGFloat dx = point.x - _vzDirectTouchStart.x;
        CGFloat dy = point.y - _vzDirectTouchStart.y;
        if (hypot(dx, dy) <= 8.0)
            return;
        _vzDirectTouchDragging = YES;
        _vzTwoFingerCandidate = NO;
        _vzDirectGestureGeneration++;
        if (!_vzDirectPrimaryPressed) {
            _vzDirectPrimaryPressed = YES;
            gTouchButtons = 1;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
        }
    }
    gTouchButtons = 1;
    sendPointer(point, self.bounds, activePointerButtons());
}

- (void)endDeferredDirectTouches:(NSSet<UITouch *> *)touches
                        withEvent:(UIEvent *)event
{
    CGPoint finalPoint = [self directTouchMidpoint];
    NSTimeInterval endTime = _vzDirectGestureStartTime;
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        CGPoint origin = [_vzDirectTouchOrigins[key] CGPointValue];
        _vzDirectGestureMaximumMovement = MAX(
            _vzDirectGestureMaximumMovement,
            hypot(point.x - origin.x, point.y - origin.y));
        [_vzActiveDirectTouchKeys removeObject:key];
        endTime = MAX(endTime, touch.timestamp);
    }
    finalPoint = [self directTouchMidpoint];
    if (_vzActiveDirectTouchKeys.count)
        return;

    NSTimeInterval duration = endTime - _vzDirectGestureStartTime;
    if (_vzLongPressConsumed) {
        // The long-press click has already completed.
    } else if (_vzTwoFingerCandidate &&
               _vzDirectTouchOrigins.count == 2 &&
               duration <= 0.35 &&
               _vzDirectGestureMaximumMovement <= 10.0) {
        [self emitDirectClickAtPoint:finalPoint button:2];
    } else if (_vzDirectTouchOrigins.count == 1 &&
               !_vzDirectTouchDragging) {
        // A tap lands where it began, not wherever the finger happened to
        // drift before lifting. This matches the pre-381c140 path and keeps
        // small targets accurate.
        finalPoint = _vzDirectTouchStart;
        if (_vzDirectPrimaryPressed) {
            gTouchButtons = 0;
            sendPointer(finalPoint, self.bounds, activePointerButtons());
        } else {
            [self emitDirectClickAtPoint:finalPoint button:1];
        }
        _vzLastDirectTap = _vzDirectTouchStart;
        _vzLastDirectTapTime = endTime;
    } else if (_vzDirectTouchDragging) {
        gTouchButtons = 0;
        sendPointer(finalPoint, self.bounds, activePointerButtons());
        _vzLastDirectTapTime = 0;
    }
    (void)event;
    [self resetDeferredDirectTouch];
}

- (void)cancelDeferredDirectTouches:(NSSet<UITouch *> *)touches
                           withEvent:(UIEvent *)event
{
    (void)event;
    CGPoint point = [self directTouchMidpoint];
    for (UITouch *touch in touches)
        if (touch.type == UITouchTypeDirect)
            point = [touch locationInView:self];
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
    [self resetDeferredDirectTouch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self beginDeferredDirectTouches:touches withEvent:event];
        return;
    }
    if (touch) {
        // Hardware trackpad clicks reach a UIKit view as indirect-pointer
        // touches even when GameController exposes no GCMouse. Preserve
        // UIKit's native primary/secondary/middle button bits instead of
        // turning every such click into a primary click. A direct finger
        // touch has no button mask and remains a primary click.
        NSUInteger eventButtons = (NSUInteger)event.buttonMask & 0x7U;
        gTouchButtons = eventButtons ?: 1U;
        // UIKit suspends hover updates while a trackpad button is held, but
        // the indirect UITouch continues to report every live drag position.
        // Treat it as authoritative or the guest only sees the final point.
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect) {
            NSTimeInterval now = touch.timestamp;
            BOOL accommodate = [VZAppSettings.sharedSettings
                boolForKey:VZTouchDoubleTapAccommodationKey];
            if (accommodate) {
                CGFloat dx = point.x - _vzLastDirectTap.x;
                CGFloat dy = point.y - _vzLastDirectTap.y;
                // Only coalesce a deliberate, quick double-tap. A broad
                // interval makes two ordinary taps on nearby controls land
                // on the first control instead.
                if (now - _vzLastDirectTapTime <= 0.20 &&
                    hypot(dx, dy) <= 30.0)
                    point = _vzLastDirectTap;
                _vzDirectTouchStart = point;
                _vzDirectTouchActive = YES;
                _vzDirectTouchDragging = NO;
            }
        }
        // Match the working hardware-trackpad path: establish the guest
        // pointer location before pressing. Modern AppKit menu tracking needs
        // this hover/move transition before a direct tap on a menu item.
        if (touch.type == UITouchTypeDirect)
            sendPointer(point, self.bounds, gHardwareMouseButtons);
        sendPointer(point, self.bounds, activePointerButtons());
        printf("[VirtualMac] touch began type=%ld buttons=0x%lx\n",
               (long)touch.type, (unsigned long)gTouchButtons);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self moveDeferredDirectTouches:touches withEvent:event];
        return;
    }
    if (touch) {
        NSUInteger eventButtons = (NSUInteger)event.buttonMask & 0x7U;
        if (eventButtons)
            gTouchButtons = eventButtons;
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect && _vzDirectTouchActive &&
            !_vzDirectTouchDragging) {
            CGFloat dx = point.x - _vzDirectTouchStart.x;
            CGFloat dy = point.y - _vzDirectTouchStart.y;
            // Ignore finger jitter during an ordinary click. Modern AppKit
            // menus interpret tiny held movement as a drag-and-dismiss. An
            // intentional drag becomes live immediately outside tap slop.
            if (hypot(dx, dy) <= 8.0)
                return;
            _vzDirectTouchDragging = YES;
        }
        sendPointer(point, self.bounds,
                    activePointerButtons());
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self endDeferredDirectTouches:touches withEvent:event];
        return;
    }
    if (touch) {
        (void)event;
        gTouchButtons = 0;
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect && _vzDirectTouchActive) {
            if (!_vzDirectTouchDragging) {
                point = _vzDirectTouchStart;
                _vzLastDirectTap = point;
                _vzLastDirectTapTime = touch.timestamp;
            } else {
                _vzLastDirectTapTime = 0;
            }
            _vzDirectTouchActive = NO;
            _vzDirectTouchDragging = NO;
        }
        sendPointer(point, self.bounds,
                    activePointerButtons());
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self cancelDeferredDirectTouches:touches withEvent:event];
        return;
    }
    [self touchesEnded:touches withEvent:event];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, YES))
        [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, NO))
        [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
               withEvent:(UIPressesEvent *)event
{
    sendPresses(presses, NO);
}

@end

@interface VZHUDView : UIView
@property(nonatomic, assign) id menuTarget;
- (instancetype)initWithTarget:(id)target;
- (void)setContentOpacity:(CGFloat)opacity;
- (void)refreshMenu;
@end

@implementation VZHUDView

- (void)refreshMenu
{
    UIButton *button = (UIButton *)[self viewWithTag:1702];
    if (!button || !self.menuTarget)
        return;
    button.menu = ((id(*)(id, SEL))objc_msgSend)(
        self.menuTarget, NSSelectorFromString(@"hudMenu"));
}

- (void)setContentOpacity:(CGFloat)opacity
{
    opacity = MAX(0.0, MIN(1.0, opacity));
    // Keep the container and buttons at alpha 1 so UIKit continues hit
    // testing them when the user chooses zero visual opacity. Only the cheap
    // solid background and symbol tint become transparent; no effect view or
    // offscreen pass is introduced.
    self.alpha = 1.0;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86 * opacity];
    UIStackView *stack = (UIStackView *)[self viewWithTag:1701];
    for (UIButton *button in stack.arrangedSubviews)
        button.tintColor = [UIColor.whiteColor colorWithAlphaComponent:opacity];
}

- (instancetype)initWithTarget:(id)target
{
    if ((self = [super initWithFrame:CGRectZero])) {
        self.menuTarget = target;
        // A small, solid translucent layer is considerably cheaper than a
        // UIVisualEffectView: no backdrop capture, blur, or offscreen effect
        // pass is introduced above the continuously updating PVG surface.
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
        self.layer.cornerRadius = 18;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        UIStackView *stack = [[[UIStackView alloc] init] autorelease];
        stack.tag = 1701;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 2;
        for (NSDictionary *item in @[
            @{@"icon": @"keyboard", @"selector": @"hudKeyboard:"},
            @{@"icon": @"ellipsis", @"menu": @YES},
        ]) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setImage:[UIImage systemImageNamed:item[@"icon"]]
                    forState:UIControlStateNormal];
            button.tintColor = UIColor.whiteColor;
            if ([item[@"menu"] boolValue]) {
                button.tag = 1702;
                button.menu = ((id(*)(id, SEL))objc_msgSend)(
                    target, NSSelectorFromString(@"hudMenu"));
                button.showsMenuAsPrimaryAction = YES;
                button.accessibilityLabel = VZL(@"Virtual Mac Controls");
            } else {
                [button addTarget:target action:NSSelectorFromString(item[@"selector"])
                    forControlEvents:UIControlEventTouchUpInside];
            }
            [button.widthAnchor constraintEqualToConstant:46].active = YES;
            [button.heightAnchor constraintEqualToConstant:46].active = YES;
            [stack addArrangedSubview:button];
        }
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
        ]];
    }
    return self;
}
@end

@interface VZViewController : UIViewController
    <VZVMLibraryViewControllerDelegate>
@property(nonatomic, retain) UINavigationController *libraryNavigationController;
@property(nonatomic, retain) VZProgressViewController *installationController;
@property(nonatomic, retain) NSTimer *installationTimer;
@property(nonatomic, copy) NSString *installationLogPath;
@property(nonatomic, copy) NSString *installationBundlePath;
@property(nonatomic, copy) NSString *installationStagingPath;
@property(nonatomic, copy) NSString *installationAttemptPath;
@property(nonatomic, copy) NSString *installationRestoreImagePath;
@property(nonatomic, retain) NSDictionary *installationOptions;
@property(nonatomic, assign) pid_t installationProcess;
@property(nonatomic, copy) NSString *activeVMBundlePath;
@property(nonatomic, assign, getter=isVMDisplayActive) BOOL vmDisplayActive;
@property(nonatomic, assign) BOOL didCheckInstallationAttempts;
- (void)presentVMLibrary;
- (void)finishVMAndShowLibraryWithError:(NSError *)error;
- (void)activateVMDisplay:(BOOL)active;
- (void)updateHUDVisibility;
- (void)updateHUDPosition;
- (UIMenu *)hudMenu;
- (void)confirmForceShutdown;
@end

@implementation VZViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(appSettingsChanged:)
        name:VZSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCKeyboardDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCKeyboardDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCMouseDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCMouseDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(externalScreenChanged:)
        name:UIScreenDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(externalScreenChanged:)
        name:UIScreenDidDisconnectNotification object:nil];
}

- (void)peripheralChanged:(NSNotification *)notification
{
    (void)notification;
    if (GCKeyboard.coalescedKeyboard && self.isVMDisplayActive &&
        !gInputView.hidden) {
        [gInputView becomeFirstResponder];
        [gInputView reloadInputViews];
    } else if (!gSoftwareKeyboardRequested) {
        [gInputView resignFirstResponder];
    }
    [self updateHUDVisibility];
}

- (void)externalScreenChanged:(NSNotification *)notification
{
    (void)notification;
    if ([notification.name isEqualToString:UIScreenDidConnectNotification]) {
        if (externalDisplayEnabled())
            connectExternalDisplay();
    } else {
        disconnectExternalDisplay();
    }
}

- (void)appSettingsChanged:(NSNotification *)notification
{
    (void)notification;
    if (gStatusLabel)
        gStatusLabel.hidden = !shouldShowStatusLabel();
    [self updateImmersivePresentation];
    [self updateHUDPosition];
    [(VZHUDView *)gHUDView refreshMenu];
    [self updateHUDVisibility];
    updateDisplayGeometry();
    if (gTouchScrollRecognizer) {
        BOOL enabled = [VZAppSettings.sharedSettings
            boolForKey:VZTouchTwoFingerScrollingKey];
        gTouchScrollRecognizer.enabled = enabled;
        NSArray *allowed = enabled ? @[@(UITouchTypeIndirectPointer)]
                                   : @[@(UITouchTypeDirect),
                                       @(UITouchTypeIndirectPointer)];
        gPinchRecognizer.allowedTouchTypes = allowed;
        gRotationRecognizer.allowedTouchTypes = allowed;
        gSmartMagnifyRecognizer.allowedTouchTypes = allowed;
    }
}

- (void)updateHUDPosition
{
    if (!gHUDView)
        return;
    if (gHUDHorizontalConstraint)
        [gHUDHorizontalConstraint setActive:NO];
    if (gHUDVerticalConstraint)
        [gHUDVerticalConstraint setActive:NO];
    NSString *corner = [VZAppSettings.sharedSettings stringForKey:VZHUDCornerKey]
        ?: @"top-right";
    BOOL left = [corner hasSuffix:@"left"];
    BOOL bottom = [corner hasPrefix:@"bottom"];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    gHUDHorizontalConstraint = left
        ? [gHUDView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16]
        : [gHUDView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16];
    gHUDVerticalConstraint = bottom
        ? [gHUDView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-16]
        : [gHUDView.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16];
    [NSLayoutConstraint activateConstraints:@[
        gHUDHorizontalConstraint, gHUDVerticalConstraint]];
}

- (void)updateHUDVisibility
{
    NSString *choice = [VZAppSettings.sharedSettings stringForKey:VZHUDVisibilityKey]
        ?: @"automatic";
    BOOL hidden = !self.isVMDisplayActive || (!gHUDForcedVisibleForBoot &&
        (gHUDHiddenForBoot || [choice isEqualToString:@"hidden"]));
    if (!gHUDForcedVisibleForBoot && [choice isEqualToString:@"automatic"])
        hidden = hidden || (GCKeyboard.coalescedKeyboard != nil && GCMouse.current != nil);
    CGFloat opacity = [[VZAppSettings.sharedSettings
        stringForKey:VZHUDOpacityKey] doubleValue];
    [(VZHUDView *)gHUDView setContentOpacity:opacity];
    gHUDView.hidden = hidden;
}

- (void)hudKeyboard:(UIButton *)sender
{
    (void)sender;
    if (gSoftwareKeyboardRequested && gInputView.isFirstResponder) {
        gSoftwareKeyboardRequested = NO;
        [gInputView resignFirstResponder];
    } else {
        gSoftwareKeyboardRequested = YES;
        [gInputView becomeFirstResponder];
        [gInputView reloadInputViews];
    }
}

- (UIMenu *)hudMenu
{
    UIAction *library = [UIAction actionWithTitle:VZL(@"Show Library")
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
        handler:^(UIAction *action) { (void)action; [self presentVMLibrary]; }];
    UIAction *shutdown = [UIAction actionWithTitle:VZL(@"Force Shut Down")
        image:[UIImage systemImageNamed:@"power"] identifier:nil
        handler:^(UIAction *action) { (void)action; [self confirmForceShutdown]; }];
    shutdown.attributes = UIMenuElementAttributesDestructive;
    UIAction *hide = [UIAction actionWithTitle:VZL(@"Hide for This Boot")
        image:[UIImage systemImageNamed:@"eye.slash"] identifier:nil
        handler:^(UIAction *action) { (void)action;
        gHUDHiddenForBoot = YES;
        [self updateHUDVisibility];
        NSString *noticeKey = @"HUDHideRecoveryNoticeShown";
        if (![VZAppSettings.sharedSettings boolForKey:noticeKey]) {
            [VZAppSettings.sharedSettings setBool:YES forKey:noticeKey];
            UIAlertController *notice = [UIAlertController
                alertControllerWithTitle:VZL(@"Controls Hidden")
                message:VZL(@"To show the controls again during this boot, touch and hold the Virtual Mac icon on the Home Screen, then choose Show Virtual Mac Controls.")
                preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:notice animated:YES completion:nil];
        }
    }];
    NSMutableArray *placements = [NSMutableArray array];
    NSString *current = [VZAppSettings.sharedSettings stringForKey:VZHUDCornerKey]
        ?: @"top-right";
    for (NSArray *placement in @[
        @[VZL(@"Top Left"), @"top-left"], @[VZL(@"Top Right"), @"top-right"],
        @[VZL(@"Bottom Left"), @"bottom-left"], @[VZL(@"Bottom Right"), @"bottom-right"],
    ]) {
        UIAction *move = [UIAction actionWithTitle:placement[0] image:nil
            identifier:nil handler:^(UIAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings setString:placement[1]
                                              forKey:VZHUDCornerKey];
            [self updateHUDPosition];
            [(VZHUDView *)gHUDView refreshMenu];
        }];
        move.state = [current isEqualToString:placement[1]]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [placements addObject:move];
    }
    UIMenu *moveMenu = [UIMenu menuWithTitle:VZL(@"Move Controls") children:placements];
    // External Display toggle
    BOOL extEnabled = [VZAppSettings.sharedSettings
        boolForKey:VZExternalDisplayEnabledKey];
    UIAction *extToggle = [UIAction actionWithTitle:VZL(@"Fullscreen Mirroring")
        image:[UIImage systemImageNamed:@"display"]
        identifier:nil handler:^(UIAction *action) {
        (void)action;
        BOOL now = ![VZAppSettings.sharedSettings
            boolForKey:VZExternalDisplayEnabledKey];
        [VZAppSettings.sharedSettings setBool:now
            forKey:VZExternalDisplayEnabledKey];
        if (now && externalDisplayEnabled())
            connectExternalDisplay();
        else if (!now)
            disconnectExternalDisplay();
    }];
    extToggle.state = extEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@""
        children:@[library, shutdown, hide, extToggle, moveMenu]];
}

- (void)confirmForceShutdown
{
    if (!gVirtualMachine)
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Force Shut Down Virtual Mac?")
        message:VZL(@"Unsaved changes in macOS may be lost.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Force Shut Down")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        forceStopVirtualMachine();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

static NSURL *persistentRestoreImageURL(NSURL *sourceURL, NSError **error)
{
    NSString *directory = VZRestoreImagesPath();
    if (![NSFileManager.defaultManager
            createDirectoryAtPath:directory
      withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    NSString *directoryPrefix = [directory.stringByStandardizingPath
        stringByAppendingString:@"/"];
    if ([sourcePath hasPrefix:directoryPrefix])
        return sourceURL;

    NSString *filename = sourceURL.lastPathComponent.length
        ? sourceURL.lastPathComponent : @"Restore.ipsw";
    NSString *destinationPath = [directory
        stringByAppendingPathComponent:filename];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    if ([NSFileManager.defaultManager fileExistsAtPath:destinationPath]) {
        NSDictionary *sourceAttributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:sourcePath error:nil];
        NSDictionary *destinationAttributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:destinationPath error:nil];
        // Reuse only the exact existing hard link. A different IPSW can have
        // the same filename (and even size), so size is not a safe identity.
        if ([sourceAttributes[NSFileSystemFileNumber] isEqual:
                destinationAttributes[NSFileSystemFileNumber]])
            return destinationURL;
        NSString *stem = filename.stringByDeletingPathExtension;
        NSString *extension = filename.pathExtension;
        filename = [NSString stringWithFormat:@"%@-%@%@%@", stem,
            NSUUID.UUID.UUIDString,
            extension.length ? @"." : @"", extension];
        destinationPath = [directory stringByAppendingPathComponent:filename];
        destinationURL = [NSURL fileURLWithPath:destinationPath];
    }
    // Downloads and the VM library are on the same APFS volume. A hard link
    // makes the security-scoped File Provider item permanently reachable by
    // the root installer without copying a multi-gigabyte IPSW.
    if (![NSFileManager.defaultManager linkItemAtURL:sourceURL
                                              toURL:destinationURL
                                              error:error])
        return nil;
    return destinationURL;
}

static NSString *VZInstallationLogTail(NSString *path, NSUInteger limit,
                                       BOOL omitProgress)
{
    NSString *contents = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    if (!contents.length)
        return @"";
    if (omitProgress) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"INSTALL_PROGRESS\t"])
                [filtered addObject:line];
        }
        contents = [filtered componentsJoinedByString:@"\n"];
    }
    if (contents.length > limit)
        contents = [@"… earlier output omitted …\n"
            stringByAppendingString:
                [contents substringFromIndex:contents.length - limit]];
    return contents;
}

static NSString *VZInstallationConsoleText(NSString *installLogPath)
{
    NSArray *sources = @[
        @[@"INSTALLER", installLogPath ?: @"", @YES],
        @[@"INSTALLER LAUNCHER", @"/tmp/installation.stderr.log", @NO],
        @[@"INSTALLATION HOOK", @"/tmp/installationhook.log", @NO],
        @[@"VIRTUALIZATION FRAMEWORK", @"/tmp/vzxpchook.log", @NO],
        @[@"MOBILEDEVICE / RESTORE USB", @"/tmp/installation-usb.log", @NO],
        @[@"USBMUXD", @"/tmp/vz-usbmuxd.log", @NO],
        @[@"USBMUXD LAUNCHER", @"/tmp/vz-usbmuxd-launch.log", @NO],
        @[@"RESTORE VMM STDERR", @"/tmp/restore-vmm.stderr.log", @NO],
        @[@"RESTORE VMM", @"/tmp/vmmhook.log", @NO],
    ];
    NSMutableString *console = [NSMutableString string];
    for (NSArray *source in sources) {
        NSString *tail = VZInstallationLogTail(
            source[1], 16 * 1024, [source[2] boolValue]);
        if (!tail.length)
            continue;
        if (console.length)
            [console appendString:@"\n\n"];
        [console appendFormat:@"── %@ ──\n%@", source[0], tail];
    }
    return console.length ? console : VZL(@"Waiting for installation output…");
}

static void VZWriteInstallationAttempt(NSString *attemptPath, NSString *state,
                                       NSDictionary *details)
{
    if (!attemptPath.length) return;
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:[attemptPath stringByAppendingPathComponent:@"Attempt.plist"]] ?: @{}];
    [record addEntriesFromDictionary:details ?: @{}];
    record[@"State"] = state;
    record[@"UpdatedAt"] = NSDate.date;
    [record writeToFile:[attemptPath stringByAppendingPathComponent:@"Attempt.plist"] atomically:YES];
}
- (BOOL)prefersStatusBarHidden
{
    return self.isVMDisplayActive;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return self.isVMDisplayActive && [VZAppSettings.sharedSettings
        boolForKey:VZHomeIndicatorSuppressionKey];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
    return self.isVMDisplayActive && [VZAppSettings.sharedSettings
        boolForKey:VZSystemGestureSuppressionKey] ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)updateImmersivePresentation
{
    BOOL active = self.isVMDisplayActive;
    printf("[VirtualMac] presentation activeVM=%d statusBarHidden=%d "
           "homeIndicatorHidden=%d deferredEdges=0x%lx\n",
           active, active, active,
           (unsigned long)(active ? UIRectEdgeAll : UIRectEdgeNone));
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}

- (void)activateVMDisplay:(BOOL)active
{
    self.vmDisplayActive = active;
    self.view.backgroundColor = active ? UIColor.blackColor
                                       : UIColor.systemBackgroundColor;
    if (active) {
        FILE *marker = fopen("/tmp/virtual-mac-vm-active", "w");
        if (marker) {
            fputs("active\n", marker);
            fclose(marker);
        }
        resetPointerSession(YES);
    } else {
        unlink("/tmp/virtual-mac-vm-active");
    }
    [self updateImmersivePresentation];
    [self updateHUDVisibility];
}

- (void)presentVMLibrary
{
    printf("[VirtualMac] presenting VM library\n");
    BOOL crossfade = self.isVMDisplayActive;
    gHUDHiddenForBoot = NO;
    gHUDForcedVisibleForBoot = NO;
    if (!self.libraryNavigationController) {
        VZVMLibraryViewController *library =
            [[[VZVMLibraryViewController alloc] init] autorelease];
        library.delegate = self;
        self.libraryNavigationController = [[[UINavigationController alloc]
            initWithRootViewController:library] autorelease];
        [self addChildViewController:self.libraryNavigationController];
        self.libraryNavigationController.view.frame = self.view.bounds;
        self.libraryNavigationController.view.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.libraryNavigationController.view.hidden = crossfade;
        [self.view addSubview:self.libraryNavigationController.view];
        [self.libraryNavigationController didMoveToParentViewController:self];
    } else {
        VZVMLibraryViewController *library =
            (id)self.libraryNavigationController.viewControllers.firstObject;
        [library reloadLibrary];
    }
    void (^showLibrary)(void) = ^{
        self.libraryNavigationController.view.hidden = NO;
        [self.view bringSubviewToFront:self.libraryNavigationController.view];
        gInputView.hidden = YES;
        gSoftwareKeyboardRequested = NO;
        [gInputView resignFirstResponder];
        gCursorView.hidden = YES;
        [self activateVMDisplay:NO];
    };
    if (crossfade) {
        [UIView transitionWithView:self.view duration:0.24
            options:UIViewAnimationOptionTransitionCrossDissolve |
                    UIViewAnimationOptionAllowAnimatedContent
            animations:showLibrary completion:nil];
    } else {
        showLibrary();
    }
    if (!self.didCheckInstallationAttempts) {
        self.didCheckInstallationAttempts = YES;
        NSMutableArray *interrupted = [NSMutableArray array];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:
                VZInstallationsPath() error:nil]) {
            if (![name hasSuffix:@".installation"]) continue;
            NSString *path = [VZInstallationsPath() stringByAppendingPathComponent:name];
            NSDictionary *attempt = [NSDictionary dictionaryWithContentsOfFile:
                [path stringByAppendingPathComponent:@"Attempt.plist"]];
            NSString *state = attempt[@"State"];
            if ([state isEqualToString:@"installing"] || [state isEqualToString:@"failed"])
                [interrupted addObject:@{ @"path": path, @"record": attempt ?: @{} }];
        }
        if (interrupted.count) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSMutableString *details = [NSMutableString string];
            for (NSDictionary *item in interrupted) {
                NSDictionary *record = item[@"record"];
                [details appendFormat:VZL(@"%@\nState: %@\n%@\n\n"),
                    record[@"Name"] ?: [item[@"path"] lastPathComponent],
                    record[@"State"] ?: VZL(@"Unknown"), item[@"path"]];
            }
            VZFailureDetailsViewController *controller =
                [[[VZFailureDetailsViewController alloc]
                    initWithTitle:interrupted.count == 1
                        ? VZL(@"Incomplete Installation")
                        : VZL(@"Incomplete Installations")
                    message:VZL(@"A previous macOS installation did not finish.")
                    details:details
                    options:VZFailureSupportOptionNone]
                    autorelease];
            [controller setDestructiveActionTitle:VZL(@"Delete All")
                handler:^{
                    NSMutableArray *paths = [NSMutableArray array];
                    for (NSDictionary *item in interrupted)
                        [paths addObject:item[@"path"]];
                    VZRemovePaths(paths);
                }];
            UINavigationController *navigation =
                [[[UINavigationController alloc]
                    initWithRootViewController:controller] autorelease];
            navigation.modalPresentationStyle = UIModalPresentationPageSheet;
            navigation.preferredContentSize = CGSizeMake(640, 720);
            [self presentViewController:navigation animated:YES completion:nil];
        });
    }
}

- (void)vmLibrary:(VZVMLibraryViewController *)library
    bootBundleAtPath:(NSString *)path options:(NSDictionary *)options
{
    (void)library;
    printf("[VirtualMac] selected VM path=%s options=%s\n", path.UTF8String,
           options.description.UTF8String);
    gHUDHiddenForBoot = NO;
    gHUDForcedVisibleForBoot = NO;
    self.activeVMBundlePath = path;
    if (self.libraryNavigationController.view.window &&
        !self.libraryNavigationController.view.hidden) {
        [UIView transitionWithView:self.view duration:0.32
            options:UIViewAnimationOptionTransitionCrossDissolve |
                    UIViewAnimationOptionAllowAnimatedContent
            animations:^{
                self.libraryNavigationController.view.hidden = YES;
                gInputView.hidden = NO;
            } completion:nil];
    } else {
        self.libraryNavigationController.view.hidden = YES;
        gInputView.hidden = NO;
    }
    [self activateVMDisplay:YES];
    startVirtualMachine(self.view, self, path, options);
}

- (NSString *)activeVMBundlePathForLibrary:
    (VZVMLibraryViewController *)library
{
    (void)library;
    return gVirtualMachine ? self.activeVMBundlePath : nil;
}

- (void)vmLibraryResumeActiveVM:(VZVMLibraryViewController *)library
{
    (void)library;
    if (!gVirtualMachine)
        return;
    [UIView transitionWithView:self.view duration:0.24
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{
            self.libraryNavigationController.view.hidden = YES;
            gInputView.hidden = NO;
            if (gCursorView.image) gCursorView.hidden = NO;
        } completion:nil];
    [self activateVMDisplay:YES];
    if (GCKeyboard.coalescedKeyboard)
        [gInputView becomeFirstResponder];
}

- (void)vmLibraryForceShutdownActiveVM:
    (VZVMLibraryViewController *)library
{
    (void)library;
    forceStopVirtualMachine();
}

- (void)vmLibrary:(VZVMLibraryViewController *)library
    installRestoreImageAtURL:(NSURL *)url name:(NSString *)name
                     options:(NSDictionary *)options
{
    (void)library;
    if (self.installationController || self.installationTimer) {
        printf("[VirtualMac] ignored duplicate installation request\n");
        return;
    }
    NSError *imageError = nil;
    NSURL *persistentURL = persistentRestoreImageURL(url, &imageError);
    [url stopAccessingSecurityScopedResource];
    if (!persistentURL) {
        VZPresentFailureReport(self,
            VZL(@"Could Not Prepare Restore Image"),
            imageError.localizedDescription, imageError.debugDescription,
            VZFailureSupportOptionNone);
        return;
    }
    url = persistentURL;
    NSString *bundlePath = [VZVMLibraryPath() stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"bundle"]];
    NSString *attempt = [NSString stringWithFormat:@"%@-%@", name,
        NSUUID.UUID.UUIDString];
    NSString *attemptPath = [VZInstallationsPath() stringByAppendingPathComponent:
        [attempt stringByAppendingPathExtension:@"installation"]];
    NSString *stagingPath = [attemptPath stringByAppendingPathComponent:@"Staging.bundle.installing"];
    // Keep the launcher's allowlisted suffix while retaining all files inside
    // the durable attempt directory.
    NSString *logPath = [attemptPath stringByAppendingPathComponent:@"Installer.install.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:attemptPath
        withIntermediateDirectories:YES attributes:nil error:nil];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        UIAlertController *exists = [UIAlertController
            alertControllerWithTitle:VZL(@"Name Already Used")
                             message:VZL(@"Delete or rename the existing Virtual Mac first.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [exists addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:exists animated:YES completion:nil];
        return;
    }
    NSString *cpu = [options[@"CPUCount"] stringValue];
    uint64_t runtimeMemory = [options[@"MemorySize"] unsignedLongLongValue];
    uint64_t restoreMemory = VZRestoreImageUsesMontereyProfile(url.path)
        ? MIN(runtimeMemory, 4ULL << 30) : runtimeMemory;
    NSString *memory = [@(restoreMemory) stringValue];
    NSString *storage = [options[@"StorageSize"] stringValue];
    const char *launcher =
        "/var/root/VirtualMac/install/install-launcher";
    char *arguments[] = {
        (char *)launcher,
        (char *)url.path.fileSystemRepresentation,
        (char *)stagingPath.fileSystemRepresentation,
        (char *)bundlePath.fileSystemRepresentation,
        (char *)logPath.fileSystemRepresentation,
        (char *)cpu.UTF8String,
        (char *)memory.UTF8String,
        (char *)storage.UTF8String,
        NULL,
    };
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    VZWriteInstallationAttempt(attemptPath, @"installing", @{
        @"Name": name, @"RestoreImage": url.path, @"Destination": bundlePath,
        @"StartedAt": NSDate.date,
    });
    pid_t process = 0;
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);
    int result = posix_spawn(&process, launcher, NULL, &attributes,
                             arguments, environ);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) {
        VZWriteInstallationAttempt(attemptPath, @"failed", @{
            @"Failure": [NSString stringWithFormat:@"Could not start installer: %s", strerror(result)]
        });
        VZPresentFailureReport(self, VZL(@"Could Not Start Installer"),
            [NSString stringWithFormat:
                VZL(@"The installer could not be started: %s"),
                strerror(result)],
            [NSString stringWithFormat:
                @"posix_spawn(install-launcher)=%d (%s)",
                result, strerror(result)],
            VZFailureSupportOptionNone);
        return;
    }
    printf("[VirtualMac] installation launcher pid=%d ipsw=%s bundle=%s\n",
           process, url.path.UTF8String, bundlePath.UTF8String);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t changed;
        do {
            changed = waitpid(process, &status, 0);
        } while (changed < 0 && errno == EINTR);
        int exitCode = changed == process && WIFEXITED(status)
            ? WEXITSTATUS(status) : -1;
        int signalCode = changed == process && WIFSIGNALED(status)
            ? WTERMSIG(status) : 0;
        printf("[VirtualMac] installation launcher exited pid=%d status=%d "
               "signal=%d wait=%d\n", process,
               exitCode, signalCode, changed);
        if (exitCode != 0 || signalCode != 0 || changed != process) {
            NSString *existing = [NSString stringWithContentsOfFile:logPath
                encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSString *failure = [NSString stringWithFormat:
                @"INSTALL_FAILED\tlauncher exited status=%d signal=%d wait=%d\n",
                exitCode, signalCode, changed];
            if (![existing containsString:@"INSTALL_FAILED"]) {
                FILE *file = fopen(logPath.fileSystemRepresentation, "a");
                if (file) { fputs(failure.UTF8String, file); fclose(file); }
            }
            VZWriteInstallationAttempt(attemptPath, @"failed", @{@"Failure": failure});
        }
    });
    if (restoreMemory != runtimeMemory)
        printf("[VirtualMac] Monterey restore memory=%lluMiB runtime-memory=%lluMiB\n",
               restoreMemory >> 20, runtimeMemory >> 20);
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.installationAttemptPath = attemptPath;
    self.installationRestoreImagePath = url.path;
    self.installationProcess = process;
    self.installationLogPath = logPath;
    self.installationBundlePath = bundlePath;
    self.installationStagingPath = stagingPath;
    self.installationOptions = options;
    self.installationController = [[[VZProgressViewController alloc]
        initWithTitle:VZL(@"Installing macOS")] autorelease];
    self.installationController.statusText = VZL(@"Preparing installation…");
    self.installationController.detailText =
        VZL(@"Installation progress may pause for several minutes while the Virtual Mac starts the installation environment. Your iPad will remain awake.");
    self.installationController.consoleText = VZL(@"Waiting for installation output…");
    self.installationController.indeterminate = YES;
    self.installationController.cancellationHandler = ^{
        UIAlertController *confirmation = [UIAlertController
            alertControllerWithTitle:VZL(@"Cancel Installation?")
                             message:VZL(@"The incomplete Virtual Mac and its installation files will be deleted.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:VZL(@"Keep Installing")
            style:UIAlertActionStyleCancel handler:nil]];
        [confirmation addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel Installation")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            [self.installationTimer invalidate];
            self.installationTimer = nil;
            NSString *pid = [NSString stringWithFormat:@"%d", self.installationProcess];
            const char *cancelLauncher = "/var/root/VirtualMac/install/install-launcher";
            char *cancelArguments[] = {(char *)cancelLauncher, "--cancel-install",
                (char *)pid.UTF8String,
                (char *)self.installationAttemptPath.fileSystemRepresentation, NULL};
            pid_t cancellation = 0;
            posix_spawn(&cancellation, cancelLauncher, NULL, NULL,
                        cancelArguments, environ);
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController
                dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationProcess = 0;
                [self presentVMLibrary];
            }];
        }]];
        [self.installationController presentViewController:confirmation
            animated:YES completion:nil];
    };
    UINavigationController *installationNavigation = [[[UINavigationController alloc]
        initWithRootViewController:self.installationController] autorelease];
    installationNavigation.modalPresentationStyle = UIModalPresentationPageSheet;
    installationNavigation.modalInPresentation = YES;
    installationNavigation.preferredContentSize = CGSizeMake(640, 620);
    [self presentViewController:installationNavigation animated:YES completion:nil];
    self.installationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
        repeats:YES block:^(NSTimer *timer) {
        NSString *log = [NSString stringWithContentsOfFile:self.installationLogPath
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        self.installationController.consoleText = VZInstallationConsoleText(
            self.installationLogPath);
        if ([log containsString:@"INSTALL_SUCCEEDED"]) {
            [timer invalidate];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self.installationController.indeterminate = NO;
            self.installationController.progress = 1.0;
            NSError *writeError = nil;
            VZWriteVMOptions(self.installationOptions,
                             self.installationBundlePath, &writeError);
            VZWriteInstallationAttempt(self.installationAttemptPath, @"complete",
                @{@"CompletedAt": NSDate.date});
            if ([VZAppSettings.sharedSettings boolForKey:VZAutoDeleteRestoreImageKey])
                VZRemovePaths(@[self.installationRestoreImagePath]);
            NSString *installedPath = [[self.installationBundlePath copy] autorelease];
            NSDictionary *installedOptions = [[self.installationOptions copy] autorelease];
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationTimer = nil;
                self.installationProcess = 0;
                [self presentVMLibrary];
                if (writeError) {
                    setStatus([NSString stringWithFormat:
                        VZL(@"Installed, but settings save failed: %@"), writeError]);
                    VZPresentFailureReport(self, VZL(@"Could Not Save"),
                        [NSString stringWithFormat:
                            VZL(@"Installed, but settings save failed: %@"),
                            writeError.localizedDescription],
                        writeError.debugDescription,
                        VZFailureSupportOptionNone);
                    return;
                }
                UIAlertController *success = [UIAlertController
                    alertControllerWithTitle:VZL(@"macOS Installed")
                                     message:VZL(@"The new Virtual Mac is ready to use.")
                              preferredStyle:UIAlertControllerStyleAlert];
                [success addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                    style:UIAlertActionStyleCancel handler:nil]];
                [success addAction:[UIAlertAction actionWithTitle:VZL(@"Start")
                    style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    (void)action;
                    VZVMLibraryViewController *library = (id)
                        self.libraryNavigationController.viewControllers.firstObject;
                    [self vmLibrary:library bootBundleAtPath:installedPath
                            options:installedOptions];
                }]];
                [self presentViewController:success animated:YES completion:nil];
            }];
            return;
        }
        NSRange failure = [log rangeOfString:@"INSTALL_FAILED"
                                     options:NSBackwardsSearch];
        if (failure.location != NSNotFound) {
            [timer invalidate];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            NSString *tail = [log substringFromIndex:failure.location];
            VZWriteInstallationAttempt(self.installationAttemptPath, @"failed",
                @{@"Failure": tail});
            NSString *archivePath = nil;
            if ([NSFileManager.defaultManager
                    fileExistsAtPath:self.installationStagingPath]) {
                NSDateFormatter *formatter = [[[NSDateFormatter alloc] init]
                    autorelease];
                formatter.dateFormat = @"yyyyMMdd-HHmmss";
                archivePath = [[self.installationStagingPath
                    stringByDeletingPathExtension]
                    stringByAppendingFormat:@".failed-%@",
                    [formatter stringFromDate:NSDate.date]];
                NSError *archiveError = nil;
                if (![NSFileManager.defaultManager
                        moveItemAtPath:self.installationStagingPath
                               toPath:archivePath error:&archiveError]) {
                    printf("[VirtualMac] failed to archive installer staging path: %s\n",
                           archiveError.description.UTF8String);
                    archivePath = nil;
                }
            }
            NSString *explanation = VZInstallationFailureExplanation(tail);
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationTimer = nil;
                self.installationProcess = 0;
                VZFailureDetailsViewController *controller =
                    [[[VZFailureDetailsViewController alloc]
                        initWithTitle:VZL(@"Installation Failed")
                        message:explanation details:tail
                        options:VZFailureSupportOptionNone]
                        autorelease];
                UINavigationController *navigation =
                    [[[UINavigationController alloc]
                        initWithRootViewController:controller] autorelease];
                navigation.modalPresentationStyle =
                    UIModalPresentationPageSheet;
                navigation.preferredContentSize = CGSizeMake(640, 720);
                [self presentViewController:navigation animated:YES
                    completion:nil];
            }];
            return;
        }
        NSRange progress = [log rangeOfString:@"INSTALL_PROGRESS\t"
                                      options:NSBackwardsSearch];
        if (progress.location != NSNotFound) {
            NSString *tail = [log substringFromIndex:NSMaxRange(progress)];
            double fraction = tail.doubleValue;
            if (fraction <= 0.0) {
                self.installationController.indeterminate = YES;
                self.installationController.statusText = VZL(@"Starting installation environment…");
                self.installationController.detailText = VZL(@"The first progress value can take several minutes while the Virtual Mac changes from DFU to RestoreOS. Your iPad will remain awake.");
                return;
            }
            self.installationController.indeterminate = NO;
            self.installationController.progress = MAX(0, MIN(1, fraction));
            self.installationController.statusText = [NSString stringWithFormat:
                VZL(@"%.0f%% complete"), fraction * 100.0];
            self.installationController.detailText = VZL(@"Installation progress may remain unchanged while macOS prepares the next installation stage. Your iPad will remain awake.");
        } else if ([log containsString:@"INSTALL_BEGIN"]) {
            self.installationController.statusText = VZL(@"Starting installation…");
        } else if ([log containsString:@"RESTORE_LOAD_OK"]) {
            self.installationController.statusText = VZL(@"Preparing virtual hardware…");
        } else if ([log containsString:@"RESTORE_LOAD_BEGIN"]) {
            self.installationController.statusText = VZL(@"Reading restore image…");
        } else if ([log containsString:@"INSTALL_PREPARE_BEGIN"]) {
            self.installationController.statusText = VZL(@"Starting installation services…");
        }
    }];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(gLastInputBoundsSize, gInputView.bounds.size)) {
        gLastInputBoundsSize = gInputView.bounds.size;
        resetPointerSession(YES);
        for (id interaction in gInputView.interactions)
            if ([interaction respondsToSelector:@selector(invalidate)])
                [interaction invalidate];
    }
    updateDisplayGeometry();
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, YES))
        [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, NO))
        [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
               withEvent:(UIPressesEvent *)event
{
    sendPresses(presses, NO);
}

- (void)virtualMachine:(id)virtualMachine didStopWithError:(NSError *)error
{
    (void)virtualMachine;
    printf("[VirtualMac] VM delegate didStopWithError=%s\n",
           error ? [[error description] UTF8String] : "(none)");
    setStatus([NSString stringWithFormat:VZL(@"Virtual Mac stopped: %@"),
                                        error.localizedDescription]);
    [self finishVMAndShowLibraryWithError:error];
}

- (void)guestDidStopVirtualMachine:(id)virtualMachine
{
    (void)virtualMachine;
    printf("[VirtualMac] VM delegate guestDidStopVirtualMachine\n");
    [self finishVMAndShowLibraryWithError:nil];
}

- (void)finishVMAndShowLibraryWithError:(NSError *)error
{
    disconnectExternalDisplay();
    [gDisplayLayer removeFromSuperlayer];
    gDisplayLayer = nil;
    gDisplayContainer = nil;
    gFramebuffer = nil;
    [gFramebufferView release];
    gFramebufferView = nil;
    [gVirtualMachine release];
    gVirtualMachine = nil;
    gVirtualMachineDelegate = nil;
    gKeyboard = nil;
    gGlobeDown = NO;
    gPointingDevice = nil;
    gTouchButtons = 0;
    gHardwareMouseButtons = 0;
    gLastPointerButtons = NSUIntegerMax;
    gCursorView.image = nil;
    gCursorView.hidden = YES;
    gInputView.hidden = YES;
    gTouchScrollRecognizer = nil;
    gPinchRecognizer = nil;
    gRotationRecognizer = nil;
    gSmartMagnifyRecognizer = nil;
    self.activeVMBundlePath = nil;
    [self presentVMLibrary];
    if (error) {
        VZPresentFailureReport(self, VZL(@"Virtual Mac Stopped"),
            error.localizedDescription, error.debugDescription,
            VZFailureSupportOptionSuggestDebugLogging |
            VZFailureSupportOptionSuggestScreenRecording);
    }
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_libraryNavigationController release];
    _installationController.cancellationHandler = nil;
    [_installationController release];
    [_installationTimer invalidate];
    [_installationTimer release];
    [_installationLogPath release];
    [_installationBundlePath release];
    [_installationStagingPath release];
    [_installationAttemptPath release];
    [_installationRestoreImagePath release];
    [_installationOptions release];
    [_activeVMBundlePath release];
    [super dealloc];
}
@end

static CGRect aspectFitRect(CGSize contentSize, CGRect bounds) {
    if (contentSize.width <= 0 || contentSize.height <= 0 ||
        bounds.size.width <= 0 || bounds.size.height <= 0)
        return bounds;
    CGFloat scale = fmin(bounds.size.width / contentSize.width,
                         bounds.size.height / contentSize.height);
    CGSize size = CGSizeMake(contentSize.width * scale,
                             contentSize.height * scale);
    return CGRectIntegral(CGRectMake(
        CGRectGetMidX(bounds) - size.width / 2.0,
        CGRectGetMidY(bounds) - size.height / 2.0,
        size.width, size.height));
}

static CGRect aspectFillRect(CGSize contentSize, CGRect bounds) {
    if (contentSize.width <= 0 || contentSize.height <= 0 ||
        bounds.size.width <= 0 || bounds.size.height <= 0)
        return bounds;
    CGFloat scale = fmax(bounds.size.width / contentSize.width,
                         bounds.size.height / contentSize.height);
    CGSize size = CGSizeMake(contentSize.width * scale,
                             contentSize.height * scale);
    return CGRectIntegral(CGRectMake(
        CGRectGetMidX(bounds) - size.width / 2.0,
        CGRectGetMidY(bounds) - size.height / 2.0,
        size.width, size.height));
}

static CGRect displayViewportRect(CGSize contentSize, CGRect bounds) {
    BOOL fill = [[VZAppSettings.sharedSettings stringForKey:
        VZDisplayScalingKey] isEqualToString:@"fill"];
    return fill ? aspectFillRect(contentSize, bounds)
                : aspectFitRect(contentSize, bounds);
}

static void updateDisplayGeometry(void) {
    static CGRect lastViewport = {{NAN, NAN}, {NAN, NAN}};
    static CGSize lastContainer = {NAN, NAN};
    if (!gDisplayContainer)
        return;
    CGRect viewport = displayViewportRect(gDisplayPixelSize,
                                          gDisplayContainer.bounds);
    if (gDisplayLayer)
        gDisplayLayer.frame = viewport;
    if (gInputView)
        gInputView.frame = viewport;
    if (!CGRectEqualToRect(viewport, lastViewport) ||
        !CGSizeEqualToSize(gDisplayContainer.bounds.size, lastContainer)) {
        printf("[VirtualMac] display viewport %.0fx%.0f at %.0f,%.0f "
               "guest=%.0fx%.0f container=%.0fx%.0f\n",
               viewport.size.width, viewport.size.height,
               viewport.origin.x, viewport.origin.y,
               gDisplayPixelSize.width, gDisplayPixelSize.height,
               gDisplayContainer.bounds.size.width,
               gDisplayContainer.bounds.size.height);
        lastViewport = viewport;
        lastContainer = gDisplayContainer.bounds.size;
    }
}

static void setStatus(NSString *status) {
    printf("[VirtualMac] %s\n", [status UTF8String]);
    if (!gStatusLabel)
        return;
    // Boot status is diagnostic-only and hidden by default. Avoid crossing
    // UIKit objects between the iPadOS 14 VZ worker and the main thread.
    if (!pthread_main_np())
        return;
    gStatusLabel.text = status;
}

static void traceFrameUpdate(id self, SEL selector, id framebuffer,
                             VZFrameUpdateSharedPtr update) {
    uint64_t count = __sync_add_and_fetch(&gFrameUpdateCount, 1);
    const VZFrameUpdateSharedPtr *shared = update.object;
    if (count <= 3 || (gDebugLogging && count % 300 == 0))
        printf("[VirtualMac] PVG frame=%llu framebuffer=%p update=%p control=%p\n",
               (unsigned long long)count, framebuffer,
               shared ? shared->object : NULL,
               shared ? shared->control : NULL);
    ((void(*)(id, SEL, id, VZFrameUpdateSharedPtr))gOriginalFrameUpdate)(
        self, selector, framebuffer, update);
    // Mirror rendered frame to external display.
    if (gExternalMirrorView && gDisplayLayer)
        gExternalMirrorView.layer.contents = gDisplayLayer.contents;
}

static UIImage *copyCursorImage(const uint8_t *cursor) {
    const void *pixels = *(const void *const *)(cursor + 0);
    uint32_t width = *(const uint32_t *)(cursor + 8);
    uint32_t height = *(const uint32_t *)(cursor + 12);
    uint32_t bytesPerPixel = *(const uint32_t *)(cursor + 16);
    if (!pixels || width == 0 || height == 0 || bytesPerPixel != 4 ||
        width > 4096 || height > 4096)
        return nil;
    size_t bytesPerRow = (size_t)width * bytesPerPixel;
    if (bytesPerRow > SIZE_MAX / height)
        return nil;
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault, pixels, (CFIndex)(bytesPerRow * height));
    CGDataProviderRef provider = data
        ? CGDataProviderCreateWithCFData(data) : NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = provider && colorSpace
        ? CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace,
                        (CGBitmapInfo)0x2004, provider, NULL, false,
                        kCGRenderingIntentDefault)
        : NULL;
    UIImage *result = image ? [[UIImage alloc] initWithCGImage:image] : nil;
    if (image)
        CGImageRelease(image);
    if (colorSpace)
        CGColorSpaceRelease(colorSpace);
    if (provider)
        CGDataProviderRelease(provider);
    if (data)
        CFRelease(data);
    return result;
}

static void updateCursorOverlay(VZFrameUpdateSharedPtr update) {
    // Clang passes this non-trivial C++ shared_ptr parameter indirectly even
    // though the Objective-C type encoding describes its two pointer fields.
    const VZFrameUpdateSharedPtr *shared = update.object;
    const uint8_t *cursor = shared ? shared->object : NULL;
    if (!cursor || !gCursorView)
        return;
    BOOL imageChanged = *(const uint8_t *)(cursor + 40) != 0;
    BOOL imagePresent = *(const uint8_t *)(cursor + 32) != 0;
    uint32_t width = *(const uint32_t *)(cursor + 8);
    uint32_t height = *(const uint32_t *)(cursor + 12);
    uint32_t hotspotX = *(const uint32_t *)(cursor + 24);
    uint32_t hotspotY = *(const uint32_t *)(cursor + 28);
    uint32_t guestX = *(const uint32_t *)(cursor + 48);
    uint32_t guestY = *(const uint32_t *)(cursor + 52);
    UIImage *image = imageChanged && imagePresent
        ? copyCursorImage(cursor) : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (imageChanged) {
            gCursorView.image = image;
            gCursorView.hidden = image == nil;
            gCursorPixelSize = image
                ? CGSizeMake(width, height) : CGSizeZero;
            gCursorHotspot = image
                ? CGPointMake(hotspotX, hotspotY) : CGPointZero;
        }
        CGFloat scaleX = gInputView.bounds.size.width /
                         gDisplayPixelSize.width;
        CGFloat scaleY = gInputView.bounds.size.height /
                         gDisplayPixelSize.height;
        CGSize size = CGSizeMake(gCursorPixelSize.width * scaleX,
                                 gCursorPixelSize.height * scaleY);
        CGPoint origin = CGPointMake(
            gInputView.frame.origin.x +
                ((CGFloat)guestX - gCursorHotspot.x) * scaleX,
            gInputView.frame.origin.y +
                ((CGFloat)guestY - gCursorHotspot.y) * scaleY);
        // A just-sent host pointer event is newer than this asynchronous PVG
        // callback. Keep the predicted position briefly; a subsequent guest
        // update reconciles it without the cursor jumping one frame backward.
        if (CACurrentMediaTime() - gLastPredictedCursorTime >= 0.05)
            gCursorView.frame = (CGRect){origin, size};
        [image release];
    });
}

static void traceCursorUpdate(id self, SEL selector, id framebuffer,
                              VZFrameUpdateSharedPtr update) {
    uint64_t count = __sync_add_and_fetch(&gCursorUpdateCount, 1);
    if (count <= 8 || (gDebugLogging && count % 300 == 0)) {
        const VZFrameUpdateSharedPtr *shared = update.object;
        const uint8_t *cursor = shared ? shared->object : NULL;
        printf("[VirtualMac] PVG cursor=%llu pos=%u,%u image-change=%d "
               "image=%d size=%ux%u\n",
               (unsigned long long)count,
               cursor ? *(const uint32_t *)(cursor + 48) : 0,
               cursor ? *(const uint32_t *)(cursor + 52) : 0,
               cursor ? *(const uint8_t *)(cursor + 40) != 0 : 0,
               cursor ? *(const uint8_t *)(cursor + 32) != 0 : 0,
               cursor ? *(const uint32_t *)(cursor + 8) : 0,
               cursor ? *(const uint32_t *)(cursor + 12) : 0);
    }
    updateCursorOverlay(update);
    ((void(*)(id, SEL, id, VZFrameUpdateSharedPtr))gOriginalCursorUpdate)(
        self, selector, framebuffer, update);
}

static BOOL installFramebufferTrace(void) {
    Class framebufferViewClass = objc_getClass("_VZFramebufferView");
    Method method = class_getInstanceMethod(
        framebufferViewClass, S("framebuffer:didUpdateFrame:"));
    if (!method)
        return NO;
    IMP frameImplementation = method_getImplementation(method);
    if (frameImplementation != (IMP)&traceFrameUpdate) {
        gOriginalFrameUpdate = method_setImplementation(
            method, (IMP)&traceFrameUpdate);
    } else if (!gOriginalFrameUpdate) {
        printf("[VirtualMac] frame callback already traced without original\n");
        return NO;
    }
    Method cursorMethod = class_getInstanceMethod(
        framebufferViewClass, S("framebuffer:didUpdateCursor:"));
    if (cursorMethod) {
        IMP cursorImplementation = method_getImplementation(cursorMethod);
        if (cursorImplementation != (IMP)&traceCursorUpdate) {
            gOriginalCursorUpdate = method_setImplementation(
                cursorMethod, (IMP)&traceCursorUpdate);
        } else if (!gOriginalCursorUpdate) {
            printf("[VirtualMac] cursor callback already traced without original\n");
            return NO;
        }
        printf("[VirtualMac] cursor callback type=%s original=%p trace=%p\n",
               method_getTypeEncoding(cursorMethod), gOriginalCursorUpdate,
               (void *)&traceCursorUpdate);
    }
    printf("[VirtualMac] frame callback type=%s original=%p trace=%p\n",
           method_getTypeEncoding(method), gOriginalFrameUpdate,
           (void *)&traceFrameUpdate);
    return gOriginalFrameUpdate != NULL && gOriginalCursorUpdate != NULL;
}

static void logFramebufferState(id view, id framebuffer, const char *phase) {
    Ivar rateIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_currentFrameRate");
    Ivar observersIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_observers");
    Ivar lastFrameIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_lastFrameUpdate");
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)framebuffer;
    uint64_t rate = *(const uint64_t *)(bytes + ivar_getOffset(rateIvar));
    const void *const *observers =
        (const void *const *)(bytes + ivar_getOffset(observersIvar));
    const void *const *lastFrame =
        (const void *const *)(bytes + ivar_getOffset(lastFrameIvar));
    NSUInteger observerCount = observers[0] && observers[1]
        ? ((const uint8_t *)observers[1] - (const uint8_t *)observers[0]) / 16
        : 0;
    printf("[VirtualMac] framebuffer state %s window=%p rate=%llu "
           "observers=%lu [%p,%p) lastFrame=%p/%p\n",
           phase, m0(view, "window"), (unsigned long long)rate,
           (unsigned long)observerCount, observers[0], observers[1],
           lastFrame[0], lastFrame[1]);
}

// VZVirtualMachine owns a libc++ unordered_map of host RPC callbacks at
// ivar offset 0x98 in the extracted 22D68 framework. Keep this diagnostic
// alongside the port so a device run can prove that the stock
// process_frame_update callback survived construction and start.
static void dumpRPCHandlers(id virtualMachine, const char *phase) {
    const uint8_t *vm = (const uint8_t *)(__bridge const void *)virtualMachine;
    const uint8_t *table = *(const uint8_t *const *)(vm + 0x98);
    if (!table) {
        printf("[VirtualMac] RPC handlers %s table=NULL\n", phase);
        return;
    }

    const void *buckets = *(const void *const *)(table + 0x0);
    uint64_t bucketCount = *(const uint64_t *)(table + 0x8);
    const uint8_t *node = *(const uint8_t *const *)(table + 0x10);
    uint64_t declaredCount = *(const uint64_t *)(table + 0x18);
    printf("[VirtualMac] RPC handlers %s table=%p buckets=%p "
           "bucketCount=%llu declaredCount=%llu head=%p\n",
           phase, table, buckets,
           (unsigned long long)bucketCount,
           (unsigned long long)declaredCount, node);

    for (uint64_t i = 0; node && i < declaredCount && i < 64; i++) {
        int8_t discriminator = *(const int8_t *)(node + 0x27);
        const char *name;
        uint64_t length;
        if (discriminator < 0) {
            name = *(const char *const *)(node + 0x10);
            length = *(const uint64_t *)(node + 0x18);
        } else {
            name = (const char *)(node + 0x10);
            length = (uint8_t)discriminator;
        }
        printf("[VirtualMac] RPC handler[%llu] node=%p hash=0x%llx "
               "name=%.*s callback=%p\n",
               (unsigned long long)i, node,
               (unsigned long long)*(const uint64_t *)(node + 0x8),
               (int)length, name,
               *(const void *const *)(node + 0x40));
        node = *(const uint8_t *const *)node;
    }
}

static BOOL loadExtractedFrameworks(void) {
    NSString *hookPath =
        [NSBundle.mainBundle pathForResource:@"VZHostCompat"
                                      ofType:@"dylib"];
    void *hook = hookPath
        ? dlopen([hookPath fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL)
        : NULL;
    if (!hook) {
        printf("[VirtualMac] dlopen host hook FAILED: %s\n", dlerror());
        return NO;
    }
    printf("[VirtualMac] loaded host hook: %s\n",
           [hookPath fileSystemRepresentation]);

    const char *images[] = {
        "/var/root/VirtualMac/payload/Frameworks/vmnet.framework/vmnet",
        "/var/root/VirtualMac/payload/Frameworks/Hypervisor.framework/Hypervisor",
        "/var/root/VirtualMac/payload/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
        "/var/root/VirtualMac/payload/Frameworks/Virtualization.framework/Virtualization",
    };
    for (NSUInteger i = 0; i < sizeof(images) / sizeof(images[0]); i++) {
        if (!dlopen(images[i], RTLD_NOW | RTLD_GLOBAL)) {
            printf("[VirtualMac] dlopen %s FAILED: %s\n", images[i], dlerror());
            return NO;
        }
    }

    Method start = class_getInstanceMethod(
        objc_getClass("VZVirtualMachine"),
        sel_registerName("startWithCompletionHandler:"));
    Dl_info virtualizationInfo = {0};
    dladdr((const void *)method_getImplementation(start), &virtualizationInfo);
    printf("[VirtualMac] VZ image=%p (%s)\n",
           virtualizationInfo.dli_fbase,
           virtualizationInfo.dli_fname ?: "?");
    if (!virtualizationInfo.dli_fbase)
        return NO;
    int (*rebindVirtualization)(void *) =
        (int(*)(void *))dlsym(hook, "vz_rebind_virtualization");
    gHostVMStarted = (void(*)(void))dlsym(hook, "vz_host_vm_started");
    int rebindResult = rebindVirtualization
        ? rebindVirtualization(virtualizationInfo.dli_fbase)
        : -1;
    printf("[VirtualMac] authenticated VZ rebind=%p result=%d\n",
           rebindVirtualization, rebindResult);
    if (rebindResult != 0 || !gHostVMStarted)
        return NO;
    return installFramebufferTrace();
}

static void configureAudio(id configuration, NSDictionary *options) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"VZDisableAudio"]) {
        printf("[VirtualMac] audio disabled by VZDisableAudio\n");
        return;
    }

    // Ventura's native macOS VM configuration uses virtio-sound with host
    // stream attachments. Use the same path for playback and microphone input.
    BOOL outputEnabled = [options[@"AudioOutputEnabled"] boolValue];
    BOOL inputEnabled = [options[@"AudioInputEnabled"] boolValue];
    if (!outputEnabled && !inputEnabled) {
        printf("[VirtualMac] audio disabled by VM configuration\n");
        return;
    }
    id sink = outputEnabled ? NEW("VZHostAudioOutputStreamSink") : nil;
    id output = outputEnabled
        ? NEW("VZVirtioSoundDeviceOutputStreamConfiguration") : nil;
    id source = inputEnabled ? NEW("VZHostAudioInputStreamSource") : nil;
    id input = inputEnabled
        ? NEW("VZVirtioSoundDeviceInputStreamConfiguration") : nil;
    id sound = NEW("VZVirtioSoundDeviceConfiguration");
    if ((outputEnabled && (!sink || !output)) ||
        (inputEnabled && (!source || !input)) || !sound) {
        printf("[VirtualMac] virtio audio classes unavailable sink=%p output=%p "
               "source=%p input=%p device=%p\n",
               sink, output, source, input, sound);
        return;
    }
    NSMutableArray *streams = [NSMutableArray array];
    if (inputEnabled) {
        setObj(input, "setSource:", source);
        [streams addObject:input];
    }
    if (outputEnabled) {
        setObj(output, "setSink:", sink);
        [streams addObject:output];
    }
    setObj(sound, "setStreams:", streams);
    setObj(configuration, "setAudioDevices:", @[sound]);
    printf("[VirtualMac] configured virtio audio output=%d/%p input=%d/%p\n",
           outputEnabled, sink, inputEnabled, source);
}

static BOOL videoToolboxAcceleratorSupported(id self, SEL selector) {
    (void)self;
    (void)selector;
    return YES;
}

static void configureVideoToolbox(id configuration, NSDictionary *options) {
    if (![options[@"VideoToolboxEnabled"] boolValue]) {
        printf("[VirtualMac] VideoToolbox accelerator disabled by VM configuration\n");
        return;
    }
    Class deviceClass = CLS("_VZMacVideoToolboxDeviceConfiguration");
    SEL supportedSelector = S("_isSupported");
    BOOL nativePredicate = deviceClass &&
        [deviceClass respondsToSelector:supportedSelector] &&
        ((BOOL(*)(id, SEL))objc_msgSend)(deviceClass, supportedSelector);
    if (!deviceClass) {
        printf("[VirtualMac] VideoToolbox accelerator class unavailable\n");
        return;
    }
    // The extracted framework's predicate resolves its weak VideoToolbox
    // imports in this UIKit host process, where iPadOS's system VideoToolbox
    // lacks the three Mac host-session exports. The VMM has our matching
    // extracted implementation, so make the configuration predicate describe
    // the actual child runtime before both init and validation consult it.
    Method supportedMethod = class_getClassMethod(deviceClass,
                                                  supportedSelector);
    if (supportedMethod)
        method_setImplementation(supportedMethod,
                                 (IMP)videoToolboxAcceleratorSupported);
    id device = NEW("_VZMacVideoToolboxDeviceConfiguration");
    if (!device ||
        ![configuration respondsToSelector:S("_setAcceleratorDevices:")]) {
        printf("[VirtualMac] VideoToolbox accelerator construction failed device=%p\n",
               device);
        [device release];
        return;
    }
    setObj(configuration, "_setAcceleratorDevices:", @[device]);
    printf("[VirtualMac] configured native VideoToolbox accelerator=%p "
           "original-supported=%d\n", device, nativePredicate);
    [device release];
}

static void requestMicrophoneAccess(dispatch_block_t continuation) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    AVAudioSessionRecordPermission permission = session.recordPermission;
    printf("[VirtualMac] microphone permission before request=%lu\n",
           (unsigned long)permission);
    NSError *sessionError = nil;
    AVAudioSessionCategoryOptions sessionOptions =
        AVAudioSessionCategoryOptionMixWithOthers |
        AVAudioSessionCategoryOptionDefaultToSpeaker |
        AVAudioSessionCategoryOptionAllowBluetoothHFP;
    BOOL categoryOK = [session
        setCategory:AVAudioSessionCategoryPlayAndRecord
               mode:AVAudioSessionModeDefault
            options:sessionOptions error:&sessionError];
    BOOL activeOK = [session setActive:YES error:&sessionError];
    printf("[VirtualMac] audio session category=%d active=%d error=%s\n",
           categoryOK, activeOK,
           sessionError ? sessionError.localizedDescription.UTF8String
                        : "none");
    if (permission != AVAudioSessionRecordPermissionUndetermined) {
        continuation();
        return;
    }

    // The host audio source is created by Virtualization only after VM setup.
    // Ask under the visible application bundle first so TCC attributes capture
    // to Virtual Mac instead of silently giving its private VMM child zeros.
    __block BOOL continued = NO;
    void (^finish)(BOOL, const char *) = ^(BOOL granted, const char *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (continued)
                return;
            continued = YES;
            printf("[VirtualMac] microphone permission granted=%d via=%s\n",
                   granted, reason);
            continuation();
        });
    };
    [session requestRecordPermission:^(BOOL granted) {
        finish(granted, "TCC callback");
    }];
    // A platform-installed app on iPadOS can fail to receive a
    // TCC callback. Never make the VM library depend indefinitely on it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        finish(NO, "timeout");
    });
}

static void configureNetwork(id configuration, NSDictionary *options) {
    NSString *mode = options[@"NetworkMode"] ?: @"NAT";
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        [mode isEqualToString:@"Bridge"]) {
        // The iPadOS 14 Wi-Fi stack cannot register a second station MAC for
        // a guest. Treat legacy configurations as NAT; newer hosts retain the
        // existing bridged-network implementation unchanged.
        printf("[VirtualMac] bridged networking is unavailable on iPadOS 14; using NAT\n");
        mode = @"NAT";
    }
    if ([mode isEqualToString:@"Disabled"] ||
        [NSUserDefaults.standardUserDefaults boolForKey:@"VZDisableNetwork"]) {
        printf("[VirtualMac] network disabled\n");
        return;
    }

    id attachment = nil;
    if ([mode isEqualToString:@"Bridge"]) {
        NSString *identifier = options[@"BridgeInterface"] ?: @"en0";
        NSArray *interfaces = ((id(*)(id, SEL))objc_msgSend)(
            CLS("VZBridgedNetworkInterface"), S("networkInterfaces"));
        id selected = nil;
        for (id candidate in interfaces) {
            NSString *candidateIdentifier = [candidate valueForKey:@"identifier"];
            if ([candidateIdentifier isEqualToString:identifier]) {
                selected = candidate;
                break;
            }
        }
        if (selected) {
            attachment = ((id(*)(id, SEL, id))objc_msgSend)(
                m0(CLS("VZBridgedNetworkDeviceAttachment"), "alloc"),
                S("initWithInterface:"), selected);
        }
        printf("[VirtualMac] bridge request interface=%s available=%s selected=%p\n",
               identifier.UTF8String, interfaces.description.UTF8String,
               selected);
    } else {
        attachment = NEW("VZNATNetworkDeviceAttachment");
    }
    id network = NEW("VZVirtioNetworkDeviceConfiguration");
    if (!attachment || !network) {
        printf("[VirtualMac] virtio NAT classes unavailable attachment=%p "
               "device=%p\n", attachment, network);
        return;
    }
    // Keep the guest NIC identity stable across app launches. The framework's
    // default is valid but randomly generated for every new configuration.
    NSString *macString = options[@"MACAddress"];
    id macAddress = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMACAddress"), "alloc"), S("initWithString:"),
        macString);
    if (!macAddress) {
        macAddress = [m0(CLS("VZMACAddress"),
            "randomLocallyAdministeredAddress") retain];
        macString = [[macAddress valueForKey:@"string"] description];
    }
    setObj(network, "setMACAddress:", macAddress);
    setObj(network, "setAttachment:", attachment);
    setObj(configuration, "setNetworkDevices:", @[network]);
    printf("[VirtualMac] configured virtio %s network attachment=%p mac=%s\n",
           mode.UTF8String, attachment,
           [[[macAddress valueForKey:@"string"] description]
                            UTF8String]);
}

static void configureDirectorySharing(id configuration,
                                      NSDictionary *options) {
    NSArray *shares = options[@"SharedDirectories"];
    if (![shares isKindOfClass:NSArray.class] || shares.count == 0)
        return;
    NSMutableDictionary *directories = [NSMutableDictionary dictionary];
    for (NSDictionary *saved in shares) {
        NSString *path = saved[@"Path"];
        if (![path isKindOfClass:NSString.class] || !path.length)
            continue;
        id directory = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
            m0(CLS("VZSharedDirectory"), "alloc"),
            S("initWithURL:readOnly:"), fileURL(path),
            [saved[@"ReadOnly"] boolValue]);
        if (!directory)
            continue;
        NSString *baseName = path.lastPathComponent.length
            ? path.lastPathComponent : VZL(@"Shared Folder");
        NSString *name = baseName;
        for (NSUInteger suffix = 2; directories[name]; suffix++)
            name = [NSString stringWithFormat:@"%@ %lu", baseName,
                    (unsigned long)suffix];
        directories[name] = directory;
    }
    if (!directories.count)
        return;
    id share = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMultipleDirectoryShare"), "alloc"),
        S("initWithDirectories:"), directories);
    id fileSystemClass = CLS("VZVirtioFileSystemDeviceConfiguration");
    NSString *tag = m0(fileSystemClass, "macOSGuestAutomountTag");
    id device = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(fileSystemClass, "alloc"), S("initWithTag:"), tag);
    if (!share || !device)
        return;
    setObj(device, "setShare:", share);
    setObj(configuration, "setDirectorySharingDevices:", @[device]);
    printf("[VirtualMac] configured directory shares count=%lu tag=%s names=%s\n",
           (unsigned long)directories.count, tag.UTF8String,
           directories.allKeys.description.UTF8String);
}

static id makeConfiguration(NSString *bundlePath, NSDictionary *options,
                            NSError **error) {
    id platform = NEW("VZMacPlatformConfiguration");
    id auxiliaryStorage = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacAuxiliaryStorage"), "alloc"),
        S("initWithContentsOfURL:"),
        fileURL([bundlePath stringByAppendingPathComponent:@"AuxiliaryStorage"]));
    setObj(platform, "setAuxiliaryStorage:", auxiliaryStorage);

    NSData *hardwareModelData = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"HardwareModel"]];
    id hardwareModel = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacHardwareModel"), "alloc"),
        S("initWithDataRepresentation:"), hardwareModelData);
    if (!hardwareModel ||
        !((BOOL(*)(id, SEL))objc_msgSend)(hardwareModel, S("isSupported"))) {
        printf("[VirtualMac] unsupported hardware model\n");
        return nil;
    }
    setObj(platform, "setHardwareModel:", hardwareModel);

    NSData *machineIdentifierData = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"MachineIdentifier"]];
    id machineIdentifier = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacMachineIdentifier"), "alloc"),
        S("initWithDataRepresentation:"), machineIdentifierData);
    setObj(platform, "setMachineIdentifier:", machineIdentifier);

    id configuration = NEW("VZVirtualMachineConfiguration");
    setObj(configuration, "setPlatform:", platform);
    NSUInteger hostCPUCount = NSProcessInfo.processInfo.activeProcessorCount;
    NSUInteger cpuCount = [options[@"CPUCount"] unsignedIntegerValue];
    cpuCount = MAX((NSUInteger)2, MIN(cpuCount, hostCPUCount));
    uint64_t physicalMemory = NSProcessInfo.processInfo.physicalMemory;
    uint64_t memoryLimit = MAX((2ULL << 30),
        (physicalMemory >> 30) << 30);
    uint64_t memorySize = [options[@"MemorySize"] unsignedLongLongValue];
    memorySize = MAX((2ULL << 30), MIN(memorySize, memoryLimit));
    ((void(*)(id, SEL, NSUInteger))objc_msgSend)(
        configuration, S("setCPUCount:"), cpuCount);
    ((void(*)(id, SEL, unsigned long long))objc_msgSend)(
        configuration, S("setMemorySize:"), memorySize);
    printf("[VirtualMac] configured guest cpus=%lu host-active-cpus=%lu "
           "memory=%lluMiB\n",
           (unsigned long)cpuCount, (unsigned long)hostCPUCount,
           memorySize >> 20);
    setObj(configuration, "setBootLoader:", NEW("VZMacOSBootLoader"));

    UIScreen *screen = UIScreen.mainScreen;
    CGSize hostSize = screen.bounds.size;
    CGFloat nativeScale = screen.nativeScale > 0
        ? screen.nativeScale : screen.scale;
    // The app is landscape-only, so multiplying the oriented UIKit bounds by
    // nativeScale produces the panel's exact native landscape pixel size
    // (2388x1668 on the connected 11-inch iPad Pro). A Retina-density PPI
    // makes macOS expose this as a 2x logical desktop instead of a scaled
    // low-density monitor.
    NSString *displayMode = options[@"DisplayMode"];
    BOOL customDisplay = [displayMode isEqualToString:@"Custom"];
    BOOL portraitDisplay = [displayMode isEqualToString:
        @"PortraitNativeRetina"];
    CGSize nativePixelSize = screen.nativeBounds.size;
    NSInteger displayWidth = customDisplay
        ? [options[@"DisplayWidth"] integerValue]
        : portraitDisplay
            ? (NSInteger)llround(MIN(nativePixelSize.width,
                                     nativePixelSize.height))
            : (NSInteger)llround(hostSize.width * nativeScale);
    NSInteger displayHeight = customDisplay
        ? [options[@"DisplayHeight"] integerValue]
        : portraitDisplay
            ? (NSInteger)llround(MAX(nativePixelSize.width,
                                     nativePixelSize.height))
            : (NSInteger)llround(hostSize.height * nativeScale);
    NSInteger pixelsPerInch = customDisplay
        ? [options[@"DisplayPixelsPerInch"] integerValue] : 264;
    displayWidth = MAX(800, MIN(7680, displayWidth));
    displayHeight = MAX(800, MIN(7680, displayHeight));
    pixelsPerInch = MAX(72, MIN(600, pixelsPerInch));
    gDisplayPixelSize = CGSizeMake(displayWidth, displayHeight);
    printf("[VirtualMac] configured guest display %ldx%ld at %ld ppi "
           "for host %.0fx%.0f scale=%.3f\n",
           (long)displayWidth, (long)displayHeight,
           (long)pixelsPerInch, hostSize.width, hostSize.height,
           nativeScale);
    id graphics = NEW("VZMacGraphicsDeviceConfiguration");
    id display = ((id(*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
        m0(CLS("VZMacGraphicsDisplayConfiguration"), "alloc"),
        S("initWithWidthInPixels:heightInPixels:pixelsPerInch:"),
        displayWidth, displayHeight, pixelsPerInch);
    setObj(graphics, "setDisplays:", @[display]);
    setObj(configuration, "setGraphicsDevices:", @[graphics]);

    id attachment = ((id(*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
        m0(CLS("VZDiskImageStorageDeviceAttachment"), "alloc"),
        S("initWithURL:readOnly:error:"),
        fileURL([bundlePath stringByAppendingPathComponent:@"Disk.img"]),
        NO, error);
    if (!attachment)
        return nil;
    id blockDevice = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZVirtioBlockDeviceConfiguration"), "alloc"),
        S("initWithAttachment:"), attachment);
    setObj(configuration, "setStorageDevices:", @[blockDevice]);

    // Monterey requires the older USB keyboard and absolute USB mouse guest devices.
    NSString *keyboardChoice = options[@"KeyboardDevice"];
    BOOL useUSBKeyboard = [keyboardChoice isEqualToString:@"USBKeyboard"];
    id keyboard = useUSBKeyboard
        ? NEW("VZUSBKeyboardConfiguration")
        : NEW("_VZMacKeyboardConfiguration");
    NSString *pointingChoice = options[@"PointingDevice"];
    BOOL useUSBMouse = [pointingChoice isEqualToString:@"USBMouse"];
    id pointing = useUSBMouse
        ? NEW("VZUSBScreenCoordinatePointingDeviceConfiguration")
        : NEW("VZMacTrackpadConfiguration");
    if (keyboard)
        setObj(configuration, "setKeyboards:", @[keyboard]);
    if (pointing)
        setObj(configuration, "setPointingDevices:", @[pointing]);
    printf("[VirtualMac] configured keyboard device=%s class=%s\n",
           useUSBKeyboard ? "USB Keyboard" : "Mac Keyboard",
           keyboard ? object_getClassName(keyboard) : "(unavailable)");
    printf("[VirtualMac] configured pointing device=%s class=%s\n",
           useUSBMouse ? "USB Mouse" : "Mac Trackpad",
           pointing ? object_getClassName(pointing) : "(unavailable)");
    configureAudio(configuration, options);
    configureVideoToolbox(configuration, options);
    configureNetwork(configuration, options);
    configureDirectorySharing(configuration, options);
    return configuration;
}

static BOOL prepareFramebuffer(UIView *container) {
    NSArray *graphicsDevices = m0(gVirtualMachine, "_graphicsDevices");
    id graphicsDevice = [graphicsDevices firstObject];
    NSArray *framebuffers = graphicsDevice ? m0(graphicsDevice, "framebuffers") : nil;
    id framebuffer = [framebuffers firstObject];
    printf("[VirtualMac] graphicsDevices=%s framebuffers=%s\n",
           [[graphicsDevices description] UTF8String],
           [[framebuffers description] UTF8String]);
    if (!framebuffer) {
        setStatus(VZL(@"Virtual Mac has no published framebuffer"));
        return NO;
    }

    Class framebufferViewClass = objc_getClass("_VZFramebufferView");
    if (!framebufferViewClass) {
        setStatus(VZL(@"The Virtual Mac display view is unavailable"));
        return NO;
    }
    VZSetNSViewFrameRequestsSuppressed(NO);
    gDisplayContainer = container;
    container.clipsToBounds = YES;
    CGRect viewport = displayViewportRect(gDisplayPixelSize, container.bounds);
    id view = ((id(*)(id, SEL, CGRect))objc_msgSend)(
        [framebufferViewClass alloc], S("initWithFrame:"), viewport);
    gFramebufferView = view;
    gFramebuffer = framebuffer;
    gFramebufferView.backgroundColor = [UIColor blackColor];
    gFramebufferView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Do not insert the AppKit-ABI subclass into UIKit's UIView tree: UIKit's
    // private hierarchy traversal and AppKit's compiled NSView layout are not
    // ABI-compatible. Its custom display layer is portable, so host that layer
    // inside an ordinary UIView while NSViewShim supplies the key window.
    CALayer *displayLayer =
        ((CALayer *(*)(id, SEL))objc_msgSend)(view, S("layer"));
    gDisplayLayer = displayLayer;
    displayLayer.frame = viewport;
    [container.layer insertSublayer:displayLayer atIndex:0];
    ((void(*)(id, SEL, BOOL))objc_msgSend)(
        view, S("setShowsCursor:"), NO);
    setObj(view, "setFramebuffer:", framebuffer);
    if ([view respondsToSelector:S("layout")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("layout"));
    updateDisplayGeometry();
    logFramebufferState(view, framebuffer, "pre-registered");
    return YES;
}

typedef struct {
    UIView *container;
    BOOL result;
} VZPrepareFramebufferContext;

static void prepareFramebufferOnMain(void *opaque) {
    VZPrepareFramebufferContext *context = opaque;
    context->result = prepareFramebuffer(context->container);
}

static BOOL prepareFramebufferThreadSafe(UIView *container) {
    if (pthread_main_np())
        return prepareFramebuffer(container);
    VZPrepareFramebufferContext context = { container, NO };
    dispatch_sync_f(dispatch_get_main_queue(), &context,
                    prepareFramebufferOnMain);
    return context.result;
}

typedef struct {
    id delegate;
    NSError *error;
} VZFinishContext;

static void finishVMOnMain(void *opaque) {
    VZFinishContext *context = opaque;
    [context->delegate finishVMAndShowLibraryWithError:context->error];
    [context->delegate release];
    [context->error release];
    free(context);
}

static void finishVMThreadSafe(id delegate, NSError *error) {
    if (pthread_main_np()) {
        [delegate finishVMAndShowLibraryWithError:error];
        return;
    }
    VZFinishContext *context = calloc(1, sizeof(*context));
    context->delegate = [delegate retain];
    context->error = [error retain];
    dispatch_async_f(dispatch_get_main_queue(), context, finishVMOnMain);
}

static void activateFramebuffer(void) {
    id view = gFramebufferView;
    id framebuffer = gFramebuffer;
    if (!view || !framebuffer)
        return;
    VZSetNSViewFrameRequestsSuppressed(NO);
    if ([view respondsToSelector:S("viewDidMoveToWindow")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("viewDidMoveToWindow"));
    if ([view respondsToSelector:S("layout")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("layout"));
    BOOL inputFocused = GCKeyboard.coalescedKeyboard
        ? [gInputView becomeFirstResponder] : gInputView.isFirstResponder;
    printf("[VirtualMac] input focus after-start requested=%d active=%d window=%p\n",
           inputFocused, [gInputView isFirstResponder], gInputView.window);
    scheduleInputSelfTest();
    pollInputCommand();
    scheduleRecoveryDialogDismissal();
    logFramebufferState(view, framebuffer, "activated");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        logFramebufferState(view, framebuffer, "after-2s");
    });
    setStatus(VZL(@"Virtual Mac running — native PVG framebuffer attached"));
    if (externalDisplayEnabled())
        connectExternalDisplay();
}

typedef struct {
    id virtualMachine;
    id startOptions;
    void (^completion)(NSError *);
} VZInvokeStartContext;

static void invokeVirtualMachineStartOnMain(void *opaque) {
    VZInvokeStartContext *context = opaque;
    if (context->startOptions) {
        ((void(*)(id, SEL, id, id))objc_msgSend)(
            context->virtualMachine,
            S("startWithOptions:completionHandler:"),
            context->startOptions, context->completion);
    } else {
        ((void(*)(id, SEL, id))objc_msgSend)(
            context->virtualMachine, S("startWithCompletionHandler:"),
            context->completion);
    }
    [context->virtualMachine release];
    [context->startOptions release];
    [context->completion release];
    free(context);
}

static void startVirtualMachineWorker(UIView *container, id delegate,
                                      NSString *bundlePath,
                                      NSDictionary *options) {
    unlink("/tmp/vzxpchook.log");
    unlink("/tmp/vmmhook.log");
    unlink("/tmp/vmm.stderr.log");
    setenv("VZ_VMM_BIN",
           "/var/root/VirtualMac/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
           1);
    setenv("VZ_AVP_BOOTER",
           "/var/root/VirtualMac/payload/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin",
           1);
    gDebugLogging = [VZAppSettings.sharedSettings boolForKey:VZDebugLoggingKey];
    setenv("VZ_DEBUG_LOGGING", gDebugLogging ? "1" : "0", 1);
    setenv("VMMHOOK_TRACE_VCPU_LIMIT", gDebugLogging ? "256" : "8", 1);
    setenv("VMMHOOK_TRACE_XPC_LIMIT", gDebugLogging ? "200" : "8", 1);
    setenv("VMM_FACTORY_SETTLE_USEC", "100000", 1);
    // Timestamp correlation places PGIOSurfaceHostDevice finalization just
    // before serialized factory boundary 6. Pause only that boundary long
    // enough for its asynchronous Metal/IOSurface capability exchange.
    setenv("VMM_FACTORY_LONG_STOP", "6", 1);
    setenv("VMM_FACTORY_LONG_SETTLE_USEC", "5000000", 1);
    setenv("PVG_TRACE", "1", 1);
    // Functional PVG task compatibility remains installed in every build;
    // this flag enables only the additional diagnostic method wrappers.
    if (gDebugLogging)
        setenv("PVG_TRACE_METHODS", "1", 1);
    else
        unsetenv("PVG_TRACE_METHODS");
    // WindowServer's long-lived PVG task reached 1.07 GiB while Launchpad was
    // populating its icon textures. Keep ordinary app clients at 1 GiB so 20+
    // simultaneous clients fit in the iPad VA, but give the first three
    // long-lived system clients 2 GiB. Their slots are recycled on deletion.
    setenv("PVG_TASK_RESERVATION_GB", "1", 1);
    setenv("PVG_LARGE_TASK_RESERVATION_GB", "2", 1);
    setenv("PVG_LARGE_TASK_COUNT", "3", 1);
    setenv("PVG_METALLIB_FALLBACK", "1", 1);

    setStatus(VZL(@"Loading extracted Apple virtualization frameworks…"));
    if (!loadExtractedFrameworks()) {
        setStatus(VZL(@"Failed to load extracted frameworks"));
        NSError *loadError = [NSError errorWithDomain:@"VirtualMac" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                VZL(@"Failed to load the extracted Apple virtualization frameworks.")}];
        finishVMThreadSafe(delegate, loadError);
        return;
    }

    printf("[VirtualMac] starting selected VM path=%s\n", bundlePath.UTF8String);
    NSError *error = nil;
    id configuration = makeConfiguration(bundlePath, options, &error);
    if (!configuration) {
        setStatus([NSString stringWithFormat:VZL(@"Configuration failed: %@"),
                                            error.localizedDescription]);
        if (!error)
            error = [NSError errorWithDomain:@"VirtualMac" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    VZL(@"The Virtual Mac configuration could not be created.")}];
        finishVMThreadSafe(delegate, error);
        return;
    }
    BOOL valid = ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(
        configuration, S("validateWithError:"), &error);
    if (!valid) {
        setStatus([NSString stringWithFormat:VZL(@"Validation failed: %@"),
                                            error.localizedDescription]);
        finishVMThreadSafe(delegate, error);
        return;
    }

    gVirtualMachine = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZVirtualMachine"), "alloc"),
        S("initWithConfiguration:"), configuration);
    gVirtualMachineDelegate = delegate;
    if ([gVirtualMachine respondsToSelector:S("setDelegate:")])
        setObj(gVirtualMachine, "setDelegate:", delegate);
    id keyboards = [gVirtualMachine respondsToSelector:S("_keyboards")]
        ? m0(gVirtualMachine, "_keyboards") : nil;
    id pointingDevices =
        [gVirtualMachine respondsToSelector:S("_pointingDevices")]
        ? m0(gVirtualMachine, "_pointingDevices") : nil;
    printf("[VirtualMac] runtime input keyboards=%s pointingDevices=%s\n",
           [[keyboards description] UTF8String],
           [[pointingDevices description] UTF8String]);
    gKeyboard = [keyboards firstObject];
    gPointingDevice = [pointingDevices firstObject];
    dumpRPCHandlers(gVirtualMachine, "after-init");
    // setFramebuffer: installs the process_frame_update handler needed by the
    // VMM. The host hook holds its set_frame_rate message until start succeeds.
    if (!prepareFramebufferThreadSafe(container)) {
        NSError *framebufferError = [NSError errorWithDomain:@"VirtualMac"
            code:3 userInfo:@{NSLocalizedDescriptionKey:
                VZL(@"The Virtual Mac did not publish a display framebuffer.")}];
        finishVMThreadSafe(delegate, framebufferError);
        return;
    }
    setStatus(VZL(@"Starting Virtual Mac…"));
    void (^completion)(NSError *) = ^(NSError *startError) {
        if (startError) {
            setStatus([NSString stringWithFormat:VZL(@"Virtual Mac start failed: %@"),
                                                startError.localizedDescription]);
            finishVMThreadSafe(delegate, startError);
            return;
        }
        printf("[VirtualMac] VM STARTED state=%ld\n",
               (long)((NSInteger(*)(id, SEL))objc_msgSend)(
                   gVirtualMachine, S("state")));
        dumpRPCHandlers(gVirtualMachine, "after-start");
        setStatus(VZL(@"Virtual Mac running — preparing native PVG display"));
        gHostVMStarted();
        // Let the start reply return before exposing the registered display.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            activateFramebuffer();
        });
    };
    id startOptions = nil;
    if ([options[@"BootRecovery"] boolValue] &&
        [gVirtualMachine respondsToSelector:
            S("startWithOptions:completionHandler:")]) {
        startOptions = NEW("VZMacOSVirtualMachineStartOptions");
        ((void(*)(id, SEL, BOOL))objc_msgSend)(
            startOptions, S("setStartUpFromMacOSRecovery:"), YES);
        printf("[VirtualMac] configured recovery start\n");
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        !pthread_main_np()) {
        VZInvokeStartContext *context = calloc(1, sizeof(*context));
        context->virtualMachine = [gVirtualMachine retain];
        context->startOptions = [startOptions retain];
        context->completion = [completion copy];
        dispatch_async_f(dispatch_get_main_queue(), context,
                         invokeVirtualMachineStartOnMain);
    } else if (startOptions) {
        ((void(*)(id, SEL, id, id))objc_msgSend)(
            gVirtualMachine, S("startWithOptions:completionHandler:"),
            startOptions, completion);
    } else {
        ((void(*)(id, SEL, id))objc_msgSend)(
            gVirtualMachine, S("startWithCompletionHandler:"), completion);
    }
    [startOptions release];
}

typedef struct {
    UIView *container;
    id delegate;
    NSString *bundlePath;
    NSDictionary *options;
} VZStartContext;

static void startVirtualMachineOnBackgroundQueue(void *opaque) {
    VZStartContext *context = opaque;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    startVirtualMachineWorker(context->container, context->delegate,
                              context->bundlePath, context->options);
    [context->container release];
    [context->delegate release];
    [context->bundlePath release];
    [context->options release];
    free(context);
    [pool drain];
}

static void startVirtualMachine(UIView *container, id delegate,
                                NSString *bundlePath,
                                NSDictionary *options) {
    // Ventura's VZ startup performs synchronous XPC and device construction.
    // On iPadOS 14, doing that from a tap blocks UIKit long enough to trip the
    // 10-second scene-update watchdog. Keep iPadOS 15/16 on their proven path.
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        pthread_main_np()) {
        VZStartContext *context = calloc(1, sizeof(*context));
        context->container = [container retain];
        context->delegate = [delegate retain];
        context->bundlePath = [bundlePath copy];
        context->options = [options copy];
        dispatch_async_f(
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), context,
            startVirtualMachineOnBackgroundQueue);
        return;
    }
    startVirtualMachineWorker(container, delegate, bundlePath, options);
}

// ─── External Display (Keynote-style) ────────────────────────────────────────
// Keynote and other presentation apps use UIWindow.screen = externalScreen
// to take over an external display without system-level borders. UIScene's
// UIWindowSceneSessionRoleExternalDisplay can add display-specific insets
// that appear as black bars.

static BOOL externalDisplayEnabled(void) {
    return [VZAppSettings.sharedSettings boolForKey:VZExternalDisplayEnabledKey]
        && gFramebuffer != nil;
}

static void connectExternalDisplay(void) {
    if (gExternalWindow)
        return;
    if (![VZAppSettings.sharedSettings boolForKey:VZExternalDisplayEnabledKey])
        return;
    UIScreen *extScreen = nil;
    for (UIScreen *s in UIScreen.screens) {
        if (s != UIScreen.mainScreen) {
            extScreen = s;
            break;
        }
    }
    if (!extScreen)
        return;

    // Disable overscan compensation so the system doesn't scale/inset
    // the display output. Without this, nativeBounds may differ from
    // bounds, introducing system-level black borders.
    extScreen.overscanCompensation = 2;  // UIScreenOverscanCompensationNone

    printf("[VirtualMac] external display connecting screen=%s "
           "bounds=%.0fx%.0f native=%.0fx%.0f scale=%.3f "
           "overscanCompensation=%ld\n",
           extScreen.description.UTF8String,
           extScreen.bounds.size.width, extScreen.bounds.size.height,
           extScreen.nativeBounds.size.width, extScreen.nativeBounds.size.height,
           extScreen.scale,
           (long)extScreen.overscanCompensation);
    for (UIScreenMode *mode in extScreen.availableModes) {
        printf("[VirtualMac] ext screen mode size=%.0fx%.0f "
               "pixelAspectRatio=%.3f\n",
               mode.size.width, mode.size.height,
               mode.pixelAspectRatio);
    }

    gExternalWindow = [[UIWindow alloc] initWithFrame:extScreen.bounds];
    gExternalWindow.screen = extScreen;
    gExternalWindow.backgroundColor = [UIColor blackColor];

    UIView *mirrorView = [[UIView alloc] initWithFrame:gExternalWindow.bounds];
    mirrorView.backgroundColor = [UIColor blackColor];
    mirrorView.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                | UIViewAutoresizingFlexibleHeight;
    mirrorView.layer.contentsGravity = kCAGravityResizeAspect;
    [gExternalWindow addSubview:mirrorView];
    gExternalMirrorView = mirrorView;
    [mirrorView release];

    gExternalWindow.hidden = NO;
    printf("[VirtualMac] external window created frame=%s\n",
           NSStringFromCGRect(gExternalWindow.frame).UTF8String);
}

static void disconnectExternalDisplay(void) {
    if (!gExternalWindow)
        return;
    printf("[VirtualMac] external display disconnecting\n");
    gExternalMirrorView = nil;
    gExternalWindow.hidden = YES;
    [gExternalWindow release];
    gExternalWindow = nil;
}

@interface VirtualMacAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, retain) UIWindow *window;
@end

@implementation VirtualMacAppDelegate
@synthesize window = _window;

- (VZVMLibraryViewController *)libraryController
{
    VZViewController *root = (id)self.window.rootViewController;
    [root presentVMLibrary];
    return (id)root.libraryNavigationController.viewControllers.firstObject;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    UIApplicationShortcutItem *shortcut = launchOptions[
        UIApplicationLaunchOptionsShortcutItemKey];
    BOOL bypassAutoBoot = [shortcut.type isEqualToString:@"com.mac.virtual.show-library"];
    freopen("/tmp/VirtualMac.log", "a", stdout);
    freopen("/tmp/VirtualMac.log", "a", stderr);
    setvbuf(stdout, NULL, _IONBF, 0);
    VZEnableKeyboardRenderingFixAfterCrash();
    installKeyboardRenderingFix();
    installShellShortcutRelay();

    self.window = [[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]
        autorelease];
    VZViewController *controller =
        [[[VZViewController alloc] init] autorelease];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = controller;

    {
        gStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        gStatusLabel.hidden = !shouldShowStatusLabel();
        gStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        gStatusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        gStatusLabel.textColor = [UIColor whiteColor];
        gStatusLabel.font =
            [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        gStatusLabel.textAlignment = NSTextAlignmentCenter;
        gStatusLabel.numberOfLines = 2;
        gStatusLabel.userInteractionEnabled = NO;
        gStatusLabel.layer.cornerRadius = 10;
        gStatusLabel.layer.cornerCurve = kCACornerCurveContinuous;
        gStatusLabel.clipsToBounds = YES;
        [controller.view addSubview:gStatusLabel];
        [NSLayoutConstraint activateConstraints:@[
            [gStatusLabel.centerXAnchor constraintEqualToAnchor:
                controller.view.centerXAnchor],
            [gStatusLabel.bottomAnchor constraintEqualToAnchor:
                controller.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
            [gStatusLabel.widthAnchor constraintEqualToConstant:560],
            [gStatusLabel.heightAnchor constraintEqualToConstant:48],
        ]];
    }

    VZInputView *inputView =
        [[[VZInputView alloc] initWithFrame:controller.view.bounds]
            autorelease];
    gInputView = inputView;
    inputView.backgroundColor = [UIColor clearColor];
    inputView.multipleTouchEnabled = YES;
    inputView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [inputView addGestureRecognizer:
        [[[UIHoverGestureRecognizer alloc]
            initWithTarget:inputView action:@selector(handleHover:)]
            autorelease]];
    [inputView addInteraction:
        [[[UIPointerInteraction alloc] initWithDelegate:inputView]
            autorelease]];
    VZRawScrollRecognizer *scrollRecognizer =
        [[[VZRawScrollRecognizer alloc]
            initWithTarget:inputView action:@selector(handleScroll:)]
            autorelease];
    scrollRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
    // Scroll-wheel input is not represented by UITouch. Rejecting all touch
    // types keeps direct touchscreen click-drag on the existing touch path.
    scrollRecognizer.allowedTouchTypes = @[];
    scrollRecognizer.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:scrollRecognizer];
    UIPanGestureRecognizer *touchScroll = [[[UIPanGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleTouchScroll:)]
        autorelease];
    touchScroll.minimumNumberOfTouches = 2;
    touchScroll.maximumNumberOfTouches = 2;
    touchScroll.allowedTouchTypes = @[@(UITouchTypeDirect)];
    touchScroll.cancelsTouchesInView = YES;
    touchScroll.enabled = [VZAppSettings.sharedSettings
        boolForKey:VZTouchTwoFingerScrollingKey];
    [inputView addGestureRecognizer:touchScroll];
    gTouchScrollRecognizer = touchScroll;
    UIPinchGestureRecognizer *pinch = [[[UIPinchGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handlePinch:)] autorelease];
    pinch.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:pinch];
    gPinchRecognizer = pinch;
    UIRotationGestureRecognizer *rotation = [[[UIRotationGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleRotation:)] autorelease];
    rotation.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:rotation];
    gRotationRecognizer = rotation;
    UITapGestureRecognizer *smartMagnify = [[[UITapGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleSmartMagnify:)]
        autorelease];
    smartMagnify.numberOfTouchesRequired = 2;
    smartMagnify.numberOfTapsRequired = 2;
    smartMagnify.cancelsTouchesInView = NO;
    gSmartMagnifyRecognizer = smartMagnify;
    if ([VZAppSettings.sharedSettings
            boolForKey:VZTouchTwoFingerScrollingKey]) {
        // Direct two-finger motion otherwise begins UIKit's pinch/rotation
        // recognizers first and the pan never emits a scroll event. Those
        // recognizers remain available for a hardware trackpad.
        pinch.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        rotation.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        smartMagnify.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
    }
    [inputView addGestureRecognizer:smartMagnify];
    [controller.view addSubview:inputView];

    gCursorView = [[UIImageView alloc] initWithFrame:CGRectZero];
    gCursorView.backgroundColor = [UIColor clearColor];
    gCursorView.contentMode = UIViewContentModeScaleToFill;
    gCursorView.userInteractionEnabled = NO;
    gCursorView.hidden = YES;
    [controller.view addSubview:gCursorView];
    VZHUDView *hud = [[[VZHUDView alloc] initWithTarget:controller] autorelease];
    gHUDView = hud;
    hud.hidden = YES;
    [controller.view addSubview:hud];
    [controller updateHUDPosition];
    if (gStatusLabel)
        [controller.view bringSubviewToFront:gStatusLabel];

    [self.window makeKeyAndVisible];
    UIApplicationShortcutIcon *libraryIcon = [UIApplicationShortcutIcon
        iconWithSystemImageName:@"square.grid.2x2"];
    UIApplicationShortcutIcon *controlsIcon = [UIApplicationShortcutIcon
        iconWithSystemImageName:@"slider.horizontal.3"];
    application.shortcutItems = @[[[[UIApplicationShortcutItem alloc]
        initWithType:@"com.mac.virtual.show-library"
        localizedTitle:VZL(@"Show Library") localizedSubtitle:nil
        icon:libraryIcon userInfo:nil] autorelease],
        [[[UIApplicationShortcutItem alloc]
        initWithType:@"com.mac.virtual.show-controls"
        localizedTitle:VZL(@"Show Virtual Mac Controls") localizedSubtitle:nil
        icon:controlsIcon userInfo:nil] autorelease]];
    unlink("/tmp/virtual-mac-vm-active");
    gMouseLocation = CGPointMake(CGRectGetMidX(inputView.bounds),
                                 CGRectGetMidY(inputView.bounds));
    installGCMouse();
    startHealthMonitor();
    startControlMonitor();
    printf("[VirtualMac] VM picker ready inputWindow=%p\n", inputView.window);
    requestMicrophoneAccess(^{
        NSString *controlPath = @"/tmp/vz-autoboot-path";
        NSString *autoBootPath = [NSString
            stringWithContentsOfFile:controlPath
                           encoding:NSUTF8StringEncoding error:nil];
        autoBootPath = [autoBootPath
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *persistentAutoBoot = [VZAppSettings.sharedSettings
            stringForKey:VZAutoBootVMPathKey];
        if (persistentAutoBoot.length && !VZIsValidVMBundle(persistentAutoBoot)) {
            NSString *identifier = [VZAppSettings.sharedSettings
                stringForKey:VZAutoBootVMIdentifierKey];
            persistentAutoBoot = nil;
            for (NSDictionary *machine in VZDiscoverVirtualMachines()) {
                if (identifier.length && [VZVMStableIdentifier(machine[@"path"])
                        isEqualToString:identifier]) {
                    persistentAutoBoot = machine[@"path"];
                    [VZAppSettings.sharedSettings setString:persistentAutoBoot
                        forKey:VZAutoBootVMPathKey];
                    break;
                }
            }
            if (!persistentAutoBoot) {
                printf("[VirtualMac] clearing missing auto boot VM\n");
                [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMPathKey];
                [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMIdentifierKey];
            }
        }
        if (!autoBootPath.length && !bypassAutoBoot)
            autoBootPath = persistentAutoBoot;
        if (autoBootPath.length && VZIsValidVMBundle(autoBootPath)) {
            unlink(controlPath.fileSystemRepresentation);
            [NSUserDefaults.standardUserDefaults setObject:autoBootPath
                                                    forKey:@"VZSelectedVMPath"];
            printf("[VirtualMac] one-shot auto boot path=%s\n",
                   autoBootPath.UTF8String);
            controller.activeVMBundlePath = autoBootPath;
            [controller activateVMDisplay:YES];
            startVirtualMachine(controller.view, controller, autoBootPath,
                                VZVMOptionsForBundle(autoBootPath));
        } else {
            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:controlPath]) {
                printf("[VirtualMac] rejected one-shot auto boot path=%s\n",
                       autoBootPath.UTF8String ?: "(unreadable)");
                unlink(controlPath.fileSystemRepresentation);
            }
            [controller presentVMLibrary];
            // Reproducible on-device integration path: a root-side test script
            // can request one real UIKit installation after launching the app.
            // The normal library, visible progress alert, polling timer, and
            // completion handling are all used; this is not a headless helper.
            NSString *requestPath = [VZVMSupportPath()
                stringByAppendingPathComponent:@".visible-install-request"];
            NSString *request = [NSString
                stringWithContentsOfFile:requestPath
                               encoding:NSUTF8StringEncoding error:nil];
            NSArray *lines = [request componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            NSString *installName = lines.count > 0 ? lines[0] : @"";
            NSString *installPath = lines.count > 1 ? lines[1] : @"";
            BOOL validRequest = installName.length && installPath.length &&
                [installName rangeOfString:@"/"].location == NSNotFound &&
                [installPath hasPrefix:[VZRestoreImagesPath()
                    stringByAppendingString:@"/"]] &&
                [NSFileManager.defaultManager fileExistsAtPath:installPath];
            if (request.length) {
                unlink(requestPath.fileSystemRepresentation);
                if (validRequest) {
                    printf("[VirtualMac] visible installation request name=%s ipsw=%s\n",
                           installName.UTF8String, installPath.UTF8String);
                    NSMutableDictionary *options = [NSMutableDictionary
                        dictionaryWithDictionary:VZVMDefaultOptions()];
                    if (VZRestoreImageUsesMontereyProfile(installPath)) {
                        options[@"KeyboardDevice"] = @"USBKeyboard";
                        options[@"PointingDevice"] = @"USBMouse";
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(0.75 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            VZVMLibraryViewController *library = (id)
                                controller.libraryNavigationController
                                    .viewControllers.firstObject;
                            [controller vmLibrary:library
                                installRestoreImageAtURL:
                                    [NSURL fileURLWithPath:installPath]
                                name:installName options:options];
                        });
                } else {
                    printf("[VirtualMac] rejected visible installation request=%s\n",
                           request.UTF8String);
                }
            }
        }
    });
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    (void)application;
    resetPointerSession(YES);
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    (void)application;
    resetPointerSession(YES);
    recoverNetworkingAfterResume();
    if (gInputView) {
        for (id interaction in gInputView.interactions)
            if ([interaction respondsToSelector:@selector(invalidate)])
                [interaction invalidate];
        VZViewController *controller = (id)self.window.rootViewController;
        if (controller.isVMDisplayActive && GCKeyboard.coalescedKeyboard)
            [gInputView becomeFirstResponder];
    }
}

- (void)application:(UIApplication *)application
    performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem
    completionHandler:(void (^)(BOOL succeeded))completionHandler
{
    (void)application;
    VZViewController *controller = (id)self.window.rootViewController;
    BOOL handled = [shortcutItem.type isEqualToString:@"com.mac.virtual.show-library"] ||
        [shortcutItem.type isEqualToString:@"com.mac.virtual.show-controls"];
    if ([shortcutItem.type isEqualToString:@"com.mac.virtual.show-library"]) {
        [controller presentVMLibrary];
    } else if ([shortcutItem.type isEqualToString:@"com.mac.virtual.show-controls"]) {
        gHUDHiddenForBoot = NO;
        gHUDForcedVisibleForBoot = YES;
        [controller updateHUDVisibility];
    }
    if (completionHandler) completionHandler(handled);
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
             options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    (void)application; (void)options;
    if (![url.scheme isEqualToString:@"virtualmac"]) return NO;
    NSString *action = url.host.lowercaseString;
    // Developer-only visible UI checks for the touch keyboard. Keep these
    // outside libraryController so exercising them does not hide the running
    // virtual Mac first.
    if ([action isEqualToString:@"keyboard-show"]) {
        gSoftwareKeyboardRequested = YES;
        return gInputView && [gInputView becomeFirstResponder];
    }
    if ([action isEqualToString:@"keyboard-hide"]) {
        gSoftwareKeyboardRequested = NO;
        return gInputView && [gInputView resignFirstResponder];
    }
    VZVMLibraryViewController *library = [self libraryController];
    if ([action isEqualToString:@"new"])
        [library presentNewVMFlow];
    else if ([action isEqualToString:@"settings"])
        [library presentSettings];
    else if ([action isEqualToString:@"library"])
        ;
    else
        return NO;
    return YES;
}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv,
                                 nil,
                                 NSStringFromClass([VirtualMacAppDelegate class]));
    }
}

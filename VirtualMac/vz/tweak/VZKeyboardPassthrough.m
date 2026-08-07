#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

static IMP gOriginalKeyCommands;
static IMP gOriginalApplicationKeyCommands;
static IMP gOriginalHandleKeyHIDEvent;
static IMP gOriginalHandleKeyUIEvent;
static IMP gOriginalShouldEnableSystemGesture;
static IMP gOriginalShouldEnableSystemGesturePrivate;
static IMP gOriginalFluidGestureShouldBegin;
static IMP gOriginalFluidGestureShouldReceiveTouch;
static BOOL gCommandIsDown;
static uint64_t gRelayingShortcutUsages;
static const char *gTargetBundleID = "com.mac.virtual";
static const char *gOpenAfterRespring =
    "/tmp/virtual-mac-open-after-respring";
static const char *gVMActiveMarker = "/tmp/virtual-mac-vm-active";
static NSString * const gSettingsPath = @"/var/mobile/Media/VirtualMac/Settings.plist";
static NSDictionary *gSettings;

static BOOL VZSettingEnabled(NSString *key)
{
    id value = gSettings[key];
    return value ? [value boolValue] : YES;
}

static void VZReloadSettings(void)
{
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:gSettingsPath];
    [gSettings release];
    gSettings = [[settings isKindOfClass:NSDictionary.class] ? settings : @{} retain];
}

static void VZSettingsChanged(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    VZReloadSettings();
}

// IOHIDEventTypeKeyboard is 3. Keyboard fields occupy its 0x30000 field
// namespace: usage page, usage, down, and repeat, in that order. These SPI
// constants are stable across the iPadOS releases supported by this project,
// but are kept local so the tweak builds with an unmodified public SDK.
enum {
    VZHIDKeyboardUsagePageField = 0x30000,
    VZHIDKeyboardUsageField = 0x30001,
    VZHIDKeyboardDownField = 0x30002,
};

typedef int64_t (*VZIOHIDEventGetIntegerValue)(CFTypeRef, uint32_t);

static void Log(const char *message)
{
    FILE *file = fopen("/tmp/vz-springboard-shortcuts.log", "a");
    if (!file)
        return;
    fprintf(file, "%s\n", message);
    fclose(file);
}

static BOOL VirtualMacIsFrontmost(id springBoard)
{
    SEL frontSelector = sel_registerName("_accessibilityFrontMostApplication");
    if (![springBoard respondsToSelector:frontSelector])
        return NO;
    id application = ((id (*)(id, SEL))objc_msgSend)(
        springBoard, frontSelector);
    SEL bundleSelector = sel_registerName("bundleIdentifier");
    if (![application respondsToSelector:bundleSelector])
        return NO;
    NSString *bundleIdentifier = ((id (*)(id, SEL))objc_msgSend)(
        application, bundleSelector);
    return [bundleIdentifier isEqualToString:
        [NSString stringWithUTF8String:gTargetBundleID]];
}

static BOOL VirtualMacVMIsActive(id springBoard)
{
    return access(gVMActiveMarker, F_OK) == 0 &&
        VirtualMacIsFrontmost(springBoard);
}

static BOOL VZSharedApplicationIsTarget(void)
{
    id application = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
    return application && VirtualMacVMIsActive(application);
}

static BOOL VZShouldEnableSystemGesture(id self, SEL selector,
                                        unsigned long long type)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"SystemGestureSuppression")) {
        static unsigned long count;
        if (count++ < 12)
            Log("suppressed an iPadOS system gesture for frontmost Virtual Mac");
        return NO;
    }
    IMP original = selector == sel_registerName("_shouldEnableSystemGestureWithType:")
        ? gOriginalShouldEnableSystemGesturePrivate
        : gOriginalShouldEnableSystemGesture;
    return ((BOOL (*)(id, SEL, unsigned long long))original)(
        self, selector, type);
}

static BOOL VZFluidGestureShouldBegin(id self, SEL selector, id recognizer)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"MultitaskingGestureSuppression")) {
        static unsigned long count;
        if (count++ < 12)
            Log("suppressed a fluid multitasking gesture for active VM display");
        return NO;
    }
    return ((BOOL (*)(id, SEL, id))gOriginalFluidGestureShouldBegin)(
        self, selector, recognizer);
}

static BOOL VZFluidGestureShouldReceiveTouch(id self, SEL selector,
                                              id recognizer, id touch)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"MultitaskingGestureSuppression"))
        return NO;
    return ((BOOL (*)(id, SEL, id, id))
        gOriginalFluidGestureShouldReceiveTouch)(
            self, selector, recognizer, touch);
}

static id VZKeyCommands(id self, SEL selector)
{
    if (VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        static unsigned long count;
        if (count++ < 8)
            Log("suppressed SpringBoard key commands for Virtual Mac");
        // Returning no system-shell UIKeyCommands lets the foreground app's
        // pressesBegan:/pressesEnded: path receive Command-Q, Command-Space,
        // Command-Tab, screenshot chords, and the other Mac guest shortcuts.
        return @[];
    }
    return ((id (*)(id, SEL))gOriginalKeyCommands)(self, selector);
}

static id VZApplicationKeyCommands(id self, SEL selector)
{
    if (VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        static unsigned long count;
        if (count++ < 8)
            Log("suppressed UIApplication system-shell key commands for Virtual Mac");
        // SpringBoard's implementation calls this superclass method, but
        // UIKit can also query the UISystemShellApplication/UIApplication
        // layer directly. Command-Space is registered in that superclass
        // path on iPadOS 16, unlike Command-Q and the screenshot commands
        // that SpringBoard itself contributes.
        return @[];
    }
    return ((id (*)(id, SEL))gOriginalApplicationKeyCommands)(self, selector);
}

static void VZPostCommandShortcut(int64_t usage, BOOL pressed)
{
    NSString *shortcut = usage == 0x2c ? @"command-space"
        : usage == 0x2b ? @"command-tab" : @"command-grave";
    NSString *name = [NSString stringWithFormat:
        @"com.mac.virtual.%@.%@", shortcut,
        pressed ? @"down" : @"up"];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)name, NULL, NULL, YES);
    Log(pressed ? "relayed consumed Command shortcut down to Virtual Mac"
                : "relayed consumed Command shortcut up to Virtual Mac");
}

static void VZPostShortcut(const char *name, BOOL pressed)
{
    NSString *notification = [NSString stringWithFormat:
        @"com.mac.virtual.%s.%@", name, pressed ? @"down" : @"up"];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)notification, NULL, NULL, YES);
    char buffer[128];
    snprintf(buffer, sizeof(buffer),
             "relayed %s %s to Virtual Mac", name, pressed ? "down" : "up");
    Log(buffer);
}

static BOOL VZIsGlobeUsage(int64_t usagePage, int64_t usage)
{
    // The globe/Fn key is an Apple vendor usage (AppleVendorTopCase page
    // 0xFF01 / 0xFF00 / 0xFF, usage 0x03). iPadOS may map it to a different
    // page. Be permissive: any non-keyboard page with usage 0x03 is almost
    // certainly the globe key. Also check Consumer page (0x0C) keyboard-layout
    // keys; 0x29D is what iPadOS keyboards actually send for the 🌐 key,
    // confirmed on-device.
    if (usage == 0x03 && usagePage != 0x07)
        return YES;
    if (usagePage == 0x0c)
        return usage == 0x22d || usage == 0x18a || usage == 0x29d;
    return NO;
}

static void VZHandleKeyHIDEvent(id self, SEL selector, CFTypeRef event)
{
    static VZIOHIDEventGetIntegerValue getIntegerValue;
    if (!getIntegerValue) {
        getIntegerValue = (VZIOHIDEventGetIntegerValue)dlsym(
            RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    }

    if (getIntegerValue && VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        int64_t usagePage = getIntegerValue(
            event, VZHIDKeyboardUsagePageField);
        int64_t usage = getIntegerValue(event, VZHIDKeyboardUsageField);
        BOOL pressed = getIntegerValue(event, VZHIDKeyboardDownField) != 0;
        if (usagePage == 0x07 && (usage == 0xe3 || usage == 0xe7)) {
            gCommandIsDown = pressed;
        } else if (VZIsGlobeUsage(usagePage, usage)) {
            // The globe/Fn key is a system key (input-source switching) that
            // iPadOS would otherwise consume. Relay it so the VM app can map
            // it to Fn, and swallow it so it never reaches the system's
            // input-method switcher.
            VZPostShortcut("globe", pressed);
            return;
        } else if (usagePage == 0x07 &&
                   (usage == 0x2c || usage == 0x2b || usage == 0x35)) {
            uint64_t bit = 1ULL << (usage & 63);
            if (gCommandIsDown || (gRelayingShortcutUsages & bit)) {
                // These three shell shortcuts are consumed below UIKit on
                // iPadOS. Relay only the non-modifier key; the physical
                // Command key already reaches the foreground VM app.
                if (pressed)
                    gRelayingShortcutUsages |= bit;
                else
                    gRelayingShortcutUsages &= ~bit;
                VZPostCommandShortcut(usage, pressed);
                return;
            }
        }
    }

    ((void (*)(id, SEL, CFTypeRef))gOriginalHandleKeyHIDEvent)(
        self, selector, event);
}

// The globe key also reaches UIKit's event layer, where iPadOS presents the
// input-method switcher. handleKeyHIDEvent: swallowing the raw HID event is
// not enough — the switcher still pops. Swallow the globe here too so the
// guest receives only the Darwin relay (Fn), never the system popup.
static void VZHandleKeyUIEvent(id self, SEL selector, id event)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        SEL hidEventSel = sel_registerName("_hidEvent");
        id hidEvent = nil;
        if ([event respondsToSelector:hidEventSel])
            hidEvent = ((id (*)(id, SEL))objc_msgSend)(event, hidEventSel);
        if (hidEvent) {
            static VZIOHIDEventGetIntegerValue getIntegerValue;
            if (!getIntegerValue)
                getIntegerValue = (VZIOHIDEventGetIntegerValue)dlsym(
                    RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
            if (getIntegerValue) {
                int64_t usagePage = getIntegerValue(
                    (CFTypeRef)hidEvent, VZHIDKeyboardUsagePageField);
                int64_t usage = getIntegerValue(
                    (CFTypeRef)hidEvent, VZHIDKeyboardUsageField);
                if (VZIsGlobeUsage(usagePage, usage)) {
                    static unsigned char logged;
                    if (!logged) {
                        Log("swallowed globe in _handleKeyUIEvent:");
                        logged = 1;
                    }
                    return;
                }
            }
        }
    }
    ((void (*)(id, SEL, id))gOriginalHandleKeyUIEvent)(
        self, selector, event);
}

static void VZScheduleOneShotOpen(void)
{
    if (access(gOpenAfterRespring, F_OK) != 0)
        return;
    Log("scheduled one-shot unlock and Virtual Mac launch");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        // sbreload can briefly start more than one SpringBoard process. Leave
        // the sentinel present until a process survives the delay, then let
        // exactly one winner consume it.
        if (unlink(gOpenAfterRespring) != 0)
            return;
        Class managerClass = objc_getClass("SBLockScreenManager");
        id manager = ((id (*)(id, SEL))objc_msgSend)(
            managerClass, sel_registerName("sharedInstance"));
        BOOL locked = manager && ((BOOL (*)(id, SEL))objc_msgSend)(
            manager, sel_registerName("isUILocked"));
        BOOL unlocked = YES;
        if (locked) {
            unlocked = ((BOOL (*)(id, SEL, int, id))objc_msgSend)(
                manager, sel_registerName("unlockUIFromSource:withOptions:"),
                17, nil);
        }

        id springBoard = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("UIApplication"),
            sel_registerName("sharedApplication"));
        BOOL launched = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(
            springBoard,
            sel_registerName("launchApplicationWithIdentifier:suspended:"),
            [NSString stringWithUTF8String:gTargetBundleID], NO);
        char message[160];
        snprintf(message, sizeof(message),
                 "one-shot open locked=%d unlocked=%d launched=%d",
                 locked, unlocked, launched);
        Log(message);
    });
}

__attribute__((constructor))
static void VZInstallKeyboardPassthrough(void)
{
    VZReloadSettings();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        VZSettingsChanged, CFSTR("com.mac.virtual.settings-changed"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    Class springBoard = objc_getClass("SpringBoard");
    VZScheduleOneShotOpen();
    Method method = class_getInstanceMethod(
        springBoard, sel_registerName("keyCommands"));
    if (!method) {
        Log("SpringBoard keyCommands method unavailable");
        return;
    }
    gOriginalKeyCommands = method_setImplementation(
        method, (IMP)VZKeyCommands);

    Method hidMethod = class_getInstanceMethod(
        springBoard, sel_registerName("handleKeyHIDEvent:"));
    if (hidMethod) {
        gOriginalHandleKeyHIDEvent = method_setImplementation(
            hidMethod, (IMP)VZHandleKeyHIDEvent);
        Log("installed raw HID Command-Space relay");
    } else {
        Log("SpringBoard handleKeyHIDEvent: unavailable");
    }

    Class application = objc_getClass("UIApplication");
    Method applicationMethod = class_getInstanceMethod(
        application, sel_registerName("keyCommands"));
    if (applicationMethod) {
        gOriginalApplicationKeyCommands = method_setImplementation(
            applicationMethod, (IMP)VZApplicationKeyCommands);
        Log("installed Virtual Mac SpringBoard and UIApplication key-command passthrough");
    } else {
        Log("UIApplication keyCommands method unavailable");
        Log("installed Virtual Mac SpringBoard key-command passthrough");
    }


    Class gestureManager = objc_getClass("SBSystemGestureManager");
    Method gestureMethod = class_getInstanceMethod(
        gestureManager, sel_registerName("shouldEnableSystemGestureWithType:"));
    if (gestureMethod) {
        gOriginalShouldEnableSystemGesture = method_setImplementation(
            gestureMethod, (IMP)VZShouldEnableSystemGesture);
    }
    Method privateGestureMethod = class_getInstanceMethod(
        gestureManager, sel_registerName("_shouldEnableSystemGestureWithType:"));
    if (privateGestureMethod) {
        gOriginalShouldEnableSystemGesturePrivate = method_setImplementation(
            privateGestureMethod, (IMP)VZShouldEnableSystemGesture);
    }
    Log("installed frontmost-only iPadOS system-gesture suppression");

    Class fluidManager = objc_getClass("SBFluidSwitcherGestureManager");
    Method fluidBeginMethod = class_getInstanceMethod(
        fluidManager, sel_registerName("gestureRecognizerShouldBegin:"));
    if (fluidBeginMethod)
        gOriginalFluidGestureShouldBegin = method_setImplementation(
            fluidBeginMethod, (IMP)VZFluidGestureShouldBegin);
    Method fluidTouchMethod = class_getInstanceMethod(
        fluidManager,
        sel_registerName("gestureRecognizer:shouldReceiveTouch:"));
    if (fluidTouchMethod)
        gOriginalFluidGestureShouldReceiveTouch = method_setImplementation(
            fluidTouchMethod, (IMP)VZFluidGestureShouldReceiveTouch);
    Log("installed active-VM fluid multitasking-gesture suppression");

    // Swallow the globe key at the UIKit event layer to suppress the
    // input-method switcher popup that handleKeyHIDEvent: can't stop.
    Method keyUIEventMethod = class_getInstanceMethod(
        application, sel_registerName("_handleKeyUIEvent:"));
    if (keyUIEventMethod) {
        gOriginalHandleKeyUIEvent = method_setImplementation(
            keyUIEventMethod, (IMP)VZHandleKeyUIEvent);
        Log("installed _handleKeyUIEvent: globe input-method suppression");
    } else {
        Log("UIApplication _handleKeyUIEvent: unavailable");
    }

}

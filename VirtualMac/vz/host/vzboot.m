// Headless iPad host for the extracted Virtualization stack. Mirrors the macOS sample's
// MacOSVirtualMachineConfigurationHelper config (boot loader, block device, graphics,
// trackpad, keyboard) built against the guest bundle copied from the Mac host, but:
//  - loads the 3 extracted frameworks via dlopen (they aren't linkable: custom layout +
//    stale export trie), so VZ classes are reached through objc_getClass + objc_msgSend;
//  - drops the NAT network device (vmnet is absent on iOS);
//  - no AppKit VZVirtualMachineView (iOS) -> headless: validate + start, report via the
//    completion handler + a state observer. Rendering (PVG -> CAMetalLayer) comes next.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <string.h>

static id CLS(const char *n) { return (id)objc_getClass(n); }
static SEL S(const char *n)  { return sel_registerName(n); }
static id m0(id o, const char *sel) { return ((id(*)(id, SEL))objc_msgSend)(o, S(sel)); }
static id m1(id o, const char *sel, id a) { return ((id(*)(id, SEL, id))objc_msgSend)(o, S(sel), a); }
static id NEW(const char *c) { return m0(m0(CLS(c), "alloc"), "init"); }
static void setObj(id o, const char *sel, id a) { ((void(*)(id, SEL, id))objc_msgSend)(o, S(sel), a); }
static NSURL *fileURL(NSString *p) { return [NSURL fileURLWithPath:p]; }
static BOOL envEnabled(const char *name) {
    const char *value = getenv(name);
    return value && value[0] && strcmp(value, "0") != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        // args: [framework.dylib ...] <VM.bundle>. Frameworks loaded in dependency order; on the
        // matching VM only Virtualization is needed (system Hypervisor/PVG resolve via its deps).
        NSString *B = @"/var/root/VM.bundle";
        if (argc > 1) {
            B = [NSString stringWithUTF8String:argv[argc - 1]];
            for (int i = 1; i < argc - 1; i++)
                if (!dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL)) { printf("dlopen %s FAIL: %s\n", argv[i], dlerror()); return 1; }
        } else {
            const char *fw[] = {"/var/root/Hypervisor.ios", "/var/root/ParavirtualizedGraphics.ios", "/var/root/Virtualization.ios"};
            for (int i = 0; i < 3; i++)
                if (!dlopen(fw[i], RTLD_NOW | RTLD_GLOBAL)) { printf("dlopen %s FAIL: %s\n", fw[i], dlerror()); return 1; }
        }

        // ---- platform (from the guest bundle) ----
        id platform = NEW("VZMacPlatformConfiguration");
        id aux = ((id(*)(id, SEL, id))objc_msgSend)(m0(CLS("VZMacAuxiliaryStorage"), "alloc"),
                 S("initWithContentsOfURL:"), fileURL([B stringByAppendingPathComponent:@"AuxiliaryStorage"]));
        setObj(platform, "setAuxiliaryStorage:", aux);
        NSData *hmData = [NSData dataWithContentsOfFile:[B stringByAppendingPathComponent:@"HardwareModel"]];
        id hwModel = ((id(*)(id, SEL, id))objc_msgSend)(m0(CLS("VZMacHardwareModel"), "alloc"),
                     S("initWithDataRepresentation:"), hmData);
        printf("hardwareModel: %p supported=%d\n", (void *)hwModel,
               ((BOOL(*)(id, SEL))objc_msgSend)(hwModel, S("isSupported")));
        setObj(platform, "setHardwareModel:", hwModel);
        NSData *midData = [NSData dataWithContentsOfFile:[B stringByAppendingPathComponent:@"MachineIdentifier"]];
        id mid = ((id(*)(id, SEL, id))objc_msgSend)(m0(CLS("VZMacMachineIdentifier"), "alloc"),
                 S("initWithDataRepresentation:"), midData);
        setObj(platform, "setMachineIdentifier:", mid);

        // ---- machine config ----
        id config = NEW("VZVirtualMachineConfiguration");
        setObj(config, "setPlatform:", platform);
        ((void(*)(id, SEL, NSUInteger))objc_msgSend)(config, S("setCPUCount:"), 2);
        ((void(*)(id, SEL, unsigned long long))objc_msgSend)(config, S("setMemorySize:"), 4ULL << 30);
        setObj(config, "setBootLoader:", NEW("VZMacOSBootLoader"));

        if (!envEnabled("VZ_NO_GRAPHICS")) {
            id gfx = NEW("VZMacGraphicsDeviceConfiguration");
            id disp = ((id(*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
                      m0(CLS("VZMacGraphicsDisplayConfiguration"), "alloc"),
                      S("initWithWidthInPixels:heightInPixels:pixelsPerInch:"), 1920, 1200, 80);
            setObj(gfx, "setDisplays:", @[disp]);
            setObj(config, "setGraphicsDevices:", @[gfx]);
            printf("graphics=%p display=%p\n", (void *)gfx, (void *)disp);
        } else {
            printf("graphics: SKIPPED\n");
        }

        NSError *err = nil;
        if (!envEnabled("VZ_NO_STORAGE")) { // skippable to isolate startup paths
            printf("platform+config props+graphics done; creating disk attachment...\n");
            id diskAtt = ((id(*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                         m0(CLS("VZDiskImageStorageDeviceAttachment"), "alloc"),
                         S("initWithURL:readOnly:error:"), fileURL([B stringByAppendingPathComponent:@"Disk.img"]), NO, &err);
            if (!diskAtt) { printf("disk attach FAIL: %s\n", [[err localizedDescription] UTF8String]); return 1; }
            id block = ((id(*)(id, SEL, id))objc_msgSend)(m0(CLS("VZVirtioBlockDeviceConfiguration"), "alloc"),
                       S("initWithAttachment:"), diskAtt);
            setObj(config, "setStorageDevices:", @[block]);
            printf("storage set; keyboard/pointing...\n");
        } else printf("storage: SKIPPED\n");

        // 13.2.1 uses the USB input devices (VZMac{Keyboard,Trackpad} are macOS 14+); guard nil.
        if (!envEnabled("VZ_NO_INPUT")) {
            id kbd = NEW("VZUSBKeyboardConfiguration");
            if (kbd) setObj(config, "setKeyboards:", @[kbd]);
            id pdev = NEW("VZUSBScreenCoordinatePointingDeviceConfiguration");
            if (pdev) setObj(config, "setPointingDevices:", @[pdev]);
            printf("keyboard=%p pointing=%p\n", (void *)kbd, (void *)pdev);
        } else {
            printf("input: SKIPPED\n");
        }

        // ---- validate (skippable: the config is built from a known-good bundle, and VZ's
        // validator exercises deep C++ filesystem-path code that hits extraction edge cases) ----
        if (!envEnabled("VZ_SKIP_VALIDATE")) {
            BOOL ok = ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(config, S("validateWithError:"), &err);
            printf("validateWithError: ok=%d%s\n", ok, ok ? "" : [[NSString stringWithFormat:@" -- %@", [err localizedDescription]] UTF8String]);
            if (!ok) return 1;
        } else printf("validate: SKIPPED\n");

        // ---- create + start (on the VM's queue = main) ----
        id vm = ((id(*)(id, SEL, id))objc_msgSend)(m0(CLS("VZVirtualMachine"), "alloc"),
                S("initWithConfiguration:"), config);
        printf("VZVirtualMachine = %p; starting...\n", (void *)vm);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^done)(NSError *) = ^(NSError *e) {
                if (e) {
                    printf("VM start FAILED: %s\n",
                           [[e localizedDescription] UTF8String]);
                    exit(1);
                } else {
                    printf("VM STARTED (state=%ld)\n",
                           (long)((NSInteger(*)(id, SEL))objc_msgSend)(
                               vm, S("state")));
                }
            };
            ((void(*)(id, SEL, id))objc_msgSend)(vm, S("startWithCompletionHandler:"), done);
        });
        // Poll state long enough to observe a real boot. Override for bounded
        // smoke tests without recompiling.
        const char *runSecondsValue = getenv("VZ_RUN_SECONDS");
        int runSeconds = runSecondsValue ? atoi(runSecondsValue) : 600;
        if (runSeconds < 1) runSeconds = 1;
        for (int t = 0; t < runSeconds; t++) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            if (t % 5 == 4) printf("  [t=%ds] VM state=%ld\n", t + 1,
                                   (long)((NSInteger(*)(id, SEL))objc_msgSend)(vm, S("state")));
        }

        // Tear down through Virtualization so PVG queues and IOSurfaces are drained
        // before the short-lived SSH test host exits.
        NSInteger state =
            ((NSInteger(*)(id, SEL))objc_msgSend)(vm, S("state"));
        if (state == 1 || state == 2) {
            __block BOOL stopDone = NO;
            void (^stopped)(NSError *) = ^(NSError *e) {
                printf("VM stop: %s\n",
                       e ? [[e localizedDescription] UTF8String] : "complete");
                stopDone = YES;
            };
            ((void(*)(id, SEL, id))objc_msgSend)(
                vm, S("stopWithCompletionHandler:"), stopped);
            for (int t = 0; t < 15 && !stopDone; t++)
                [[NSRunLoop mainRunLoop]
                    runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        }
    }
    return 0;
}

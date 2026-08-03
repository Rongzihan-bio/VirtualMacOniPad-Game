// Diagnostic: replicate vzboot's exact config-build sequence step by step with per-step
// logging, to find which step turns subsequent VZMac* inits nil (vzboot crashes at @[disp]
// with supported=0, yet these inits work in isolation). Also verifies the protoref fix lets
// VZVirtualMachine init run past the old conformsToProtocol: crash.
#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#import <Foundation/Foundation.h>

static id CLS(const char *n) { return (id)objc_getClass(n); }
static id msg(id s, const char *sel) { return ((id(*)(id, SEL))objc_msgSend)(s, sel_registerName(sel)); }
static id alloc(const char *n) { return msg(CLS(n), "alloc"); }
static id NEW(const char *n) { return msg(alloc(n), "init"); }
static void setObj(id o, const char *sel, id v) { ((void(*)(id, SEL, id))objc_msgSend)(o, sel_registerName(sel), v); }
static id initData(const char *cls, NSData *d) {
    return ((id(*)(id, SEL, id))objc_msgSend)(alloc(cls), sel_registerName("initWithDataRepresentation:"), d);
}
static id fileURL(NSString *p) { return [NSURL fileURLWithPath:p]; }

#define B @"/var/root/VM.bundle"
#define P(name, val) printf("%-34s = %p\n", name, (void *)(val))

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *fw[] = {"/var/root/Hypervisor.ios", "/var/root/ParavirtualizedGraphics.ios", "/var/root/Virtualization.ios"};
    for (int i = 0; i < 3; i++)
        if (!dlopen(fw[i], RTLD_NOW | RTLD_GLOBAL)) { printf("dlopen %s FAIL: %s\n", fw[i], dlerror()); return 1; }
    printf("frameworks loaded; +[VZVirtualMachine isSupported]=%d\n",
           ((BOOL(*)(id, SEL))objc_msgSend)(CLS("VZVirtualMachine"), sel_registerName("isSupported")));

    id platform = NEW("VZMacPlatformConfiguration");                            P("platform", platform);
    id aux = ((id(*)(id, SEL, id))objc_msgSend)(alloc("VZMacAuxiliaryStorage"),
             sel_registerName("initWithContentsOfURL:"), fileURL([B stringByAppendingPathComponent:@"AuxiliaryStorage"]));
    P("aux (VZMacAuxiliaryStorage)", aux);
    setObj(platform, "setAuxiliaryStorage:", aux);

    NSData *hmData = [NSData dataWithContentsOfFile:[B stringByAppendingPathComponent:@"HardwareModel"]];
    id hwModel = initData("VZMacHardwareModel", hmData);
    printf("hwModel=%p supported=%d (hmData.len=%lu)\n", (void *)hwModel,
           hwModel ? ((BOOL(*)(id, SEL))objc_msgSend)(hwModel, sel_registerName("isSupported")) : 0,
           (unsigned long)hmData.length);
    setObj(platform, "setHardwareModel:", hwModel);
    id mid = initData("VZMacMachineIdentifier", [NSData dataWithContentsOfFile:[B stringByAppendingPathComponent:@"MachineIdentifier"]]);
    P("machineIdentifier", mid);
    setObj(platform, "setMachineIdentifier:", mid);

    id config = NEW("VZVirtualMachineConfiguration");                           P("config", config);
    setObj(config, "setPlatform:", platform);
    ((void(*)(id, SEL, NSUInteger))objc_msgSend)(config, sel_registerName("setCPUCount:"), 2);
    ((void(*)(id, SEL, unsigned long long))objc_msgSend)(config, sel_registerName("setMemorySize:"), 4ULL << 30);
    setObj(config, "setBootLoader:", NEW("VZMacOSBootLoader"));

    // VZ_NO_GFX=1 drops the graphics device so the VMM doesn't look up the
    // "com.apple.virtualization.avp.paravirtualized-graphics-gpu-arm" device-type
    // (which ParavirtualizedGraphics.ios doesn't register on iPad — see vz-start-progress
    // memo). Without gfx the guest boots headless; useful for proving the VM otherwise runs.
    if (!getenv("VZ_NO_GFX")) {
        id gfx = NEW("VZMacGraphicsDeviceConfiguration");                           P("gfx", gfx);
        id disp = ((id(*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(alloc("VZMacGraphicsDisplayConfiguration"),
                  sel_registerName("initWithWidthInPixels:heightInPixels:pixelsPerInch:"), 1920, 1200, 80);
        P("disp", disp);
        if (disp) setObj(gfx, "setDisplays:", @[disp]); else printf("  !! disp nil -> would crash @[disp]\n");
        if (gfx) setObj(config, "setGraphicsDevices:", @[gfx]);
    } else {
        printf(">>> VZ_NO_GFX=1 -> skipping VZMacGraphicsDeviceConfiguration (headless test)\n");
    }

    NSError *err = nil;
    id diskAtt = ((id(*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(alloc("VZDiskImageStorageDeviceAttachment"),
                 sel_registerName("initWithURL:readOnly:error:"), fileURL([B stringByAppendingPathComponent:@"Disk.img"]), NO, &err);
    P("diskAtt", diskAtt);
    if (diskAtt) {
        id block = ((id(*)(id, SEL, id))objc_msgSend)(alloc("VZVirtioBlockDeviceConfiguration"),
                   sel_registerName("initWithAttachment:"), diskAtt);
        setObj(config, "setStorageDevices:", @[block]);
    } else printf("  disk err: %s\n", [[err localizedDescription] UTF8String]);

    id kbd = NEW("VZUSBKeyboardConfiguration");   if (kbd) setObj(config, "setKeyboards:", @[kbd]);
    id pdev = NEW("VZUSBScreenCoordinatePointingDeviceConfiguration"); if (pdev) setObj(config, "setPointingDevices:", @[pdev]);
    P("kbd", kbd); P("pdev", pdev);

    printf(">>> validateWithError: (exercises config validation)...\n");
    NSError *verr = nil;
    BOOL ok = ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(config, sel_registerName("validateWithError:"), &verr);
    printf("    validate ok=%d%s\n", ok, ok ? "" : [[NSString stringWithFormat:@" -- %@", [verr localizedDescription]] UTF8String]);

    printf(">>> creating VZVirtualMachine with a real queue (exercises the protoref/conformsToProtocol path)...\n");
    dispatch_queue_t q = dispatch_queue_create("vm.q", DISPATCH_QUEUE_SERIAL);
    id vm = ((id(*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(alloc("VZVirtualMachine"),
            sel_registerName("initWithConfiguration:queue:"), config, q);
    P("VZVirtualMachine vm", vm);
    printf(">>> DONE (reached past VZVirtualMachine init — protoref/conformsToProtocol survived)\n");

    if (getenv("VZ_START")) {
        // [vm start] reaches the VMM via xpc_connection_create("com.apple.Virtualization.
        // VirtualMachine"); with DYLD_INSERT_LIBRARIES=vzxpchook.ios that's redirected to the
        // launchd MachService org.jb.vmmservice (the rebooted-in VMM daemon).
        __block BOOL canStart = NO;   // VZ asserts queue affinity: all vm methods must run on q
        dispatch_sync(q, ^{ canStart = ((BOOL(*)(id, SEL))objc_msgSend)(vm, sel_registerName("canStart")); });
        printf(">>> canStart=%d ; calling startWithCompletionHandler: on the VM queue...\n", canStart);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        void (^h)(id) = ^(id err) {
            if (err) {
                id d = ((id(*)(id, SEL))objc_msgSend)(err, sel_registerName("localizedDescription"));
                printf(">>> START COMPLETION: FAILED: %s\n", d ? [(NSString *)d UTF8String] : "(no description)");
            } else {
                printf(">>> START COMPLETION: SUCCESS — VM started\n");
            }
            dispatch_semaphore_signal(done);
        };
        dispatch_async(q, ^{
            ((void(*)(id, SEL, id))objc_msgSend)(vm, sel_registerName("startWithCompletionHandler:"), h);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)))
            printf(">>> start completion did NOT fire within 30s (hung in the VMM connection?)\n");
        dispatch_sync(q, ^{
            long st = ((long(*)(id, SEL))objc_msgSend)(vm, sel_registerName("state"));
            printf(">>> vm.state = %ld (0=stopped 1=running 2=paused 3=error 4=starting 7=stopping)\n", st);
        });
        printf(">>> letting the guest run for 15s...\n");
        sleep(15);
        dispatch_sync(q, ^{
            long st = ((long(*)(id, SEL))objc_msgSend)(vm, sel_registerName("state"));
            printf(">>> vm.state after 15s = %ld\n", st);
        });
    }
    return 0;
}

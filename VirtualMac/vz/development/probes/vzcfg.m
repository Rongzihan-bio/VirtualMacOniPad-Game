// Minimal VZ dispatch probe: chain-load, create config, check respondsToSelector for a
// spread of methods. With the extractor's selref pool + cleared fixed_up flag, objc should
// linear-search and resolve all of them.
#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

static id msg(id s, const char *sel) { return ((id(*)(id, SEL))objc_msgSend)(s, sel_registerName(sel)); }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 1; i < argc; i++) {
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL);
        if (!h) { printf("dlopen %s FAIL: %s\n", argv[i], dlerror()); return 1; }
        printf("loaded %s\n", argv[i]);
    }
    Class C = objc_getClass("VZVirtualMachineConfiguration");
    id cfg = msg(msg((id)C, "alloc"), "init");
    printf("config = %p\n", (void *)cfg);
    const char *sels[] = {"setCPUCount:", "CPUCount", "setMemorySize:", "memorySize",
                          "platform", "setPlatform:", "validateWithError:", "audioDevices", "keyboards"};
    int ok = 1;
    for (unsigned i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        BOOL r = ((BOOL(*)(id,SEL,SEL))objc_msgSend)(cfg, sel_registerName("respondsToSelector:"), sel_registerName(sels[i]));
        printf("  responds(%s)=%d\n", sels[i], r);
        if (!r) ok = 0;
    }
    printf(ok ? "ALL RESOLVE\n" : "some unresolved\n");

    // Exercise real method calls (not just respondsToSelector): set/get round-trip + validate.
    ((void(*)(id,SEL,unsigned long))objc_msgSend)(cfg, sel_registerName("setCPUCount:"), 2);
    unsigned long n = ((unsigned long(*)(id,SEL))objc_msgSend)(cfg, sel_registerName("CPUCount"));
    printf("setCPUCount:2 -> CPUCount=%lu %s\n", n, n == 2 ? "OK" : "MISMATCH");
    ((void(*)(id,SEL,unsigned long long))objc_msgSend)(cfg, sel_registerName("setMemorySize:"), 4ULL<<30);
    unsigned long long mem = ((unsigned long long(*)(id,SEL))objc_msgSend)(cfg, sel_registerName("memorySize"));
    printf("setMemorySize:4G -> memorySize=%llu\n", mem);
    // validateWithError: on an incomplete config should DISPATCH into VZ's validator and return
    // an NSError (not crash) -- proves real IMP execution through the framework's own logic.
    id err = nil;
    BOOL valid = ((BOOL(*)(id,SEL,id*))objc_msgSend)(cfg, sel_registerName("validateWithError:"), &err);
    printf("validateWithError: -> valid=%d, err=%p\n", valid, (void*)err);
    if (err) {
        id desc = ((id(*)(id,SEL))objc_msgSend)(err, sel_registerName("localizedDescription"));
        const char *s = ((const char*(*)(id,SEL))objc_msgSend)(desc, sel_registerName("UTF8String"));
        printf("  error: %s\n", s ? s : "(nil)");
    }
    printf("DISPATCH OK\n");
    return 0;
}

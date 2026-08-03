// Chain-dlopen harness: load several extracted+stamped frameworks in order, then
// probe ObjC class realization. Used to load our Hypervisor first (so dyld satisfies
// Virtualization's strong LC_LOAD_DYLIB by install-name match) then Virtualization.
#include <stdio.h>
#include <dlfcn.h>
extern void *objc_getClass(const char *);

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);   // unbuffered: survive a crash over ssh
    for (int i = 1; i < argc; i++) {
        printf("dlopen(%s)...\n", argv[i]);
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL);  // GLOBAL: later loads + flat binds see these symbols
        if (!h) { printf("  FAILED: %s\n", dlerror()); return 1; }
        printf("  OK handle=%p\n", h);
    }
    const char *cls[] = {
        "VZVirtualMachineConfiguration", "VZVirtualMachine",
        "VZMacOSBootLoader", "VZVirtioBlockDeviceConfiguration",
        "VZMacPlatformConfiguration", "VZMacGraphicsDeviceConfiguration",
    };
    for (int i = 0; i < (int)(sizeof(cls)/sizeof(cls[0])); i++)
        printf("class %-40s = %p\n", cls[i], objc_getClass(cls[i]));
    return 0;
}

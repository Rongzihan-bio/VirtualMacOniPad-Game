#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void print_uuid(const struct mach_header_64 *mh)
{
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)p;
            for (unsigned j = 0; j < sizeof(uc->uuid); j++) {
                printf("%02X", uc->uuid[j]);
                if (j == 3 || j == 5 || j == 7 || j == 9)
                    putchar('-');
            }
            return;
        }
        p += lc->cmdsize;
    }
    printf("none");
}

static void print_build_version(const struct mach_header_64 *mh)
{
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_BUILD_VERSION) {
            const struct build_version_command *bc =
                (const struct build_version_command *)p;
            printf("%u\t%u.%u.%u\t%u.%u.%u",
                   bc->platform,
                   bc->minos >> 16, (bc->minos >> 8) & 0xff, bc->minos & 0xff,
                   bc->sdk >> 16, (bc->sdk >> 8) & 0xff, bc->sdk & 0xff);
            return;
        }
        p += lc->cmdsize;
    }
    printf("none\tnone\tnone");
}

static int inspect(const char *label, const char *path, const char *symbol)
{
    dlerror();
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        printf("LOAD\t%s\tFAIL\t%s\n", label, dlerror());
        return 1;
    }

    void *address = dlsym(handle, symbol);
    if (!address) {
        printf("LOAD\t%s\tNOSYMBOL\t%s\n", label, symbol);
        return 1;
    }

    Dl_info info = {0};
    if (!dladdr(address, &info) || !info.dli_fbase) {
        printf("LOAD\t%s\tNODLADDR\t%s\n", label, symbol);
        return 1;
    }

    const struct mach_header_64 *mh =
        (const struct mach_header_64 *)info.dli_fbase;
    printf("IMAGE\t%s\t%s\t", label, info.dli_fname ?: "(unknown)");
    print_uuid(mh);
    putchar('\t');
    print_build_version(mh);
    printf("\t%s\t%p\n", symbol, address);
    return 0;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    int failures = 0;
    failures += inspect(
        "Hypervisor",
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "hv_vm_create");
    failures += inspect(
        "ParavirtualizedGraphics",
        "/System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics",
        "PGNewDeviceWithDescriptor");
    failures += inspect(
        "Virtualization",
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Virtualization",
        "VZErrorDomain");

    Class vm = objc_getClass("VZVirtualMachine");
    BOOL supported = NO;
    if (vm != Nil) {
        SEL sel = sel_registerName("isSupported");
        supported = ((BOOL (*)(id, SEL))objc_msgSend)((id)vm, sel);
    }
    printf("VZ\tclass=%p\tisSupported=%d\n", vm, supported);
    return failures ? 1 : 0;
}


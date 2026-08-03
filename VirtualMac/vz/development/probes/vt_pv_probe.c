#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

static void report_symbol(void *image, const char *name) {
    void *symbol = dlsym(image, name);
    printf("SYMBOL\t%s\t%p\n", name, symbol);
}

int main(int argc, char **argv) {
    const char *videoToolbox = argc > 1
        ? argv[1]
        : "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox";
    const char *support =
        "/System/Library/PrivateFrameworks/"
        "VideoToolboxParavirtualizationSupport.framework/"
        "VideoToolboxParavirtualizationSupport";
    void *vt = dlopen(videoToolbox, RTLD_NOW | RTLD_GLOBAL);
    printf("DLOPEN\tVideoToolbox\t%p\t%s\n", vt, vt ? "ok" : dlerror());
    void *pv = dlopen(support, RTLD_NOW | RTLD_GLOBAL);
    printf("DLOPEN\tPVSupport\t%p\t%s\n", pv, pv ? "ok" : dlerror());

    const char *symbols[] = {
        "VTParavirtualizationHostSessionCreate",
        "VTParavirtualizationHostSessionDeliverMessageFromGuest",
        "VTParavirtualizationHostSessionInvalidate",
    };
    for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); ++i)
        report_symbol(RTLD_DEFAULT, symbols[i]);

    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "VideoToolbox") || strstr(name, "AppleVXE") ||
                     strstr(name, "AppleAVD")))
            printf("IMAGE\t%s\n", name);
    }
    return 0;
}

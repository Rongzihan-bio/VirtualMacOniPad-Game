// dlopen-load test for an extracted+stamped Hypervisor.framework on-device.
// Tells us exactly what dyld thinks of the reconstructed image.
#include <stdio.h>
#include <dlfcn.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);   // unbuffered: survive a crash over ssh
    const char *p = argc > 1 ? argv[1] : "/var/root/Hypervisor.ios";
    printf("dlopen(%s)...\n", p);
    void *h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        printf("dlopen FAILED: %s\n", dlerror());
        return 1;
    }
    printf("dlopen OK: handle=%p\n", h);
    void *f = dlsym(h, "hv_vm_create");
    printf("dlsym(hv_vm_create) = %p\n", f);
    if (f) {
        typedef int (*fn_t)(void *);
        int r = ((fn_t)f)(NULL);   // real framework call → expect arg-validation err, not crash
        printf("hv_vm_create(NULL) = 0x%x\n", r);
    }
    return 0;
}

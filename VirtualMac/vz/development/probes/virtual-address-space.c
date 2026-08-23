#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>

extern kern_return_t mach_vm_allocate(vm_map_t target,
                                      mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target,
                                        mach_vm_address_t address,
                                        mach_vm_size_t size);

static void probe_fixed(const char *name, mach_vm_address_t address,
                        mach_vm_size_t size) {
    mach_vm_address_t requested = address;
    kern_return_t result = mach_vm_allocate(
        mach_task_self(), &requested, size, VM_FLAGS_FIXED);
    printf("%s address=0x%llx size=0x%llx result=%d actual=0x%llx\n",
           name, address, size, result, requested);
    if (result == KERN_SUCCESS)
        mach_vm_deallocate(mach_task_self(), requested, size);
}

int main(void) {
    mach_vm_address_t anywhere = 0;
    mach_vm_size_t sixteen_gib = 16ULL << 30;
    kern_return_t result = mach_vm_allocate(
        mach_task_self(), &anywhere, sixteen_gib, VM_FLAGS_ANYWHERE);
    printf("anywhere address=0x%llx size=0x%llx result=%d\n",
           anywhere, sixteen_gib, result);
    if (result == KERN_SUCCESS)
        mach_vm_deallocate(mach_task_self(), anywhere, sixteen_gib);

    probe_fixed("below-carveout", 0x0c00000000ULL, sixteen_gib);
    probe_fixed("gpu-carveout", 0x1000000000ULL, sixteen_gib);
    probe_fixed("above-carveout", 0x7000000000ULL, sixteen_gib);
    probe_fixed("above-carveout-next", 0x7400000000ULL, sixteen_gib);
    return 0;
}

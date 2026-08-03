#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>

enum { kReservationCount = 8 };
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
extern kern_return_t mach_vm_allocate(
    vm_map_t target, mach_vm_address_t *address,
    mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(
    vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
static const mach_vm_size_t kReservationSize = 16ULL << 30;

int main(void) {
    mach_vm_address_t vm[kReservationCount] = {0};
    void *sparse[kReservationCount] = {0};

    puts("mach_vm_allocate reservations:");
    for (unsigned index = 0; index < kReservationCount; index++) {
        kern_return_t result = mach_vm_allocate(
            mach_task_self(), &vm[index], kReservationSize,
            VM_FLAGS_ANYWHERE);
        printf("  %u: result=%d address=0x%llx\n", index, result,
               (unsigned long long)vm[index]);
        if (result != KERN_SUCCESS)
            break;
    }
    for (unsigned index = 0; index < kReservationCount; index++) {
        if (vm[index] != 0)
            mach_vm_deallocate(mach_task_self(), vm[index],
                               kReservationSize);
    }

    puts("mmap PROT_NONE reservations:");
    for (unsigned index = 0; index < kReservationCount; index++) {
        errno = 0;
        sparse[index] = mmap(NULL, (size_t)kReservationSize, PROT_NONE,
                             MAP_PRIVATE | MAP_ANON, -1, 0);
        printf("  %u: address=%p errno=%d\n", index, sparse[index], errno);
        if (sparse[index] == MAP_FAILED)
            break;
    }
    for (unsigned index = 0; index < kReservationCount; index++) {
        if (sparse[index] != NULL && sparse[index] != MAP_FAILED)
            munmap(sparse[index], (size_t)kReservationSize);
    }
    return 0;
}

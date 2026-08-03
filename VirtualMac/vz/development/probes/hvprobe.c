// hvprobe: confirm the iPad 16.3.1 kernel grants the host hypervisor to our signed binary.
// Mirrors UTM's Services/UTMJailbreak.m hv_trap (mach trap #-5). If this returns
// != HV_UNSUPPORTED, macOS Hypervisor (which funnels all hv_* through the
// same trap) will likely work on this device with com.apple.private.hypervisor.
#include <stdio.h>
#include <stdint.h>

#define HV_CALL_VM_GET_CAPABILITIES 0
#define HV_CALL_VM_CREATE           1
#define HV_UNSUPPORTED ((int32_t)0xfae9400f)

__attribute__((naked)) static uint64_t hv_trap(unsigned int hv_call, void *hv_arg) {
    __asm__ volatile(
        "mov x16, #-0x5\n"   // mach trap #-5 (hv_trap)
        "svc #0x80\n"
        "ret\n");
}

int main(void) {
    int64_t caps = hv_trap(HV_CALL_VM_GET_CAPABILITIES, NULL);   // exact UTM check
    printf("hv_trap(VM_GET_CAPABILITIES) = 0x%llx\n", (unsigned long long)caps);
    printf("HV_UNSUPPORTED              = 0x%llx\n", (unsigned long long)(uint32_t)HV_UNSUPPORTED);

    if ((int32_t)caps == HV_UNSUPPORTED) {
        printf("RESULT: HV UNSUPPORTED — kernel denied the hypervisor to this process.\n");
        return 2;
    }
    printf("RESULT: HV AVAILABLE — kernel granted the hypervisor.\n");

    // Bonus: try to actually create a VM. Non-zero/!=UNSUPPORTED here = even stronger signal.
    int64_t vm = hv_trap(HV_CALL_VM_CREATE, NULL);
    printf("hv_trap(VM_CREATE, NULL)    = 0x%llx  (errno-ish; arg=NULL so may EINVAL, but not UNSUPPORTED)\n",
           (unsigned long long)vm);
    return 0;
}

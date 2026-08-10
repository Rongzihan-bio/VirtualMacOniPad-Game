// iPadOS 14 Hypervisor facade for Ventura's VirtualMachine service.
//
// The actual implementation is Apple's Hypervisor binary extracted from
// macOS 11 (XNU 20) and re-exported by this dylib. Ventura's VMM additionally
// imports three IPA-size configuration APIs introduced after Big Sur. XNU 20
// selects a suitable IPA size when its vm-config fields remain at their
// defaults, so these compatibility APIs report that default and deliberately
// leave the older private config object unchanged.

#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ptrauth.h>
#include <stdio.h>

typedef int32_t hv_return_t;
typedef void *hv_vm_config_t;
typedef void *hv_vcpu_config_t;
typedef uint64_t hv_vcpu_t;
typedef uint64_t hv_ipa_t;
typedef uint64_t hv_memory_flags_t;
typedef uint32_t hv_reg_t;
typedef uint16_t hv_sys_reg_t;
typedef uint32_t hv_simd_fp_reg_t;
typedef struct hv_vcpu_exit hv_vcpu_exit_t;

enum {
    kDefaultIPABitLength = 36,
    HV_SUCCESS = 0,
    HV_BAD_ARGUMENT = (int32_t)0xfae94003U,
};

static uintptr_t big_sur_symbol_address(const char *name) {
    // HypervisorBigSur is an eager re-export dependency immediately after
    // this facade. Avoid dlopen("@loader_path/…") here: dyld14 does not
    // reliably resolve that token for an already-loaded image.
    void *symbol = dlsym(RTLD_NEXT, name);
    if (!symbol) {
        FILE *log = fopen("/tmp/hv14facade.log", "a");
        if (log) {
            fprintf(log, "%s unresolved: %s\n", name, dlerror());
            fclose(log);
        }
        return 0;
    }
    uintptr_t address =
        (uintptr_t)ptrauth_strip(symbol, ptrauth_key_function_pointer);
    return address;
}

#define FORWARD_RETURN(return_type, name, signature, arguments)              \
    static uintptr_t name##_target;                                           \
    __attribute__((constructor)) static void name##_resolve(void) {           \
        name##_target = big_sur_symbol_address(#name);                        \
    }                                                                         \
    __attribute__((naked)) return_type name signature {                       \
        __asm__ volatile(                                                     \
            "adrp x16, _" #name "_target@PAGE\n"                            \
            "ldr x16, [x16, _" #name "_target@PAGEOFF]\n"                   \
            "br x16\n");                                                     \
    }

#define FORWARD_CREATE(return_type, name, signature, arguments)              \
    FORWARD_RETURN(return_type, name, signature, arguments)

extern void *_os_object_alloc(const void *requested_class, size_t size);

hv_vcpu_config_t hv_vcpu_config_create(void) {
    return _os_object_alloc(NULL, 0x20);
}
FORWARD_RETURN(hv_return_t, hv_vcpu_config_get_feature_reg,
               (hv_vcpu_config_t config, uint64_t reg, uint64_t *value),
               (config, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_create,
               (hv_vcpu_t *vcpu, hv_vcpu_exit_t **exit,
                hv_vcpu_config_t config), (vcpu, exit, config))
FORWARD_RETURN(hv_return_t, hv_vcpu_destroy, (hv_vcpu_t vcpu), (vcpu))
FORWARD_RETURN(hv_return_t, hv_vcpu_get_reg,
               (hv_vcpu_t vcpu, hv_reg_t reg, uint64_t *value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_reg,
               (hv_vcpu_t vcpu, hv_reg_t reg, uint64_t value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_get_sys_reg,
               (hv_vcpu_t vcpu, hv_sys_reg_t reg, uint64_t *value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_sys_reg,
               (hv_vcpu_t vcpu, hv_sys_reg_t reg, uint64_t value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_get_simd_fp_reg,
               (hv_vcpu_t vcpu, hv_simd_fp_reg_t reg, __uint128_t *value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_simd_fp_reg,
               (hv_vcpu_t vcpu, hv_simd_fp_reg_t reg, __uint128_t value),
               (vcpu, reg, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_run, (hv_vcpu_t vcpu), (vcpu))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_trap_debug_exceptions,
               (hv_vcpu_t vcpu, bool value), (vcpu, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_trap_debug_reg_accesses,
               (hv_vcpu_t vcpu, bool value), (vcpu, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_vtimer_mask,
               (hv_vcpu_t vcpu, bool value), (vcpu, value))
FORWARD_RETURN(hv_return_t, hv_vcpu_set_vtimer_offset,
               (hv_vcpu_t vcpu, uint64_t value), (vcpu, value))
FORWARD_RETURN(hv_return_t, hv_vcpus_exit,
               (const hv_vcpu_t *vcpus, uint32_t count), (vcpus, count))
struct big_sur_vm_config {
    uint8_t object_header[16];
    uint64_t min_ipa;
    uint64_t ipa_size;
    uint32_t granule;
    uint32_t isa;
};

hv_vm_config_t hv_vm_config_create(void) {
    struct big_sur_vm_config *config = _os_object_alloc(NULL, sizeof(*config));
    if (config)
        config->isa = 1;
    return config;
}
FORWARD_RETURN(hv_return_t, hv_vm_create,
               (hv_vm_config_t config), (config))
FORWARD_RETURN(hv_return_t, hv_vm_destroy, (void), ())
FORWARD_RETURN(hv_return_t, hv_vm_get_max_vcpu_count,
               (uint32_t *count), (count))
FORWARD_RETURN(hv_return_t, hv_vm_map,
               (void *address, hv_ipa_t ipa, size_t size,
                hv_memory_flags_t flags), (address, ipa, size, flags))
FORWARD_RETURN(hv_return_t, hv_vm_unmap,
               (hv_ipa_t ipa, size_t size), (ipa, size))

hv_return_t hv_vm_config_get_default_ipa_size(uint32_t *ipa_bit_length) {
    if (!ipa_bit_length)
        return HV_BAD_ARGUMENT;
    *ipa_bit_length = kDefaultIPABitLength;
    return HV_SUCCESS;
}

hv_return_t hv_vm_config_get_max_ipa_size(uint32_t *ipa_bit_length) {
    if (!ipa_bit_length)
        return HV_BAD_ARGUMENT;
    *ipa_bit_length = kDefaultIPABitLength;
    return HV_SUCCESS;
}

hv_return_t hv_vm_config_set_ipa_size(hv_vm_config_t config,
                                       uint32_t ipa_bit_length) {
    if (!config || ipa_bit_length != kDefaultIPABitLength)
        return HV_BAD_ARGUMENT;
    return HV_SUCCESS;
}

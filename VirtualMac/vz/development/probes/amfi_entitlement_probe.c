#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "info.h"

extern int jbclient_initialize_primitives(void);
#ifdef __arm64e__
extern int jbclient_get_fugu14_kcall(void);
#else
extern int arm64_kcall_init(void);
#endif
extern _Bool is_kcall_available(void);
extern uint64_t proc_find(pid_t pid);
extern int proc_rele(uint64_t proc);
extern uint64_t proc_task(uint64_t proc);
extern uint64_t proc_ucred(uint64_t proc);
extern uint32_t proc_getcsflags(uint64_t proc);
extern uint64_t kread64(uint64_t address);
extern uint64_t kread_ptr(uint64_t address);
extern uint32_t kread32(uint64_t address);
extern uint8_t kread8(uint64_t address);
extern int kreadbuf(uint64_t address, void *output, size_t size);
extern uint64_t mac_label_get(uint64_t label, int slot);
extern int kalloc(uint64_t *address, uint64_t size);
extern int kfree(uint64_t address, uint64_t size);
extern int kwritebuf(uint64_t address, const void *input, size_t size);
extern uint8_t kread8(uint64_t address);
extern int kcall(uint64_t *result, uint64_t function, int argc,
                 const uint64_t *arguments);

static const uint64_t amfiEntitlementGetBoolUnslid =
    0xfffffe00092b5e34ULL; // iPadOS 16.3.1 20D67, iPad14,3-6
static const uint64_t amfiMacSlotUnslid =
    0xfffffe0007bb91d0ULL; // _amfi_mac_slot in the same kernelcache

static uint32_t readBigEndian32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | bytes[3];
}

static _Bool containsBytes(const uint8_t *haystack, size_t haystackLength,
                           const char *needle) {
    size_t needleLength = strlen(needle);
    if (needleLength > haystackLength)
        return 0;
    for (size_t i = 0; i <= haystackLength - needleLength; i++) {
        if (memcmp(haystack + i, needle, needleLength) == 0)
            return 1;
    }
    return 0;
}

static void inspect(uint64_t process) {
    uint64_t task = proc_task(process);
    uint64_t map = task ? kread_ptr(task + koffsetof(task, map)) : 0;
    uint64_t pmap = map ? kread_ptr(map + koffsetof(vm_map, pmap)) : 0;
    uint64_t region = pmap ?
        kread_ptr(pmap + koffsetof(pmap, pmap_cs_main)) : 0;
    uint64_t codeDirectory = region ?
        kread_ptr(region + koffsetof(pmap_cs_region, cd_entry)) : 0;
    uint32_t trust = codeDirectory ?
        kread32(codeDirectory + koffsetof(pmap_cs_code_directory, trust)) : 0;
    uint64_t credential = proc_ucred(process);
    uint64_t label = credential ?
        kread_ptr(credential + koffsetof(ucred, label)) : 0;
    int32_t slot = (int32_t)kread32(amfiMacSlotUnslid +
                                    gSystemInfo.kernelConstant.slide);
    uint64_t entitlements = label && slot >= 0 ?
        mac_label_get(label, slot) : 0;

    printf("csflags=0x%08x task=0x%llx map=0x%llx pmap=0x%llx\n",
           proc_getcsflags(process),
           (unsigned long long)task, (unsigned long long)map,
           (unsigned long long)pmap);
    printf("pmap_cs_region=0x%llx code_directory=0x%llx trust=%u\n",
           (unsigned long long)region, (unsigned long long)codeDirectory,
           trust);
    printf("ucred=0x%llx label=0x%llx amfi_slot=%d "
           "OSEntitlements=0x%llx\n",
           (unsigned long long)credential, (unsigned long long)label, slot,
           (unsigned long long)entitlements);
    if (entitlements) {
        printf("OSEntitlements words:");
        for (uint64_t offset = 0; offset < 0x60; offset += 8)
            printf(" %016llx", (unsigned long long)
                   kread64(entitlements + offset));
        putchar('\n');
        uint64_t state = kread_ptr(entitlements + 0x10);
        printf("OSEntitlements state=0x%llx is_cs_platform=%u words:",
               (unsigned long long)state,
               state ? kread8(state + 0x69) : 0);
        for (uint64_t offset = 0; state && offset < 0x80; offset += 8)
            printf(" %016llx", (unsigned long long)
                   kread64(state + offset));
        putchar('\n');

        uint64_t der = state ? kread_ptr(state + 0x60) : 0;
        if (der) {
            uint8_t prefix[64] = { 0 };
            kreadbuf(der, prefix, sizeof(prefix));
            uint32_t blobLength = readBigEndian32(prefix + 4);
            printf("DER pointer=0x%llx prefix=",
                   (unsigned long long)der);
            for (size_t i = 0; i < sizeof(prefix); i++)
                printf("%02x", prefix[i]);
            putchar('\n');
            if (blobLength >= 8 && blobLength <= 0x20008) {
                uint8_t *blob = malloc(blobLength);
                if (blob && kreadbuf(der, blob, blobLength) == 0) {
                    const char *ethernet =
                        "com.apple.networking.ethernet.user-access";
                    printf("DER length=%u contains_ethernet_key=%u\n",
                           blobLength,
                           containsBytes(blob, blobLength, ethernet));
                }
                free(blob);
            }
        }
    }
}

static int query(uint64_t process, const char *key) {
    uint64_t kernelKey = 0;
    uint64_t kernelBool = 0;
    uint64_t result = 0;
    int error = kalloc(&kernelKey, 256);
    if (error != 0)
        return fprintf(stderr, "kalloc(key) failed: %d\n", error), 1;
    error = kalloc(&kernelBool, 8);
    if (error != 0) {
        kfree(kernelKey, 256);
        return fprintf(stderr, "kalloc(bool) failed: %d\n", error), 1;
    }

    uint8_t zero = 0;
    kwritebuf(kernelKey, key, strlen(key) + 1);
    kwritebuf(kernelBool, &zero, sizeof(zero));
    uint64_t arguments[] = { process, kernelKey, kernelBool };
    error = kcall(&result,
                  amfiEntitlementGetBoolUnslid +
                      gSystemInfo.kernelConstant.slide,
                  3, arguments);
    uint8_t granted = kread8(kernelBool);
    printf("key=%s kcall=%d amfi=0x%llx granted=%u\n", key, error,
           (unsigned long long)result, granted);

    kfree(kernelBool, 8);
    kfree(kernelKey, 256);
    return error != 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s PID [ENTITLEMENT ...]\n", argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
    int error = jbclient_initialize_primitives();
    if (error != 0) {
        fprintf(stderr, "jbclient_initialize_primitives failed: %d\n", error);
        return 1;
    }
    uint64_t process = proc_find(pid);
    if (process == 0) {
        fprintf(stderr, "proc_find(%d) failed\n", pid);
        return 1;
    }
    printf("pid=%d proc=0x%llx slide=0x%llx amfi=0x%llx\n", pid,
           (unsigned long long)process,
           (unsigned long long)gSystemInfo.kernelConstant.slide,
           (unsigned long long)(amfiEntitlementGetBoolUnslid +
                                gSystemInfo.kernelConstant.slide));
    inspect(process);

    if (!is_kcall_available()) {
#ifdef __arm64e__
        error = jbclient_get_fugu14_kcall();
        fprintf(stderr, "jbclient_get_fugu14_kcall=%d available=%d\n",
                error, is_kcall_available());
#else
        error = arm64_kcall_init();
        fprintf(stderr, "arm64_kcall_init=%d available=%d\n", error,
                is_kcall_available());
#endif
    }
    if (!is_kcall_available()) {
        fprintf(stderr, "kernel call primitive unavailable; "
                "credential inspection above is still valid\n");
        proc_rele(process);
        return 0;
    }

    int failed = 0;
    if (argc == 2) {
        const char *keys[] = {
            "com.apple.networking.ethernet.user-access",
            "com.apple.pf.allow",
            "platform-application",
            "com.apple.private.security.no-sandbox",
            "com.mac.virtual.does-not-exist",
        };
        for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
            failed |= query(process, keys[i]);
    } else {
        for (int i = 2; i < argc; i++)
            failed |= query(process, argv[i]);
    }
    proc_rele(process);
    return failed ? 1 : 0;
}

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>

typedef struct vmnet_interface *interface_ref;
typedef interface_ref (*start_interface_fn)(xpc_object_t, dispatch_queue_t,
                                             void (^)(uint32_t, xpc_object_t));
typedef void (*stop_interface_fn)(interface_ref, dispatch_queue_t,
                                  void (^)(uint32_t));
typedef CFTypeRef (*dynamic_store_create_fn)(CFAllocatorRef, CFStringRef,
                                              void *, const void *);
typedef int (*sc_error_fn)(void);
typedef const char *(*sc_error_string_fn)(int);

int main(void) {
    void *systemConfiguration = dlopen(
        "/System/Library/Frameworks/SystemConfiguration.framework/"
        "SystemConfiguration", RTLD_NOW | RTLD_LOCAL);
    dynamic_store_create_fn createStore = (dynamic_store_create_fn)dlsym(
        systemConfiguration, "SCDynamicStoreCreate");
    sc_error_fn getSCError =
        (sc_error_fn)dlsym(systemConfiguration, "SCError");
    sc_error_string_fn getSCErrorString =
        (sc_error_string_fn)dlsym(systemConfiguration, "SCErrorString");
    CFTypeRef store = createStore ? createStore(
        NULL, CFSTR("com.apple.NetworkSharing"), NULL, NULL) : NULL;
    int storeError = getSCError ? getSCError() : -1;
    printf("vmnet probe: dynamic store=%p error=%d (%s)\n", store,
           storeError, getSCErrorString ? getSCErrorString(storeError) : "?");
    if (store)
        CFRelease(store);

    const char *framework =
        "/var/jb/usr/local/lib/vmnet.framework/vmnet";
    void *image = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "vmnet probe: dlopen failed: %s\n", dlerror());
        return 1;
    }

    start_interface_fn start =
        (start_interface_fn)dlsym(image, "vmnet_start_interface");
    stop_interface_fn stop =
        (stop_interface_fn)dlsym(image, "vmnet_stop_interface");
    const char *const *operationModeKey =
        (const char *const *)dlsym(image, "vmnet_operation_mode_key");
    if (!start || !operationModeKey || !*operationModeKey) {
        fprintf(stderr, "vmnet probe: required symbols unavailable\n");
        return 1;
    }

    xpc_object_t description = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(description, *operationModeKey, 1001);
    dispatch_queue_t queue = dispatch_queue_create(
        "com.mac.virtual.vmnet-probe", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block uint32_t startStatus = UINT32_MAX;
    __block interface_ref interface = NULL;

    interface = start(description, queue, ^(uint32_t status,
                                             xpc_object_t parameters) {
        startStatus = status;
        char *text = parameters ? xpc_copy_description(parameters) : NULL;
        printf("vmnet probe: start status=%u parameters=%s\n", status,
               text ? text : "(null)");
        free(text);
        fflush(stdout);
        dispatch_semaphore_signal(started);
    });
    xpc_release(description);
    if (!interface) {
        fprintf(stderr, "vmnet probe: start returned NULL\n");
        return 2;
    }
    if (dispatch_semaphore_wait(
            started, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
        fprintf(stderr, "vmnet probe: start timed out\n");
        return 3;
    }
    if (startStatus != 1000)
        return 4;
    if (!stop)
        return 0;

    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    __block uint32_t stopStatus = UINT32_MAX;
    stop(interface, queue, ^(uint32_t status) {
        stopStatus = status;
        printf("vmnet probe: stop status=%u\n", status);
        fflush(stdout);
        dispatch_semaphore_signal(stopped);
    });
    if (dispatch_semaphore_wait(
            stopped, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        fprintf(stderr, "vmnet probe: stop timed out\n");
        return 5;
    }
    return stopStatus == 1000 ? 0 : 6;
}

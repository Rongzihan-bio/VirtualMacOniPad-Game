// DYLD_INSERT hook for the iOS-ported VZ VMM service.
// The VMM's main() calls xpc_main(handler), but iOS xpc_main requires the launchd
// XPCService-domain context (it reads the job's "XPCService" config dict -> "Could not
// retrieve service name"); iOS launchd doesn't register framework XPCServices that way.
// We interpose xpc_main with a plain MACH-SERVICE listener instead: a MachServices
// launchd daemon (vmm-launchd.plist) gives us the receive right for
// "com.apple.Virtualization.VirtualMachine", and the host reaches us via
// xpc_connection_create_mach_service(name). The handler passed to xpc_main is invoked
// once per incoming peer connection (a bare function pointer in this libxpc).
//
// The iOS SDK marks xpc_main / xpc_connection_create_mach_service __API_UNAVAILABLE(ios),
// though iOS libxpc exports them, so we declare them ourselves and link with
// -undefined dynamic_lookup (resolved at runtime from libSystem/libxpc).
#import <objc/message.h>
#import <objc/runtime.h>

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <limits.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <ptrauth.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "usb_restore_bridge.h"

typedef void *xo_t; // xpc_object_t / xpc_connection_t (opaque pointers)
extern void  xpc_main(void (*handler)(xo_t));
extern xo_t  xpc_connection_create_mach_service(const char *, dispatch_queue_t, uint64_t);
extern xo_t  xpc_connection_create(const char *name, dispatch_queue_t q);
extern xo_t  xpc_endpoint_create(xo_t connection);
extern xo_t  xpc_connection_create_from_endpoint(xo_t endpoint);
extern void  xpc_connection_set_event_handler(xo_t, void (^)(xo_t));
extern void  xpc_connection_resume(xo_t);
extern void  xpc_connection_send_message(xo_t, xo_t);
extern void  xpc_connection_send_message_with_reply(
    xo_t, xo_t, dispatch_queue_t, void (^)(xo_t));
extern void *xpc_get_type(xo_t);
extern const char *xpc_dictionary_get_string(xo_t, const char *);
extern xo_t xpc_dictionary_get_value(xo_t, const char *);
extern void xpc_dictionary_set_bool(xo_t, const char *, bool);
extern void xpc_dictionary_set_uint64(xo_t, const char *, uint64_t);
extern char *xpc_copy_description(xo_t);
extern char  _xpc_type_connection[]; // XPC_TYPE_CONNECTION
extern char  _xpc_type_dictionary[]; // XPC_TYPE_DICTIONARY
extern char  _xpc_type_error[];      // XPC_TYPE_ERROR
extern int   sandbox_init(const char *profile, uint64_t flags, char **errorbuf);

// xpc_endpoint object layout: the backing mach send-right is a uint32 at +0x18
// (confirmed on iPadOS 16.3.1 via vz/development/probes/epprobe.m). iPad hands the host's
// anonymous-listener port to us as an inherited send right (name in VMM_EP_PORT); we
// rebuild an endpoint by port-swap and connect back, peer-to-peer (no launchd).
#define XPC_ENDPOINT_PORT_OFF 0x18

// Custom name: launchd reserves/special-cases com.apple.Virtualization.VirtualMachine
// (an Application-type service it forces to user/foreground), refusing our system daemon
// with EX_CONFIG. A plain custom MachService name registers + spawns fine. The host
// interposes xpc_connection_create("com.apple.Virtualization.VirtualMachine") to connect here.
#define VMM_SERVICE "org.jb.vmmservice"
#define XPC_MACH_SERVICE_LISTENER 1ULL

static void logf_(const char *fmt, ...) {
    FILE *f = fopen("/tmp/vmmhook.log", "a"); if (!f) return;
    fchmod(fileno(f), 0666);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

static void log_address(const char *label, void *address) {
    Dl_info info = {0};
    if (address && dladdr(address, &info) && info.dli_fbase) {
        logf_("[vmmhook] %s=%p image=%s +0x%llx symbol=%s",
              label, address, info.dli_fname ? info.dli_fname : "?",
              (unsigned long long)((uintptr_t)address -
                                   (uintptr_t)info.dli_fbase),
              info.dli_sname ? info.dli_sname : "?");
    } else {
        logf_("[vmmhook] %s=%p (dladdr failed)", label, address);
    }
}

static uint64_t xpc_trace_count;
static uint64_t xpc_digitizer_received;
static uint64_t xpc_digitizer_processed;
static uint64_t xpc_keyboard_received;
static uint64_t xpc_keyboard_processed;
static uint64_t xpc_frame_updates;
static uint64_t xpc_cursor_updates;
static uint64_t iosurface_create_count;
static void *vmm_vcpu_exits[64];
static uint64_t vmm_vcpu_exit_counts[64];
static uint64_t vmm_vcpu_exit_reason_counts[64][4];
static uint64_t vmm_vcpu_last_cntv_ctl[64];
static uint64_t vmm_vcpu_last_cntv_cval[64];
static uint64_t vmm_vcpu_last_mach_time[64];
static uint64_t vmm_vtimer_mask_calls[64];
static uint64_t vmm_vtimer_last_mask[64];
static uint64_t vmm_vtimer_offset_calls[64];
static uint64_t vmm_vtimer_last_offset[64];
static uint64_t vmm_vcpus_exit_calls;
static xo_t fake_usb_location_reply_connection;

static bool fake_usb_hci_enabled(void);

static uint32_t vmm_latest_exit_reason(size_t index) {
    void *exit = index < 64
        ? __atomic_load_n(&vmm_vcpu_exits[index], __ATOMIC_ACQUIRE)
        : NULL;
    return exit ? *(volatile uint32_t *)exit : UINT32_MAX;
}

static uint64_t vmm_latest_exit_syndrome(size_t index) {
    void *exit = index < 64
        ? __atomic_load_n(&vmm_vcpu_exits[index], __ATOMIC_ACQUIRE)
        : NULL;
    return exit ? *(volatile uint64_t *)((uint8_t *)exit + 8) : 0;
}

static const char *xpc_message_name(xo_t message) {
    if (!message || xpc_get_type(message) != (void *)_xpc_type_dictionary)
        return NULL;
    return xpc_dictionary_get_string(message, "name");
}

static void count_received_xpc(const char *name) {
    if (!name)
        return;
    if (strcmp(name, "process_digitizer_events") == 0)
        __atomic_add_fetch(&xpc_digitizer_received, 1, __ATOMIC_RELAXED);
    else if (strcmp(name, "process_keyboard_events") == 0)
        __atomic_add_fetch(&xpc_keyboard_received, 1, __ATOMIC_RELAXED);
}

static void count_processed_xpc(const char *name) {
    if (!name)
        return;
    if (strcmp(name, "process_digitizer_events") == 0)
        __atomic_add_fetch(&xpc_digitizer_processed, 1, __ATOMIC_RELAXED);
    else if (strcmp(name, "process_keyboard_events") == 0)
        __atomic_add_fetch(&xpc_keyboard_processed, 1, __ATOMIC_RELAXED);
}

static void count_sent_xpc(const char *name) {
    if (!name)
        return;
    if (strcmp(name, "process_frame_update") == 0)
        __atomic_add_fetch(&xpc_frame_updates, 1, __ATOMIC_RELAXED);
    else if (strcmp(name, "process_cursor_update") == 0)
        __atomic_add_fetch(&xpc_cursor_updates, 1, __ATOMIC_RELAXED);
}

typedef void *iosurface_ref_t;
extern iosurface_ref_t IOSurfaceCreate(CFDictionaryRef properties);
extern uint32_t IOSurfaceGetID(iosurface_ref_t surface);

// Ask iPadOS to register PVG's IOSurfaces globally before its native
// IOSurfaceCreateXPCObject path transfers the Mach right to the UIKit host.
static iosurface_ref_t vmm_IOSurfaceCreate(CFDictionaryRef properties) {
    CFMutableDictionaryRef globalProperties =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, properties);
    CFDictionarySetValue(
        globalProperties, CFSTR("IOSurfaceIsGlobal"), kCFBooleanTrue);
    iosurface_ref_t surface = IOSurfaceCreate(globalProperties);
    uint32_t identifier = surface ? IOSurfaceGetID(surface) : 0;
    uint64_t count = __atomic_add_fetch(
        &iosurface_create_count, 1, __ATOMIC_RELAXED);
    if (count <= 12 || count % 300 == 0) {
        logf_("[vmmhook] IOSurfaceCreate #%llu requested-global=1 "
              "-> %p id=%u",
              (unsigned long long)count, surface, identifier);
    }
    CFRelease(globalProperties);
    return surface;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_iosurface_create __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&vmm_IOSurfaceCreate,
    (const void *)&IOSurfaceCreate,
};

static bool should_trace_xpc(uint64_t *sequence) {
    const char *limit_text = getenv("VMMHOOK_TRACE_XPC_LIMIT");
    uint64_t limit = limit_text ? strtoull(limit_text, NULL, 0) : 0;
    *sequence = __atomic_add_fetch(&xpc_trace_count, 1, __ATOMIC_RELAXED);
    return *sequence <= limit;
}

static void trace_xpc_message(const char *operation, xo_t connection,
                              xo_t message) {
    const char *name = xpc_message_name(message);
    if (name && strcmp(name, "guest_did_post_trace_event") == 0)
        return;
    uint64_t sequence;
    if (!should_trace_xpc(&sequence))
        return;
    char *description = xpc_copy_description(message);
    logf_("[vmmhook] XPC #%llu %s connection=%p message=%s",
          (unsigned long long)sequence, operation, connection,
          description ? description : "?");
    if (description)
        free(description);
}

static void vmm_xpc_connection_send_message(xo_t connection, xo_t message) {
    if (fake_usb_hci_enabled() &&
        connection == fake_usb_location_reply_connection &&
        message && xpc_get_type(message) == (void *)_xpc_type_dictionary) {
        xo_t result = xpc_dictionary_get_value(message, "result");
        if (result && xpc_get_type(result) == (void *)_xpc_type_dictionary) {
            // Without AppleUSBUserHCIResources there is no IORegistry
            // AppleUSBUserHCIPort node from which VMM can recover locationID.
            // Preserve the value produced by Ventura's genuine virtual USB
            // controller so Installation/MobileDevice can bind to this AVP
            // transport.
            xpc_dictionary_set_bool(result, "has_value", true);
            xpc_dictionary_set_uint64(result, "value", 0x80100000U);
            fake_usb_location_reply_connection = NULL;
            logf_("[vmmhook] supplied fake USB controller location ID "
                  "0x80100000");
        }
    }
    count_sent_xpc(xpc_message_name(message));
    trace_xpc_message("send", connection, message);
    xpc_connection_send_message(connection, message);
}

static void vmm_xpc_connection_send_message_with_reply(
    xo_t connection, xo_t message, dispatch_queue_t queue,
    void (^handler)(xo_t)) {
    count_sent_xpc(xpc_message_name(message));
    trace_xpc_message("send-with-reply", connection, message);
    xpc_connection_send_message_with_reply(
        connection, message, queue, handler);
}

static void vmm_xpc_connection_set_event_handler(
    xo_t connection, void (^handler)(xo_t)) {
    xpc_connection_set_event_handler(connection, ^(xo_t event) {
        const char *name = xpc_message_name(event);
        count_received_xpc(name);
        trace_xpc_message("receive", connection, event);
        if (fake_usb_hci_enabled() && name &&
            strcmp(name, "get_usb_controller_location_id") == 0)
            fake_usb_location_reply_connection = connection;
        handler(event);
        count_processed_xpc(name);
    });
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_xpc_send __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_xpc_connection_send_message,
      (const void *)&xpc_connection_send_message };
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_xpc_send_with_reply __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_xpc_connection_send_message_with_reply,
      (const void *)&xpc_connection_send_message_with_reply };
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_xpc_set_handler __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_xpc_connection_set_event_handler,
      (const void *)&xpc_connection_set_event_handler };

typedef id (*usb_hci_init_t)(id, SEL, id, id, uint64_t, id *, id, id, id);
static usb_hci_init_t original_usb_hci_init;
typedef bool (*usb_hci_enqueue_one_t)(id, SEL, const void *, id *);
typedef bool (*usb_hci_enqueue_one_expedite_t)(id, SEL, const void *, bool,
                                               id *);
typedef bool (*usb_hci_enqueue_many_t)(id, SEL, const void *, uintptr_t, id *);
typedef bool (*usb_hci_enqueue_many_expedite_t)(id, SEL, const void *,
                                                uintptr_t, bool, id *);
typedef void (*usb_hci_destroy_t)(id, SEL);
static usb_hci_enqueue_one_t original_usb_hci_enqueue_one;
static usb_hci_enqueue_one_expedite_t original_usb_hci_enqueue_one_expedite;
static usb_hci_enqueue_many_t original_usb_hci_enqueue_many;
static usb_hci_enqueue_many_expedite_t original_usb_hci_enqueue_many_expedite;
static usb_hci_destroy_t original_usb_hci_destroy;
static char fake_usb_hci_marker_key;
static char fake_usb_hci_doorbell_handler_key;
static uint64_t fake_usb_hci_interrupt_count;

typedef struct {
    uint32_t control;
    uint32_t data0;
    uint64_t data1;
} usb_hci_message_t;

typedef void (^usb_hci_command_handler_t)(id, usb_hci_message_t);
typedef void (^usb_hci_doorbell_handler_t)(id, const uint32_t *, uintptr_t);
extern void *_Block_copy(const void *block);

enum {
    FakeUSBHostStageIdle = 0,
    FakeUSBHostStageControllerPowerOn,
    FakeUSBHostStageControllerStart,
    FakeUSBHostStagePortPowerOn,
    FakeUSBHostStagePortStatus,
    FakeUSBHostStageWaitForConnect,
    FakeUSBHostStagePortReset,
    FakeUSBHostStageDeviceCreate,
    FakeUSBHostStageDeviceCreated,
    FakeUSBHostStageEndpointCreate,
    FakeUSBHostStageEndpointReset,
    FakeUSBHostStageEndpointSetNextTransfer,
    FakeUSBHostStageReadDeviceDescriptor,
    FakeUSBHostStageDeviceDescriptorRead,
    FakeUSBHostStageFailed,
};

static int fake_usb_host_stage;
static uint8_t fake_usb_host_device_address;
static id fake_usb_host_controller;
static usb_hci_command_handler_t fake_usb_host_command_handler;
static usb_hci_doorbell_handler_t fake_usb_host_doorbell_handler;
static dispatch_queue_t fake_usb_host_queue;
static unsigned fake_usb_descriptor_retry_count;

static uint8_t fake_usb_ep0_descriptor[7] __attribute__((aligned(16))) = {
    7, 5, 0, 0, 64, 0, 0,
};
static uint8_t fake_usb_device_descriptor[64] __attribute__((aligned(16)));
static usb_hci_message_t fake_usb_device_descriptor_transfer[4]
    __attribute__((aligned(16)));

typedef struct {
    dispatch_semaphore_t command_done;
    dispatch_semaphore_t transfer_done;
    uint32_t command_type;
    usb_hci_message_t *terminal;
    int command_status;
    int transfer_status;
    uint32_t actual_length;
} fake_usb_bridge_pending_t;

static void fake_usb_bridge_pending_destroy(
    fake_usb_bridge_pending_t *pending) {
    if (pending->command_done) {
        dispatch_release(pending->command_done);
        pending->command_done = NULL;
    }
    if (pending->transfer_done) {
        dispatch_release(pending->transfer_done);
        pending->transfer_done = NULL;
    }
}

static pthread_mutex_t fake_usb_bridge_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t fake_usb_bridge_command_lock =
    PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t fake_usb_bridge_bulk_input_lock =
    PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t fake_usb_bridge_bulk_output_lock =
    PTHREAD_MUTEX_INITIALIZER;
static fake_usb_bridge_pending_t *fake_usb_bridge_command_pending;
static fake_usb_bridge_pending_t *fake_usb_bridge_transfer_pending[256];
static bool fake_usb_bridge_started;
static uint32_t fake_usb_device_generation = 1;
static usb_hci_message_t *fake_usb_bridge_tail;
static usb_hci_message_t *fake_usb_bridge_retained_ring;
static bool fake_usb_bridge_endpoints[256];
// AVP's endpoint object retains the descriptor pointer supplied to the
// EndpointCreate command and reads fields such as wMaxPacketSize for every
// later transfer. These descriptors therefore must live until the USB
// personality is torn down; a command-local buffer becomes a delayed UAF on
// com.apple.virtualization.usb.hci once restore traffic reaches that endpoint.
static uint8_t fake_usb_bridge_endpoint_descriptors[256][7]
    __attribute__((aligned(16)));
static usb_hci_message_t *fake_usb_bridge_bulk_tails[256];
static usb_hci_message_t *fake_usb_bridge_bulk_rings[256];
static pthread_mutex_t fake_usb_bridge_mux_cache_lock =
    PTHREAD_MUTEX_INITIALIZER;
static uint8_t fake_usb_bridge_mux_reply[4096];
static uint32_t fake_usb_bridge_mux_reply_length;
static uint32_t fake_usb_bridge_mux_generation;
static unsigned fake_usb_bridge_mux_suppress_writes;

static void fake_usb_bridge_prepare_restoreos(uint32_t generation);

static bool fake_usb_read_full(int fd, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    while (length) {
        ssize_t count = read(fd, bytes, length);
        if (count == 0)
            return false;
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        bytes += count;
        length -= (size_t)count;
    }
    return true;
}

static bool fake_usb_write_full(int fd, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    while (length) {
        ssize_t count = write(fd, bytes, length);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        bytes += count;
        length -= (size_t)count;
    }
    return true;
}

static bool fake_usb_hci_enabled(void) {
    const char *value = getenv("VMMHOOK_FAKE_USB");
    return value && value[0] != '\0' && strcmp(value, "0") != 0;
}

static bool fake_usb_trace_enabled(void) {
    const char *value = getenv("VMMHOOK_TRACE_USB");
    return value && value[0] != '\0' && strcmp(value, "0") != 0;
}

static bool is_fake_usb_hci(id object) {
    return objc_getAssociatedObject(object, &fake_usb_hci_marker_key) != nil;
}

static const char *fake_usb_host_stage_name(int stage) {
    switch (stage) {
    case FakeUSBHostStageIdle: return "idle";
    case FakeUSBHostStageControllerPowerOn: return "controller-power-on";
    case FakeUSBHostStageControllerStart: return "controller-start";
    case FakeUSBHostStagePortPowerOn: return "port-power-on";
    case FakeUSBHostStagePortStatus: return "port-status";
    case FakeUSBHostStageWaitForConnect: return "wait-for-connect";
    case FakeUSBHostStagePortReset: return "port-reset";
    case FakeUSBHostStageDeviceCreate: return "device-create";
    case FakeUSBHostStageDeviceCreated: return "device-created";
    case FakeUSBHostStageEndpointCreate: return "endpoint-create";
    case FakeUSBHostStageEndpointReset: return "endpoint-reset";
    case FakeUSBHostStageEndpointSetNextTransfer:
        return "endpoint-set-next-transfer";
    case FakeUSBHostStageReadDeviceDescriptor:
        return "read-device-descriptor";
    case FakeUSBHostStageDeviceDescriptorRead:
        return "device-descriptor-read";
    case FakeUSBHostStageFailed: return "failed";
    default: return "unknown";
    }
}

static void fake_usb_host_send_after(id controller, int stage,
                                     uint32_t type, uint32_t data0,
                                     uint64_t data1, uint64_t delay_ns) {
    usb_hci_command_handler_t handler = fake_usb_host_command_handler;
    dispatch_queue_t queue = fake_usb_host_queue;
    if (controller != fake_usb_host_controller || !handler || !queue) {
        logf_("[vmmhook] fake USB cannot send type=0x%02x: "
              "controller=%p active=%p handler=%p queue=%p", type,
              controller, fake_usb_host_controller, handler, queue);
        __atomic_store_n(&fake_usb_host_stage, FakeUSBHostStageFailed,
                         __ATOMIC_RELEASE);
        return;
    }
    __atomic_store_n(&fake_usb_host_stage, stage, __ATOMIC_RELEASE);
    usb_hci_message_t message = {
        .control = 0x8000U | (type & 0x3fU),
        .data0 = data0,
        .data1 = data1,
    };
    logf_("[vmmhook] fake USB send stage=%s control=0x%08x "
          "data0=0x%08x data1=0x%016llx delay-ns=%llu",
          fake_usb_host_stage_name(stage), message.control, message.data0,
          (unsigned long long)message.data1,
          (unsigned long long)delay_ns);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay_ns),
                   queue, ^{
        handler(controller, message);
    });
}

static void fake_usb_host_send(id controller, int stage, uint32_t type,
                               uint32_t data0, uint64_t data1) {
    fake_usb_host_send_after(controller, stage, type, data0, data1, 0);
}

static void fake_usb_host_prepare_device_descriptor_transfer(void) {
    memset(fake_usb_device_descriptor, 0,
           sizeof(fake_usb_device_descriptor));
    memset(fake_usb_device_descriptor_transfer, 0,
           sizeof(fake_usb_device_descriptor_transfer));
    // This is the exact first control-transfer ring emitted by
    // IOUSBHost.framework 1.2 on Ventura 13.2.1. Bit 15 owns the first three
    // messages on the controller side; the invalid terminator has the
    // opposite ownership bit (bit 14). Asking for only the traditional
    // eight-byte prefix, or reversing these bits, makes the AVP backend
    // return StallError before it sends anything to the restore device.
    fake_usb_device_descriptor_transfer[0].control = 0x8038;
    fake_usb_device_descriptor_transfer[0].data1 =
        0x80ULL | (6ULL << 8) | (0x0100ULL << 16) | (18ULL << 48);
    fake_usb_device_descriptor_transfer[1].control = 0x8039;
    fake_usb_device_descriptor_transfer[1].data0 = 18;
    fake_usb_device_descriptor_transfer[1].data1 =
        (uintptr_t)fake_usb_device_descriptor;
    fake_usb_device_descriptor_transfer[2].control = 0x803a;
    fake_usb_device_descriptor_transfer[3].control = 0x403c;
}

static void fake_usb_host_ring_ep0_doorbell(id controller) {
    usb_hci_doorbell_handler_t handler = fake_usb_host_doorbell_handler;
    if (!handler) {
        logf_("[vmmhook] fake USB cannot ring EP0: missing handler");
        __atomic_store_n(&fake_usb_host_stage, FakeUSBHostStageFailed,
                         __ATOMIC_RELEASE);
        return;
    }

    uint32_t doorbell = (uint32_t)fake_usb_host_device_address;
    __atomic_store_n(&fake_usb_host_stage,
                     FakeUSBHostStageReadDeviceDescriptor,
                     __ATOMIC_RELEASE);
    logf_("[vmmhook] fake USB ring EP0 doorbell=0x%08x transfer=%p "
          "buffer=%p", doorbell, fake_usb_device_descriptor_transfer,
          fake_usb_device_descriptor);
    handler(controller, &doorbell, 1);
}

static void fake_usb_log_device_descriptor(void) {
    char bytes[3 * 18 + 1] = {0};
    size_t offset = 0;
    for (size_t index = 0; index < 18; index++) {
        int written = snprintf(bytes + offset, sizeof(bytes) - offset,
                               "%02x%s", fake_usb_device_descriptor[index],
                               index == 17 ? "" : " ");
        if (written < 0)
            break;
        offset += (size_t)written;
    }
    logf_("[vmmhook] fake USB device descriptor: %s", bytes);
}

static uint16_t fake_usb_descriptor_u16(size_t offset) {
    return (uint16_t)fake_usb_device_descriptor[offset] |
           ((uint16_t)fake_usb_device_descriptor[offset + 1] << 8);
}

static bool fake_usb_bridge_wait(dispatch_semaphore_t semaphore,
                                 uint32_t timeout_ms) {
    uint64_t nanoseconds = (uint64_t)(timeout_ms ? timeout_ms : 30000) *
                           NSEC_PER_MSEC;
    return dispatch_semaphore_wait(
               semaphore,
               dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanoseconds)) == 0;
}

static int fake_usb_bridge_command(uint32_t type, uint32_t data0,
                                   uint64_t data1,
                                   fake_usb_bridge_pending_t *pending,
                                   uint32_t timeout_ms) {
    usb_hci_command_handler_t handler = fake_usb_host_command_handler;
    dispatch_queue_t queue = fake_usb_host_queue;
    id controller = fake_usb_host_controller;
    if (!handler || !queue || !controller)
        return ENODEV;

    pthread_mutex_lock(&fake_usb_bridge_command_lock);
    pending->command_type = type;
    pending->command_status = -1;
    __atomic_store_n(&fake_usb_bridge_command_pending, pending,
                     __ATOMIC_RELEASE);
    usb_hci_message_t message = {
        .control = 0x8000U | (type & 0x3fU),
        .data0 = data0,
        .data1 = data1,
    };
    dispatch_async(queue, ^{
        handler(controller, message);
    });
    if (!fake_usb_bridge_wait(pending->command_done, timeout_ms)) {
        logf_("[vmmhook] USB bridge command 0x%x timed out", type);
        __atomic_store_n(&fake_usb_bridge_command_pending, NULL,
                         __ATOMIC_RELEASE);
        pthread_mutex_unlock(&fake_usb_bridge_command_lock);
        return ETIMEDOUT;
    }
    __atomic_store_n(&fake_usb_bridge_command_pending, NULL,
                     __ATOMIC_RELEASE);
    int result = pending->command_status == 1 ? 0 : EIO;
    pthread_mutex_unlock(&fake_usb_bridge_command_lock);
    return result;
}

static int fake_usb_bridge_reset_ep0(uint32_t timeout_ms) {
    fake_usb_bridge_pending_t pending = {
        .command_done = dispatch_semaphore_create(0),
        .transfer_done = dispatch_semaphore_create(0),
    };
    int result = fake_usb_bridge_command(
        0x2d, fake_usb_host_device_address, 1, &pending, timeout_ms);
    logf_("[vmmhook] USB bridge reset endpoint 0 address=%u -> %d",
          fake_usb_host_device_address, result);
    fake_usb_bridge_pending_destroy(&pending);
    return result;
}

static int fake_usb_bridge_control(
    const struct vz_usb_bridge_request *request, uint8_t *payload,
    uint32_t *actual_length) {
    bool input = (request->request_type & 0x80U) != 0;
    if (!input && request->payload_length != request->length)
        return EINVAL;

    usb_hci_message_t *ring = NULL;
    uint8_t *transfer_buffer = NULL;
    if (posix_memalign((void **)&ring, 16, 4 * sizeof(*ring)) != 0)
        return ENOMEM;
    memset(ring, 0, 4 * sizeof(*ring));
    if (request->length &&
        posix_memalign((void **)&transfer_buffer, 16,
                       request->length) != 0) {
        free(ring);
        return ENOMEM;
    }
    if (!input && request->length)
        memcpy(transfer_buffer, payload, request->length);

    ring[0].control = 0x8038;
    ring[0].data1 =
        (uint64_t)request->request_type |
        ((uint64_t)request->request << 8) |
        ((uint64_t)request->value << 16) |
        ((uint64_t)request->index << 32) |
        ((uint64_t)request->length << 48);
    usb_hci_message_t *terminal = NULL;
    if (request->length) {
        ring[1].control = 0x8039;
        ring[1].data0 = request->length;
        ring[1].data1 = (uintptr_t)transfer_buffer;
        ring[2].control = 0x803a;
        ring[3].control = 0x403c;
        terminal = &ring[2];
    } else {
        ring[1].control = 0x803a;
        ring[2].control = 0x403c;
        terminal = &ring[1];
    }

    fake_usb_bridge_pending_t pending = {
        .command_done = dispatch_semaphore_create(0),
        .transfer_done = dispatch_semaphore_create(0),
        .terminal = terminal,
        .transfer_status = -1,
    };
    usb_hci_message_t *previous_tail = fake_usb_bridge_tail;
    usb_hci_message_t *previous_ring = fake_usb_bridge_retained_ring;
    int result = 0;
    if (!previous_tail) {
        // ResetEndpoint invalidates the controller's saved dequeue pointer.
        // Hand the AVP backend a new ring exactly as IOUSBHost does before
        // ringing the endpoint doorbell again.
        result = fake_usb_bridge_command(
            0x2e, fake_usb_host_device_address, (uintptr_t)ring, &pending,
            request->timeout_ms);
    }
    if (!result) {
        __atomic_store_n(&fake_usb_bridge_transfer_pending[0], &pending,
                         __ATOMIC_RELEASE);
        uint32_t doorbell = fake_usb_host_device_address;
        usb_hci_doorbell_handler_t handler = fake_usb_host_doorbell_handler;
        id controller = fake_usb_host_controller;
        dispatch_queue_t queue = fake_usb_host_queue;
        dispatch_async(queue, ^{
            // IOUSBHost owns a persistent ring per endpoint.  Appending is
            // performed by filling the previous InvalidTransfer link and
            // handing ownership to AVP; EndpointSetNextTransfer is only valid
            // for the first ring and returns InvalidState thereafter.
            if (previous_tail) {
                previous_tail->data1 = (uintptr_t)ring;
                __atomic_thread_fence(__ATOMIC_RELEASE);
                previous_tail->control = 0xc03c;
            }
            handler(controller, &doorbell, 1);
        });
        if (!fake_usb_bridge_wait(pending.transfer_done,
                                  request->timeout_ms)) {
            logf_("[vmmhook] USB bridge control request 0x%02x timed out",
                  request->request);
            result = ETIMEDOUT;
        } else if (pending.transfer_status != 1) {
            result = EIO;
        }
        if (!result) {
            fake_usb_bridge_tail = request->length ? &ring[3] : &ring[2];
            fake_usb_bridge_retained_ring = ring;
        } else {
            // A STALL halts endpoint 0 in the real AVP device. Native
            // IOUSBHost clears it before the next DeviceRequest; without
            // that command all subsequent transfers merely time out.
            fake_usb_bridge_tail = NULL;
            fake_usb_bridge_retained_ring = NULL;
        }
        if (previous_ring)
            free(previous_ring);
    }
    __atomic_store_n(&fake_usb_bridge_transfer_pending[0], NULL,
                     __ATOMIC_RELEASE);
    if (result && fake_usb_host_device_address)
        fake_usb_bridge_reset_ep0(request->timeout_ms);
    if (!result) {
        *actual_length = request->length
            ? pending.actual_length : 0;
        if (input && *actual_length)
            memcpy(payload, transfer_buffer, *actual_length);
    }
    free(transfer_buffer);
    if (!fake_usb_bridge_retained_ring ||
        fake_usb_bridge_retained_ring != ring)
        free(ring);
    fake_usb_bridge_pending_destroy(&pending);
    return result;
}

static int fake_usb_bridge_bulk(
    const struct vz_usb_bridge_request *request, uint8_t *payload,
    uint32_t *actual_length) {
    uint8_t endpoint = request->endpoint;
    bool input = (endpoint & 0x80U) != 0;
    uint32_t length = request->transfer_length;
    if (!endpoint || !fake_usb_bridge_endpoints[endpoint] ||
        length > VZ_USB_BRIDGE_MAX_PAYLOAD ||
        (!input && request->payload_length != length) ||
        (input && request->payload_length != 0))
        return EINVAL;

    static const uint8_t mux_greeting[20] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x00, 0x00, 0x00,
    };
    pthread_mutex_lock(&fake_usb_bridge_mux_cache_lock);
    bool cached_generation =
        fake_usb_bridge_mux_generation == fake_usb_device_generation;
    if (input && endpoint == 0x81 && cached_generation &&
        fake_usb_bridge_mux_reply_length) {
        uint32_t cached_length = fake_usb_bridge_mux_reply_length;
        if (cached_length > length) {
            pthread_mutex_unlock(&fake_usb_bridge_mux_cache_lock);
            return EOVERFLOW;
        }
        memcpy(payload, fake_usb_bridge_mux_reply, cached_length);
        fake_usb_bridge_mux_reply_length = 0;
        *actual_length = cached_length;
        pthread_mutex_unlock(&fake_usb_bridge_mux_cache_lock);
        logf_("[vmmhook] USB bridge replayed cached USBMux reply "
              "generation=%u length=%u", fake_usb_device_generation,
              cached_length);
        return 0;
    }
    bool suppress = false;
    if (!input && endpoint == 0x01 && cached_generation) {
        if (fake_usb_bridge_mux_suppress_writes == 2 && length == 0) {
            fake_usb_bridge_mux_suppress_writes = 1;
            suppress = true;
        } else if (fake_usb_bridge_mux_suppress_writes == 1 &&
                   length == sizeof(mux_greeting) &&
                   memcmp(payload, mux_greeting, sizeof(mux_greeting)) == 0) {
            fake_usb_bridge_mux_suppress_writes = 0;
            suppress = true;
        }
    }
    pthread_mutex_unlock(&fake_usb_bridge_mux_cache_lock);
    if (suppress) {
        *actual_length = length;
        logf_("[vmmhook] USB bridge suppressed replayed USBMux write "
              "generation=%u length=%u", fake_usb_device_generation,
              length);
        return 0;
    }

    usb_hci_message_t *ring = NULL;
    uint8_t *transfer_buffer = NULL;
    if (posix_memalign((void **)&ring, 16, 2 * sizeof(*ring)) != 0)
        return ENOMEM;
    memset(ring, 0, 2 * sizeof(*ring));
    if (posix_memalign((void **)&transfer_buffer, 16, length ?: 1) != 0) {
        free(ring);
        return ENOMEM;
    }
    if (!input && length)
        memcpy(transfer_buffer, payload, length);

    if (!input && length <= 64 && fake_usb_trace_enabled()) {
        char bytes[3 * 64 + 1] = {0};
        size_t offset = 0;
        for (uint32_t index = 0; index < length; index++) {
            int written = snprintf(bytes + offset, sizeof(bytes) - offset,
                                   "%02x%s", transfer_buffer[index],
                                   index + 1 == length ? "" : " ");
            if (written < 0)
                break;
            offset += (size_t)written;
        }
        logf_("[vmmhook] USB bridge bulk OUT endpoint=0x%02x "
              "length=%u bytes=%s", endpoint, length, bytes);
    }

    ring[0].control = 0x8039;
    ring[0].data0 = length;
    ring[0].data1 = (uintptr_t)transfer_buffer;
    ring[1].control = 0x403c;

    fake_usb_bridge_pending_t pending = {
        .command_done = dispatch_semaphore_create(0),
        .transfer_done = dispatch_semaphore_create(0),
        .terminal = &ring[0],
        .transfer_status = -1,
    };
    usb_hci_message_t *previous_tail =
        fake_usb_bridge_bulk_tails[endpoint];
    usb_hci_message_t *previous_ring =
        fake_usb_bridge_bulk_rings[endpoint];
    uint32_t endpoint_key = ((uint32_t)endpoint << 8) |
                            fake_usb_host_device_address;
    int result = 0;
    if (!previous_tail) {
        result = fake_usb_bridge_command(
            0x2e, endpoint_key, (uintptr_t)ring, &pending,
            request->timeout_ms);
    }
    if (!result) {
        __atomic_store_n(&fake_usb_bridge_transfer_pending[endpoint],
                         &pending, __ATOMIC_RELEASE);
        usb_hci_doorbell_handler_t handler = fake_usb_host_doorbell_handler;
        id controller = fake_usb_host_controller;
        dispatch_queue_t queue = fake_usb_host_queue;
        dispatch_async(queue, ^{
            if (previous_tail) {
                previous_tail->data1 = (uintptr_t)ring;
                __atomic_thread_fence(__ATOMIC_RELEASE);
                previous_tail->control = 0xc03c;
            }
            handler(controller, &endpoint_key, 1);
        });
        if (!fake_usb_bridge_wait(pending.transfer_done,
                                  request->timeout_ms)) {
            logf_("[vmmhook] USB bridge bulk endpoint=0x%02x timed out",
                  endpoint);
            result = ETIMEDOUT;
        } else if (pending.transfer_status != 1) {
            result = EIO;
        }
        if (!result) {
            fake_usb_bridge_bulk_tails[endpoint] = &ring[1];
            fake_usb_bridge_bulk_rings[endpoint] = ring;
        } else {
            fake_usb_bridge_bulk_tails[endpoint] = NULL;
            fake_usb_bridge_bulk_rings[endpoint] = NULL;
        }
        if (previous_ring)
            free(previous_ring);
    }
    __atomic_store_n(&fake_usb_bridge_transfer_pending[endpoint], NULL,
                     __ATOMIC_RELEASE);
    if (result) {
        fake_usb_bridge_pending_t reset_pending = {
            .command_done = dispatch_semaphore_create(0),
            .transfer_done = dispatch_semaphore_create(0),
        };
        fake_usb_bridge_command(0x2d, endpoint_key, 1, &reset_pending,
                                request->timeout_ms);
        fake_usb_bridge_pending_destroy(&reset_pending);
    } else {
        *actual_length = input ? pending.actual_length : length;
        if (*actual_length > length) {
            logf_("[vmmhook] USB bridge bulk endpoint=0x%02x returned "
                  "oversize transfer %u > %u", endpoint, *actual_length,
                  length);
            result = EOVERFLOW;
            *actual_length = 0;
        } else if (input && *actual_length) {
            memcpy(payload, transfer_buffer, *actual_length);
            if (*actual_length <= 64 && fake_usb_trace_enabled()) {
                char bytes[3 * 64 + 1] = {0};
                size_t offset = 0;
                for (uint32_t index = 0; index < *actual_length; index++) {
                    int written = snprintf(
                        bytes + offset, sizeof(bytes) - offset, "%02x%s",
                        transfer_buffer[index],
                        index + 1 == *actual_length ? "" : " ");
                    if (written < 0)
                        break;
                    offset += (size_t)written;
                }
                logf_("[vmmhook] USB bridge bulk IN endpoint=0x%02x "
                      "length=%u bytes=%s", endpoint, *actual_length,
                      bytes);
            }
        }
    }
    free(transfer_buffer);
    if (fake_usb_bridge_bulk_rings[endpoint] != ring)
        free(ring);
    if (result || fake_usb_trace_enabled())
        logf_("[vmmhook] USB bridge bulk endpoint=0x%02x length=%u -> %d "
              "actual=%u", endpoint, length, result,
              result ? 0 : *actual_length);
    fake_usb_bridge_pending_destroy(&pending);
    return result;
}

static void fake_usb_bridge_drop_personality(void) {
    usb_hci_message_t *retained_ring = fake_usb_bridge_retained_ring;
    fake_usb_bridge_tail = NULL;
    fake_usb_bridge_retained_ring = NULL;
    if (retained_ring)
        free(retained_ring);
    for (unsigned endpoint = 0; endpoint < 256; endpoint++) {
        if (fake_usb_bridge_bulk_rings[endpoint])
            free(fake_usb_bridge_bulk_rings[endpoint]);
        fake_usb_bridge_bulk_rings[endpoint] = NULL;
        fake_usb_bridge_bulk_tails[endpoint] = NULL;
    }
    fake_usb_host_device_address = 0;
    memset(fake_usb_bridge_endpoints, 0,
           sizeof(fake_usb_bridge_endpoints));
    memset(fake_usb_bridge_endpoint_descriptors, 0,
           sizeof(fake_usb_bridge_endpoint_descriptors));
    pthread_mutex_lock(&fake_usb_bridge_mux_cache_lock);
    fake_usb_bridge_mux_reply_length = 0;
    fake_usb_bridge_mux_generation = 0;
    fake_usb_bridge_mux_suppress_writes = 0;
    pthread_mutex_unlock(&fake_usb_bridge_mux_cache_lock);
    fake_usb_descriptor_retry_count = 0;
    __atomic_add_fetch(&fake_usb_device_generation, 1, __ATOMIC_ACQ_REL);
}

static void fake_usb_bridge_prime_restoreos_mux(uint32_t generation) {
    static const uint8_t greeting[20] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x00, 0x00, 0x00,
    };
    __block struct {
        struct vz_usb_bridge_request request;
        uint8_t payload[32768];
        uint32_t actual;
        int result;
    } input = {
        .request = {
            .endpoint = 0x81,
            .transfer_length = 32768,
            .timeout_ms = 5000,
        },
    };
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(
                                   QOS_CLASS_USER_INITIATED, 0), ^{
        input.result = fake_usb_bridge_bulk(&input.request, input.payload,
                                            &input.actual);
    });
    usleep(20000);

    struct vz_usb_bridge_request output = {
        .endpoint = 0x01,
        .timeout_ms = 5000,
    };
    uint32_t actual = 0;
    int result = fake_usb_bridge_bulk(&output, NULL, &actual);
    output.payload_length = sizeof(greeting);
    output.transfer_length = sizeof(greeting);
    if (!result)
        result = fake_usb_bridge_bulk(&output, (uint8_t *)greeting,
                                      &actual);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    if (!result)
        result = input.result;
    if (result || generation != fake_usb_device_generation ||
        !input.actual || input.actual > sizeof(fake_usb_bridge_mux_reply)) {
        logf_("[vmmhook] RestoreOS USBMux handshake failed "
              "generation=%u output=%d input=%d actual=%u",
              generation, result, input.result, input.actual);
        return;
    }

    pthread_mutex_lock(&fake_usb_bridge_mux_cache_lock);
    memcpy(fake_usb_bridge_mux_reply, input.payload, input.actual);
    fake_usb_bridge_mux_reply_length = input.actual;
    fake_usb_bridge_mux_generation = generation;
    fake_usb_bridge_mux_suppress_writes = 2;
    pthread_mutex_unlock(&fake_usb_bridge_mux_cache_lock);
    logf_("[vmmhook] RestoreOS USBMux handshake cached generation=%u "
          "length=%u", generation, input.actual);
}

static int fake_usb_bridge_reset(uint32_t timeout_ms) {
    fake_usb_bridge_pending_t pending = {
        .command_done = dispatch_semaphore_create(0),
        .transfer_done = dispatch_semaphore_create(0),
    };
    int result = fake_usb_bridge_command(0x1c, 1, 0, &pending,
                                         timeout_ms);
    fake_usb_bridge_pending_destroy(&pending);
    if (result)
        return result;

    // USBDeviceReEnumerate asks the host controller to reset the actual
    // restore device.  The personalized iBSS then disconnects/reconnects as a
    // new USB personality.  Drop only our userspace EP0 ring and run the same
    // AVP port-status/enumeration sequence used for initial DFU discovery.
    fake_usb_bridge_drop_personality();
    fake_usb_host_send_after(fake_usb_host_controller,
                             FakeUSBHostStagePortStatus, 0x1e, 1, 0,
                             500 * NSEC_PER_MSEC);
    logf_("[vmmhook] USB bridge reset real device; awaiting next "
          "personality generation=%u", fake_usb_device_generation);
    return 0;
}

static int fake_usb_bridge_create_endpoint(const uint8_t *descriptor,
                                           uint32_t length,
                                           uint32_t timeout_ms) {
    if (!descriptor || length < 7 || descriptor[0] < 7 ||
        descriptor[1] != 5 || !fake_usb_host_device_address)
        return EINVAL;
    uint8_t endpoint = descriptor[2];
    if (!endpoint)
        return EINVAL;
    if (fake_usb_bridge_endpoints[endpoint])
        return 0;
    fake_usb_bridge_pending_t pending = {
        .command_done = dispatch_semaphore_create(0),
        .transfer_done = dispatch_semaphore_create(0),
    };
    uint8_t *endpoint_descriptor =
        fake_usb_bridge_endpoint_descriptors[endpoint];
    memcpy(endpoint_descriptor, descriptor,
           sizeof(fake_usb_bridge_endpoint_descriptors[endpoint]));
    uint32_t endpoint_key = ((uint32_t)endpoint << 8) |
                            fake_usb_host_device_address;
    int result = fake_usb_bridge_command(
        0x28, endpoint_key, (uintptr_t)endpoint_descriptor, &pending,
        timeout_ms);
    if (!result)
        fake_usb_bridge_endpoints[endpoint] = true;
    logf_("[vmmhook] USB bridge create endpoint=0x%02x address=%u "
          "max-packet=%u -> %d", endpoint, fake_usb_host_device_address,
          (unsigned)endpoint_descriptor[4] |
              ((unsigned)endpoint_descriptor[5] << 8), result);
    fake_usb_bridge_pending_destroy(&pending);
    return result;
}

static int fake_usb_bridge_control_simple(uint8_t request_type,
                                          uint8_t request,
                                          uint16_t value,
                                          uint16_t index,
                                          uint8_t *payload,
                                          uint32_t length,
                                          uint32_t *actual_length) {
    struct vz_usb_bridge_request bridge_request = {
        .request_type = request_type,
        .request = request,
        .value = value,
        .index = index,
        .length = length,
        .payload_length = (request_type & 0x80U) ? 0 : length,
        .timeout_ms = 5000,
    };
    return fake_usb_bridge_control(&bridge_request, payload, actual_length);
}

static void fake_usb_bridge_prepare_restoreos(uint32_t generation) {
    // RestoreOS disconnects after only a few seconds if the host leaves its
    // USB device unconfigured.  Native IOUSBHost configures it before
    // usbmuxd publishes the attachment.  Do that time-critical part here;
    // MobileDevice still owns the subsequent USBMux/restore protocol.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pthread_mutex_lock(&fake_usb_bridge_lock);
        if (generation != fake_usb_device_generation ||
            fake_usb_descriptor_u16(10) != 0x12ac ||
            __atomic_load_n(&fake_usb_host_stage, __ATOMIC_ACQUIRE) !=
                FakeUSBHostStageDeviceDescriptorRead) {
            pthread_mutex_unlock(&fake_usb_bridge_lock);
            return;
        }

        uint8_t configuration[4096] = {0};
        uint32_t actual = 0;
        int result = fake_usb_bridge_control_simple(
            0x80, 0x06, 0x0200, 0, configuration, 9, &actual);
        if (result || actual < 9) {
            logf_("[vmmhook] RestoreOS configuration header failed -> %d "
                  "actual=%u", result, actual);
            pthread_mutex_unlock(&fake_usb_bridge_lock);
            return;
        }
        uint32_t total = (uint32_t)configuration[2] |
                         ((uint32_t)configuration[3] << 8);
        if (total < 9 || total > sizeof(configuration)) {
            logf_("[vmmhook] RestoreOS invalid configuration length=%u",
                  total);
            pthread_mutex_unlock(&fake_usb_bridge_lock);
            return;
        }
        memset(configuration, 0, total);
        result = fake_usb_bridge_control_simple(
            0x80, 0x06, 0x0200, 0, configuration, total, &actual);
        if (result || actual < total) {
            logf_("[vmmhook] RestoreOS configuration read failed -> %d "
                  "actual=%u expected=%u", result, actual, total);
            pthread_mutex_unlock(&fake_usb_bridge_lock);
            return;
        }
        char bytes[3 * sizeof(configuration) + 1] = {0};
        size_t text_offset = 0;
        for (uint32_t offset = 0; offset < total; offset++) {
            int written = snprintf(bytes + text_offset,
                                   sizeof(bytes) - text_offset,
                                   "%02x%s", configuration[offset],
                                   offset + 1 == total ? "" : " ");
            if (written < 0)
                break;
            text_offset += (size_t)written;
        }
        logf_("[vmmhook] RestoreOS configuration generation=%u length=%u: "
              "%s", generation, total, bytes);

        uint8_t configuration_value = configuration[5];
        actual = 0;
        result = fake_usb_bridge_control_simple(
            0x00, 0x09, configuration_value, 0, NULL, 0, &actual);
        if (result) {
            logf_("[vmmhook] RestoreOS set configuration %u failed -> %d",
                  configuration_value, result);
            pthread_mutex_unlock(&fake_usb_bridge_lock);
            return;
        }

        bool active_interface = false;
        for (uint32_t offset = 0; offset + 2 <= total;) {
            uint8_t descriptor_length = configuration[offset];
            uint8_t descriptor_type = configuration[offset + 1];
            if (descriptor_length < 2 || offset + descriptor_length > total)
                break;
            if (descriptor_type == 4 && descriptor_length >= 9)
                active_interface = configuration[offset + 3] == 0;
            else if (descriptor_type == 5 && descriptor_length >= 7 &&
                     active_interface) {
                result = fake_usb_bridge_create_endpoint(
                    configuration + offset, descriptor_length, 5000);
                if (result)
                    break;
            }
            offset += descriptor_length;
        }
        logf_("[vmmhook] RestoreOS USB configured generation=%u value=%u "
              "endpoints-in=0x%02x endpoints-out=0x%02x -> %d",
              generation, configuration_value,
              fake_usb_bridge_endpoints[0x81] ? 0x81 : 0,
              fake_usb_bridge_endpoints[0x02] ? 0x02 : 0, result);
        pthread_mutex_unlock(&fake_usb_bridge_lock);
        if (!result)
            fake_usb_bridge_prime_restoreos_mux(generation);
    });
}

static void fake_usb_bridge_handle_client(int client) {
    struct vz_usb_bridge_request request = {0};
    if (!fake_usb_read_full(client, &request, sizeof(request)) ||
        request.magic != VZ_USB_BRIDGE_MAGIC ||
        request.version != VZ_USB_BRIDGE_VERSION ||
        request.payload_length > VZ_USB_BRIDGE_MAX_PAYLOAD ||
        (request.operation == VZ_USB_BRIDGE_BULK &&
         request.transfer_length > VZ_USB_BRIDGE_MAX_PAYLOAD))
        return;

    uint32_t payload_capacity = request.payload_length;
    if (request.operation == VZ_USB_BRIDGE_BULK &&
        (request.endpoint & 0x80U) &&
        request.transfer_length > payload_capacity)
        payload_capacity = request.transfer_length;
    else if ((request.request_type & 0x80U) &&
             request.length > payload_capacity)
        payload_capacity = request.length;
    uint8_t *payload = payload_capacity ? malloc(payload_capacity) : NULL;
    if (payload_capacity && !payload)
        return;
    if (request.payload_length) {
        if (!fake_usb_read_full(client, payload, request.payload_length)) {
            free(payload);
            return;
        }
    }

    struct vz_usb_bridge_response response = {
        .magic = VZ_USB_BRIDGE_MAGIC,
        .device_generation = fake_usb_device_generation,
        .vendor_id = fake_usb_descriptor_u16(8),
        .product_id = fake_usb_descriptor_u16(10),
        .device_address = fake_usb_host_device_address,
        .ready = __atomic_load_n(&fake_usb_host_stage, __ATOMIC_ACQUIRE) ==
                 FakeUSBHostStageDeviceDescriptorRead,
    };
    pthread_mutex_t *operation_lock = &fake_usb_bridge_lock;
    if (request.operation == VZ_USB_BRIDGE_BULK) {
        operation_lock = (request.endpoint & 0x80U)
            ? &fake_usb_bridge_bulk_input_lock
            : &fake_usb_bridge_bulk_output_lock;
    }
    pthread_mutex_lock(operation_lock);
    if (request.operation == VZ_USB_BRIDGE_GET_STATE) {
        response.status = response.ready ? 0 : ENODEV;
    } else if (request.operation == VZ_USB_BRIDGE_CONTROL && response.ready) {
        uint32_t actual = 0;
        response.status = fake_usb_bridge_control(&request, payload, &actual);
        response.payload_length =
            (request.request_type & 0x80U) ? actual : 0;
        logf_("[vmmhook] USB bridge control type=0x%02x request=0x%02x "
              "value=0x%04x index=0x%04x length=%u -> %d actual=%u",
              request.request_type, request.request, request.value,
              request.index, request.length, response.status, actual);
    } else if (request.operation == VZ_USB_BRIDGE_RESET && response.ready) {
        response.status = fake_usb_bridge_reset(request.timeout_ms);
        response.ready = 0;
        response.device_generation = fake_usb_device_generation;
        logf_("[vmmhook] USB bridge re-enumerate -> %d generation=%u",
              response.status, response.device_generation);
    } else if (request.operation == VZ_USB_BRIDGE_CREATE_ENDPOINT &&
               response.ready) {
        response.status = fake_usb_bridge_create_endpoint(
            payload, request.payload_length, request.timeout_ms);
    } else if (request.operation == VZ_USB_BRIDGE_BULK && response.ready) {
        uint32_t actual = 0;
        response.status = fake_usb_bridge_bulk(&request, payload, &actual);
        response.payload_length = (request.endpoint & 0x80U) ? actual : 0;
    } else {
        response.status = response.ready ? ENOTSUP : ENODEV;
    }
    pthread_mutex_unlock(operation_lock);

    if (fake_usb_write_full(client, &response, sizeof(response)) &&
        response.payload_length)
        fake_usb_write_full(client, payload, response.payload_length);
    free(payload);
}

static void fake_usb_bridge_start(void) {
    if (__atomic_exchange_n(&fake_usb_bridge_started, true,
                            __ATOMIC_ACQ_REL))
        return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unlink(VZ_USB_BRIDGE_SOCKET);
        int server = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server < 0) {
            logf_("[vmmhook] USB bridge socket failed: %s", strerror(errno));
            return;
        }
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        strlcpy(address.sun_path, VZ_USB_BRIDGE_SOCKET,
                sizeof(address.sun_path));
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0 ||
            chmod(VZ_USB_BRIDGE_SOCKET, 0666) < 0 ||
            listen(server, SOMAXCONN) < 0) {
            logf_("[vmmhook] USB bridge listen failed: %s", strerror(errno));
            close(server);
            return;
        }
        logf_("[vmmhook] USB bridge ready at %s", VZ_USB_BRIDGE_SOCKET);
        for (;;) {
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }
            dispatch_async(dispatch_get_global_queue(
                               QOS_CLASS_USER_INITIATED, 0), ^{
                fake_usb_bridge_handle_client(client);
                close(client);
            });
        }
        close(server);
        unlink(VZ_USB_BRIDGE_SOCKET);
    });
}

static void fake_usb_host_poll_port(id controller) {
    id retained_controller = controller;
    dispatch_queue_t queue = fake_usb_host_queue;
    if (!queue)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, ^{
        int stage = __atomic_load_n(&fake_usb_host_stage, __ATOMIC_ACQUIRE);
        if (stage == FakeUSBHostStageWaitForConnect) {
            fake_usb_host_send(retained_controller,
                               FakeUSBHostStagePortStatus, 0x1e, 1, 0);
        }
    });
}

static void fake_usb_host_process_interrupt(id controller,
                                            const usb_hci_message_t *message) {
    uint32_t type = message->control & 0x3fU;
    uint32_t status = (message->control >> 8) & 0xfU;
    int stage = __atomic_load_n(&fake_usb_host_stage, __ATOMIC_ACQUIRE);
    fake_usb_bridge_pending_t *command_pending = __atomic_load_n(
        &fake_usb_bridge_command_pending, __ATOMIC_ACQUIRE);

    if (command_pending && type == command_pending->command_type) {
        command_pending->command_status = (int)status;
        dispatch_semaphore_signal(command_pending->command_done);
        return;
    }

    if (type == 0x08) {
        logf_("[vmmhook] fake USB port event port=%u stage=%s",
              message->data0 & 0xfU, fake_usb_host_stage_name(stage));
        if (stage == FakeUSBHostStageDeviceDescriptorRead) {
            // iBoot's `go` disconnects Recovery and later reconnects as the
            // RestoreOS USB personality.  This port-change is not initiated
            // by USBDeviceReEnumerate, so begin a fresh enumeration here and
            // publish a new generation to the IOUSBLib façade.
            fake_usb_bridge_drop_personality();
            fake_usb_host_send(controller, FakeUSBHostStagePortStatus,
                               0x1e, message->data0 & 0xfU, 0);
        } else if (stage >= FakeUSBHostStagePortPowerOn &&
            stage <= FakeUSBHostStageWaitForConnect) {
            fake_usb_host_send(controller, FakeUSBHostStagePortStatus,
                               0x1e, message->data0 & 0xfU, 0);
        }
        return;
    }

    if (type < 0x10 || type > 0x37)
        goto transfer_interrupt;
    if (status != 1) {
        logf_("[vmmhook] fake USB command failed stage=%s type=0x%02x "
              "status=0x%x", fake_usb_host_stage_name(stage), type,
              status);
        __atomic_store_n(&fake_usb_host_stage, FakeUSBHostStageFailed,
                         __ATOMIC_RELEASE);
        return;
    }

    switch (type) {
    case 0x10:
        if (stage == FakeUSBHostStageControllerPowerOn)
            fake_usb_host_send(controller, FakeUSBHostStageControllerStart,
                               0x12, 0, 0);
        break;
    case 0x12:
        if (stage == FakeUSBHostStageControllerStart)
            fake_usb_host_send(controller, FakeUSBHostStagePortPowerOn,
                               0x18, 1, 0);
        break;
    case 0x18:
        if (stage == FakeUSBHostStagePortPowerOn)
            fake_usb_host_send(controller, FakeUSBHostStagePortStatus,
                               0x1e, 1, 0);
        break;
    case 0x1e:
        if (stage == FakeUSBHostStagePortStatus) {
            bool connected = (message->data1 & (1ULL << 2)) != 0;
            unsigned speed = (unsigned)((message->data1 >> 8) & 0x7U);
            logf_("[vmmhook] fake USB port status=0x%016llx "
                  "connected=%d speed=%u",
                  (unsigned long long)message->data1, connected, speed);
            if (connected) {
                fake_usb_host_send(controller, FakeUSBHostStagePortReset,
                                   0x1c, 1, 0);
            } else {
                __atomic_store_n(&fake_usb_host_stage,
                                 FakeUSBHostStageWaitForConnect,
                                 __ATOMIC_RELEASE);
                fake_usb_host_poll_port(controller);
            }
        }
        break;
    case 0x1c:
        if (stage == FakeUSBHostStagePortReset)
            fake_usb_host_send(controller, FakeUSBHostStageDeviceCreate,
                               0x20, 1, 0);
        break;
    case 0x20:
        if (stage == FakeUSBHostStageDeviceCreate) {
            fake_usb_host_device_address = (uint8_t)(message->data1 & 0xffU);
            logf_("[vmmhook] fake USB device created address=%u",
                  fake_usb_host_device_address);
            fake_usb_host_send(
                controller, FakeUSBHostStageEndpointCreate, 0x28,
                fake_usb_host_device_address,
                (uintptr_t)fake_usb_ep0_descriptor);
        }
        break;
    case 0x28:
        if (stage == FakeUSBHostStageEndpointCreate) {
            fake_usb_host_prepare_device_descriptor_transfer();
            fake_usb_host_send(
                controller, FakeUSBHostStageEndpointSetNextTransfer, 0x2e,
                fake_usb_host_device_address,
                (uintptr_t)fake_usb_device_descriptor_transfer);
        }
        break;
    case 0x2d:
        if (stage == FakeUSBHostStageEndpointReset) {
            fake_usb_host_send(
                controller, FakeUSBHostStageEndpointSetNextTransfer, 0x2e,
                fake_usb_host_device_address,
                (uintptr_t)fake_usb_device_descriptor_transfer);
        }
        break;
    case 0x2e:
        if (stage == FakeUSBHostStageEndpointSetNextTransfer)
            fake_usb_host_ring_ep0_doorbell(controller);
        break;
    default:
        break;
    }
    return;

transfer_interrupt:
    if (type == 0x3d) {
        uint8_t address = (uint8_t)((message->control >> 16) & 0xffU);
        uint8_t endpoint = (uint8_t)((message->control >> 24) & 0xffU);
        fake_usb_bridge_pending_t *pending = __atomic_load_n(
            &fake_usb_bridge_transfer_pending[endpoint], __ATOMIC_ACQUIRE);
        usb_hci_message_t *completed =
            (usb_hci_message_t *)(uintptr_t)message->data1;
        if (status != 1 || fake_usb_trace_enabled())
            logf_("[vmmhook] fake USB transfer complete address=%u "
                  "endpoint=0x%02x status=0x%x length=%u transfer=%p "
                  "stage=%s", address, endpoint, status,
                  message->data0 & 0x0fffffffU,
                  (void *)(uintptr_t)message->data1,
                  fake_usb_host_stage_name(stage));
        if (pending) {
            if (status != 1) {
                pending->transfer_status = (int)status;
                dispatch_semaphore_signal(pending->transfer_done);
                return;
            }
            uint32_t length = message->data0 & 0x0fffffffU;
            if (length)
                pending->actual_length = length;
            if (completed == pending->terminal) {
                pending->transfer_status = (int)status;
                dispatch_semaphore_signal(pending->transfer_done);
            }
            return;
        }
        if (stage == FakeUSBHostStageReadDeviceDescriptor &&
            completed == &fake_usb_device_descriptor_transfer[1]) {
            if (status == 1 && (message->data0 & 0x0fffffffU) == 18) {
                fake_usb_log_device_descriptor();
                __atomic_store_n(&fake_usb_host_stage,
                                 FakeUSBHostStageDeviceDescriptorRead,
                                 __ATOMIC_RELEASE);
                fake_usb_bridge_tail =
                    &fake_usb_device_descriptor_transfer[3];
                fake_usb_bridge_retained_ring = NULL;
                fake_usb_bridge_start();
                if (fake_usb_descriptor_u16(10) == 0x12ac)
                    fake_usb_bridge_prepare_restoreos(
                        fake_usb_device_generation);
            } else if (status == 0xb &&
                       fake_usb_descriptor_retry_count < 15) {
                fake_usb_descriptor_retry_count++;
                logf_("[vmmhook] fake USB descriptor stalled; "
                      "reset/retry %u in one second",
                      fake_usb_descriptor_retry_count);
                fake_usb_host_send_after(
                    controller, FakeUSBHostStageEndpointReset, 0x2d,
                    fake_usb_host_device_address, 1, NSEC_PER_SEC);
            }
        }
    }
}

static void trace_fake_usb_interrupts(id controller,
                                      const usb_hci_message_t *messages,
                                      uintptr_t count, bool expedite) {
    if (!messages)
        return;
    for (uintptr_t index = 0; index < count; index++) {
        const usb_hci_message_t *message = &messages[index];
        uint64_t sequence = __atomic_add_fetch(
            &fake_usb_hci_interrupt_count, 1, __ATOMIC_RELAXED);
        if (fake_usb_trace_enabled())
            logf_("[vmmhook] fake USB interrupt #%llu index=%llu/%llu "
                  "expedite=%d control=0x%08x type=0x%02x status=0x%x "
                  "data0=0x%08x data1=0x%016llx",
                  (unsigned long long)sequence,
                  (unsigned long long)(index + 1),
                  (unsigned long long)count, expedite,
                  message->control, message->control & 0x3f,
                  (message->control >> 8) & 0xf, message->data0,
                  (unsigned long long)message->data1);
        fake_usb_host_process_interrupt(controller, message);
    }
}

static bool fake_usb_hci_enqueue_one(id self, SEL command,
                                     const void *interrupt, id *error) {
    if (!is_fake_usb_hci(self))
        return original_usb_hci_enqueue_one(self, command, interrupt, error);
    if (error)
        *error = nil;
    trace_fake_usb_interrupts(self, interrupt, 1, false);
    return true;
}

static bool fake_usb_hci_enqueue_one_expedite(id self, SEL command,
                                              const void *interrupt,
                                              bool expedite, id *error) {
    if (!is_fake_usb_hci(self)) {
        return original_usb_hci_enqueue_one_expedite(
            self, command, interrupt, expedite, error);
    }
    if (error)
        *error = nil;
    trace_fake_usb_interrupts(self, interrupt, 1, expedite);
    return true;
}

static bool fake_usb_hci_enqueue_many(id self, SEL command,
                                      const void *interrupts,
                                      uintptr_t count, id *error) {
    if (!is_fake_usb_hci(self)) {
        return original_usb_hci_enqueue_many(
            self, command, interrupts, count, error);
    }
    if (error)
        *error = nil;
    trace_fake_usb_interrupts(self, interrupts, count, false);
    return true;
}

static bool fake_usb_hci_enqueue_many_expedite(id self, SEL command,
                                               const void *interrupts,
                                               uintptr_t count,
                                               bool expedite, id *error) {
    if (!is_fake_usb_hci(self)) {
        return original_usb_hci_enqueue_many_expedite(
            self, command, interrupts, count, expedite, error);
    }
    if (error)
        *error = nil;
    trace_fake_usb_interrupts(self, interrupts, count, expedite);
    return true;
}

static void fake_usb_hci_destroy(id self, SEL command) {
    if (!is_fake_usb_hci(self)) {
        original_usb_hci_destroy(self, command);
        return;
    }
    logf_("[vmmhook] fake IOUSBHostControllerInterface destroy");
}

static id send_object(id object, const char *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static const char *object_utf8(id object) {
    id description = object ? send_object(object, "description") : nil;
    return description
        ? ((const char *(*)(id, SEL))objc_msgSend)(
              description, sel_registerName("UTF8String"))
        : "(none)";
}

static id traced_usb_hci_init(id self, SEL command, id capabilities, id queue,
                              uint64_t interrupt_rate_hz, id *error,
                              id command_handler, id doorbell_handler,
                              id interest_handler) {
    if (fake_usb_hci_enabled()) {
        self = ((id (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("init"));
        if (!self) {
            logf_("[vmmhook] fake USB NSObject initialization failed");
            return nil;
        }
        objc_setAssociatedObject(self, &fake_usb_hci_marker_key, self,
                                 OBJC_ASSOCIATION_ASSIGN);
        if (doorbell_handler) {
            objc_setAssociatedObject(self, &fake_usb_hci_doorbell_handler_key,
                                     doorbell_handler,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        dispatch_queue_t host_queue = (dispatch_queue_t)queue;
        if (!host_queue) {
            host_queue = dispatch_queue_create(
                "org.jb.vmmservice.fake-usb-host", DISPATCH_QUEUE_SERIAL);
        }
        if (!host_queue) {
            host_queue = dispatch_get_global_queue(
                QOS_CLASS_USER_INITIATED, 0);
        }
        fake_usb_host_controller = self;
        fake_usb_host_command_handler = command_handler
            ? (usb_hci_command_handler_t)_Block_copy(command_handler)
            : nil;
        fake_usb_host_doorbell_handler = doorbell_handler
            ? (usb_hci_doorbell_handler_t)_Block_copy(doorbell_handler)
            : nil;
        fake_usb_host_queue = host_queue;

        // Preserve the userspace half of IOUSBHostControllerInterface's real
        // initializer.  The omitted half only allocates interrupt buffers and
        // opens AppleUSBUserHCIResources in the kernel.  VMM's command path
        // relies on these state-machine ivars even when enqueueInterrupt: is
        // interposed, so returning an otherwise raw allocated object makes the
        // first ControllerPowerOn command fail validation.
        id capabilities_data = capabilities
            ? ((id (*)(id, SEL))objc_msgSend)(
                  capabilities, sel_registerName("mutableCopy"))
            : nil;
        Ivar capabilities_ivar = class_getInstanceVariable(
            object_getClass(self), "_capabilitiesData");
        if (capabilities_ivar && capabilities_data)
            object_setIvar(self, capabilities_ivar, capabilities_data);
        const void *capability_bytes = capabilities_data
            ? ((const void *(*)(id, SEL))objc_msgSend)(
                  capabilities_data, sel_registerName("bytes"))
            : NULL;
        ((void (*)(id, SEL, const void *))objc_msgSend)(
            self, sel_registerName("setCapabilities:"), capability_bytes);
        ((void (*)(id, SEL, id))objc_msgSend)(
            self, sel_registerName("setQueue:"), (id)host_queue);
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(
            self, sel_registerName("setInterruptRateHz:"),
            interrupt_rate_hz);
        ((void (*)(id, SEL, id))objc_msgSend)(
            self, sel_registerName("setCommandHandler:"), command_handler);
        ((void (*)(id, SEL, id))objc_msgSend)(
            self, sel_registerName("setDoorbellHandler:"), doorbell_handler);
        ((void (*)(id, SEL, void *))objc_msgSend)(
            self, sel_registerName("setInterestHandler:"), interest_handler);

        id controller_state_class =
            (id)objc_getClass("IOUSBHostCIControllerStateMachine");
        id controller_state = controller_state_class
            ? ((id (*)(id, SEL))objc_msgSend)(
                  controller_state_class, sel_registerName("alloc"))
            : nil;
        id state_error = nil;
        controller_state = controller_state
            ? ((id (*)(id, SEL, id, id *))objc_msgSend)(
                  controller_state,
                  sel_registerName("initWithInterface:error:"), self,
                  &state_error)
            : nil;
        if (controller_state) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                self, sel_registerName("setControllerStateMachine:"),
                controller_state);
        }
        if (error)
            *error = state_error;
        uintptr_t capability_length = capabilities
            ? ((uintptr_t (*)(id, SEL))objc_msgSend)(
                  capabilities, sel_registerName("length"))
            : 0;
        logf_("[vmmhook] faking IOUSBHostControllerInterface v3=%p "
              "capability-bytes=%llu rate=%llu queue=%p command=%p "
              "doorbell=%p interest=%p state-machine=%p error=%s",
              self, (unsigned long long)capability_length,
              (unsigned long long)interrupt_rate_hz, host_queue,
              command_handler, doorbell_handler, interest_handler,
              controller_state, object_utf8(state_error));
        if (command_handler) {
            void *usb_controller = *(void **)(
                (uint8_t *)(void *)command_handler + 0x20);
            void **backend_vtable = usb_controller
                ? *(void ***)usb_controller : NULL;
            logf_("[vmmhook] fake USB backend controller=%p vtable=%p",
                  usb_controller, backend_vtable);
            for (unsigned index = 0; backend_vtable && index < 8; index++) {
                char label[64];
                snprintf(label, sizeof(label), "fake USB backend[%u]", index);
                void *target = ptrauth_strip(
                    backend_vtable[index], ptrauth_key_function_pointer);
                log_address(label, target);
            }
        }
        if (!controller_state) {
            __atomic_store_n(&fake_usb_host_stage,
                             FakeUSBHostStageFailed, __ATOMIC_RELEASE);
            return nil;
        }
        fake_usb_host_device_address = 0;
        fake_usb_descriptor_retry_count = 0;
        fake_usb_host_send_after(self, FakeUSBHostStageControllerPowerOn,
                                 0x10, 0, 0, 100 * NSEC_PER_MSEC);
        return self;
    }
    id local_error = nil;
    id *error_out = error ? error : &local_error;
    id result = original_usb_hci_init(
        self, command, capabilities, queue, interrupt_rate_hz, error_out,
        command_handler, doorbell_handler, interest_handler);
    id actual_error = error ? *error : local_error;
    logf_("[vmmhook] IOUSBHostControllerInterface init -> %p "
          "rate=%llu error=%s",
          result, (unsigned long long)interrupt_rate_hz,
          object_utf8(actual_error));
    if (actual_error) {
        id domain = send_object(actual_error, "domain");
        long code = ((long (*)(id, SEL))objc_msgSend)(
            actual_error, sel_registerName("code"));
        id user_info = send_object(actual_error, "userInfo");
        logf_("[vmmhook] USB HCI NSError domain=%s code=%ld userInfo=%s",
              object_utf8(domain), code, object_utf8(user_info));
    }
    return result;
}

static void install_usb_hci_trace(void) {
    if (!getenv("VMMHOOK_TRACE_USB") && !fake_usb_hci_enabled())
        return;
    Class controller = objc_getClass("IOUSBHostControllerInterface");
    SEL initializer = sel_registerName(
        "initWithCapabilities:queue:interruptRateHz:error:commandHandler:"
        "doorbellHandler:interestHandler:");
    Method method = controller ? class_getInstanceMethod(controller, initializer)
                               : NULL;
    if (!method) {
        logf_("[vmmhook] USB HCI trace unavailable: class=%p method=%p",
              controller, method);
        return;
    }
    original_usb_hci_init =
        (usb_hci_init_t)method_setImplementation(method,
                                                 (IMP)traced_usb_hci_init);
    Method enqueue_one = class_getInstanceMethod(
        controller, sel_registerName("enqueueInterrupt:error:"));
    Method enqueue_one_expedite = class_getInstanceMethod(
        controller, sel_registerName("enqueueInterrupt:expedite:error:"));
    Method enqueue_many = class_getInstanceMethod(
        controller, sel_registerName("enqueueInterrupts:count:error:"));
    Method enqueue_many_expedite = class_getInstanceMethod(
        controller,
        sel_registerName("enqueueInterrupts:count:expedite:error:"));
    Method destroy = class_getInstanceMethod(controller,
                                              sel_registerName("destroy"));
    if (enqueue_one) {
        original_usb_hci_enqueue_one =
            (usb_hci_enqueue_one_t)method_setImplementation(
                enqueue_one, (IMP)fake_usb_hci_enqueue_one);
    }
    if (enqueue_one_expedite) {
        original_usb_hci_enqueue_one_expedite =
            (usb_hci_enqueue_one_expedite_t)method_setImplementation(
                enqueue_one_expedite,
                (IMP)fake_usb_hci_enqueue_one_expedite);
    }
    if (enqueue_many) {
        original_usb_hci_enqueue_many =
            (usb_hci_enqueue_many_t)method_setImplementation(
                enqueue_many, (IMP)fake_usb_hci_enqueue_many);
    }
    if (enqueue_many_expedite) {
        original_usb_hci_enqueue_many_expedite =
            (usb_hci_enqueue_many_expedite_t)method_setImplementation(
                enqueue_many_expedite,
                (IMP)fake_usb_hci_enqueue_many_expedite);
    }
    if (destroy) {
        original_usb_hci_destroy =
            (usb_hci_destroy_t)method_setImplementation(
                destroy, (IMP)fake_usb_hci_destroy);
    }
    logf_("[vmmhook] tracing IOUSBHostControllerInterface initializer "
          "types=%s original=%p fake=%d",
          method_getTypeEncoding(method), original_usb_hci_init,
          fake_usb_hci_enabled());
}

static bool trace_iokit(void) {
    return getenv("VMMHOOK_TRACE_IOKIT") != NULL;
}

static CFMutableDictionaryRef traced_IOServiceMatching(const char *name) {
    CFMutableDictionaryRef matching = IOServiceMatching(name);
    if (trace_iokit())
        logf_("[vmmhook] IOServiceMatching(%s) -> %p",
              name ? name : "(null)", matching);
    return matching;
}

static CFMutableDictionaryRef traced_IOServiceNameMatching(const char *name) {
    CFMutableDictionaryRef matching = IOServiceNameMatching(name);
    if (trace_iokit())
        logf_("[vmmhook] IOServiceNameMatching(%s) -> %p",
              name ? name : "(null)", matching);
    return matching;
}

static io_service_t traced_IOServiceGetMatchingService(
    mach_port_t main_port, CFDictionaryRef matching) {
    if (trace_iokit() && matching)
        logf_("[vmmhook] IOServiceGetMatchingService matching=%s",
              object_utf8((id)matching));
    io_service_t service = IOServiceGetMatchingService(main_port, matching);
    if (trace_iokit())
        logf_("[vmmhook] IOServiceGetMatchingService -> 0x%x", service);
    return service;
}

static kern_return_t traced_IOServiceOpen(io_service_t service,
                                           task_port_t owning_task,
                                           uint32_t type,
                                           io_connect_t *connect) {
    io_name_t class_name = {0};
    io_name_t entry_name = {0};
    IOObjectGetClass(service, class_name);
    IORegistryEntryGetName(service, entry_name);
    kern_return_t result =
        IOServiceOpen(service, owning_task, type, connect);
    if (trace_iokit())
        logf_("[vmmhook] IOServiceOpen(service=0x%x class=%s name=%s "
              "type=%u) -> 0x%x connect=0x%x",
              service, class_name, entry_name, type, result,
              connect ? *connect : 0);
    return result;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_io_service_matching __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&traced_IOServiceMatching,
      (const void *)&IOServiceMatching };
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_io_service_name_matching __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&traced_IOServiceNameMatching,
      (const void *)&IOServiceNameMatching };
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_io_get_matching_service __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&traced_IOServiceGetMatchingService,
      (const void *)&IOServiceGetMatchingService };
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} _ip_io_service_open __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&traced_IOServiceOpen, (const void *)&IOServiceOpen };


static dispatch_source_t vmm_health_timer;

static void start_health_timer(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(
        QOS_CLASS_UTILITY, 0);
    vmm_health_timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(
        vmm_health_timer,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC,
        NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(vmm_health_timer, ^{
        logf_("[vmmhook] health vcpu=%llu,%llu digitizer=%llu/%llu "
              "keyboard=%llu/%llu frame=%llu cursor=%llu surfaces=%llu",
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_counts[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_counts[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_digitizer_processed, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_digitizer_received, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_keyboard_processed, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_keyboard_received, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_frame_updates, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &xpc_cursor_updates, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &iosurface_create_count, __ATOMIC_RELAXED));
        logf_("[vmmhook] health exit=%u/0x%llx,%u/0x%llx "
              "vtimer-mask=%llu(%llu),%llu(%llu) "
              "vtimer-offset=0x%llx(%llu),0x%llx(%llu) vcpus-exit=%llu",
              vmm_latest_exit_reason(0),
              (unsigned long long)vmm_latest_exit_syndrome(0),
              vmm_latest_exit_reason(1),
              (unsigned long long)vmm_latest_exit_syndrome(1),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_last_mask[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_mask_calls[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_last_mask[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_mask_calls[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_last_offset[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_offset_calls[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_last_offset[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vtimer_offset_calls[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpus_exit_calls, __ATOMIC_RELAXED));
        logf_("[vmmhook] health exit-reasons "
              "vcpu0=%llu/%llu/%llu/%llu vcpu1=%llu/%llu/%llu/%llu "
              "cntv0=0x%llx/0x%llx/0x%llx cntv1=0x%llx/0x%llx/0x%llx",
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[0][0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[0][1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[0][2], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[0][3], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[1][0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[1][1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[1][2], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_exit_reason_counts[1][3], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_cntv_ctl[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_cntv_cval[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_mach_time[0], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_cntv_ctl[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_cntv_cval[1], __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &vmm_vcpu_last_mach_time[1], __ATOMIC_RELAXED));
    });
    dispatch_resume(vmm_health_timer);
}

__attribute__((constructor)) static void hook_init(void) {
    logf_("[vmmhook] loaded pid %d", getpid());
    // macOS configures its host audio endpoint through CoreAudio HAL. On iOS,
    // the same endpoint needs an explicit per-process AVAudioSession before
    // input buffers contain microphone samples. The VMM owns the actual host
    // streams, so activating only the UIKit parent is insufficient.
    // Resolve this dynamically: including AVFAudio's header also pulls
    // in modern typed XPC declarations, which conflict with this Ventura
    // binary-ABI shim's intentionally opaque XPC declarations above.
    Class audioSessionClass = objc_getClass("AVAudioSession");
    id audioSession = audioSessionClass
        ? ((id(*)(id, SEL))objc_msgSend)(
              (id)audioSessionClass, sel_registerName("sharedInstance"))
        : nil;
    id *categorySymbol = dlsym(RTLD_DEFAULT,
                               "AVAudioSessionCategoryPlayAndRecord");
    id *modeSymbol = dlsym(RTLD_DEFAULT, "AVAudioSessionModeDefault");
    id audioError = nil;
    NSUInteger audioOptions = 0x1U | 0x4U | 0x8U;
    BOOL categoryOK = audioSession && categorySymbol && modeSymbol &&
        ((BOOL(*)(id, SEL, id, id, NSUInteger, id *))objc_msgSend)(
            audioSession,
            sel_registerName("setCategory:mode:options:error:"),
            *categorySymbol, *modeSymbol, audioOptions, &audioError);
    BOOL rateOK = audioSession &&
        ((BOOL(*)(id, SEL, double, id *))objc_msgSend)(
            audioSession, sel_registerName("setPreferredSampleRate:error:"),
            48000, &audioError);
    BOOL activeOK = audioSession &&
        ((BOOL(*)(id, SEL, BOOL, id *))objc_msgSend)(
            audioSession, sel_registerName("setActive:error:"), YES,
            &audioError);
    NSUInteger permission = audioSession
        ? ((NSUInteger(*)(id, SEL))objc_msgSend)(
              audioSession, sel_registerName("recordPermission")) : 0;
    double sampleRate = audioSession
        ? ((double(*)(id, SEL))objc_msgSend)(
              audioSession, sel_registerName("sampleRate")) : 0;
    id errorDescription = audioError
        ? ((id(*)(id, SEL))objc_msgSend)(
              audioError, sel_registerName("localizedDescription")) : nil;
    const char *errorText = errorDescription
        ? ((const char *(*)(id, SEL))objc_msgSend)(
              errorDescription, sel_registerName("UTF8String")) : "none";
    logf_("[vmmhook] audio session category=%d rate=%d active=%d "
          "permission=%lu sample-rate=%.0f error=%s",
          categoryOK, rateOK, activeOK,
          (unsigned long)permission, sampleRate, errorText);
    start_health_timer();
    install_usb_hci_trace();
    // Optional debug delay: set VMMHOOK_DEBUG_SLEEP=N to give lldb time to attach
    // before the VMM accepts the host's connection (catch breakpoints in the open/hv path).
    const char *s = getenv("VMMHOOK_DEBUG_SLEEP");
    if (s) { int n = atoi(s); if (n > 0) { logf_("[vmmhook] sleeping %ds for lldb attach", n); sleep(n); } }
}

void vmm_xpc_main(void (*handler)(xo_t)) {
    // VMM = listener, matching VZ's host-sends-first model: create an anonymous
    // xpc listener (no launchd check-in needed) whose event handler is the VMM's real connection
    // handler, then PUBLISH our endpoint's mach port name to a file. The host (which has
    // task_for_pid on us) mach_port_extract_right's that port, rebuilds the endpoint, and
    // connects in as the client — the host then sends the config and our handler services it.
    logf_("[vmmhook] vmm_xpc_main (strategy-B listener) handler=%p", (void *)handler);
    xo_t L = xpc_connection_create(NULL, dispatch_get_main_queue());
    xpc_connection_set_event_handler(L, ^(xo_t ev) {
        void *t = xpc_get_type(ev);
        if (t == (void *)_xpc_type_connection) { logf_("[vmmhook] host PEER %p -> handler", ev); handler(ev); }
        else { char *d = xpc_copy_description(ev); logf_("[vmmhook] L event: %s", d ? d : "?"); if (d) free(d); }
    });
    xpc_connection_resume(L);
    xo_t E = xpc_endpoint_create(L);
    uint32_t myport = *(uint32_t *)((char *)E + XPC_ENDPOINT_PORT_OFF);
    logf_("[vmmhook] listener L=%p E=%p myport=0x%x", L, E, myport);
    const char *endpointFile = getenv("VZ_VMM_ENDPOINT_FILE");
    if (!endpointFile || !endpointFile[0])
        endpointFile = "/tmp/vmm_ep.txt";
    FILE *f = fopen(endpointFile, "w");
    if (f) {
        fprintf(f, "0x%x\n", myport);
        fclose(f);
        logf_("[vmmhook] published listener port to %s", endpointFile);
    } else {
        logf_("[vmmhook] failed to publish listener port to %s errno=%d",
              endpointFile, errno);
        _exit(70);
    }
    dispatch_main();
}

// The VMM compiles + applies its .sb sandbox profile via sandbox_init(); iOS doesn't
// support runtime SBPL compilation ("profile compilation not supported") -> FATAL.
// We run with the no-sandbox entitlement, so report success and skip it.
int vmm_sandbox_init(const char *profile, uint64_t flags, char **errorbuf) {
    logf_("[vmmhook] sandbox_init bypassed (flags=%llu)", (unsigned long long)flags);
    if (errorbuf) *errorbuf = NULL;
    return 0;
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_xpc_main __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_xpc_main, (const void *)&xpc_main };
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_sandbox_init __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_sandbox_init, (const void *)&sandbox_init };

// The VMM opens AVPBooter ROM at the macOS framework path:
//   /System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vmapple2.bin
// which doesn't exist on iOS. Redirect anything ending in /AVPBooter.* to /var/root/.
// Call __open directly (libsystem_kernel's leaf syscall wrapper) because dlsym(RTLD_NEXT,"open")
// returns our own interposer here -> infinite recursion. __open is the real syscall stub
// and is NOT itself interposed.
extern int __open(const char *, int, int);
static int vmm_open(const char *path, int oflag, ...) {
    int mode = 0;
    if (oflag & O_CREAT) { va_list ap; va_start(ap, oflag); mode = va_arg(ap, int); va_end(ap); }
    if (path) {
        const char *slash = strrchr(path, '/');
        const char *base = slash ? slash + 1 : path;
        if (strncmp(base, "AVPBooter.", 10) == 0) {
            const char *configured = getenv("VZ_AVP_BOOTER");
            char fb[1024];
            if (configured && configured[0])
                snprintf(fb, sizeof(fb), "%s", configured);
            else
                snprintf(fb, sizeof(fb),
                         "/var/root/VirtualMac/payload/%s", base);
            int fd = __open(fb, oflag, mode);
            void *ret0 = __builtin_return_address(0);
            void *ret1 = __builtin_return_address(1);
            logf_("[vmmhook] open(%s, oflag=0x%x) -> %s fd=%d  caller=%p caller2=%p",
                  path, oflag, fb, fd, ret0, ret1);
            log_address("open caller", ret0);
            log_address("open caller2", ret1);
            return fd;
        }
    }
    return __open(path, oflag, mode);
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_open __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_open, (const void *)&open };

// Trace hv_vcpu_config_get_feature_reg: the start path queries each of ~10 features per
// vCPU and aborts (hv_vm_destroy) if any returns non-zero. We log reg-index, return value,
// and the out-value to identify which one triggers the abort.
extern int hv_vcpu_config_get_feature_reg(void *config, uint64_t reg, uint64_t *value);
static int vmm_hv_vcpu_config_get_feature_reg(void *config, uint64_t reg, uint64_t *value) {
    int rc = hv_vcpu_config_get_feature_reg(config, reg, value);
    uint64_t v = (rc == 0 && value) ? *value : 0;
    logf_("[vmmhook] hv_vcpu_config_get_feature_reg(reg=%llu) -> rc=%d *out=0x%llx",
          (unsigned long long)reg, rc, (unsigned long long)v);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_feat __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpu_config_get_feature_reg,
      (const void *)&hv_vcpu_config_get_feature_reg };

// Trace the post-AVPBooter startup path: pin down whether teardown fires, whether
// vCPU creation is reached, and whether guest execution begins. Signatures match
// the Hypervisor.framework public headers.
extern int hv_vm_destroy(void);
static int vmm_hv_vm_destroy(void) {
    void *ret0 = __builtin_return_address(0);
    void *ret1 = __builtin_return_address(1);
    logf_("[vmmhook] hv_vm_destroy CALLED  caller=%p caller2=%p", ret0, ret1);
    log_address("hv_vm_destroy caller", ret0);
    log_address("hv_vm_destroy caller2", ret1);
    int rc = hv_vm_destroy();
    logf_("[vmmhook] hv_vm_destroy -> rc=%d", rc);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vm_destroy __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vm_destroy, (const void *)&hv_vm_destroy };

extern int hv_vm_create(void *config);
static int vmm_hv_vm_create(void *config) {
    int rc = hv_vm_create(config);
    logf_("[vmmhook] hv_vm_create(config=%p) -> rc=%d", config, rc);
    if (rc != 0) log_address("hv_vm_create caller", __builtin_return_address(0));
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vm_create __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vm_create, (const void *)&hv_vm_create };

extern int hv_vm_map(void *addr, uint64_t ipa, size_t size, uint64_t flags);
static int vmm_hv_vm_map(void *addr, uint64_t ipa, size_t size, uint64_t flags) {
    int rc = hv_vm_map(addr, ipa, size, flags);
    logf_("[vmmhook] hv_vm_map(addr=%p ipa=0x%llx size=0x%zx flags=0x%llx) -> rc=%d",
          addr, (unsigned long long)ipa, size, (unsigned long long)flags, rc);
    if (rc != 0) log_address("hv_vm_map caller", __builtin_return_address(0));
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vm_map __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vm_map, (const void *)&hv_vm_map };

extern int hv_vm_protect(uint64_t ipa, size_t size, uint64_t flags);
static int vmm_hv_vm_protect(uint64_t ipa, size_t size, uint64_t flags) {
    int rc = hv_vm_protect(ipa, size, flags);
    logf_("[vmmhook] hv_vm_protect(ipa=0x%llx size=0x%zx flags=0x%llx) -> rc=%d",
          (unsigned long long)ipa, size, (unsigned long long)flags, rc);
    if (rc != 0) log_address("hv_vm_protect caller", __builtin_return_address(0));
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vm_protect __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vm_protect, (const void *)&hv_vm_protect };

extern int hv_vcpu_create(uint64_t *vcpu, void **exit_out, void *config);
typedef struct {
    uint32_t reason;
    uint32_t reserved;
    uint64_t syndrome;
    uint64_t virtual_address;
    uint64_t physical_address;
} vmm_hv_vcpu_exit_t;

static int vmm_hv_vcpu_create(uint64_t *vcpu, void **exit_out, void *config) {
    logf_("[vmmhook] hv_vcpu_create CALLED vcpu_out=%p exit_out=%p cfg=%p",
          vcpu, exit_out, config);
    int rc = hv_vcpu_create(vcpu, exit_out, config);
    logf_("[vmmhook] hv_vcpu_create -> rc=%d vcpu=0x%llx",
          rc, (unsigned long long)(vcpu ? *vcpu : 0));
    if (rc == 0 && vcpu && *vcpu < 64 && exit_out)
        vmm_vcpu_exits[*vcpu] = (vmm_hv_vcpu_exit_t *)*exit_out;
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vcpu_create __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpu_create, (const void *)&hv_vcpu_create };

extern int hv_vcpu_run(uint64_t vcpu);
extern int hv_vcpu_get_reg(uint64_t vcpu, uint32_t reg, uint64_t *value);
extern int hv_vcpu_get_sys_reg(uint64_t vcpu, uint32_t reg, uint64_t *value);
static int vmm_hv_vcpu_run(uint64_t vcpu) {
    static uint64_t seen_vcpus;
    uint64_t bit = vcpu < 64 ? (1ULL << vcpu) : 0;
    bool trace_all = getenv("VMMHOOK_TRACE_VCPU") != NULL;
    bool first_run = bit && !(__atomic_fetch_or(
        &seen_vcpus, bit, __ATOMIC_RELAXED) & bit);
    if (trace_all || first_run)
        logf_("[vmmhook] hv_vcpu_run CALLED vcpu=0x%llx%s",
              (unsigned long long)vcpu, first_run ? " (first)" : "");
    int rc = hv_vcpu_run(vcpu);
    const char *limit_text = getenv("VMMHOOK_TRACE_VCPU_LIMIT");
    uint64_t trace_limit = limit_text ? strtoull(limit_text, NULL, 0) : 0;
    uint64_t exit_count = vcpu < 64
        ? __atomic_add_fetch(&vmm_vcpu_exit_counts[vcpu], 1,
                             __ATOMIC_RELAXED)
        : 0;
    vmm_hv_vcpu_exit_t *exit = vcpu < 64 ? vmm_vcpu_exits[vcpu] : NULL;
    if (vcpu < 64 && exit) {
        uint32_t reason_bucket = exit->reason < 3 ? exit->reason : 3;
        __atomic_add_fetch(
            &vmm_vcpu_exit_reason_counts[vcpu][reason_bucket], 1,
            __ATOMIC_RELAXED);
        uint32_t exception_class = (uint32_t)(exit->syndrome >> 26);
        if (exit->reason == 1 && exception_class == 1 &&
            exit_count % 4096 == 0) {
            uint64_t control = 0;
            uint64_t compare = 0;
            if (hv_vcpu_get_sys_reg(
                    vcpu, 0xdf19 /* HV_SYS_REG_CNTV_CTL_EL0 */,
                    &control) == 0 &&
                hv_vcpu_get_sys_reg(
                    vcpu, 0xdf1a /* HV_SYS_REG_CNTV_CVAL_EL0 */,
                    &compare) == 0) {
                __atomic_store_n(&vmm_vcpu_last_cntv_ctl[vcpu], control,
                                 __ATOMIC_RELAXED);
                __atomic_store_n(&vmm_vcpu_last_cntv_cval[vcpu], compare,
                                 __ATOMIC_RELAXED);
                __atomic_store_n(&vmm_vcpu_last_mach_time[vcpu],
                                 mach_absolute_time(), __ATOMIC_RELAXED);
            }
        }
    }
    if (vcpu < 64 && exit_count <= trace_limit) {
        uint64_t pc = 0;
        int pc_rc = hv_vcpu_get_reg(vcpu, 31 /* HV_REG_PC */, &pc);
        logf_("[vmmhook] vcpu=0x%llx exit#%llu rc=%d reason=%u "
              "pc=0x%llx pc_rc=%d esr=0x%llx va=0x%llx ipa=0x%llx",
              (unsigned long long)vcpu, (unsigned long long)exit_count, rc,
              exit ? exit->reason : UINT32_MAX,
              (unsigned long long)pc, pc_rc,
              (unsigned long long)(exit ? exit->syndrome : 0),
              (unsigned long long)(exit ? exit->virtual_address : 0),
              (unsigned long long)(exit ? exit->physical_address : 0));
    }
    if (trace_all || rc != 0)
        logf_("[vmmhook] hv_vcpu_run -> rc=%d vcpu=0x%llx",
              rc, (unsigned long long)vcpu);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vcpu_run __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpu_run, (const void *)&hv_vcpu_run };

extern int hv_vcpu_set_vtimer_mask(uint64_t vcpu, bool masked);
static int vmm_hv_vcpu_set_vtimer_mask(uint64_t vcpu, bool masked) {
    int rc = hv_vcpu_set_vtimer_mask(vcpu, masked);
    uint64_t count = 0;
    if (vcpu < 64) {
        __atomic_store_n(&vmm_vtimer_last_mask[vcpu], masked,
                         __ATOMIC_RELAXED);
        count = __atomic_add_fetch(&vmm_vtimer_mask_calls[vcpu], 1,
                                   __ATOMIC_RELAXED);
    }
    if (count <= 12 || (count && count % 1000000 == 0) || rc != 0)
        logf_("[vmmhook] hv_vcpu_set_vtimer_mask vcpu=0x%llx "
              "masked=%d call=%llu -> rc=%d",
              (unsigned long long)vcpu, masked,
              (unsigned long long)count, rc);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vcpu_set_vtimer_mask __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpu_set_vtimer_mask,
      (const void *)&hv_vcpu_set_vtimer_mask };

extern int hv_vcpu_set_vtimer_offset(uint64_t vcpu, uint64_t offset);
static int vmm_hv_vcpu_set_vtimer_offset(uint64_t vcpu, uint64_t offset) {
    int rc = hv_vcpu_set_vtimer_offset(vcpu, offset);
    uint64_t count = 0;
    if (vcpu < 64) {
        __atomic_store_n(&vmm_vtimer_last_offset[vcpu], offset,
                         __ATOMIC_RELAXED);
        count = __atomic_add_fetch(&vmm_vtimer_offset_calls[vcpu], 1,
                                   __ATOMIC_RELAXED);
    }
    if (count <= 12 || (count && count % 1000000 == 0) || rc != 0)
        logf_("[vmmhook] hv_vcpu_set_vtimer_offset vcpu=0x%llx "
              "offset=0x%llx call=%llu -> rc=%d",
              (unsigned long long)vcpu, (unsigned long long)offset,
              (unsigned long long)count, rc);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vcpu_set_vtimer_offset __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpu_set_vtimer_offset,
      (const void *)&hv_vcpu_set_vtimer_offset };

extern int hv_vcpus_exit(uint64_t *vcpus, uint32_t vcpu_count);
static int vmm_hv_vcpus_exit(uint64_t *vcpus, uint32_t vcpu_count) {
    int rc = hv_vcpus_exit(vcpus, vcpu_count);
    uint64_t count = __atomic_add_fetch(&vmm_vcpus_exit_calls, 1,
                                        __ATOMIC_RELAXED);
    if (count <= 12 || count % 100000 == 0 || rc != 0)
        logf_("[vmmhook] hv_vcpus_exit vcpus=%p count=%u call=%llu -> rc=%d",
              vcpus, vcpu_count, (unsigned long long)count, rc);
    return rc;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_ip_hv_vcpus_exit __attribute__((section("__DATA,__interpose"))) =
    { (const void *)&vmm_hv_vcpus_exit, (const void *)&hv_vcpus_exit };

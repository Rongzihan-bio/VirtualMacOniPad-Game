// (1) extract the mach send-right backing an anonymous xpc_endpoint (confirmed at +0x18).
// (2) validate the rendezvous primitive in-process:
// xpc_connection_create_from_endpoint(E) -> the listener L receives a PEER connection and a
// message flows. (3) validate reconstruction-by-port-swap: clone an endpoint object and
// overwrite its +0x18 port with a copy of L's port -> still reaches L (this is how the
// spawned child will rebuild the endpoint from just the inherited mach port).
#include <xpc/xpc.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

extern xpc_object_t xpc_endpoint_create(xpc_connection_t connection);
extern xpc_connection_t xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint);

#define PORT_OFF 0x18

static uint32_t ep_port(xpc_object_t E) { return *(uint32_t *)((char *)E + PORT_OFF); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    dispatch_queue_t q = dispatch_queue_create("L", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t L = xpc_connection_create(NULL, q);
    xpc_connection_set_event_handler(L, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
            printf(">>> L: non-connection event (%s)\n", xpc_copy_description(peer)); return;
        }
        printf(">>> L received PEER %p — accepting\n", (void *)peer);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
            if (xpc_get_type(m) == XPC_TYPE_DICTIONARY) {
                const char *s = xpc_dictionary_get_string(m, "hello");
                printf(">>> L PEER got message: hello=%s  *** RENDEZVOUS WORKS ***\n", s ? s : "(nil)");
            }
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(L);

    xpc_object_t E = xpc_endpoint_create(L);
    printf("L=%p E=%p E.port=0x%x\n", (void *)L, (void *)E, ep_port(E));

    // (2) connect from the endpoint in-process
    xpc_connection_t c = xpc_connection_create_from_endpoint((xpc_endpoint_t)E);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
        if (xpc_get_type(e) == XPC_TYPE_ERROR)
            printf("    c error: %s\n", xpc_dictionary_get_string(e, XPC_ERROR_KEY_DESCRIPTION));
    });
    xpc_connection_resume(c);
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "hello", "from-endpoint");
    xpc_connection_send_message(c, msg);

    // (3) reconstruction-by-port-swap: a fresh endpoint object whose port we overwrite
    xpc_object_t E2 = xpc_endpoint_create(L);                 // same listener (clone shape)
    mach_port_t copy = ep_port(E);                            // reuse L's send right
    *(uint32_t *)((char *)E2 + PORT_OFF) = copy;
    xpc_connection_t c2 = xpc_connection_create_from_endpoint((xpc_endpoint_t)E2);
    xpc_connection_set_event_handler(c2, ^(xpc_object_t e) {});
    xpc_connection_resume(c2);
    xpc_object_t msg2 = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg2, "hello", "from-portswap");
    xpc_connection_send_message(c2, msg2);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        printf(">>> done\n"); exit(0);
    });
    dispatch_main();
    return 0;
}

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <xpc/xpc.h>

typedef void *(*client_create_fn)(dispatch_queue_t, void (^)(xpc_object_t),
                                  uint64_t);
typedef void (*client_destroy_fn)(void *);
typedef bool (*setup_and_send_fn)(dispatch_queue_t, xpc_object_t,
                                  void (^)(xpc_object_t));

int main(void) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    void *image = dlopen(
        "/System/Library/PrivateFrameworks/Netrb.framework/Netrb",
        RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "native Netrb dlopen failed: %s\n", dlerror());
        return 1;
    }
    client_create_fn create = (client_create_fn)dlsym(
        image, "_NETRBClientCreate");
    client_destroy_fn destroy = (client_destroy_fn)dlsym(
        image, "_NETRBClientDestroy");
    setup_and_send_fn send = (setup_and_send_fn)dlsym(
        image, "NETRBXPCSetupAndSend");
    if (!create || !destroy || !send) {
        fprintf(stderr, "native Netrb symbols unavailable create=%p "
                "destroy=%p send=%p\n", create, destroy, send);
        return 2;
    }
    dispatch_queue_t queue = dispatch_queue_create(
        "com.mac.virtual.netrb-native-probe", DISPATCH_QUEUE_SERIAL);
    void *client = create(queue, ^(xpc_object_t notification) {
        char *text = notification ? xpc_copy_description(notification) : NULL;
        printf("native Netrb notification: %s\n", text ?: "(null)");
        free(text);
    }, 0);
    if (!client) {
        fprintf(stderr, "native Netrb client create failed\n");
        return 3;
    }
    const char *clientID = (const char *)client + 0x20;
    printf("native Netrb client=%p id=%s\n", client, clientID);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(request, "xpcKey", 1014);
    xpc_dictionary_set_uint64(request, "opMode", 201);
    xpc_dictionary_set_string(request, "clientid", clientID);
    __block xpc_object_t reply = NULL;
    bool sent = send(NULL, request, ^(xpc_object_t response) {
        if (response)
            reply = xpc_retain(response);
    });
    char *requestText = xpc_copy_description(request);
    char *replyText = reply ? xpc_copy_description(reply) : NULL;
    printf("native Netrb operation 1014 sent=%d\nrequest=%s\nreply=%s\n",
           sent, requestText ?: "(null)", replyText ?: "(null)");
    free(requestText);
    free(replyText);
    uint64_t responseCode = reply
        ? xpc_dictionary_get_uint64(reply, "response") : 0;
    int interfaceFD = reply
        ? xpc_dictionary_dup_fd(reply, "interface_socket") : -1;
    printf("native Netrb response=%llu interface_socket=%d\n",
           (unsigned long long)responseCode, interfaceFD);
    if (interfaceFD >= 0)
        close(interfaceFD);
    if (reply)
        xpc_release(reply);
    xpc_release(request);
    destroy(client);
    return responseCode == 2001 && interfaceFD >= 0 ? 0 : 4;
}

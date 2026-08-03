#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../../host/usb_restore_bridge.h"

static int write_full(int fd, const void *buffer, size_t length) {
    const unsigned char *bytes = buffer;
    while (length) {
        ssize_t count = write(fd, bytes, length);
        if (count <= 0)
            return errno ?: EIO;
        bytes += count;
        length -= (size_t)count;
    }
    return 0;
}

static int read_full(int fd, void *buffer, size_t length) {
    unsigned char *bytes = buffer;
    while (length) {
        ssize_t count = read(fd, bytes, length);
        if (count <= 0)
            return errno ?: EIO;
        bytes += count;
        length -= (size_t)count;
    }
    return 0;
}

static int bridge_request(const struct vz_usb_bridge_request *request,
                          const void *payload,
                          struct vz_usb_bridge_response *response,
                          void *response_payload,
                          size_t response_capacity) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, VZ_USB_BRIDGE_SOCKET,
            sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&address,
                          sizeof(address)) < 0) {
        perror("connect");
        return 1;
    }
    int error = write_full(fd, request, sizeof(*request));
    if (!error && request->payload_length)
        error = write_full(fd, payload, request->payload_length);
    if (!error)
        error = read_full(fd, response, sizeof(*response));
    if (!error && response->payload_length) {
        if (!response_payload || response->payload_length > response_capacity)
            error = EOVERFLOW;
        else
            error = read_full(fd, response_payload,
                              response->payload_length);
    }
    close(fd);
    return error;
}

static int bulk_transfer(uint8_t endpoint, void *buffer, uint32_t length,
                         uint32_t timeout_ms, uint32_t *actual) {
    bool input = (endpoint & 0x80U) != 0;
    struct vz_usb_bridge_request request = {
        .magic = VZ_USB_BRIDGE_MAGIC,
        .version = VZ_USB_BRIDGE_VERSION,
        .operation = VZ_USB_BRIDGE_BULK,
        .payload_length = input ? 0 : length,
        .timeout_ms = timeout_ms,
        .endpoint = endpoint,
        .transfer_length = length,
    };
    struct vz_usb_bridge_response response = {0};
    int error = bridge_request(&request, input ? NULL : buffer, &response,
                               input ? buffer : NULL,
                               input ? length : 0);
    if (!error && response.status)
        error = response.status;
    if (actual)
        *actual = error ? 0 : (input ? response.payload_length : length);
    return error;
}

struct read_context {
    uint8_t buffer[32768];
    uint32_t actual;
    int error;
};

static void *read_handshake(void *opaque) {
    struct read_context *context = opaque;
    context->error = bulk_transfer(0x81, context->buffer,
                                   sizeof(context->buffer), 10000,
                                   &context->actual);
    return NULL;
}

static int probe_usbmux_handshake(void) {
    static const uint8_t greeting[20] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x00, 0x00, 0x00,
    };
    struct read_context context = {0};
    pthread_t reader;
    int error = pthread_create(&reader, NULL, read_handshake, &context);
    if (error)
        return error;
    usleep(20000);
    uint32_t actual = 0;
    error = bulk_transfer(0x01, NULL, 0, 5000, &actual);
    if (!error)
        error = bulk_transfer(0x01, (void *)greeting, sizeof(greeting),
                              5000, &actual);
    pthread_join(reader, NULL);
    if (!error)
        error = context.error;
    if (error) {
        fprintf(stderr, "USBMUX_HANDSHAKE_FAILED\terror=%d (%s)\n",
                error, strerror(error));
        return 1;
    }
    printf("USBMUX_HANDSHAKE_OK\tactual=%u\tbytes=", context.actual);
    for (uint32_t index = 0; index < context.actual; index++)
        printf("%02x%s", context.buffer[index],
               index + 1 == context.actual ? "" : " ");
    putchar('\n');
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "usbmux-handshake") == 0)
        return probe_usbmux_handshake();

    static const char command[] = "getenv ota-uuid";
    struct vz_usb_bridge_request request = {
        .magic = VZ_USB_BRIDGE_MAGIC,
        .version = VZ_USB_BRIDGE_VERSION,
        .operation = VZ_USB_BRIDGE_CONTROL,
        .payload_length = sizeof(command),
        .timeout_ms = 30000,
        .request_type = 0x40,
        .request = 0,
        .length = sizeof(command),
    };
    struct vz_usb_bridge_response response = {0};
    int error = bridge_request(&request, command, &response, NULL, 0);
    if (error) {
        fprintf(stderr, "transport error: %s\n", strerror(error));
        return 1;
    }
    printf("status=%d generation=%u vid=%04x pid=%04x ready=%u\n",
           response.status, response.device_generation, response.vendor_id,
           response.product_id, response.ready);
    return response.status ? 1 : 0;
}

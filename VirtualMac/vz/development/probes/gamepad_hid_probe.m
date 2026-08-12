#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kGamepadReportLength = 16,
    kGamepadButtonCount = 16,
    kGamepadPacketLength = 32,
    kGamepadProtocolVersion = 1,
    kGamepadPacketTypeState = 1,
    kGamepadPacketTypeAck = 2,
    kGamepadAckLength = 16,
    kGamepadDefaultStateTimeoutMilliseconds = 750,
    kGamepadReceiveBufferBytes = 256 * 1024,
    kGamepadMaxBatchPackets = 256,
};

static volatile sig_atomic_t gStop;

static void handle_signal(int signal_number) {
    (void)signal_number;
    gStop = 1;
}

static CFNumberRef number_for_int(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static const uint8_t kGenericGamepadDescriptor[] = {
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x05,       // Usage (Game Pad)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x01,       //   Report ID (1)
    0x05, 0x09,       //   Usage Page (Button)
    0x19, 0x01,       //   Usage Minimum (Button 1)
    0x29, 0x10,       //   Usage Maximum (Button 16)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x01,       //   Logical Maximum (1)
    0x95, 0x10,       //   Report Count (16)
    0x75, 0x01,       //   Report Size (1)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x05, 0x01,       //   Usage Page (Generic Desktop)
    0x09, 0x30,       //   Usage (X)
    0x09, 0x31,       //   Usage (Y)
    0x09, 0x33,       //   Usage (Rx)
    0x09, 0x34,       //   Usage (Ry)
    0x16, 0x00, 0x80, //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F, //   Logical Maximum (32767)
    0x75, 0x10,       //   Report Size (16)
    0x95, 0x04,       //   Report Count (4)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x32,       //   Usage (Z)
    0x09, 0x35,       //   Usage (Rz)
    0x15, 0x00,       //   Logical Minimum (0)
    // A 16-bit HID Logical Maximum is signed because Logical Minimum is zero.
    // Use the 32-bit item form so 65535 is not decoded as -1 by IOHIDFamily.
    0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
    0x75, 0x10,       //   Report Size (16)
    0x95, 0x02,       //   Report Count (2)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x39,       //   Usage (Hat switch)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x07,       //   Logical Maximum (7)
    0x35, 0x00,       //   Physical Minimum (0)
    0x46, 0x3B, 0x01, //   Physical Maximum (315)
    0x65, 0x14,       //   Unit (English Rotation)
    0x75, 0x04,       //   Report Size (4)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x75, 0x04,       //   Report Size (4)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x03,       //   Input (Constant, Variable, Absolute)
    0xC0,             // End Collection
};

static void neutral_report(uint8_t report[kGamepadReportLength]) {
    memset(report, 0, kGamepadReportLength);
    report[0] = 0x01;
    report[15] = 0x08;
}

static const char *dpad_name_for_generic(uint8_t hat) {
    static const char *names[] = {
        "up", "up-right", "right", "down-right",
        "down", "down-left", "left", "up-left", "neutral",
    };
    return hat <= 8 ? names[hat] : "invalid";
}

static IOReturn handle_gamepad_report(
    IOHIDUserDeviceRef device, uint64_t timestamp,
    const uint8_t report[kGamepadReportLength]) {
    return IOHIDUserDeviceHandleReportWithTimeStamp(
        device, timestamp, report, kGamepadReportLength);
}

static void make_report(uint8_t report[kGamepadReportLength], double seconds) {
    neutral_report(report);

    if (seconds >= 1.0 && seconds < 2.0) {
        report[1] = 0x01; // Button 1.
    }

    double phase = seconds * 2.0 * 3.14159265358979323846;
    int16_t x = (int16_t)lrint(sin(phase) * 28000.0);
    int16_t y = (int16_t)lrint(cos(phase) * 28000.0);
    int16_t rx = (int16_t)lrint(sin(phase * 0.5) * 22000.0);
    int16_t ry = (int16_t)lrint(cos(phase * 0.5) * 22000.0);
    uint16_t z = (uint16_t)lrint((sin(seconds * 3.0) * 0.5 + 0.5) * 65535.0);
    uint16_t rz = (uint16_t)lrint((cos(seconds * 2.0) * 0.5 + 0.5) * 65535.0);

    memcpy(&report[3], &x, sizeof(x));
    memcpy(&report[5], &y, sizeof(y));
    memcpy(&report[7], &rx, sizeof(rx));
    memcpy(&report[9], &ry, sizeof(ry));
    memcpy(&report[11], &z, sizeof(z));
    memcpy(&report[13], &rz, sizeof(rz));
    report[15] = (uint8_t)((int)(seconds * 2.0) % 9);
}

static uint64_t monotonic_timestamp(void) {
    return mach_absolute_time();
}

static double seconds_between(uint64_t later, uint64_t earlier) {
    mach_timebase_info_data_t timebase_info;
    mach_timebase_info(&timebase_info);
    return (double)(later - earlier) * (double)timebase_info.numer /
           (double)timebase_info.denom / 1e9;
}

static uint16_t read_be16(const uint8_t *value) {
    return (uint16_t)((uint16_t)value[0] << 8 | value[1]);
}

static uint32_t read_be32(const uint8_t *value) {
    return (uint32_t)((uint32_t)value[0] << 24 | (uint32_t)value[1] << 16 |
                      (uint32_t)value[2] << 8 | value[3]);
}

static bool packet_is_newer(uint32_t candidate, uint32_t previous) {
    return (int32_t)(candidate - previous) > 0;
}

static bool decode_state_packet(const uint8_t packet[kGamepadPacketLength],
                                uint32_t *sequence,
                                uint32_t *session,
                                uint8_t report[kGamepadReportLength]) {
    if (read_be32(&packet[0]) != 0x564D4750 || // "VMGP"
        packet[4] != kGamepadProtocolVersion ||
        packet[5] != kGamepadPacketTypeState ||
        read_be16(&packet[6]) != kGamepadReportLength ||
        packet[16] != 0x01 || packet[31] > 8) {
        return false;
    }
    *sequence = read_be32(&packet[8]);
    *session = read_be32(&packet[12]);
    memcpy(report, &packet[16], kGamepadReportLength);
    return true;
}

static int create_udp_listener(uint16_t port) {
    int socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_fd < 0) {
        perror("[gamepad-probe] socket");
        return -1;
    }
    int reuse = 1;
    (void)setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int receive_buffer = kGamepadReceiveBufferBytes;
    (void)setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                     sizeof(receive_buffer));
    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        fprintf(stderr, "[gamepad-probe] failed to make UDP socket nonblocking: %s\n",
                strerror(errno));
        close(socket_fd);
        return -1;
    }
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socket_fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        fprintf(stderr, "[gamepad-probe] bind UDP %u failed: %s\n", port,
                strerror(errno));
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static void send_ack(int socket_fd, const struct sockaddr *destination,
                     socklen_t destination_length, uint32_t sequence,
                     uint32_t session) {
    uint8_t ack[kGamepadAckLength] = {0};
    ack[0] = 'V'; ack[1] = 'M'; ack[2] = 'G'; ack[3] = 'A';
    ack[4] = kGamepadProtocolVersion;
    ack[5] = kGamepadPacketTypeAck;
    ack[8] = (uint8_t)(sequence >> 24);
    ack[9] = (uint8_t)(sequence >> 16);
    ack[10] = (uint8_t)(sequence >> 8);
    ack[11] = (uint8_t)sequence;
    ack[12] = (uint8_t)(session >> 24);
    ack[13] = (uint8_t)(session >> 16);
    ack[14] = (uint8_t)(session >> 8);
    ack[15] = (uint8_t)session;
    (void)sendto(socket_fd, ack, sizeof(ack), 0, destination,
                 destination_length);
}

static void print_state(uint32_t sequence,
                        const uint8_t report[kGamepadReportLength]) {
    uint16_t buttons = (uint16_t)report[1] | (uint16_t)report[2] << 8;
    int16_t x, y, rx, ry;
    uint16_t z, rz;
    memcpy(&x, &report[3], sizeof(x));
    memcpy(&y, &report[5], sizeof(y));
    memcpy(&rx, &report[7], sizeof(rx));
    memcpy(&ry, &report[9], sizeof(ry));
    memcpy(&z, &report[11], sizeof(z));
    memcpy(&rz, &report[13], sizeof(rz));
    fprintf(stderr, "[gamepad-probe] seq=%u buttons=0x%04x "
            "left=%+.3f,%+.3f right=%+.3f,%+.3f "
            "triggers=%.3f,%.3f hat=%u(%s)\n",
            sequence, buttons, (double)x / 32767.0, (double)y / 32767.0,
            (double)rx / 32767.0, (double)ry / 32767.0,
            (double)z / 65535.0, (double)rz / 65535.0, report[15],
            dpad_name_for_generic(report[15]));
}

static void print_usage(const char *program) {
    fprintf(stderr, "usage: %s [--duration SECONDS] [--listen UDP_PORT] "
            "[--timeout-ms MILLISECONDS] [--stats] "
            "[--print-state]\n", program);
}

int main(int argc, char **argv) {
    double duration = 8.0;
    uint16_t listen_port = 0;
    bool print_received_state = false;
    bool print_stats = false;
    uint32_t state_timeout_ms = kGamepadDefaultStateTimeoutMilliseconds;
    for (int argument = 1; argument < argc;) {
        if (strcmp(argv[argument], "--print-state") == 0) {
            print_received_state = true;
            argument++;
            continue;
        }
        if (strcmp(argv[argument], "--stats") == 0) {
            print_stats = true;
            argument++;
            continue;
        }
        if (argument + 1 >= argc) {
            print_usage(argv[0]);
            return 2;
        }
        if (strcmp(argv[argument], "--duration") == 0) {
            duration = strtod(argv[argument + 1], NULL);
            if (!(duration > 0.0)) {
                fprintf(stderr, "duration must be greater than zero\n");
                return 2;
            }
        } else if (strcmp(argv[argument], "--listen") == 0) {
            char *end = NULL;
            long parsed = strtol(argv[argument + 1], &end, 10);
            if (!end || *end != '\0' || parsed < 1 || parsed > UINT16_MAX) {
                fprintf(stderr, "UDP port must be between 1 and 65535\n");
                return 2;
            }
            listen_port = (uint16_t)parsed;
            if (duration == 8.0) {
                duration = 0.0; // A receiver is normally long-lived.
            }
        } else if (strcmp(argv[argument], "--timeout-ms") == 0) {
            char *end = NULL;
            long parsed = strtol(argv[argument + 1], &end, 10);
            if (!end || *end != '\0' || parsed < 100 || parsed > 10000) {
                fprintf(stderr,
                        "state timeout must be between 100 and 10000 ms\n");
                return 2;
            }
            state_timeout_ms = (uint32_t)parsed;
        } else {
            print_usage(argv[0]);
            return 2;
        }
        argument += 2;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    CFNumberRef vendor = number_for_int(0xfeed);
    CFNumberRef product = number_for_int(0x4790);
    CFNumberRef version = number_for_int(0x0100);
    CFNumberRef usage_page = number_for_int(0x01);
    CFNumberRef usage = number_for_int(0x05);
    CFNumberRef vendor_source = number_for_int(0x00);
    CFDataRef descriptor = CFDataCreate(kCFAllocatorDefault,
        kGenericGamepadDescriptor, sizeof(kGenericGamepadDescriptor));
    if (!vendor || !product || !version || !usage_page || !usage ||
        !vendor_source || !descriptor) {
        fprintf(stderr, "failed to allocate HID properties\n");
        return 1;
    }

    const void *keys[] = {
        CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDTransportKey),
        CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey),
        CFSTR(kIOHIDVersionNumberKey), CFSTR(kIOHIDManufacturerKey),
        CFSTR(kIOHIDProductKey), CFSTR(kIOHIDSerialNumberKey),
        CFSTR(kIOHIDPrimaryUsagePageKey), CFSTR(kIOHIDPrimaryUsageKey),
        CFSTR(kIOHIDVendorIDSourceKey),
    };
    const void *values[] = {
        descriptor, CFSTR("VirtualMac"),
        vendor, product, version,
        CFSTR("VirtualMac"), CFSTR("VirtualMac Network Gamepad"),
        CFSTR("virtualmac-gamepad-0"), usage_page, usage,
        vendor_source,
    };
    CFDictionaryRef base_properties = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(keys[0]),
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef properties = base_properties
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0,
                                        base_properties) : NULL;
    if (base_properties) CFRelease(base_properties);

    dispatch_queue_t queue = dispatch_queue_create("com.virtualmac.gamepad-probe",
                                                   DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
    IOHIDUserDeviceRef device = NULL;
    if (properties && queue && cancelled) {
        device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties, 0);
    }
    if (!device) {
        fprintf(stderr,
                "failed to create virtual HID device (check the virtual-device entitlement)\n");
        return 1;
    }

    IOHIDUserDeviceRegisterGetReportBlock(device,
        ^IOReturn(IOHIDReportType type, uint32_t report_id, uint8_t *report,
                  CFIndex *report_length) {
            (void)type;
            CFIndex required_length = kGamepadReportLength;
            if (!report || !report_length || *report_length < required_length) {
                return kIOReturnBadArgument;
            }
            uint8_t neutral[kGamepadReportLength];
            neutral_report(neutral);
            memcpy(report, neutral, sizeof(neutral));
            *report_length = required_length;
            return kIOReturnSuccess;
        });
    IOHIDUserDeviceRegisterSetReportBlock(device,
        ^IOReturn(IOHIDReportType type, uint32_t report_id, const uint8_t *report,
                  CFIndex report_length) {
            fprintf(stderr, "[gamepad-probe] output report type=%u length=%ld\n",
                    (unsigned)type, (long)report_length);
            (void)report_id;
            (void)report;
            return kIOReturnSuccess;
        });
    IOHIDUserDeviceSetDispatchQueue(device, queue);
    IOHIDUserDeviceSetCancelHandler(device, ^{
        dispatch_semaphore_signal(cancelled);
    });
    IOHIDUserDeviceActivate(device);

    int socket_fd = -1;
    if (listen_port) {
        socket_fd = create_udp_listener(listen_port);
        if (socket_fd < 0) {
            IOHIDUserDeviceCancel(device);
            return 1;
        }
        int actual_receive_buffer = 0;
        socklen_t actual_receive_buffer_length = sizeof(actual_receive_buffer);
        (void)getsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF,
                         &actual_receive_buffer,
                         &actual_receive_buffer_length);
        fprintf(stderr,
                "[gamepad-probe] listening on UDP %u "
                "(state timeout %ums, receive buffer %d bytes)\n",
                listen_port, state_timeout_ms, actual_receive_buffer);
    }
    fprintf(stderr, "[gamepad-probe] active: device=%s "
            "(%u-byte HID reports%s)\n",
            "VirtualMac Network Gamepad feed:4790",
            kGamepadReportLength,
            duration > 0.0 ? ", timed" : ", until interrupted");
    const uint64_t start = monotonic_timestamp();
    uint64_t last_packet_at = 0;
    uint32_t last_sequence = 0;
    uint32_t last_session = 0;
    bool have_sequence = false;
    bool neutralized_for_timeout = false;
    uint64_t last_state_print_at = 0;
    uint16_t last_printed_buttons = 0;
    uint8_t last_printed_hat = 8;
    bool have_printed_state = false;
    uint64_t packets_received = 0;
    uint64_t packets_accepted = 0;
    uint64_t reports_published = 0;
    uint64_t sequence_gaps = 0;
    uint64_t stale_packets = 0;
    uint64_t malformed_packets = 0;
    uint64_t timeout_count = 0;
    uint64_t last_stats_at = start;
    uint16_t last_published_buttons = 0;
    uint8_t last_published_hat = 8;
    bool have_published_report = false;

    while (!gStop) {
        uint64_t now = monotonic_timestamp();
        double elapsed = seconds_between(now, start);
        if (duration > 0.0 && elapsed >= duration) {
            break;
        }

        if (socket_fd < 0) {
            uint8_t report[kGamepadReportLength];
            make_report(report, elapsed);
            IOReturn status = handle_gamepad_report(device, now, report);
            if (status != kIOReturnSuccess) {
                fprintf(stderr, "[gamepad-probe] report failed: 0x%08x\n", status);
                break;
            }
            usleep(16667);
            continue;
        }

        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socket_fd, &readable);
        struct timeval wait_time = {.tv_sec = 0, .tv_usec = 20000};
        int ready = select(socket_fd + 1, &readable, NULL, NULL, &wait_time);
        if (ready > 0 && FD_ISSET(socket_fd, &readable)) {
            bool have_batch_state = false;
            bool batch_state_was_published = false;
            uint8_t batch_report[kGamepadReportLength];
            uint32_t batch_sequence = 0;
            for (unsigned batch = 0; batch < kGamepadMaxBatchPackets; batch++) {
                uint8_t packet[kGamepadPacketLength];
                struct sockaddr_storage sender = {0};
                socklen_t sender_length = sizeof(sender);
                ssize_t received = recvfrom(socket_fd, packet, sizeof(packet), 0,
                    (struct sockaddr *)&sender, &sender_length);
                if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                    break;
                if (received < 0) {
                    fprintf(stderr, "[gamepad-probe] UDP receive failed: %s\n",
                            strerror(errno));
                    break;
                }
                packets_received++;
                uint32_t sequence = 0;
                uint32_t session = 0;
                uint8_t report[kGamepadReportLength];
                if (received != kGamepadPacketLength ||
                    !decode_state_packet(packet, &sequence, &session, report)) {
                    malformed_packets++;
                    continue;
                }
                if (have_sequence && session == last_session &&
                    !packet_is_newer(sequence, last_sequence)) {
                    stale_packets++;
                    continue;
                }
                if (have_sequence && session == last_session) {
                    uint32_t distance = sequence - last_sequence;
                    if (distance > 1)
                        sequence_gaps += (uint64_t)distance - 1;
                }
                last_sequence = sequence;
                last_session = session;
                have_sequence = true;
                packets_accepted++;
                memcpy(batch_report, report, sizeof(batch_report));
                batch_sequence = sequence;
                have_batch_state = true;
                uint16_t report_buttons = (uint16_t)report[1] |
                    (uint16_t)report[2] << 8;
                bool digital_transition = !have_published_report ||
                    report_buttons != last_published_buttons ||
                    report[15] != last_published_hat;
                batch_state_was_published = false;
                if (digital_transition) {
                    IOReturn status = handle_gamepad_report(
                        device, monotonic_timestamp(), report);
                    if (status != kIOReturnSuccess) {
                        fprintf(stderr,
                                "[gamepad-probe] report failed: 0x%08x\n",
                                status);
                        gStop = 1;
                        break;
                    }
                    reports_published++;
                    last_published_buttons = report_buttons;
                    last_published_hat = report[15];
                    have_published_report = true;
                    batch_state_was_published = true;
                }
                send_ack(socket_fd, (const struct sockaddr *)&sender,
                         sender_length, sequence, session);
            }
            if (have_batch_state && !batch_state_was_published) {
                uint64_t publish_now = monotonic_timestamp();
                IOReturn status = handle_gamepad_report(
                    device, publish_now, batch_report);
                if (status != kIOReturnSuccess) {
                    fprintf(stderr, "[gamepad-probe] report failed: 0x%08x\n", status);
                    break;
                }
                reports_published++;
                last_published_buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                last_published_hat = batch_report[15];
                have_published_report = true;
            }
            if (have_batch_state) {
                uint64_t publish_now = monotonic_timestamp();
                last_packet_at = publish_now;
                neutralized_for_timeout = false;
                uint16_t buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                if (print_received_state &&
                    (!have_printed_state || buttons != last_printed_buttons ||
                     batch_report[15] != last_printed_hat ||
                     seconds_between(publish_now, last_state_print_at) >= 0.10)) {
                    print_state(batch_sequence, batch_report);
                    last_state_print_at = publish_now;
                    last_printed_buttons = buttons;
                    last_printed_hat = batch_report[15];
                    have_printed_state = true;
                }
            }
        }
        now = monotonic_timestamp();
        if (last_packet_at && !neutralized_for_timeout &&
            seconds_between(now, last_packet_at) * 1000.0 >=
                state_timeout_ms) {
            uint8_t neutral[kGamepadReportLength];
            neutral_report(neutral);
            handle_gamepad_report(device, now, neutral);
            neutralized_for_timeout = true;
            timeout_count++;
            fprintf(stderr,
                    "[gamepad-probe] state timed out after %ums; neutralized\n",
                    state_timeout_ms);
        }
        if (print_stats && seconds_between(now, last_stats_at) >= 10.0) {
            fprintf(stderr,
                    "[gamepad-probe] stats received=%llu accepted=%llu "
                    "published=%llu sequence-gaps=%llu stale=%llu "
                    "malformed=%llu timeouts=%llu\n",
                    packets_received, packets_accepted, reports_published,
                    sequence_gaps, stale_packets, malformed_packets,
                    timeout_count);
            last_stats_at = now;
        }
    }

    uint8_t neutral[kGamepadReportLength];
    neutral_report(neutral);
    handle_gamepad_report(device, monotonic_timestamp(), neutral);
    IOHIDUserDeviceCancel(device);
    dispatch_semaphore_wait(cancelled,
                            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    fprintf(stderr,
            "[gamepad-probe] stopped: received=%llu accepted=%llu "
            "published=%llu sequence-gaps=%llu stale=%llu malformed=%llu "
            "timeouts=%llu\n",
            packets_received, packets_accepted, reports_published,
            sequence_gaps, stale_packets, malformed_packets, timeout_count);

    if (socket_fd >= 0) {
        close(socket_fd);
    }
    CFRelease(device);
    dispatch_release(cancelled);
    dispatch_release(queue);
    CFRelease(properties);
    CFRelease(descriptor);
    CFRelease(usage);
    CFRelease(usage_page);
    CFRelease(vendor_source);
    CFRelease(version);
    CFRelease(product);
    CFRelease(vendor);
    return 0;
}

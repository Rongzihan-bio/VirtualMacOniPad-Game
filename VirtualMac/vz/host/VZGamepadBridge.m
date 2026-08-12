#import "VZGamepadBridge.h"
#import "VZAppSettings.h"
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/socket.h>
#include <string.h>
#include <unistd.h>

enum {
    VZGamepadPacketLength = 32,
    VZGamepadReportLength = 16,
    VZGamepadAckLength = 16,
};

NSString * const VZGamepadBridgeStateDidChangeNotification =
    @"VZGamepadBridgeStateDidChange";

@interface VZGamepadBridge () {
    int _socketFD;
    struct sockaddr_in _destination;
    BOOL _configured;
    BOOL _enabled;
    BOOL _foregroundActive;
    BOOL _started;
    uint32_t _sequence;
    uint32_t _sessionIdentifier;
    uint64_t _packetsSent;
    uint64_t _acksReceived;
    uint32_t _lastAckSequence;
    CFTimeInterval _lastAckTime;
    CFTimeInterval _lastStateNotificationTime;
    NSString *_destinationText;
    NSString *_lastError;
    GCController *_controller;
    dispatch_source_t _heartbeat;
    dispatch_source_t _socketReader;
}
@end

static void VZWriteBE16(uint8_t *output, uint16_t value)
{
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static void VZWriteBE32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static int16_t VZAxis(float value)
{
    value = fminf(1.0f, fmaxf(-1.0f, value));
    return (int16_t)lrintf(value * 32767.0f);
}

static uint16_t VZTrigger(float value)
{
    value = fminf(1.0f, fmaxf(0.0f, value));
    return (uint16_t)lrintf(value * 65535.0f);
}

static BOOL VZPressed(GCControllerButtonInput *button)
{
    return button && button.isPressed;
}

@implementation VZGamepadBridge

+ (instancetype)sharedBridge
{
    static VZGamepadBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [[self alloc] init]; });
    return bridge;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _socketFD = -1;
        _foregroundActive = YES;
        _sessionIdentifier = arc4random();
        if (_sessionIdentifier == 0)
            _sessionIdentifier = 1;
    }
    return self;
}

- (void)start
{
    if (_started)
        return;
    _started = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(controllerDidConnect:)
        name:GCControllerDidConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(controllerDidDisconnect:)
        name:GCControllerDidDisconnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(settingsDidChange:)
        name:VZSettingsDidChangeNotification object:nil];
    [self configureFromSettings];
    [self selectController];

    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_main_queue());
    dispatch_source_set_timer(_heartbeat, DISPATCH_TIME_NOW,
        NSEC_PER_SEC / 60, NSEC_PER_MSEC * 2);
    dispatch_source_set_event_handler(_heartbeat, ^{ [self sendCurrentState]; });
    dispatch_resume(_heartbeat);
}

- (void)settingsDidChange:(NSNotification *)notification
{
    (void)notification;
    [self configureFromSettings];
}

- (void)configureFromSettings
{
    BOOL requestedEnabled = [VZAppSettings.sharedSettings boolForKey:
        VZGamepadRelayEnabledKey];
    NSString *text = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadDestinationKey];
    [_destinationText release];
    _destinationText = [text copy];
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    struct in_addr address;
    long port = parts.count == 2 ? [parts[1] integerValue] : 0;
    BOOL valid = parts.count == 2 && port > 0 && port <= UINT16_MAX &&
        inet_pton(AF_INET, parts[0].UTF8String, &address) == 1;
    if (_enabled && _configured && _socketFD >= 0)
        [self sendNeutralReport];
    _enabled = requestedEnabled;
    if (_socketReader) {
        dispatch_source_cancel(_socketReader);
        dispatch_release(_socketReader);
        _socketReader = NULL;
    }
    if (_socketFD >= 0) {
        close(_socketFD);
        _socketFD = -1;
    }
    _configured = valid;
    if (!valid) {
        if (_enabled)
            printf("[VirtualMac] gamepad relay needs IPv4 destination host:port\n");
        [self setLastError:text.length ? @"Invalid destination address" : nil];
        [self publishState:YES];
        return;
    }
    _socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_socketFD < 0) {
        perror("[VirtualMac] gamepad UDP socket");
        _configured = NO;
        [self setLastError:@"Could not create the UDP socket"];
        [self publishState:YES];
        return;
    }
    int flags = fcntl(_socketFD, F_GETFL, 0);
    if (flags >= 0)
        (void)fcntl(_socketFD, F_SETFL, flags | O_NONBLOCK);
    memset(&_destination, 0, sizeof(_destination));
    _destination.sin_family = AF_INET;
    _destination.sin_port = htons((uint16_t)port);
    _destination.sin_addr = address;
    [self setLastError:nil];
    _socketReader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)_socketFD, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_socketReader, ^{ [self receiveAcks]; });
    dispatch_resume(_socketReader);
    printf("[VirtualMac] gamepad relay destination=%s\n", text.UTF8String);
    if (_enabled)
        [self sendNeutralReport];
    [self publishState:YES];
}

- (void)controllerDidConnect:(NSNotification *)notification
{
    GCController *controller = notification.object;
    printf("[VirtualMac] gamepad connected vendor=%s profile=%p\n",
        controller.vendorName.UTF8String ?: "(unknown)",
        controller.extendedGamepad);
    [self selectController];
    [self publishState:YES];
}

- (void)controllerDidDisconnect:(NSNotification *)notification
{
    GCController *controller = notification.object;
    printf("[VirtualMac] gamepad disconnected vendor=%s\n",
        controller.vendorName.UTF8String ?: "(unknown)");
    if (controller == _controller) {
        [self sendNeutralReport];
        [_controller release];
        _controller = nil;
    }
    [self selectController];
    [self publishState:YES];
}

- (void)selectController
{
    GCController *selected = nil;
    for (GCController *candidate in GCController.controllers) {
        if (candidate.extendedGamepad) {
            selected = candidate;
            break;
        }
    }
    if (selected == _controller)
        return;
    [_controller release];
    _controller = [selected retain];
    if (!_controller)
    {
        [self publishState:YES];
        return;
    }
    printf("[VirtualMac] gamepad selected vendor=%s\n",
        _controller.vendorName.UTF8String ?: "(unknown)");
    __unsafe_unretained VZGamepadBridge *weakSelf = self;
    _controller.extendedGamepad.valueChangedHandler =
        ^(GCExtendedGamepad *profile, GCControllerElement *element) {
            (void)profile;
            (void)element;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf sendCurrentState];
            });
        };
    [self sendCurrentState];
    [self publishState:YES];
}

- (void)fillReport:(uint8_t[VZGamepadReportLength])report
{
    memset(report, 0, VZGamepadReportLength);
    report[0] = 1;
    report[15] = 8;
    GCExtendedGamepad *pad = _controller.extendedGamepad;
    if (!pad)
        return;
    uint16_t buttons = 0;
    buttons |= VZPressed(pad.buttonA) << 0;
    buttons |= VZPressed(pad.buttonB) << 1;
    buttons |= VZPressed(pad.buttonX) << 2;
    buttons |= VZPressed(pad.buttonY) << 3;
    buttons |= VZPressed(pad.leftShoulder) << 4;
    buttons |= VZPressed(pad.rightShoulder) << 5;
    buttons |= VZPressed(pad.leftThumbstickButton) << 6;
    buttons |= VZPressed(pad.rightThumbstickButton) << 7;
    buttons |= VZPressed(pad.buttonMenu) << 8;
    buttons |= VZPressed(pad.buttonOptions) << 9;
    buttons |= VZPressed(pad.buttonHome) << 10;
    report[1] = (uint8_t)buttons;
    report[2] = (uint8_t)(buttons >> 8);
    int16_t x = VZAxis(pad.leftThumbstick.xAxis.value);
    int16_t y = VZAxis(-pad.leftThumbstick.yAxis.value);
    int16_t rx = VZAxis(pad.rightThumbstick.xAxis.value);
    int16_t ry = VZAxis(-pad.rightThumbstick.yAxis.value);
    uint16_t z = VZTrigger(pad.leftTrigger.value);
    uint16_t rz = VZTrigger(pad.rightTrigger.value);
    memcpy(&report[3], &x, sizeof(x));
    memcpy(&report[5], &y, sizeof(y));
    memcpy(&report[7], &rx, sizeof(rx));
    memcpy(&report[9], &ry, sizeof(ry));
    memcpy(&report[11], &z, sizeof(z));
    memcpy(&report[13], &rz, sizeof(rz));
    float dpadX = pad.dpad.xAxis.value;
    float dpadY = pad.dpad.yAxis.value;
    BOOL up = dpadY > 0.5f, down = dpadY < -0.5f;
    BOOL right = dpadX > 0.5f, left = dpadX < -0.5f;
    if (up && right) report[15] = 1;
    else if (right && down) report[15] = 3;
    else if (down && left) report[15] = 5;
    else if (left && up) report[15] = 7;
    else if (up) report[15] = 0;
    else if (right) report[15] = 2;
    else if (down) report[15] = 4;
    else if (left) report[15] = 6;
}

- (void)sendCurrentState
{
    if (!_enabled || !_foregroundActive || !_configured ||
        _socketFD < 0 || !_controller)
        return;
    uint8_t report[VZGamepadReportLength];
    [self fillReport:report];
    [self sendReport:report];
}

- (void)sendNeutralReport
{
    if (!_configured || _socketFD < 0)
        return;
    uint8_t neutral[VZGamepadReportLength] = {0};
    neutral[0] = 1;
    neutral[15] = 8;
    [self sendReport:neutral];
}

- (void)sendReport:(const uint8_t[VZGamepadReportLength])report
{
    uint8_t packet[VZGamepadPacketLength] = {0};
    VZWriteBE32(&packet[0], 0x564D4750); // VMGP
    packet[4] = 1;
    packet[5] = 1;
    VZWriteBE16(&packet[6], VZGamepadReportLength);
    VZWriteBE32(&packet[8], ++_sequence);
    VZWriteBE32(&packet[12], _sessionIdentifier);
    memcpy(&packet[16], report, VZGamepadReportLength);
    ssize_t sent = sendto(_socketFD, packet, sizeof(packet), 0,
               (const struct sockaddr *)&_destination,
               sizeof(_destination));
    if (sent != sizeof(packet)) {
        perror("[VirtualMac] gamepad UDP send");
        [self setLastError:[NSString stringWithFormat:@"UDP send failed: %s",
            strerror(errno)]];
        [self publishState:YES];
    } else {
        _packetsSent++;
        [self publishState:NO];
    }
}

- (void)receiveAcks
{
    if (_socketFD < 0)
        return;
    for (;;) {
        uint8_t ack[VZGamepadAckLength];
        ssize_t received = recv(_socketFD, ack, sizeof(ack), 0);
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        if (received != sizeof(ack))
            break;
        uint32_t magic = ((uint32_t)ack[0] << 24) |
            ((uint32_t)ack[1] << 16) | ((uint32_t)ack[2] << 8) | ack[3];
        uint32_t sequence = ((uint32_t)ack[8] << 24) |
            ((uint32_t)ack[9] << 16) | ((uint32_t)ack[10] << 8) | ack[11];
        uint32_t session = ((uint32_t)ack[12] << 24) |
            ((uint32_t)ack[13] << 16) | ((uint32_t)ack[14] << 8) | ack[15];
        if (magic != 0x564D4741 || ack[4] != 1 || ack[5] != 2 ||
            session != _sessionIdentifier)
            continue;
        _acksReceived++;
        _lastAckSequence = sequence;
        _lastAckTime = CACurrentMediaTime();
        [self setLastError:nil];
        [self publishState:NO];
    }
}

- (void)setLastError:(NSString *)error
{
    if ((_lastError == error) || [_lastError isEqualToString:error])
        return;
    [_lastError release];
    _lastError = [error copy];
}

- (NSDictionary *)stateSnapshot
{
    uint8_t report[VZGamepadReportLength];
    [self fillReport:report];
    int16_t x, y, rx, ry;
    uint16_t z, rz;
    memcpy(&x, &report[3], sizeof(x));
    memcpy(&y, &report[5], sizeof(y));
    memcpy(&rx, &report[7], sizeof(rx));
    memcpy(&ry, &report[9], sizeof(ry));
    memcpy(&z, &report[11], sizeof(z));
    memcpy(&rz, &report[13], sizeof(rz));
    uint16_t buttons = (uint16_t)report[1] | (uint16_t)report[2] << 8;
    CFTimeInterval ackAge = _lastAckTime > 0
        ? CACurrentMediaTime() - _lastAckTime : -1;
    return @{
        @"enabled": @(_enabled),
        @"configured": @(_configured),
        @"foreground": @(_foregroundActive),
        @"controllerConnected": @(_controller != nil),
        @"controllerName": _controller.vendorName ?: @"",
        @"destination": _destinationText ?: @"",
        @"packetsSent": @(_packetsSent),
        @"acksReceived": @(_acksReceived),
        @"lastAckSequence": @(_lastAckSequence),
        @"lastAckAge": @(ackAge),
        @"lastError": _lastError ?: @"",
        @"buttons": @(buttons),
        @"leftX": @((float)x / 32767.0f),
        @"leftY": @((float)y / 32767.0f),
        @"rightX": @((float)rx / 32767.0f),
        @"rightY": @((float)ry / 32767.0f),
        @"leftTrigger": @((float)z / 65535.0f),
        @"rightTrigger": @((float)rz / 65535.0f),
        @"hat": @(report[15]),
    };
}

- (void)publishState:(BOOL)immediate
{
    CFTimeInterval now = CACurrentMediaTime();
    if (!immediate && now - _lastStateNotificationTime < 0.10)
        return;
    _lastStateNotificationTime = now;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:VZGamepadBridgeStateDidChangeNotification
        object:self userInfo:[self stateSnapshot]];
}

- (void)sendTestState
{
    if (!_configured || _socketFD < 0) {
        [self setLastError:@"Enter a valid guest IPv4 address and port first"];
        [self publishState:YES];
        return;
    }
    uint8_t report[VZGamepadReportLength];
    [self fillReport:report];
    [self sendReport:report];
}

- (void)setForegroundActive:(BOOL)active
{
    if (_foregroundActive == active)
        return;
    _foregroundActive = active;
    if (!active)
        [self sendNeutralReport];
    else
        [self sendCurrentState];
}

- (void)neutralize
{
    [self sendNeutralReport];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self neutralize];
    if (_heartbeat) {
        dispatch_source_cancel(_heartbeat);
        dispatch_release(_heartbeat);
    }
    if (_socketReader) {
        dispatch_source_cancel(_socketReader);
        dispatch_release(_socketReader);
    }
    if (_socketFD >= 0)
        close(_socketFD);
    [_controller release];
    [_destinationText release];
    [_lastError release];
    [super dealloc];
}
@end

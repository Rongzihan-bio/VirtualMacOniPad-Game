# 8. iPad Controller Relay (Development)

The iPad app now observes `GCControllerDidConnectNotification` and
`GCControllerDidDisconnectNotification`, enumerates controllers already
connected when the app launches, and selects the first controller with an
`extendedGamepad` profile. This covers standard Bluetooth and USB gamepads
exposed by iPadOS GameController.

The state is normalized into the 16-byte guest HID report described in
[`07-development-udp-protocol.md`](07-development-udp-protocol.md):

- A/B/X/Y, shoulders, thumbstick clicks, Menu, Options, and Home become bits
  0 through 10.
- Both sticks use signed 16-bit axes; Y is inverted to the HID convention.
- Both analog triggers use unsigned 16-bit values.
- The D-pad becomes the Hat switch.

While a gamepad is connected, the app sends a full state packet at 60 Hz and
also sends immediately on an input change. On controller disconnect or when
the app backgrounds, it sends a neutral state first. The guest helper's 750 ms
default timeout remains the final protection against a lost packet while
tolerating short scheduling and network stalls.

## Enable and test the relay

The relay defaults to disabled. Open Virtual Mac Settings, select the gamepad
relay and test page, enter the guest numeric IPv4 address and UDP port 25863,
then save. The page shows the selected controller and its live buttons,
sticks, triggers, and D-pad before networking is enabled.

Start the guest receiver as root:

```sh
cd /path/to/VirtualMacOniPad
sudo VirtualMac/scripts/development/start-guest-gamepad-receiver.sh \
  --print-state
```

Tap the GUI test button. A working route shows a recent guest ACK, while the
guest terminal prints the decoded controller state. Enable continuous relay
only after this one-packet test succeeds.

The current implementation accepts only a numeric IPv4 `host:port`, avoiding
DNS changes and ambiguity while NAT/Bridge behavior is being measured.

## NAT versus Bridge

The protocol itself is the same in either mode. The destination is not:

- With **Bridge**, enter the guest's LAN IPv4 address.
- With **NAT**, enter the guest address assigned inside the VM's private
  subnet. Do not use the NAT gateway address unless it is also the guest.

If the iPad app cannot route to the NAT guest address, that is a networking
limitation to resolve in the NAT discovery phase; use Bridge for the first
end-to-end gamepad test. This development transport has no authentication, so
use it only on a trusted network.

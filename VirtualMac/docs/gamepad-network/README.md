# Network Gamepad Relay

This experimental relay forwards one USB or Bluetooth controller connected to
the iPad into the macOS guest as a generic IOHID gamepad. Steam Input can map
the device, and Wine/SDL applications can consume its raw HID controls.

The target data path is:

```text
USB/Bluetooth controller
        |
        v
VirtualMac.app on iPadOS (GameController.framework)
        |
        v
full-state UDP over the VM network
        |
        v
command-line receiver in the macOS guest
        |
        v
IOHIDUserDevice virtual gamepad
        |
        v
Steam / Wine / SDL games
```

## Current scope

- Read physical controllers in the foreground `VirtualMac.app` process.
- The iPad sends one complete normalized state at 60 Hz and on input changes.
- The guest rejects stale packets and neutralizes the device after a 750 ms
  silence, preventing stuck controls while tolerating short stalls.
- Bridge works when the guest LAN IPv4 is reachable. NAT works only when the
  iPad process can route to the guest private IPv4.
- The development protocol is unauthenticated and must be used only on a
  trusted network.
- `IOHIDUserDevice` creation currently requires the virtual-device entitlement,
  root in the tested guest, and a guest security configuration that permits the
  ad-hoc-signed helper.
- Apple `GameController.framework` intentionally filters this virtual device on
  the tested macOS release. Safari/native GameController support is therefore
  not a goal of this implementation; use Steam Input or raw IOHID consumers.

## Documents

1. [Development UDP protocol](07-development-udp-protocol.md)
2. [iPad controller relay](08-ipad-controller-relay.md)
3. [中文测试操作指南](09-中文测试操作指南.md)

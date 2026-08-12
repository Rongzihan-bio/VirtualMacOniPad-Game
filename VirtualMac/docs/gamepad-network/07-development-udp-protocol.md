# 7. Development UDP Protocol

This is the intentionally small, unauthenticated protocol used only to prove
the guest-side network-to-HID path. It is not a release protocol and must only
be exposed on a trusted development network.

The guest helper listens on IPv4 UDP. Each datagram is exactly 32 bytes, with
all multi-byte envelope fields in network byte order:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `VMGP` |
| 4 | 1 | Protocol version: `1` |
| 5 | 1 | Type: `1` for full controller state |
| 6 | 2 | Payload length: `16` |
| 8 | 4 | Monotonically increasing sequence number |
| 12 | 4 | Random sender session ID |
| 16 | 16 | HID input report |

The HID report begins with report ID `1`, contains 16 button bits, four signed
little-endian 16-bit sticks, two unsigned little-endian 16-bit triggers, and a
Hat switch in byte 15 (`0`–`7`, or `8` neutral). The payload intentionally has
the guest HID byte order, so it can be passed to `IOHIDUserDevice` unchanged.

The listener rejects malformed and stale packets. Its command-line default is
to send a neutral report 750 ms after the last accepted state packet,
preventing a stuck button when the sender, controller, or network disappears
while tolerating short scheduling or Wi-Fi stalls. `--timeout-ms` can tune the
development value between 100 and 10000 ms.

The UDP socket is nonblocking and uses an enlarged receive buffer. When several
packets are queued, the listener preserves every button and Hat-switch edge but
coalesces redundant analog-only snapshots to the newest state. Sequence gaps
are counted for diagnostics and never retransmitted because every datagram is a
complete state snapshot.

For GUI diagnostics the listener replies to every accepted state with a
16-byte ACK: ASCII `VMGA`, version `1`, type `2`, and the accepted big-endian
sequence number at offset 8. The ACK confirms reception by the guest process;
bytes 12–15 echo the sender session ID. A new session ID resets sequence
filtering, so restarting the iPad app does not require restarting the guest
helper. The ACK confirms reception by the guest process; it does not
authenticate the sender.

## Local guest test

Terminal 1 (requires root because this VM requires it for virtual HID):

```sh
cd /path/to/VirtualMacOniPad
sudo VirtualMac/scripts/development/start-guest-gamepad-receiver.sh --print-state
```

Terminal 2:

```sh
cd /path/to/VirtualMacOniPad
VirtualMac/build/guest-gamepad-send --host 127.0.0.1 --port 25863 --duration 3
```

The listener should report a timeout and neutralization roughly 750 ms after
the sender exits. Use an HID tester or a native gamepad-aware application to
verify the initial button press and moving left stick.

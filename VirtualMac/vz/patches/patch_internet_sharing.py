#!/usr/bin/env python3
"""Apply narrowly verified iPad compatibility patches to InternetSharing."""

import pathlib
import sys


def main(path_text: str) -> None:
    path = pathlib.Path(path_text)
    data = bytearray(path.read_bytes())

    # Ventura 13.2.1's startup prerequisite at 0x10001cc54 configures only
    # com.apple.NS-logging.plist through SCPreferences. That desktop-only
    # preference domain is unavailable on iPadOS, and the daemon otherwise
    # treats its absence as fatal. Return success while leaving all network,
    # DHCP, NAT, and packet-filter initialization unchanged.
    offset = 0x1CC54
    expected = bytes.fromhex("7f2303d5ffc300d1")  # pacibsp; sub sp,sp,#0x30
    replacement = bytes.fromhex("20008052c0035fd6")  # mov w0,#1; ret
    actual = bytes(data[offset:offset + len(expected)])
    if actual != expected:
        raise SystemExit(
            f"{path}: unexpected logging initializer bytes at {offset:#x}: "
            f"{actual.hex()}"
        )
    data[offset:offset + len(replacement)] = replacement

    # InternetSharing enables bootpd by launchd label through
    # SMJobSetEnabled. Reusing com.apple.bootpd causes ServiceManagement on
    # iPadOS to replace our matching Ventura helper with the sandboxed stock
    # iPadOS job; that binary cannot see /var/db/dhcpd_leases and never answers
    # the guest's otherwise-valid DHCP discovers. Use a private, equal-length
    # label registered by our deployment plist. Equal length is required
    # because the literal backs a constant CFString with a fixed length.
    old = b"com.apple.bootpd"
    new = b"vzi.apple.bootpd"
    if len(old) != len(new):
        raise AssertionError("bootpd launchd labels must remain equal length")
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one bootpd launchd label, found {count}"
        )
    data = bytearray(data.replace(old, new))

    # The desktop daemon verifies that bootpd exists at the sealed-system path
    # before enabling its launchd job. On rootless iPadOS the matching helper is
    # deployed under /var/jb, while the job itself remains com.apple.bootpd.
    # Skip only the path-existence failure; notification and launchd setup still
    # execute and therefore surface real helper failures.
    offset = 0x18470
    expected = bytes.fromhex("80010034")  # cbz w0, success
    replacement = bytes.fromhex("0c000014")  # b success
    actual = bytes(data[offset:offset + len(expected)])
    if actual != expected:
        raise SystemExit(
            f"{path}: unexpected bootpd path-check bytes at {offset:#x}: "
            f"{actual.hex()}"
        )
    data[offset:offset + len(replacement)] = replacement

    # rtadvd is likewise staged under /var/jb on a rootless jailbreak. Preserve
    # all IPv6 setup while accepting the relocated matching Ventura helper.
    offset = 0x1BCCC
    expected = bytes.fromhex("40feff34")  # cbz w0, success
    replacement = bytes.fromhex("f2ffff17")  # b success
    actual = bytes(data[offset:offset + len(expected)])
    if actual != expected:
        raise SystemExit(
            f"{path}: unexpected rtadvd path-check bytes at {offset:#x}: "
            f"{actual.hex()}"
        )
    data[offset:offset + len(replacement)] = replacement

    # NAT-PMP is an optional port-mapping service, but the desktop initializer
    # treats its sealed-system helper-path probe as fatal to the whole shared
    # network. Allow network creation to continue when the relocated helper is
    # not requested; outbound NAT and DHCP do not depend on NAT-PMP.
    offset = 0x19A0C
    expected = bytes.fromhex("60010034")  # cbz w0, available
    replacement = bytes.fromhex("0b000014")  # b available
    actual = bytes(data[offset:offset + len(expected)])
    if actual != expected:
        raise SystemExit(
            f"{path}: unexpected natpmpd path-check bytes at {offset:#x}: "
            f"{actual.hex()}"
        )
    data[offset:offset + len(replacement)] = replacement

    # The iPad root filesystem is sealed, so NetworkSharing cannot update the
    # desktop DHCP configuration under /etc. Keep the filename and binary
    # layout unchanged while moving it to a writable transient location. The
    # matching bootpd helper receives the same path rewrite.
    old = b"/etc/bootpd.plist"
    new = b"/tmp/bootpd.plist"
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one bootpd config path, found {count}"
        )
    data = bytearray(data.replace(old, new))

    old = b"/etc/com.apple.mis.rtadvd.conf"
    new = b"/tmp/com.apple.mis.rtadvd.conf"
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one rtadvd config path, found {count}"
        )
    data = bytearray(data.replace(old, new))

    path.write_bytes(data)
    print(
        f"patched {path}: bypassed desktop logging preferences and "
        "rootless network-helper path checks and selected matching bootpd"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} INTERNET_SHARING_BINARY")
    main(sys.argv[1])

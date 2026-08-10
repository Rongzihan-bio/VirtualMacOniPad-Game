#!/usr/bin/env python3
"""Adapt Big Sur InternetSharing to iPadOS 14 IOUserEthernet timing.

iPadOS 14 reports its newly attached IOUserEthernet interface before every
socket ioctl can address it. InternetSharing treats a transient SIOCSIFMTU
failure as fatal even though the interface already has the requested 1500-byte
default MTU. The iPadOS 14-only daemon therefore makes this best-effort, just
as ifconfig callers normally do after attach.
"""

import argparse
import struct
from pathlib import Path


PATCH_OFFSET = 0xC7C4
EXPECTED = 0x54000060  # b.eq failure after ioctl(SIOCSIFMTU)
NOP = 0xD503201F
NATPMP_ENABLED_OFFSET = 0x2C154


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()

    data = bytearray(args.binary.read_bytes())
    found = struct.unpack_from("<I", data, PATCH_OFFSET)[0]
    if found != EXPECTED:
        raise SystemExit(
            f"{args.binary}: unexpected SIOCSIFMTU branch at "
            f"0x{PATCH_OFFSET:x}: 0x{found:08x}"
        )
    struct.pack_into("<I", data, PATCH_OFFSET, NOP)
    natpmp_enabled = struct.unpack_from("<I", data, NATPMP_ENABLED_OFFSET)[0]
    if natpmp_enabled != 1:
        raise SystemExit(
            f"{args.binary}: unexpected NAT-PMP default at "
            f"0x{NATPMP_ENABLED_OFFSET:x}: {natpmp_enabled}"
        )
    # iPadOS has no natpmpd. Port forwarding is optional and must not make
    # creation of the guest's ordinary outbound-NAT interface fail.
    struct.pack_into("<I", data, NATPMP_ENABLED_OFFSET, 0)

    # Never address Apple's system DHCP job. The matching iPadOS helper is
    # shipped at a package-owned path and registered under this private label.
    old = b"com.apple.bootpd"
    new = b"vzi.apple.bootpd"
    if len(old) != len(new) or data.count(old) != 1:
        raise SystemExit(
            f"{args.binary}: unexpected iPadOS 14 bootpd label layout"
        )
    data = bytearray(data.replace(old, new))

    # Share the writable configuration path with the private iPadOS helper.
    old = b"/etc/bootpd.plist"
    new = b"/tmp/bootpd.plist"
    if len(old) != len(new) or data.count(old) != 1:
        raise SystemExit(
            f"{args.binary}: unexpected iPadOS 14 bootpd path layout"
        )
    data = bytearray(data.replace(old, new))
    args.binary.write_bytes(data)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Relocate the matching iPadOS 14 DHCP helper's writable configuration."""

import pathlib
import sys


def main(path_text: str) -> None:
    path = pathlib.Path(path_text)
    data = bytearray(path.read_bytes())

    # iPadOS bootpd normally reads this file from the sealed system volume.
    # The package-owned InternetSharing process writes the same configuration
    # to /tmp. Shortening a NUL-terminated cstring in place preserves every
    # Mach-O offset and authenticated pointer in this arm64e executable.
    old = b"/Library/Preferences/SystemConfiguration/bootpd.plist\0"
    new = b"/tmp/bootpd.plist\0"
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one iPadOS bootpd config path, found {count}"
        )
    replacement = new + b"\0" * (len(old) - len(new))
    data = bytearray(data.replace(old, replacement))
    path.write_bytes(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} BOOTPD_BINARY")
    main(sys.argv[1])

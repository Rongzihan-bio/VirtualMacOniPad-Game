#!/usr/bin/env python3
"""Apply rootless path compatibility patches to Ventura network helpers."""

import pathlib
import sys


def main(path_text: str) -> None:
    path = pathlib.Path(path_text)
    data = bytearray(path.read_bytes())
    old = b"/etc/bootpd.plist"
    new = b"/tmp/bootpd.plist"
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one bootpd config path, found {count}"
        )
    data = bytearray(data.replace(old, new))

    # Ventura binds the desktop symbol variant while iPadOS 16 exports the
    # same ABI as plain syslog.  Rewrite both symbol-table/string-pool copies
    # in place so Mach-O offsets remain unchanged.
    old = b"_syslog$DARWIN_EXTSN"
    new = b"_syslog" + b"\0" * (len(old) - len(b"_syslog"))
    count = data.count(old)
    if count != 2:
        raise SystemExit(
            f"{path}: expected two extended syslog symbol strings, found {count}"
        )
    data = bytearray(data.replace(old, new))
    path.write_bytes(data)
    print(f"patched {path}: writable DHCP config and iPad syslog ABI")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} NETWORK_HELPER_BINARY")
    main(sys.argv[1])

#!/usr/bin/env python3
"""Allow the macOS 13.2.1 VMM to omit unavailable host-side devices.

The iPadOS kernel does not contain macOS's AppleUSBUserHCI kext or its related
AppleUSBUserHCIResources service. Consequently, IOUSBHostControllerInterface
returns nil while creating com.apple.virtualization.avp.usb-device-controller.

The VMM's device-factory loop already represents devices as nullable pointers,
and its success path explicitly handles a null pointer before continuing to the
next descriptor. Remove only the branch that converts a null device into an
immediate failure. This does not bypass the platform initializer: all remaining
device descriptors are still initialized, and the factory's finalization runs.

The exact instruction and its neighbors are asserted for the 22D68 arm64e VMM
after iOS stamping/install-name rewriting, preventing accidental application to
another binary.
"""

import struct
import sys


PATCH_OFFSET = 0x154F20
EXPECTED = (
    0x9101E3E0,  # add x0, sp, #0x78
    0x97FB8F92,  # call device-result cleanup
    0x3600017A,  # tbz w26, #0, failure
    0xA97723BA,  # success: ldp x26, x8, [x29, #-0x90]
)
NOP = 0xD503201F


def main(path: str) -> None:
    with open(path, "rb") as source:
        data = bytearray(source.read())
    actual = struct.unpack_from("<4I", data, PATCH_OFFSET - 8)
    if actual != EXPECTED:
        expected_text = " ".join(f"{word:08x}" for word in EXPECTED)
        actual_text = " ".join(f"{word:08x}" for word in actual)
        raise SystemExit(
            f"{path}: optional-device site mismatch at 0x{PATCH_OFFSET - 8:x}: "
            f"expected {expected_text}, got {actual_text}"
        )
    struct.pack_into("<I", data, PATCH_OFFSET, NOP)
    with open(path, "wb") as output:
        output.write(data)
    print(
        f"patched {path}: nullable host devices continue at "
        f"0x{PATCH_OFFSET:x}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VMM_BINARY")
    main(sys.argv[1])

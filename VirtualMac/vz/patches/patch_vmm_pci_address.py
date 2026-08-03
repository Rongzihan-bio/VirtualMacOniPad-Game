#!/usr/bin/env python3
"""Repair 22D68 VMM PCI address allocation on iPadOS.

On iPadOS a PCI device can retain the automatic-address sentinel 0x7ff. The
macOS VMM uses it directly as a 256-entry table index, reading and
occasionally writing about 16 KiB beyond the bus. That makes startup alternate
between a phantom occupied-slot failure and heap-corrupting apparent success.
Preserve an explicit address when it is free; otherwise allocate the first free
slot before the table access.

The arm64e VMM is a thin image whose virtual addresses map to identical file
offsets above its 0x100000000 base. The helper occupies the tail of a long
VirtioSocket diagnostic string; this VM deliberately configures no socket
devices. Both the call site and the complete original string are asserted so
this build-specific patch fails closed on any other binary.

The helper avoids new Mach-O imports in the extracted executable.
"""

import struct
import sys


PCI_ADDRESS_CALL_OFFSET = 0x179DF0
STRING_OFFSET = 0x1A5F4A
ORIGINAL_STRING = (
    b"VirtioSocketDevice: Unexpected error sending data from guest to host: %s.\0"
)
HELPER_OFFSET = STRING_OFFSET + 2  # preserve 4-byte instruction alignment


def encode_bl(source: int, target: int) -> int:
    delta = target - source
    if delta & 3 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError(f"BL target out of range: 0x{source:x} -> 0x{target:x}")
    return 0x94000000 | ((delta >> 2) & 0x03FFFFFF)


def pci_address_helper_words() -> tuple[int, ...]:
    # Replace "add x8, x24, x8, lsl #3". Preserve a free explicit address;
    # otherwise select the first free slot.
    return (
        0xF11FFD1F,  # cmp x8, #0x7ff
        0x54000080,  # b.eq scan
        0x8B080F08,  # add x8, x24, x8, lsl #3
        0xF940250A,  # ldr x10, [x8, #0x48]
        0xB400012A,  # cbz x10, ready
        0xAA1803E8,  # scan: mov x8, x24
        0xD280200B,  # mov x11, #0x100
        0xF940250A,  # loop: ldr x10, [x8, #0x48]
        0xB40000AA,  # cbz x10, ready
        0x91002108,  # add x8, x8, #8
        0xF100056B,  # subs x11, x11, #1
        0x54FFFF81,  # b.ne loop
        0xAA1803E8,  # full: mov x8, x24 (preserve occupied failure)
        0xD65F03C0,  # ret
    )


def main(path: str) -> None:
    with open(path, "rb") as source:
        data = bytearray(source.read())

    actual_string = bytes(
        data[STRING_OFFSET : STRING_OFFSET + len(ORIGINAL_STRING)]
    )
    if actual_string != ORIGINAL_STRING:
        raise SystemExit(
            f"{path}: helper storage mismatch at 0x{STRING_OFFSET:x}"
        )

    helper = struct.pack(
        f"<{len(pci_address_helper_words())}I",
        *pci_address_helper_words()
    )
    available = len(ORIGINAL_STRING) - (HELPER_OFFSET - STRING_OFFSET)
    if len(helper) > available:
        raise SystemExit("PCI address helper does not fit asserted storage")
    pci_address_instruction = struct.unpack_from(
        "<I", data, PCI_ADDRESS_CALL_OFFSET
    )[0]
    if pci_address_instruction != 0x8B080F08:
        raise SystemExit(
            f"{path}: PCI address site mismatch at "
            f"0x{PCI_ADDRESS_CALL_OFFSET:x}: {pci_address_instruction:08x}"
        )
    data[HELPER_OFFSET : HELPER_OFFSET + len(helper)] = helper
    struct.pack_into(
        "<I", data, PCI_ADDRESS_CALL_OFFSET,
        encode_bl(PCI_ADDRESS_CALL_OFFSET, HELPER_OFFSET)
    )
    with open(path, "wb") as output:
        output.write(data)
    print(
        f"patched {path}: PciBus address 0x{PCI_ADDRESS_CALL_OFFSET:x} -> "
        f"free-slot allocator 0x{HELPER_OFFSET:x}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VMM_BINARY")
    main(sys.argv[1])

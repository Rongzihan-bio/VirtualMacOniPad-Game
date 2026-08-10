#!/usr/bin/env python3
"""Convert Ventura arm64e Objective-C class-data fixups to the iOS 15 ABI.

Ventura signs class_t::data with the DA key.  The iOS 15 Objective-C runtime
expects that field to be an ordinary chained rebase (as emitted by its own
system frameworks), so it treats the PAC bits as address bits and faults in
readClass.  Only the data field is different; isa and superclass remain
authenticated.  Rewrite that one fixup in every class_t without changing the
chain topology or any code.
"""

import struct
import sys

LC_SEGMENT_64 = 0x19


def main(path: str) -> None:
    image = bytearray(open(path, "rb").read())
    ncmds = struct.unpack_from("<I", image, 16)[0]
    command_offset = 32
    sections = []

    for _ in range(ncmds):
        command, command_size = struct.unpack_from("<II", image, command_offset)
        if command == LC_SEGMENT_64:
            section_count = struct.unpack_from("<I", image, command_offset + 64)[0]
            section_offset = command_offset + 72
            for _ in range(section_count):
                name = image[section_offset:section_offset + 16].split(b"\0", 1)[0]
                if name == b"__objc_data":
                    size = struct.unpack_from("<Q", image, section_offset + 40)[0]
                    file_offset = struct.unpack_from("<I", image, section_offset + 48)[0]
                    sections.append((file_offset, size))
                section_offset += 80
        command_offset += command_size

    patched = 0
    for file_offset, size in sections:
        if size % 40:
            raise SystemExit(f"unexpected __objc_data size {size:#x} in {path}")
        # class_t is five pointers.  data is its fifth field.
        for offset in range(file_offset + 32, file_offset + size, 40):
            word = struct.unpack_from("<Q", image, offset)[0]
            authenticated = word >> 63
            bound = (word >> 62) & 1
            diversity = (word >> 32) & 0xFFFF
            key = (word >> 49) & 3
            if not authenticated or bound or diversity != 0x61F8 or key != 2:
                raise SystemExit(
                    f"unexpected class data fixup {word:#018x} at file offset {offset:#x}"
                )
            target = word & 0xFFFFFFFF
            next_delta = (word >> 51) & 0x7FF
            plain_rebase = target | (next_delta << 51)
            struct.pack_into("<Q", image, offset, plain_rebase)
            patched += 1

    if not patched:
        print(f"{path}: no Objective-C class data to adapt")
        return
    open(path, "wb").write(image)
    print(f"{path}: adapted {patched} Objective-C class-data fixups for iPadOS 15")


if __name__ == "__main__":
    main(sys.argv[1])

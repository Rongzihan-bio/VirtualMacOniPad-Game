#!/usr/bin/env python3
"""Add one LC_LOAD_DYLIB to a thin 64-bit Mach-O using header slack.

The file is not relocated: the new command must fit between the existing load
commands and the first file-backed section. The caller must re-sign the Mach-O
afterward. This deliberately small patcher is sufficient for the matching VMM 
and asserts every structural assumption before writing.
"""

import os
import struct
import sys


MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def main(path: str, install_name: str) -> None:
    with open(path, "rb") as source:
        data = bytearray(source.read())

    if len(data) < 32:
        raise SystemExit(f"{path}: file is smaller than a Mach-O header")
    magic, _, _, _, command_count, command_bytes, _, _ = struct.unpack_from(
        "<8I", data, 0
    )
    if magic != MH_MAGIC_64:
        raise SystemExit(f"{path}: expected thin little-endian 64-bit Mach-O")

    cursor = 32
    first_section_offset = len(data)
    existing_names: list[str] = []
    for _ in range(command_count):
        if cursor + 8 > 32 + command_bytes:
            raise SystemExit(f"{path}: truncated load-command table")
        command, command_size = struct.unpack_from("<2I", data, cursor)
        if command_size < 8 or cursor + command_size > 32 + command_bytes:
            raise SystemExit(f"{path}: invalid load command at 0x{cursor:x}")
        if command == LC_LOAD_DYLIB:
            name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
            name_start = cursor + name_offset
            name_end = data.find(b"\0", name_start, cursor + command_size)
            if name_end != -1:
                existing_names.append(data[name_start:name_end].decode())
        if command == LC_SEGMENT_64:
            section_count = struct.unpack_from("<I", data, cursor + 64)[0]
            section_cursor = cursor + 72
            if section_cursor + section_count * 80 > cursor + command_size:
                raise SystemExit(f"{path}: invalid LC_SEGMENT_64 sections")
            for index in range(section_count):
                section = section_cursor + index * 80
                section_offset = struct.unpack_from("<I", data, section + 48)[0]
                section_size = struct.unpack_from("<Q", data, section + 40)[0]
                if section_offset and section_size:
                    first_section_offset = min(first_section_offset,
                                               section_offset)
        cursor += command_size

    if cursor != 32 + command_bytes:
        raise SystemExit(f"{path}: load-command size mismatch")
    if install_name in existing_names:
        print(f"{path}: already loads {install_name}")
        return

    encoded_name = install_name.encode() + b"\0"
    command_size = align(24 + len(encoded_name), 8)
    new_end = cursor + command_size
    if new_end > first_section_offset:
        raise SystemExit(
            f"{path}: need {command_size} bytes of header slack, have "
            f"{first_section_offset - cursor}"
        )
    if any(data[cursor:new_end]):
        raise SystemExit(f"{path}: prospective header slack is not zero-filled")

    command = bytearray(command_size)
    struct.pack_into("<6I", command, 0, LC_LOAD_DYLIB, command_size,
                     24, 2, 0x10000, 0x10000)
    command[24:24 + len(encoded_name)] = encoded_name
    data[cursor:new_end] = command
    struct.pack_into("<I", data, 16, command_count + 1)
    struct.pack_into("<I", data, 20, command_bytes + command_size)

    temporary = f"{path}.add-dylib.tmp"
    with open(temporary, "wb") as output:
        output.write(data)
    os.chmod(temporary, os.stat(path).st_mode)
    os.replace(temporary, path)
    print(
        f"patched {path}: LC_LOAD_DYLIB {install_name} "
        f"({command_size} bytes at 0x{cursor:x})"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} MACHO INSTALL_NAME")
    main(sys.argv[1], sys.argv[2])

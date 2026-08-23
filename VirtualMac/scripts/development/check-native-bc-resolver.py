#!/usr/bin/env python3
"""Check whether the runtime native-BC patchfinder resolves an AGX Mach-O.

This mirrors the structural matcher in native_bc_texture_support.m. It is a
fast firmware qualification tool; it never patches or executes the binary.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19


def add_immediate(instruction: int, destination: int, source: int) -> bool:
    return instruction & 0xFFC003FF == 0x91000000 | destination | source << 5


def adrp(instruction: int, destination: int) -> bool:
    return instruction & 0x9F00001F == 0x90000000 | destination


def match(code: tuple[int, ...]) -> int | None:
    if code[0] not in (0x51000410, 0xD1000410):
        return None
    first_compare = 0xF100021F if code[0] == 0xD1000410 else 0x7100021F
    if code[1] & 0xFFC003FF != first_compare:
        return None
    if code[2] & 0xFF00001F != 0x54000008:
        return None
    if not adrp(code[3], 0) or not add_immediate(code[4], 0, 0):
        return None
    if code[5] & 0xFFC003FF != 0xF100021F:
        return None
    if not (
        code[6] == 0x9A9F9210
        and adrp(code[7], 17)
        and add_immediate(code[8], 17, 17)
        and code[9] == 0xB8B07A30
        and code[10] == 0x10000011
        and code[11] == 0x8B100230
        and code[12] == 0xD61F0200
    ):
        return None
    first_limit = code[1] >> 10 & 0xFFF
    second_limit = code[5] >> 10 & 0xFFF
    if not first_limit or first_limit != second_limit:
        return None
    return first_limit + 2


def macho_layout(data: bytes) -> tuple[tuple[int, int, int], list[tuple[int, int, int, int]]]:
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
        raise ValueError("not a thin little-endian 64-bit Mach-O")
    command_count = struct.unpack_from("<I", data, 16)[0]
    command_offset = 32
    found_text: tuple[int, int, int] | None = None
    segments: list[tuple[int, int, int, int]] = []
    for _ in range(command_count):
        command, command_size = struct.unpack_from("<II", data, command_offset)
        if command_size < 8 or command_offset + command_size > len(data):
            raise ValueError("invalid load command")
        if command == LC_SEGMENT_64:
            vm_address, vm_size, file_offset, file_size = struct.unpack_from(
                "<QQQQ", data, command_offset + 24
            )
            segments.append((vm_address, vm_size, file_offset, file_size))
            section_count = struct.unpack_from("<I", data, command_offset + 64)[0]
            section_offset = command_offset + 72
            for _ in range(section_count):
                section_name = data[section_offset : section_offset + 16].rstrip(b"\0")
                segment_name = data[section_offset + 16 : section_offset + 32].rstrip(b"\0")
                if section_name == b"__text" and segment_name == b"__TEXT":
                    address, size, offset = struct.unpack_from(
                        "<QQI", data, section_offset + 32
                    )
                    if offset + size > len(data) or size % 4:
                        raise ValueError("invalid __text section")
                    found_text = offset, size, address
                section_offset += 80
        command_offset += command_size
    if found_text is None:
        raise ValueError("missing __TEXT,__text")
    return found_text, segments


def vm_bytes(
    data: bytes, segments: list[tuple[int, int, int, int]], address: int, size: int
) -> bytes:
    for vm_address, _vm_size, file_offset, file_size in segments:
        if vm_address <= address and address + size <= vm_address + file_size:
            offset = file_offset + address - vm_address
            return data[offset : offset + size]
    raise ValueError(f"VM address 0x{address:x} is not file-backed")


def sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def descriptor_hash(record: bytes) -> int:
    result = 14695981039346656037
    for byte in record:
        result = (result ^ byte) * 1099511628211 & 0xFFFFFFFFFFFFFFFF
    return result


def adrp_target(pc: int, instruction: int) -> int:
    immediate = ((instruction >> 5 & 0x7FFFF) << 2) | (instruction >> 29 & 3)
    return (pc & ~0xFFF) + (sign_extend(immediate, 21) << 12)


def add_value(instruction: int) -> int:
    immediate = instruction >> 10 & 0xFFF
    return immediate << (12 if instruction & 1 << 22 else 0)


def descriptor_for_format(
    data: bytes,
    segments: list[tuple[int, int, int, int]],
    instructions: tuple[int, ...],
    text_address: int,
    chooser_index: int,
    format_value: int,
) -> int:
    chooser_address = text_address + chooser_index * 4
    if format_value == 0:
        target_index = chooser_index + 16
    else:
        table_pc = chooser_address + 7 * 4
        table_address = adrp_target(table_pc, instructions[chooser_index + 7])
        table_address += add_value(instructions[chooser_index + 8])
        table_entry = struct.unpack(
            "<i", vm_bytes(data, segments, table_address + (format_value - 1) * 4, 4)
        )[0]
        target_address = chooser_address + 10 * 4 + table_entry
        target_index = chooser_index + (target_address - chooser_address) // 4
    target_pc = text_address + target_index * 4
    first, second = instructions[target_index : target_index + 2]
    if first == 0xD65F03C0:
        # The dispatcher preloads its most common record in x0; switch cases
        # using that record jump directly to a shared ret.
        first, second = instructions[chooser_index + 3 : chooser_index + 5]
        target_pc = text_address + (chooser_index + 3) * 4
    if not adrp(first, 0) or not add_immediate(second, 0, 0):
        raise ValueError(f"format {format_value} target is not an AGX record return")
    return adrp_target(target_pc, first) + add_value(second)


def inspect(path: pathlib.Path) -> tuple[int, int, str]:
    data = path.read_bytes()
    (offset, size, address), segments = macho_layout(data)
    instructions = struct.unpack_from(f"<{size // 4}I", data, offset)
    matches: list[tuple[int, int, int]] = []
    for index in range(len(instructions) - 17):
        count = match(instructions[index : index + 18])
        if count is None:
            continue
        branch = instructions[index + 2]
        branch_words = branch >> 5 & 0x7FFFF
        if branch_words & 0x40000:
            branch_words -= 0x80000
        target = index + 2 + branch_words
        if not 0 <= target <= len(instructions) - 3:
            continue
        if not (
            adrp(instructions[target], 0)
            and add_immediate(instructions[target + 1], 0, 0)
            and instructions[target + 2] == 0xD65F03C0
        ):
            continue
        matches.append((address + index * 4, count, index))
    if len(matches) != 1:
        raise ValueError(f"expected one chooser, found {len(matches)}")
    chooser_address, count, chooser_index = matches[0]
    invalid = descriptor_for_format(
        data, segments, instructions, address, chooser_index, 0
    )
    probes = (1, 10, 30, 70, 80, 115, 170, 180, 204)
    records = [
        descriptor_for_format(
            data, segments, instructions, address, chooser_index, format_value
        )
        for format_value in probes
    ]
    if any(record == invalid for record in records):
        raise ValueError("known valid format resolves to the invalid record")
    adjacent_pairs = sum(
        abs(record - previous) == 0x60
        for index, record in enumerate(records)
        for previous in records[:index]
    )
    if adjacent_pairs < 2:
        raise ValueError("driver does not prove the 0x60-byte descriptor ABI")
    for record in (invalid, *records):
        vm_bytes(data, segments, record, 0x60)
    expected_hashes = {
        170: 0x96C7F2141F60B4C2,
        180: 0xE095D5CB46537E57,
        204: 0xD0CB277563853582,
    }
    for format_value, expected_hash in expected_hashes.items():
        record = descriptor_for_format(
            data, segments, instructions, address, chooser_index, format_value
        )
        if descriptor_hash(vm_bytes(data, segments, record, 0x60)) != expected_hash:
            raise ValueError(f"format {format_value} descriptor ABI changed")
    bc_formats = (130, 131, 132, 133, 134, 135, 140, 141, 142, 143, 150, 151, 152, 153)
    bc_records = [
        descriptor_for_format(
            data, segments, instructions, address, chooser_index, format_value
        )
        for format_value in bc_formats
    ]
    invalid_count = sum(record == invalid for record in bc_records)
    if invalid_count not in (0, len(bc_records)):
        raise ValueError("driver has a partial BC descriptor table")
    for record in bc_records:
        vm_bytes(data, segments, record, 0x60)
    state = "native" if not invalid_count else "absent"
    return chooser_address, count, state


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mach_o", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    failed = False
    for path in args.mach_o:
        try:
            address, count, state = inspect(path)
            print(
                f"PASS {path}: chooser=0x{address:x} formats={count} "
                f"record_abi=0x60 bc={state}"
            )
        except (OSError, ValueError, struct.error) as error:
            failed = True
            print(f"FAIL {path}: {error}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Disable macOS PVG exception logs that are unsafe in the iOS process.

The 22D68 PGFIFO command dispatchers catch Objective-C exceptions and log them
with a ``%@`` argument before running their normal recovery paths.  On iPadOS, 
libsystem_trace attempts to authenticate/dereference a macOS exception
object while flattening the log argument and crashes the VMM in objc_msgSend.
Replacing only those logging calls with NOPs falls through to each existing
branch back to exception recovery.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


LOG_CALL_OFFSETS = (
    0x1C7F4,
    0x1C9F0,
    0x1CC04,
    0x1CE00,
    0x1CFFC,
    0x1D1FC,
    0x1D438,
    0x1D840,
    0x1DA70,
    0x1DC20,
    0x1DE40,
    0x1E040,
    0x1E23C,
    0x1E524,
    0x1E770,
    0x1E9BC,
    0x1EBBC,
    0x1EEB0,
    0x1F240,
    0x1F498,
    0x1F8F4,
    0x1F9C8,
    0x201BC,
    0x203BC,
    0x20584,
    0x20788,
    0x20984,
    0x20B30,
    0x20EFC,
    0x21268,
    0x21570,
)
OS_LOG_ERROR_STUB_OFFSET = 0x28278
NOP = 0xD503201F


def branch_target(instruction: int, offset: int) -> int | None:
    if instruction & 0xFC000000 != 0x94000000:
        return None
    immediate = instruction & 0x03FFFFFF
    if immediate & 0x02000000:
        immediate -= 0x04000000
    return offset + immediate * 4


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()

    data = bytearray(args.binary.read_bytes())
    if len(data) < max(LOG_CALL_OFFSETS) + 4:
        raise SystemExit(f"{args.binary}: file is too small")

    patched = 0
    for offset in LOG_CALL_OFFSETS:
        current = struct.unpack_from("<I", data, offset)[0]
        if current == NOP:
            continue
        target = branch_target(current, offset)
        if target != OS_LOG_ERROR_STUB_OFFSET:
            target_text = "not a BL" if target is None else f"0x{target:x}"
            raise SystemExit(
                f"{args.binary}: unexpected instruction at 0x{offset:x}: "
                f"0x{current:08x} targets {target_text}, expected "
                f"0x{OS_LOG_ERROR_STUB_OFFSET:x}"
            )
        struct.pack_into("<I", data, offset, NOP)
        patched += 1

    if not patched:
        print(f"{args.binary}: all PVG exception logs already disabled")
        return
    args.binary.write_bytes(data)
    print(
        f"{args.binary}: disabled {patched} unsafe PGFIFO exception object "
        "log calls"
    )


if __name__ == "__main__":
    main()

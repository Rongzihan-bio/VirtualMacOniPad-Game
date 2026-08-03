#!/usr/bin/env python3
"""Patch iPadOS 16.3.1 Netrb to use its current bootstrap namespace."""

import pathlib
import sys


def main(path_text: str) -> None:
    path = pathlib.Path(path_text)
    data = bytearray(path.read_bytes())
    expected = bytes.fromhex("42008052")     # mov w2, #2
    replacement = bytes.fromhex("02008052")  # mov w2, #0
    # 22D68 macOS Netrb is the production input.  The iPadOS offset remains
    # accepted so this diagnostic patcher can also validate the native copy.
    candidates = [0xC3C, 0x16B4]
    matches = [
        offset for offset in candidates
        if bytes(data[offset:offset + len(expected)]) == expected
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"{path}: expected one NETRBXPCCreate lookup instruction; "
            f"matched offsets {[hex(offset) for offset in matches]}"
        )
    offset = matches[0]
    data[offset:offset + 4] = replacement

    path.write_bytes(data)
    print(f"patched {path}: Netrb lookup uses current bootstrap domain")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} NETRB_BINARY")
    main(sys.argv[1])

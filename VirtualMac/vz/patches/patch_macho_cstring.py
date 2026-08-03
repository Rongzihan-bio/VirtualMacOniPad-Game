#!/usr/bin/env python3
"""Replace one Mach-O load-command string without moving chained fixups."""

import sys


def main(path: str, old_text: str, new_text: str, expected_count: int = 1) -> None:
    old = old_text.encode() + b"\0"
    new = new_text.encode() + b"\0"
    if len(new) > len(old):
        raise SystemExit(
            f"replacement is longer than original: {len(new)} > {len(old)}"
        )
    with open(path, "rb") as source:
        data = bytearray(source.read())
    count = data.count(old)
    if count != expected_count:
        raise SystemExit(
            f"{path}: expected {expected_count} copies of {old_text!r}, "
            f"found {count}"
        )
    padded = new + bytes(len(old) - len(new))
    data = data.replace(old, padded)
    with open(path, "wb") as output:
        output.write(data)
    print(f"patched {path}: {old_text} -> {new_text}")


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        raise SystemExit(
            f"usage: {sys.argv[0]} MACHO OLD_CSTRING NEW_CSTRING "
            "[EXPECTED_COUNT]"
        )
    expected = int(sys.argv[4]) if len(sys.argv) == 5 else 1
    main(*sys.argv[1:4], expected)

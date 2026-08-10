#!/usr/bin/env python3
"""Guard Ventura VMM's optional PVG reset-retain list on older iPadOS hosts."""

from pathlib import Path
import struct
import sys


SITE = 0x11D58C
CAVE = 0x3D00
SKIP_CLEANUP = 0x11D5B0
CONTINUE_CLEANUP = 0x11D594
LOAD_RETAIN_LIST = 0xF9405694  # ldr x20, [x20, #0xa8]


def branch(source: int, target: int) -> int:
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError(f"invalid branch from {source:#x} to {target:#x}")
    return 0x14000000 | ((delta // 4) & 0x03FFFFFF)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VMM")
    path = Path(sys.argv[1])
    image = bytearray(path.read_bytes())
    old = struct.unpack_from("<I", image, SITE)[0]
    site_branch = branch(SITE, CAVE)
    if old not in (LOAD_RETAIN_LIST, site_branch):
        raise SystemExit(
            f"error: unexpected PVG reset instruction in {path}: {old:#010x}"
        )
    words = [
        LOAD_RETAIN_LIST,
        0xB5000054,  # cbnz x20, cave + 12
        branch(CAVE + 8, SKIP_CLEANUP),
        0xA9405A95,  # ldp x21, x22, [x20]
        branch(CAVE + 16, CONTINUE_CLEANUP),
    ]
    cave_bytes = struct.pack("<5I", *words)
    if old == LOAD_RETAIN_LIST and any(image[CAVE:CAVE + len(cave_bytes)]):
        raise SystemExit(f"error: VMM compatibility cave is occupied")
    image[CAVE:CAVE + len(cave_bytes)] = cave_bytes
    struct.pack_into("<I", image, SITE, site_branch)
    path.write_bytes(image)
    print(f"Patched VMM optional PVG reset list: {path}")


if __name__ == "__main__":
    main()

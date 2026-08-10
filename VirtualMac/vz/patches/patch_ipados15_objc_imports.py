#!/usr/bin/env python3
"""Retarget post-iPadOS-15 register-specialized ObjC imports.

Ventura's arm64e binaries import objc_retain_x0 and objc_release_x0.  Those
symbols do not exist in iPadOS 15, so its dyld correctly leaves their weak
authenticated GOT entries null.  The ordinary entry points have the same x0
calling contract.  Rewriting the chained-import name lets dyld resolve and
sign every slot itself using the host ABI.
"""

from pathlib import Path
import sys


REPLACEMENTS = {
    b"_objc_retain_x0\0": b"_objc_retain\0\0\0\0",
    b"_objc_release_x0\0": b"_objc_release\0\0\0\0",
}


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} MACH-O")
    path = Path(sys.argv[1])
    data = path.read_bytes()
    counts: list[str] = []
    for old, new in REPLACEMENTS.items():
        assert len(old) == len(new)
        count = data.count(old)
        if count:
            data = data.replace(old, new)
            counts.append(f"{old[:-1].decode()}={count}")
    path.write_bytes(data)
    print(f"{path}: retargeted Objective-C imports " +
          (", ".join(counts) if counts else "none"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Apply the narrow Ventura MobileDevice compatibility fix for iPadOS 14."""

from pathlib import Path
import sys


# ____initCloseNotificationGlobals_block_invoke checks for macOS 12 and then
# selects kIOMainPortDefault over kIOMasterPortDefault.  iPadOS 14 does not
# export the newer weak symbol, although the platform check succeeds after the
# macOS image is restamped.  Select the already-loaded legacy symbol instead.
BEFORE = bytes.fromhex("1f000071 2801889a 000140b9")
AFTER = bytes.fromhex("1f000071 e80309aa 000140b9")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} MOBILEDEVICE")
    path = Path(sys.argv[1])
    image = path.read_bytes()
    count = image.count(BEFORE)
    if count != 1:
        raise SystemExit(
            f"error: expected one iPadOS 14 main-port branch in {path}, "
            f"found {count}"
        )
    path.write_bytes(image.replace(BEFORE, AFTER, 1))
    print(f"Patched iPadOS 14 MobileDevice main-port selection: {path}")


if __name__ == "__main__":
    main()

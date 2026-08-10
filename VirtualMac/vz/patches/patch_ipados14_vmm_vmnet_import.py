#!/usr/bin/env python3
"""Make Ventura VMM load against Big Sur's smaller vmnet key surface."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()

    data = args.binary.read_bytes()
    old = b"_vmnet_enable_checksum_offload_key"
    # Big Sur has no checksum-offload capability. Bind the missing import to
    # an existing vmnet key so the Ventura VMM can load; the iPadOS 14-only
    # vmnet_write interposer then fulfills Ventura's checksum contract in
    # software for the scatter/gather frames emitted by the guest.
    replacement = b"_vmnet_enable_isolation_key" + b"\0" * (
        len(old) - len(b"_vmnet_enable_isolation_key")
    )
    count = data.count(old)
    if count != 2:
        raise SystemExit(
            f"{args.binary}: expected two checksum-key symbol strings, "
            f"found {count}"
        )
    args.binary.write_bytes(data.replace(old, replacement))


if __name__ == "__main__":
    main()

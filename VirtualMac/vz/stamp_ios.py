#!/usr/bin/env python3
"""stamp_ios: post-process an uncache (compact) output into an iOS-loadable, signed dylib.

uncache emits a loadable arm64e Mach-O but leaves the macOS LC_BUILD_VERSION in place and
doesn't sign. This step:
  - rewrites LC_BUILD_VERSION (0x32): platform -> IOS (2), minos/sdk -> <ver> (default 16.0)
  - ad-hoc signs (codesign -f -s -), preserving the LC_DYLD_CHAINED_FIXUPS blob
    (do NOT use ldid -S here: it rebuilds LINKEDIT and drops the chained-fixups command)

vmnet/MetalSerializer weakening is done in uncache via VZ_WEAKEN (LC_LOAD_DYLIB->WEAK).

Usage: stamp_ios.py <in> <out> [minos]    e.g. stamp_ios.py /tmp/Virt.proto /tmp/Virt.ios 16.0
"""
import sys, struct, subprocess, shutil

LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2


def stamp(buf, minos="16.0"):
    maj, _, mn = minos.partition(".")
    ver = (int(maj) << 16) | ((int(mn) if mn else 0) << 8)
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    sizeofcmds = struct.unpack_from("<I", buf, 20)[0]
    off, found = 32, 0
    commands = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        command = bytearray(buf[off:off + sz])
        if cmd == LC_BUILD_VERSION:
            if found:
                off += sz
                continue
            struct.pack_into(
                "<III", command, 8, PLATFORM_IOS, ver, ver
            )  # platform, minos, sdk
            found = 1
        commands.append(command)
        off += sz
    rebuilt = b"".join(commands)
    if len(rebuilt) > sizeofcmds:
        raise ValueError("rebuilt load commands grew unexpectedly")
    struct.pack_into("<II", buf, 16, len(commands), len(rebuilt))
    buf[32:32 + sizeofcmds] = rebuilt + bytes(sizeofcmds - len(rebuilt))
    return found


def main(inp, outp, minos="16.0"):
    buf = bytearray(open(inp, "rb").read())
    n = stamp(buf, minos)
    if not n:
        raise SystemExit("no LC_BUILD_VERSION found")
    open(outp, "wb").write(buf)
    subprocess.run(["codesign", "-f", "-s", "-", outp], check=True)
    cd = subprocess.run(["codesign", "-dvvv", outp], capture_output=True, text=True).stderr
    cdhash = next((l.split("=", 1)[1] for l in cd.splitlines() if l.startswith("CDHash=")), "?")
    print(f"stamped {outp}: platform=iOS minos={minos} ({n} LC_BUILD_VERSION), signed; CDHash={cdhash}")


if __name__ == "__main__":
    main(*sys.argv[1:])

#!/usr/bin/env python3
"""Apply iOS-specific binary patches to the post-extracted Virtualization framework.

The extracted framework expects symbols not available on iOS (or that behave wrong).
Rather than runtime-hook every one, we patch the auth-stubs / call sites directly:

  +0xed980  confstr stub          → returns 8, writes 8 NUL bytes if buf!=NULL
                                    (iOS confstr returns 0 for _CS_DARWIN_USER_TEMP_DIR
                                    -> framework throws "Failed to retrieve cache dir")
  +0xee1f0  sandbox_extension_issue_generic_to_process stub → returns 1
  +0xee200  sandbox_extension_release stub                  → returns 0
                                    (iOS sandbox_extension_* are weak-import unresolved
                                    via flat-namespace; export trick gets shadowed.)
  +0x39ab4..+0x39ab8  device-iter loop in VZ_START -> store xzr into sp+0x528/0x530
                                    instead of LOAD. The vtable method that's
                                    supposed to populate that iterator-pair leaves
                                    them stale, so the loop walks bogus memory &
                                    strlen-crashes on a `*x19 == 0x1` garbage byte.
                                    A destructor later re-reads the SAME slots, so
                                    we must zero the actual memory (not just regs)
                                    or get a free-of-bogus SIGABRT. C++ vtable
                                    dispatch may still be partly mis-wired — worth
                                    revisiting once VMM-side dependencies are in.

These offsets are tied to the specific macOS 13.2.1 Virtualization.framework slice.
"""
import struct, sys, pathlib

def main(path):
    p = pathlib.Path(path)
    b = bytearray(p.read_bytes())
    # confstr stub: cbz x1,+8 ; str xzr,[x1] ; mov x0,#8 ; ret
    struct.pack_into('<IIII', b, 0xed980, 0xb4000041, 0xf900003f, 0xd2800100, 0xd65f03c0)
    # sandbox_extension_issue stub: mov x0,#1 ; ret ; brk ; brk
    struct.pack_into('<IIII', b, 0xee1f0, 0xd2800020, 0xd65f03c0, 0xd4200020, 0xd4200020)
    # sandbox_extension_release stub: mov x0,#0 ; ret ; brk ; brk
    struct.pack_into('<IIII', b, 0xee200, 0xd2800000, 0xd65f03c0, 0xd4200020, 0xd4200020)
    # device-iter loop skip + destructor skip:
    #   +0x39ab4/ab8: STR xzr into sp+0x528/0x530 (so the later destructor at +0x39f98
    #                 reads 0 and cbz x20 → skip free; otherwise stack garbage → SIGABRT)
    #   +0x39ac0    : force-branch to +0x39b30 (loop-exit) regardless of cmp x19, x20.
    #                 The orig was `b.eq #0x39b30`; turning the LOADS into STORES leaves
    #                 x19/x20 with stale values and the cmp doesn't reliably fall through.
    struct.pack_into('<II', b, 0x39ab4, 0xf90297ff, 0xf9029bff)  # str xzr,[sp,#0x528/0x530]
    struct.pack_into('<I',  b, 0x39ac0, 0x1400001c)              # b #+0x70 (=> +0x39b30)

    # Function at +0x3d3fc validates a sandbox-extension struct and throws via NSException
    # when [x1+0x30]==0 (or other validation failures); the localized helper at +0x879b0
    # returns nil for ANY key (Localizable.strings bundle absent on iPad) so the throw turns
    # into "__NSPlaceholderDictionary attempt to insert nil object". The struct fields it
    # validates were populated by the device-iter loop we skipped, so we make it return
    # success (x0=0) immediately. Caller doesn't consume x0.
    struct.pack_into('<II', b, 0x3d3fc, 0xd2800000, 0xd65f03c0)   # mov x0,#0 ; ret
    p.write_bytes(b)
    print(f"patched {path}: confstr/sandbox-ext stubs + VZ_START device-iter skip")

if __name__ == "__main__":
    main(sys.argv[1])

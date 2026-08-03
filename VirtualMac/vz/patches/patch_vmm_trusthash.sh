#!/bin/bash
# Workaround for the device-type registry lookup miss (PG-GPU): the VMM's inlined libc++
# string-equality on the find path returns not-equal for the byte-identical 61-char key
# "com.apple.virtualization.avp.paravirtualized-graphics-gpu-arm" when this macOS-compiled
# arm64e binary runs on iOS (workaround for transplant fidelity issue).
#
# Since the 41 registry keys have DISTINCT 64-bit hashes, a stored-hash match uniquely
# identifies the entry. Two patches:
#  (1) In unnamed_4871's two inlined find copies, on a hash match branch straight to the
#      found+extract-value path (0x154c18), skipping the buggy byte compare.
#  (2) unnamed_4871 is a recursive resolver: the per-entry success flag w20 comes from a
#      recursive call's boolean return, which (1) alone doesn't flip. NOP the per-iter gate
#      tbz w20 at 0x15517c so every entry is treated as resolved (factory already extracted
#      by (1)). Result: VMM gets past the registry and reaches hv_vcpu_create.
# Re-sign with the original entitlements (ldid -S<ents>) so AMFI still loads the arm64e bin.
set -e
VMM="${1:?usage: $0 /path/to/com.apple.Virtualization.VirtualMachine}"
ENTS="$(dirname "$0")/vmm.ents.xml"
python3 - "$VMM" <<'PY'
import struct,sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
def patch(off,orig,new):
    cur=struct.unpack_from('<I',b,off)[0]
    assert cur==orig, f'0x{off:x}: expected {orig:08x} got {cur:08x}'
    struct.pack_into('<I',b,off,new); print(f'  0x{off:x}: {orig:08x} -> {new:08x}')
patch(0x154ae0,0x39409ee8,0x1400004e)  # find copy1: hash-match -> b 0x154c18 (found)
patch(0x154b80,0x39409ee8,0x14000026)  # find copy2: hash-match -> b 0x154c18 (found)
patch(0x15517c,0x36000dd4,0xd503201f)  # per-iter w20 gate -> nop
patch(0xdf398, 0xdac11a30,0xdac147f0)  # device-setup autda x16,x17 -> xpacd x16 (PAC
                                       # fault site unnamed_3573+112; surgical strip,
                                       # NOT global de-PAC which breaks the syslib ABI)
open(p,'wb').write(b); print(f'patched {p}')
PY
ldid -S"$ENTS" "$VMM"
echo "re-signed with $ENTS"

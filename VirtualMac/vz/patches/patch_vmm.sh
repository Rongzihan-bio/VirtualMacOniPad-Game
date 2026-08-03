#!/bin/bash
# Patch the on-disk VMM binary: NOP the cbz at unnamed_734+4580 (file offset 0x1d3e4) so
# the failure path after unnamed_3450 isn't taken. Re-sign with original entitlements so
# AMFI still loads the arm64e binary (ldid -S without ents strips entitlements and the
# binary then can't run with com.apple.private.hypervisor).
#
# Bypassing this check leaves downstream code with uninitialised state (next observed crash: 
# pthread_mutex_lock(NULL+0x18) at unnamed_4067+40). The real fix is to figure out what unnamed_3450 
# checks and make our hv_trap return values it accepts; this patch just unblocks the immediate symptom.
set -e
VMM="${1:?usage: $0 /path/to/com.apple.Virtualization.VirtualMachine}"
ENTS="$(dirname "$0")/vmm.ents.xml"
python3 - "$VMM" <<'PY'
import struct, sys
p = sys.argv[1]
b = bytearray(open(p,'rb').read())
orig = struct.unpack_from('<I', b, 0x1d3e4)[0]
assert orig == 0x340000a8, f"unexpected at +0x1d3e4: {orig:08x}"
struct.pack_into('<I', b, 0x1d3e4, 0xd503201f)   # nop
open(p,'wb').write(b)
print(f"patched {p}: cbz w8,#+20 -> nop at +0x1d3e4")
PY
ldid -S"$ENTS" "$VMM"
echo "re-signed with $ENTS"

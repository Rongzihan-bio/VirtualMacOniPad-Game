#!/usr/bin/env python3
"""uncache: regenerate loadable arm64e LC_DYLD_CHAINED_FIXUPS for a cache image.

Takes DyldExtractor's (RE-only) output and makes it loadable:
  - collect the image's own slide-info-v3 fixups (location-filtered)
  - classify rebase (in-image) vs bind (cross-image); resolve binds via `ipsw dyld a2s`
  - emit DYLD_CHAINED_PTR_ARM64E_USERLAND chains (auth-preserving), weave into __DATA*
  - add LC_DYLD_CHAINED_FIXUPS, clear MH_DYLIB_IN_CACHE
Validate with `dyld_info -fixups`, then stamp iOS + sign.

Usage: uncache.py <main-cache> <image-substr> <dyldextractor-output> <final-output>
"""
import sys, struct, logging, subprocess, re, os
import progressbar
from DyldExtractor.extraction_context import ExtractionContext
from DyldExtractor.macho.macho_context import MachOContext
from DyldExtractor.dyld.dyld_context import DyldContext
from DyldExtractor.dyld.dyld_structs import dyld_cache_slide_pointer3
from DyldExtractor.macho.macho_structs import mach_header_64
from DyldExtractor.converter import slide_info

LC_SEGMENT_64, LC_LOAD_DYLIB = 0x19, 0xC
LC_SYMTAB, LC_DYSYMTAB = 0x2, 0xB
LC_FUNCTION_STARTS, LC_DATA_IN_CODE = 0x26, 0x29
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033
MH_DYLIB_IN_CACHE = 0x80000000
PF_ARM64E_USERLAND = 9
START_NONE = 0xFFFF
PAGE = 0x4000

DSC = None  # set in main


IPSW = os.environ.get("VZ_IPSW", "ipsw")   # path to ipsw binary (VZ_IPSW for the rebuilt batch one)


def a2s_batch(targets):
    """Resolve many unslid addresses -> {addr: (symbol, image)} in ONE ipsw call
    (DSC + a2s cache opened once). Uses the rebuilt `ipsw dyld a2sb`."""
    if not targets:
        return {}
    import tempfile
    tf = tempfile.NamedTemporaryFile("w", delete=False, suffix=".addrs")
    for t in targets:
        tf.write(hex(t) + "\n")
    tf.close()
    out = subprocess.run([IPSW, "--no-color", "dyld", "a2sb", "--cache", DSC + ".a2s", DSC, tf.name],
                         capture_output=True, text=True).stdout
    out = re.sub(r"\x1b\[[0-9;]*m", "", out)
    os.unlink(tf.name)
    m = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) >= 2 and p[0].startswith("0x"):
            m[int(p[0], 16)] = (p[1] or None, p[2] if len(p) > 2 else None)
    return m


def build_local_str_va(buf):
    """{cstring_bytes: vmaddr} for every CstringLiterals section in buf (selectors,
    class names, method types, __cstring). Used to localize objc selref pointers that
    the cache uniqued into libobjc's shared __OBJC_RO pool."""
    smap = {}
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", buf, off+64)[0]
            so = off + 72
            for _ in range(nsects):
                addr, size = struct.unpack_from("<QQ", buf, so+32)
                foff = struct.unpack_from("<I", buf, so+48)[0]
                flags = struct.unpack_from("<I", buf, so+64)[0]
                if (flags & 0xff) == 0x2 and size:          # S_CSTRING_LITERALS
                    blob = bytes(buf[foff:foff+size])
                    p = 0
                    while p < len(blob):
                        e = blob.find(b"\x00", p)
                        if e < 0: break
                        s = blob[p:e]
                        if s and s not in smap: smap[s] = addr + p
                        p = e + 1
                so += 80
        off += sz
    return smap


def read_cache_cstrs(dsc, targets):
    """{target_addr: cstring_bytes} read from the cache (reopens it; handles subcaches)."""
    import pathlib
    out = {}
    with open(dsc, "rb") as f:
        dc = DyldContext(f)
        subs = dc.addSubCaches(pathlib.Path(dsc))
        try:
            for t in targets:
                try:
                    o, ctx = dc.convertAddr(t)
                    out[t] = bytes(ctx.getBytes(o, 256)).split(b"\x00")[0]
                except Exception:
                    out[t] = None
        finally:
            for sf in subs:
                sf.close()
    return out


# ---- arm64e USERLAND chain-entry packers (64-bit little-endian) ----
def pack_rebase(runtimeOffset, nxt, high8=0):
    return (runtimeOffset & ((1 << 43) - 1)) | ((high8 & 0xFF) << 43) | ((nxt & 0x7FF) << 51) | (0 << 62) | (0 << 63)
def pack_auth_rebase(runtimeOffset, div, addrDiv, key, nxt):
    return ((runtimeOffset & 0xFFFFFFFF) | ((div & 0xFFFF) << 32) | ((addrDiv & 1) << 48)
            | ((key & 3) << 49) | ((nxt & 0x7FF) << 51) | (0 << 62) | (1 << 63))
def pack_bind(ordinal, addend, nxt):
    return ((ordinal & 0xFFFF) | (0 << 16) | ((addend & 0x7FFFF) << 32)
            | ((nxt & 0x7FF) << 51) | (1 << 62) | (0 << 63))
def pack_auth_bind(ordinal, div, addrDiv, key, nxt):
    return ((ordinal & 0xFFFF) | (0 << 16) | ((div & 0xFFFF) << 32) | ((addrDiv & 1) << 48)
            | ((key & 3) << 49) | ((nxt & 0x7FF) << 51) | (1 << 62) | (1 << 63))


def rewrite_dylib_paths(buf):
    """Rewrite macOS framework dylib paths to iOS-flat form (strip Versions/X/).
    e.g. .../CoreFoundation.framework/Versions/A/CoreFoundation -> .../CoreFoundation.framework/CoreFoundation"""
    import re as _re
    ncmds = struct.unpack_from("<I", buf, 16)[0]; off = 32
    DYLIB_CMDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023}  # LOAD/ID/WEAK/REEXPORT/UPWARD
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd in DYLIB_CMDS:
            noff = struct.unpack_from("<I", buf, off+8)[0]
            old = buf[off+noff:off+sz].split(b"\0")[0]
            new = _re.sub(rb"(\.framework/)Versions/[^/]+/", rb"\1", old)
            if new != old:
                region = sz - noff
                buf[off+noff:off+sz] = new + b"\0"*(region-len(new))
        off += sz
    return buf


def weaken_absent_dylibs(buf, markers):
    """Demote LC_LOAD_DYLIB -> LC_LOAD_WEAK_DYLIB for deps whose path matches any marker.
    Used for frameworks absent on iOS (e.g. MetalSerializer, vmnet) that we import NO
    symbols from: a missing weak dylib is fine, so dyld won't fail the load."""
    LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB = 0xC, 0x80000018   # 0x8000001F is REEXPORT, not weak!
    ncmds = struct.unpack_from("<I", buf, 16)[0]; off = 32
    weakened = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_LOAD_DYLIB:
            noff = struct.unpack_from("<I", buf, off+8)[0]
            path = buf[off+noff:off+sz].split(b"\0")[0].decode("utf-8", "replace")
            if any(m in path for m in markers):
                struct.pack_into("<I", buf, off, LC_LOAD_WEAK_DYLIB)
                weakened.append(path)
        off += sz
    if weakened:
        print(f"weakened {len(weakened)} iOS-absent dep(s): {[p.split('/')[-1] for p in weakened]}")
    return buf


def reorder_segments(buf):
    """dyld requires LC_SEGMENT_64 in ascending vmaddr order. Reorder the segment
    load commands (same total size) without moving segment file content."""
    ncmds, scmds = struct.unpack_from("<II", buf, 16)
    lcs, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        lcs.append((cmd, bytes(buf[off:off+sz])))
        off += sz
    seg_blobs = [b for c, b in lcs if c == LC_SEGMENT_64]
    seg_blobs.sort(key=lambda b: struct.unpack_from("<Q", b, 24)[0])  # by vmaddr
    out, k = bytearray(), 0
    for c, b in lcs:
        if c == LC_SEGMENT_64:
            out += seg_blobs[k]; k += 1
        else:
            out += b
    buf[32:32+len(out)] = out
    return buf


def relayout(buf):
    """Repack file so segment fileoffs are monotonic in vmaddr order (dyld requires
    it). Moves segment content, patches seg.fileoff + section offsets + LINKEDIT-
    internal LC offsets. Assumes segment LCs already vmaddr-sorted (reorder_segments)."""
    ncmds, scmds = struct.unpack_from("<II", buf, 16)
    segs, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            name = buf[off+8:off+24].split(b"\0")[0].decode()
            _, _, fo, fs = struct.unpack_from("<QQQQ", buf, off+24)
            nsects = struct.unpack_from("<I", buf, off+64)[0]
            segs.append((off, name, fo, fs, nsects))
        off += sz
    place, cur = [], 0
    for i, (lc, nm, fo, fs, ns) in enumerate(segs):
        nf = 0 if i == 0 else ((cur + 0x3FFF) & ~0x3FFF)
        place.append(nf); cur = nf + fs
    new = bytearray(cur)
    ld = 0
    for (lc, nm, fo, fs, ns), nf in zip(segs, place):
        new[nf:nf+fs] = buf[fo:fo+fs]
    for (lc, nm, fo, fs, ns), nf in zip(segs, place):
        delta = nf - fo
        struct.pack_into("<Q", new, lc+40, nf)                 # seg.fileoff
        for k in range(ns):
            fld = lc+72+k*80+48                                  # section_64.offset
            o = struct.unpack_from("<I", new, fld)[0]
            if o: struct.pack_into("<I", new, fld, o+delta)
        if nm == "__LINKEDIT":
            ld = delta
    # patch LINKEDIT-internal file offsets in LCs (all live in __TEXT header @0)
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", new, off)
        if cmd == LC_SYMTAB:
            for fo_field in (8, 16):
                v = struct.unpack_from("<I", new, off+fo_field)[0]
                if v: struct.pack_into("<I", new, off+fo_field, v+ld)
        elif cmd == LC_DYSYMTAB:
            for fo_field in (32, 40, 48, 56, 64, 72):           # toc/modtab/extref/indirect/extrel/locrel
                v = struct.unpack_from("<I", new, off+fo_field)[0]
                if v: struct.pack_into("<I", new, off+fo_field, v+ld)
        elif cmd in (LC_DYLD_EXPORTS_TRIE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE):
            v = struct.unpack_from("<I", new, off+8)[0]
            if v: struct.pack_into("<I", new, off+8, v+ld)
        off += sz
    return new


def relayout_pad(buf):
    """PAD mode: lay each segment at fileoff = vmaddr - base (file mirrors vm).
    Preserves vmaddrs so code/ADRP refs are untouched. Produces a huge (sparse-
    ish) file but satisfies dyld's hasSwiftOrObjC (content=addr+slide). Proof only."""
    ncmds, scmds = struct.unpack_from("<II", buf, 16)
    segs, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            nm = buf[off+8:off+24].split(b"\0")[0].decode()
            va, vs, fo, fs = struct.unpack_from("<QQQQ", buf, off+24)
            ns = struct.unpack_from("<I", buf, off+64)[0]
            segs.append((off, nm, va, vs, fo, fs, ns))
        off += sz
    base = min(s[2] for s in segs)
    total = max(s[2]+s[5] for s in segs) - base          # by filesize
    new = bytearray(total)
    ld = 0
    for lc, nm, va, vs, fo, fs, ns in segs:
        new[va-base:va-base+fs] = buf[fo:fo+fs]            # content at vmaddr-base (left-pad precedes)
    for lc, nm, va, vs, fo, fs, ns in segs:
        av = va & ~0x3FFF; pad = va - av                   # page-align vmaddr down, left-pad
        struct.pack_into("<Q", new, lc+24, av)             # seg.vmaddr -> aligned
        struct.pack_into("<Q", new, lc+32, vs+pad)         # seg.vmsize += pad
        struct.pack_into("<Q", new, lc+40, av-base)        # seg.fileoff -> aligned-base (page-aligned)
        struct.pack_into("<Q", new, lc+48, fs+pad)         # seg.filesize += pad
        for k in range(ns):
            so = lc+72+k*80
            saddr = struct.unpack_from("<Q", new, so+32)[0]
            if struct.unpack_from("<I", new, so+48)[0]:
                struct.pack_into("<I", new, so+48, saddr-base)   # sect.offset = addr-base
        if nm == "__LINKEDIT": ld = (va-base) - fo
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", new, off)
        if cmd == LC_SYMTAB:
            for f in (8, 16):
                v = struct.unpack_from("<I", new, off+f)[0]
                if v: struct.pack_into("<I", new, off+f, v+ld)
        elif cmd == LC_DYSYMTAB:
            for f in (32, 40, 48, 56, 64, 72):
                v = struct.unpack_from("<I", new, off+f)[0]
                if v: struct.pack_into("<I", new, off+f, v+ld)
        elif cmd in (LC_DYLD_EXPORTS_TRIE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE):
            v = struct.unpack_from("<I", new, off+8)[0]
            if v: struct.pack_into("<I", new, off+8, v+ld)
        off += sz
    return new


def _find_section(buf, lc, ns, segname_unused, sectname):
    """Return (sect_lc_off, addr, size) of sectname within the segment at load-command lc."""
    for k in range(ns):
        so = lc+72+k*80
        if buf[so:so+16].split(b"\0")[0] == sectname:
            sa, ssz = struct.unpack_from("<QQ", buf, so+32)
            return so, sa, ssz
    return None, 0, 0


def _section_segment(buf, sectname):
    """Return the name of the segment containing section `sectname` (bytes), or None."""
    ncmds = struct.unpack_from("<I", buf, 16)[0]; off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            ns = struct.unpack_from("<I", buf, off+64)[0]
            for k in range(ns):
                so = off+72+k*80
                if buf[so:so+16].split(b"\0")[0] == sectname:
                    return buf[off+8:off+24].split(b"\0")[0].decode()
        off += sz
    return None


def relayout_compact(buf, newbase=0x100000000, insert=None):
    """COMPACT: relocate segments to small 16KB-page-aligned slots (fileoffset==
    vmaddr-newbase, the mach header stays at file 0). Cache segments are >=4KB-aligned
    so each segment delta is a 4KB-multiple, which preserves ADD immediates (12-bit);
    only ADRP page bits need rewriting. Returns (new_buf, deltas=[(lo,hi,delta)]).

    insert=(seg_name, sect_name, nbytes): grow that segment by `shift` (nbytes rounded to
    16KB) and open a `shift`-byte gap right after sect_name's content, extending sect_name's
    size by nbytes (used to append objc selref-slot pool into __objc_selrefs so objc uniques
    them). The gap shifts the rest of that segment; its delta is split into two ranges.
    Returns (new_buf, deltas, pool_va) -- pool_va is the new vmaddr of the gap start."""
    ncmds, scmds = struct.unpack_from("<II", buf, 16)
    segs, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            nm = buf[off+8:off+24].split(b"\0")[0].decode()
            va, vs, fo, fs = struct.unpack_from("<QQQQ", buf, off+24)
            ns = struct.unpack_from("<I", buf, off+64)[0]
            segs.append([off, nm, va, vs, fo, fs, ns])
        off += sz
    if insert:
        ins_seg, ins_sect, ins_n = insert[0], insert[1], insert[2]
        ins_grow = insert[3] if len(insert) > 3 else ins_n     # how much to extend the section
    else:
        ins_seg = ins_sect = None; ins_n = ins_grow = 0
    shift = ((ins_n + 0x3FFF) & ~0x3FFF) if insert else 0       # gap holds selref pool + GOT pool
    # pack each segment into a 16KB-aligned slot (no left-pad: header must stay at file 0)
    deltas = []; cur = newbase; place = []; pool_va = None
    for lc, nm, va, vs, fo, fs, ns in segs:
        nf = cur
        place.append(nf)
        if nm == ins_seg:
            _, sa_sr, sz_sr = _find_section(buf, lc, ns, nm, ins_sect.encode())
            split_va = sa_sr + sz_sr                          # gap opens right after the section
            deltas.append((va, split_va, nf - va))
            deltas.append((split_va, va + max(vs, fs), nf - va + shift))
            pool_va = split_va + (nf - va)                    # new vmaddr of the gap (pool) start
            cur = nf + ((max(vs, fs) + shift + 0x3FFF) & ~0x3FFF)
        else:
            deltas.append((va, va + max(vs, fs), nf - va))
            cur = nf + ((max(vs, fs) + 0x3FFF) & ~0x3FFF)
    new = bytearray(cur - newbase)
    for (lc, nm, va, vs, fo, fs, ns), nf in zip(segs, place):
        if nm == ins_seg:
            _, sa_sr, sz_sr = _find_section(buf, lc, ns, nm, ins_sect.encode())
            soff = (sa_sr + sz_sr) - va                       # split offset within the segment
            new[nf-newbase:nf-newbase+soff] = buf[fo:fo+soff]
            new[nf-newbase+soff+shift:nf-newbase+fs+shift] = buf[fo+soff:fo+fs]
        else:
            new[nf-newbase:nf-newbase+fs] = buf[fo:fo+fs]
    ld = 0
    for (lc, nm, va, vs, fo, fs, ns), nf in zip(segs, place):
        delta = nf - va
        extra = shift if nm == ins_seg else 0
        split_va = (struct.unpack_from("<Q", buf, _find_section(buf, lc, ns, nm, ins_sect.encode())[0]+32)[0]
                    + _find_section(buf, lc, ns, nm, ins_sect.encode())[2]) if nm == ins_seg else None
        struct.pack_into("<Q", new, lc+24, nf)                       # vmaddr (16KB-aligned)
        struct.pack_into("<Q", new, lc+32, (vs+extra+0x3FFF) & ~0x3FFF)    # vmsize
        struct.pack_into("<Q", new, lc+40, nf-newbase)               # fileoff
        fsz = fs+extra if nm == "__LINKEDIT" else ((fs+extra+0x3FFF) & ~0x3FFF)
        struct.pack_into("<Q", new, lc+48, fsz)                      # filesize
        for k in range(ns):
            so = lc+72+k*80
            sa = struct.unpack_from("<Q", new, so+32)[0]
            if sa == 0:                  # zerofill / no-address section: nothing to relocate
                continue
            if not (va <= sa < va+vs):   # real section out of range would be a bug -> surface it
                print(f"  WARN: section addr {sa:#x} outside {nm} [{va:#x},{va+vs:#x}] (relocating anyway)")
            sd = delta + (shift if (split_va is not None and sa >= split_va) else 0)
            struct.pack_into("<Q", new, so+32, sa+sd)               # sect.addr += (split-aware) delta
            if struct.unpack_from("<I", new, so+48)[0]:
                struct.pack_into("<I", new, so+48, (sa+sd)-newbase)  # sect.offset = addr-base
            if nm == ins_seg and buf[so:so+16].split(b"\0")[0] == ins_sect.encode():
                struct.pack_into("<Q", new, so+40, sz_sr + ins_grow)  # extend section over selref pool only
        if nm == "__LINKEDIT": ld = (nf-newbase) - fo
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", new, off)
        if cmd == LC_SYMTAB:
            for f in (8, 16):
                v = struct.unpack_from("<I", new, off+f)[0]
                if v: struct.pack_into("<I", new, off+f, v+ld)
        elif cmd == LC_DYSYMTAB:
            for f in (32, 40, 48, 56, 64, 72):
                v = struct.unpack_from("<I", new, off+f)[0]
                if v: struct.pack_into("<I", new, off+f, v+ld)
        elif cmd in (LC_DYLD_EXPORTS_TRIE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE):
            v = struct.unpack_from("<I", new, off+8)[0]
            if v: struct.pack_into("<I", new, off+8, v+ld)
        off += sz
    return (new, deltas, pool_va) if insert else (new, deltas)


def collect_got_refs(buf, dsc):
    """Scan __text + __objc_stubs for ADRP+consumer references whose target is OUT of the
    extracted image. The cache uniqued the image's GOT into a shared GOT (out of image): system
    data globals (__stack_chk_guard, __NSConcrete*Block, CF allocators...) accessed via a plain
    LDR of the slot, and function pointers (objc_msgSend in __objc_stubs) accessed via an ADD to
    the slot address then ldr+braa. rewrite_adrp can't relocate those. Resolve each via a2s and
    return {old_target_addr: (symbol, is_auth)} -- is_auth (ADD consumer -> braa) means the slot
    holds a signed fn ptr (auth bind); plain LDR means a data pointer (plain bind)."""
    import capstone
    osegs, _, _ = parse_segments(buf)
    inimg = lambda a: any(va <= a < va+vs for nm, va, vs, fo, fs, lc in osegs)
    t = next(s for s in osegs if s[0] == "__TEXT")
    nsects = struct.unpack_from("<I", buf, t[5]+64)[0]
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); md.detail = True
    targets = {}                                       # old_target -> is_auth
    for k in range(nsects):
        so = t[5]+72+k*80
        if buf[so:so+16].split(b"\0")[0] not in (b"__text", b"__objc_stubs"): continue
        sa, ssz = struct.unpack_from("<QQ", buf, so+32)
        soff = struct.unpack_from("<I", buf, so+48)[0]
        regs = {}; pos = 0
        while pos < ssz:
            adv = pos
            for ins in md.disasm(bytes(buf[soff+pos:soff+ssz]), sa+pos):
                adv = (ins.address - sa) + ins.size; m, ops = ins.mnemonic, ins.operands
                if m == "adrp" and len(ops) == 2:
                    regs[ops[0].reg] = [ops[1].imm, False]
                elif ops:
                    base = disp = None; is_add = (m == "add")
                    if is_add and len(ops) == 3 and ops[2].type == capstone.CS_OP_IMM:
                        base, disp = ops[1].reg, ops[2].imm
                    else:
                        for op in ops:
                            if op.type == capstone.CS_OP_MEM:
                                base, disp = op.mem.base, op.mem.disp; break
                    if base in regs and not regs[base][1]:
                        tt = regs[base][0] + (disp or 0)
                        if not inimg(tt): targets[tt] = is_add    # ADD-to-slot => auth (braa)
                        regs[base][1] = True
            pos = adv+4 if adv == pos else adv
    if not targets: return {}
    sm = a2s_batch(list(targets))
    out = {}
    for a, is_auth in targets.items():
        nm = sm.get(a, (None,))[0]
        if nm and nm.startswith("_ptr."): nm = nm[5:]
        if nm: out[a] = (nm, is_auth)
    return out


def _find_sect(buf, name):
    osegs, _, _ = parse_segments(buf)
    for nm, va, vs, fo, fs, lc in osegs:
        for k in range(struct.unpack_from("<I", buf, lc+64)[0]):
            so = lc+72+k*80
            if buf[so:so+16].split(b"\0")[0] == name:
                sa, sz = struct.unpack_from("<QQ", buf, so+32)
                return sa, sz, struct.unpack_from("<I", buf, so+48)[0]
    return None


def collect_unwind_personalities(buf, dsc):
    """__unwind_info's personality array references the C++/objc personality routine via a GOT
    slot (a 32-bit offset relative to the image's mach header). The cache uniqued that GOT out
    of the image, so the offset points out-of-image -> libunwind reads garbage when unwinding an
    exception through our frames. Return the ORDERED personality symbols so they can be bound in
    the GOT pool and the offsets repointed."""
    osegs, _, _ = parse_segments(buf)
    base = next(va for nm, va, vs, fo, fs, lc in osegs if nm == "__TEXT")
    s = _find_sect(buf, b"__unwind_info")
    if not s: return []
    sa, sz, fo = s
    pao, pac = struct.unpack_from("<II", buf, fo+12)   # personalityArraySectionOffset, count
    targets = [base + struct.unpack_from("<I", buf, fo+pao+i*4)[0] for i in range(pac)]
    if not targets: return []
    sm = a2s_batch(targets); out = []
    for t in targets:
        nm = sm.get(t, (None,))[0]
        if nm and nm.startswith("_ptr."): nm = nm[5:]
        out.append(nm)
    return out


def rewrite_unwind_personalities(buf, syms, got_slot, nbase):
    s = _find_sect(buf, b"__unwind_info")
    if not s: return 0
    sa, sz, fo = s
    pao, pac = struct.unpack_from("<II", buf, fo+12)
    n = 0
    for i, sym in enumerate(syms):
        if i < pac and sym and sym in got_slot:
            struct.pack_into("<I", buf, fo+pao+i*4, got_slot[sym] - nbase)   # -> in-image GOT slot
            n += 1
    return n


def _read_uleb(buf, offset):
    value = shift = 0
    while True:
        byte = buf[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, offset
        shift += 7


def _read_sleb(buf, offset):
    value = shift = 0
    while True:
        byte = buf[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        shift += 7
        if not byte & 0x80:
            if byte & 0x40:
                value -= 1 << shift
            return value, offset


def _read_eh_value(buf, offset, encoding):
    form = encoding & 0x0f
    if form == 0x01:
        return _read_uleb(buf, offset)
    if form == 0x03:
        return struct.unpack_from("<I", buf, offset)[0], offset + 4
    if form == 0x04:
        return struct.unpack_from("<Q", buf, offset)[0], offset + 8
    if form == 0x09:
        return _read_sleb(buf, offset)
    if form == 0x0b:
        return struct.unpack_from("<i", buf, offset)[0], offset + 4
    if form == 0x0c:
        return struct.unpack_from("<q", buf, offset)[0], offset + 8
    raise ValueError(f"unsupported DW_EH_PE encoding {encoding:#x}")


def collect_lsda_type_refs(buf, dsc):
    """Collect indirect PC-relative catch-type references in LSDA tables.

    dyld shared caches leave these signed offsets pointing at cache-uniqued GOT
    slots (usually ``_OBJC_EHTYPE_$_NSException``).  Compact relayout moves the
    framework but a normal chained-fixup rebuild does not visit bytes inside
    ``__gcc_except_tab``.  The stale offset only becomes visible when a native
    framework exception is thrown: libc++abi follows it out of the image and
    crashes while looking up the catch type.

    Return ``(field_va, old_target_va, symbol_or_none)`` for every type-table
    entry reached by an action record.  External targets are resolved in one
    a2sb batch so the caller can allocate ordinary rebuilt GOT slots for them.
    """
    unwind = _find_sect(buf, b"__unwind_info")
    if not unwind:
        return []
    unwind_va, unwind_size, unwind_off = unwind
    if unwind_size < 28:
        return []

    osegs, _, _ = parse_segments(buf)
    image_base = min(va for _nm, va, _vs, _fo, _fs, _lc in osegs)

    def va_to_off(address):
        for _nm, va, _vs, fileoff, filesize, _lc in osegs:
            if va <= address < va + filesize:
                return fileoff + address - va
        raise ValueError(f"LSDA address outside file-backed image: {address:#x}")

    def off_to_va(offset):
        for _nm, va, _vs, fileoff, filesize, _lc in osegs:
            if fileoff <= offset < fileoff + filesize:
                return va + offset - fileoff
        raise ValueError(f"LSDA file offset outside image: {offset:#x}")

    (_version, _common_off, _common_count, _personality_off,
     _personality_count, index_off, index_count) = struct.unpack_from(
        "<7I", buf, unwind_off)
    indices = [
        struct.unpack_from("<III", buf, unwind_off + index_off + index * 12)
        for index in range(index_count)
    ]
    lsda_offsets = []
    for index in range(max(0, index_count - 1)):
        first = indices[index][2]
        limit = indices[index + 1][2]
        if not first or limit < first:
            continue
        for entry in range(first, limit, 8):
            _function_offset, lsda_offset = struct.unpack_from(
                "<II", buf, unwind_off + entry)
            if lsda_offset:
                lsda_offsets.append(lsda_offset)

    raw_refs = []
    for lsda_offset in sorted(set(lsda_offsets)):
        offset = va_to_off(image_base + lsda_offset)
        lpstart_encoding = buf[offset]
        offset += 1
        if lpstart_encoding != 0xff:
            _unused, offset = _read_eh_value(
                buf, offset, lpstart_encoding)

        type_encoding = buf[offset]
        offset += 1
        if type_encoding == 0xff:
            type_table_end = None
        else:
            type_table_delta, offset = _read_uleb(buf, offset)
            type_table_end = offset + type_table_delta

        call_site_encoding = buf[offset]
        offset += 1
        call_site_length, offset = _read_uleb(buf, offset)
        call_site_end = offset + call_site_length
        actions = []
        while offset < call_site_end:
            _start, offset = _read_eh_value(
                buf, offset, call_site_encoding)
            _length, offset = _read_eh_value(
                buf, offset, call_site_encoding)
            _landing_pad, offset = _read_eh_value(
                buf, offset, call_site_encoding)
            action, offset = _read_uleb(buf, offset)
            if action:
                actions.append(action)
        if offset != call_site_end or type_table_end is None:
            continue

        action_table = call_site_end
        max_type_index = 0
        pending = [action_table + action - 1 for action in actions]
        visited = set()
        while pending:
            action_entry = pending.pop()
            if action_entry in visited:
                continue
            visited.add(action_entry)
            type_filter, next_field = _read_sleb(buf, action_entry)
            next_offset, next_end = _read_sleb(buf, next_field)
            if type_filter > max_type_index:
                max_type_index = type_filter
            if next_offset:
                pending.append(next_field + next_offset)

        form = type_encoding & 0x0f
        width = {0x03: 4, 0x04: 8, 0x0b: 4, 0x0c: 8}.get(form)
        if max_type_index and (width is None or type_encoding & 0x70 != 0x10):
            raise ValueError(
                f"unsupported LSDA type encoding {type_encoding:#x} "
                f"at {image_base + lsda_offset:#x}")
        for type_index in range(1, max_type_index + 1):
            field_off = type_table_end - type_index * width
            if width == 4:
                relative = struct.unpack_from("<i", buf, field_off)[0]
            else:
                relative = struct.unpack_from("<q", buf, field_off)[0]
            field_va = off_to_va(field_off)
            raw_refs.append((field_va, field_va + relative, width))

    external_targets = sorted({
        target for _field, target, _width in raw_refs
        if not any(va <= target < va + vsize
                   for _nm, va, vsize, _fo, _fs, _lc in osegs)
    })
    symbols = a2s_batch(external_targets)
    refs = []
    for field, target, width in raw_refs:
        symbol = symbols.get(target, (None, None))[0]
        if symbol and symbol.startswith("_ptr."):
            symbol = symbol[5:]
        if target in external_targets and not symbol:
            raise ValueError(
                f"unresolved external LSDA type target {target:#x}")
        refs.append((field, target, symbol, width))
    return refs


def rewrite_lsda_type_refs(buf, refs, amap, got_slot, nbase):
    rewritten = 0
    for old_field, old_target, symbol, width in refs:
        new_field = amap(old_field)
        new_target = got_slot.get(symbol) if symbol else amap(old_target)
        if new_field is None or new_target is None:
            raise ValueError(
                f"cannot relocate LSDA type ref {old_field:#x} -> "
                f"{old_target:#x} ({symbol})")
        relative = new_target - new_field
        if width == 4 and not -(1 << 31) <= relative < (1 << 31):
            raise ValueError(f"LSDA sdata4 target is out of range: {relative}")
        struct.pack_into("<i" if width == 4 else "<q",
                         buf, new_field - nbase, relative)
        rewritten += 1
    return rewritten


def fix_export_trie(buf, amap, nbase, deltas):
    """DyldExtractor leaves the export trie's symbol offsets at the ORIGINAL cache/RE image
    offsets; uncache's compact relayout moves every segment, so those offsets now point at the
    wrong place. dyld resolves imports (and ld links) against the trie -> a flat/two-level lookup
    of e.g. `operator new` or `hv_vm_*` lands on a stale-offset address (a different in-image
    function) -> wrong call. Walk the trie and remap each export offset through amap (re-encoding
    the uleb to its ORIGINAL byte length so node/child offsets stay valid)."""
    re_base = next(lo for lo, hi, d in deltas if lo + d == nbase)
    ncmds = struct.unpack_from("<I", buf, 16)[0]; off = 32; trie_off = 0
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == 0x80000033:                          # LC_DYLD_EXPORTS_TRIE
            trie_off = struct.unpack_from("<I", buf, off+8)[0]
        off += sz
    if not trie_off: return 0
    def ruleb(p):
        r = s = 0
        while True:
            b = buf[p]; r |= (b & 0x7f) << s; p += 1; s += 7
            if not (b & 0x80): break
        return r, p
    def ulen(p):
        n = 1
        while buf[p] & 0x80: p += 1; n += 1
        return n
    def wpad(p, val, length):                          # re-encode val as a uleb of exactly `length` bytes
        for i in range(length):
            buf[p+i] = ((val >> (7*i)) & 0x7f) | (0x80 if i < length-1 else 0)
    def fixoff(p):
        L = ulen(p); old, _ = ruleb(p); na = amap(re_base + old)
        if na is not None: wpad(p, na - nbase, L); return 1
        return 0
    fixed = 0; stack = [trie_off]; seen = set()
    while stack:
        node = stack.pop()
        if node in seen: continue
        seen.add(node)
        tsize, p = ruleb(node)
        if tsize:
            flags, q = ruleb(p)
            if not (flags & 0x08) and (flags & 0x03) != 0x02:   # not reexport, not absolute
                fixed += fixoff(q)
                if flags & 0x10:                                # stub-and-resolver: 2nd offset
                    fixed += fixoff(q + ulen(q))
            p += tsize                                          # children follow the terminal blob
        cc = buf[p]; cp = p + 1
        for _ in range(cc):
            while buf[cp]: cp += 1
            cp += 1
            child, cp = ruleb(cp)
            stack.append(trie_off + child)
    print(f"fix_export_trie: remapped {fixed} export offsets")
    return fixed


def rewrite_adrp(buf, osegs, deltas, got_ref_slot=None):
    """Rewrite cross-segment ADRP page immediates in __TEXT after compact relocation.
    Follow register definitions through the control-flow graph so one ADRP can safely
    feed consumers on both sides of a branch.  A linear scan loses the alternate-path
    state after the fall-through path reuses the register (Netrb's synchronous XPC
    connection load is one concrete example)."""
    import capstone
    def seg_delta_old(a):
        for lo, hi, d in deltas:
            if lo <= a < hi: return d
        return None
    def set_consumer_disp(foff, new_off):     # rewrite the ldr/add low-12 byte offset
        w = struct.unpack_from("<I", buf, foff)[0]
        if (w & 0x7F800000) == 0x11000000:                 # ADD (immediate)
            w = (w & ~((1 << 22) | (0xFFF << 10))) | ((new_off & 0xFFF) << 10)
        elif (w & 0x3B000000) == 0x39000000:               # LDR/STR (unsigned imm)
            scale = (w >> 30) & 3
            if new_off & ((1 << scale) - 1): return False   # not scale-aligned
            w = (w & ~(0xFFF << 10)) | (((new_off >> scale) & 0xFFF) << 10)
        else:
            return False
        struct.pack_into("<I", buf, foff, w); return True
    t = next(s for s in osegs if s[0] == "__TEXT")
    tva, tlc = t[1], t[5]
    text_delta = next(d for lo, hi, d in deltas if lo + d == tva)
    trace_window = None
    if os.environ.get("VZ_DBG_ADRP_WINDOW"):
        trace_window = tuple(
            int(value, 0)
            for value in os.environ["VZ_DBG_ADRP_WINDOW"].split(":", 1)
        )
    if os.environ.get("VZ_DBG_ADRP"):
        print("  DELTAS:", [(hex(lo), hex(hi), hex(d)) for lo, hi, d in deltas])
        for probe in (0x216b4d000, 0x216b4ddd8, 0x216b4da00, 0x216b4d488):
            print(f"    seg_delta_old({probe:#x}) = {seg_delta_old(probe)} -> {probe + (seg_delta_old(probe) or 0):#x}")
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True
    def _is_caller_saved(rid):                 # x0-x18 (incl. x16/x17 PAC scratch) clobbered by calls
        n = md.reg_name(rid) or ""
        return n[:1] == "x" and n[1:].isdigit() and int(n[1:]) <= 18
    def function_starts():
        dataoff = datasize = 0
        ncmds = struct.unpack_from("<I", buf, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack_from("<II", buf, off)
            if cmd == LC_FUNCTION_STARTS:
                dataoff, datasize = struct.unpack_from("<II", buf, off + 8)
                break
            off += sz
        starts = []
        if not dataoff or not datasize:
            return starts
        p, end, value = dataoff, dataoff + datasize, 0
        while p < end:
            delta = shift = 0
            while p < end:
                byte = buf[p]; p += 1
                delta |= (byte & 0x7f) << shift
                if not (byte & 0x80): break
                shift += 7
            if delta == 0: break
            value += delta
            starts.append(tva + value)
        return starts

    all_function_starts = function_starts()
    nsects = struct.unpack_from("<I", buf, tlc+64)[0]
    fixed_offsets = set(); scanned = 0
    for k in range(nsects):
        so = tlc + 72 + k*80
        sname = buf[so:so+16].split(b"\0")[0].decode()
        saddr, ssize = struct.unpack_from("<QQ", buf, so+32)
        soff = struct.unpack_from("<I", buf, so+48)[0]
        sflags = struct.unpack_from("<I", buf, so+64)[0]
        if sname == "__auth_stubs": continue       # fix_auth_stubs owns these (needs the original cache imm)
        is_code = (sflags & 0x80000000) or (sflags & 0x400) or sname in ("__text", "__stubs")
        if os.environ.get("VZ_DBG_ADRP"):
            print(f"  ADRP sect {sname:20} flags={sflags:#x} code={bool(is_code)} addr={saddr:#x} size={ssize:#x}")
        if not (is_code and soff and ssize):
            continue
        old_sa = saddr - text_delta                       # section's old addr
        sec_fixed0 = len(fixed_offsets)
        scanned += 1
        instructions = {}
        for pos in range(0, ssize - (ssize % 4), 4):
            decoded = list(md.disasm(
                bytes(buf[soff+pos:soff+pos+4]), old_sa+pos, count=1))
            instructions[pos] = decoded[0] if decoded else None

        incoming = {}; work = []
        def merge_state(pos, state):
            if pos not in instructions: return
            previous = incoming.get(pos)
            if previous is None:
                merged = dict(state)
            else:
                merged = {}
                for reg, previous_value in previous.items():
                    current_value = state.get(reg)
                    if current_value is None:
                        continue
                    previous_page, previous_defs = previous_value
                    current_page, current_defs = current_value
                    if previous_page != current_page:
                        continue
                    merged[reg] = (
                        previous_page,
                        tuple(sorted(
                            set(previous_defs) | set(current_defs))))
            if previous is None or merged != previous:
                incoming[pos] = merged; work.append(pos)

        seeds = [a - saddr for a in all_function_starts
                 if saddr <= a < saddr + ssize]
        if not seeds: seeds = [0]
        for seed in seeds: merge_state(seed, {})
        adrp_pages = {}                                  # instruction fileoff -> rewritten page

        while True:
            if not work:
                # An indirect switch branch has no statically enumerable
                # successors, so case blocks are not necessarily reachable
                # from a function-start seed. Seed the first still-unreached
                # ADRP, drain that whole connected component, then repeat.
                # Seeding every ADRP up front is incorrect: its empty state
                # intersects with a legitimate incoming state and discards
                # callee-saved definitions that cross the ADRP (for example
                # libcrypto's OBJ_NAME_init x19 table pointer).
                seed = next((candidate for candidate, instruction
                             in instructions.items()
                             if candidate not in incoming and instruction and
                             instruction.mnemonic == "adrp"), None)
                if seed is None:
                    break
                merge_state(seed, {})
                continue
            pos = work.pop()
            state = dict(incoming[pos])
            ins = instructions[pos]
            word = struct.unpack_from("<I", buf, soff + pos)[0]
            trace = (trace_window is not None and
                     trace_window[0] <= saddr + pos - tva < trace_window[1])
            if trace:
                rendered = ins.op_str if ins else f"{word:#x}"
                print(f"    TRACE {saddr + pos - tva:#x} "
                      f"{ins.mnemonic if ins else '<undecoded>'} "
                      f"{rendered} state={state}")
            successors = [pos + 4]
            if ins is None:
                if word in (0xD65F0BFF, 0xD65F0FFF):     # retab/retaa
                    successors = []
                elif (word & 0xFF000000) == 0xD7000000:  # authenticated branch/call
                    for reg in [r for r in state if _is_caller_saved(r)]:
                        del state[reg]
                elif (word & 0xFFFF0000) == 0xDAC10000:  # pac*/aut*/xpac* writes Rd
                    rd = word & 0x1F
                    for reg in [r for r in state if md.reg_name(r) == f"x{rd}"]:
                        del state[reg]
            else:
                m, ops = ins.mnemonic, ins.operands
                if m == "adrp" and len(ops) == 2:
                    old_page = ops[1].imm
                    instruction_offset = soff + pos
                    # Repair page-only definitions eagerly when the complete
                    # page moves by a page-aligned segment delta. Waiting for
                    # a consumer misses loop-carried definitions: CFG state
                    # merging intentionally drops a register when two ADRPs
                    # from different back-edges define it, even when both
                    # definitions name the same Objective-C reference page.
                    # The displacement of every eventual consumer remains
                    # valid for a page-aligned relocation, so no consumer is
                    # needed to prove this rewrite.
                    page_delta = seg_delta_old(old_page)
                    if trace and got_ref_slot:
                        page_refs = [
                            (old, new) for old, new in got_ref_slot.items()
                            if (old & ~0xFFF) == old_page
                        ]
                        if page_refs:
                            print(f"      page refs={page_refs[:16]}")
                    if (page_delta is not None and
                            page_delta != text_delta and
                            (page_delta & 0xFFF) == 0):
                        new_page = old_page + page_delta
                        new_pc = ins.address + text_delta
                        adrp_word = struct.unpack_from(
                            "<I", buf, instruction_offset)[0]
                        struct.pack_into(
                            "<I", buf, instruction_offset,
                            _set_adrp(adrp_word, new_pc, new_page))
                        adrp_pages[instruction_offset] = new_page
                        fixed_offsets.add(instruction_offset)
                    state[ops[0].reg] = (
                        old_page, ((ins.address, instruction_offset),))
                else:
                    base = disp = None
                    if (m == "add" and len(ops) == 3 and
                            ops[1].type == capstone.CS_OP_REG and
                            ops[2].type == capstone.CS_OP_IMM):
                        base, disp = ops[1].reg, ops[2].imm
                    else:
                        for op in ops:
                            if op.type == capstone.CS_OP_MEM:
                                base, disp = op.mem.base, op.mem.disp; break
                    if base in state:
                        page, definitions = state[base]
                        old_t = page + (disp or 0)
                        dt = seg_delta_old(old_t)
                        new_target = None
                        if dt is not None and dt != text_delta:
                            new_target = old_t + dt
                        elif dt is None and got_ref_slot and old_t in got_ref_slot:
                            new_target = got_ref_slot[old_t]
                        if trace:
                            print(f"      consumer target={old_t:#x} delta={dt} "
                                  f"new={new_target}")
                        if new_target is not None:
                            page_aligned = (
                                dt is not None and (dt & 0xFFF) == 0)
                            desired_page = ((page + dt) if page_aligned
                                            else (new_target & ~0xFFF))
                            for aaddr, foff in definitions:
                                new_page = adrp_pages.get(foff)
                                if new_page is None:
                                    new_page = desired_page
                                    new_pc = aaddr + text_delta
                                    adrp_word = struct.unpack_from(
                                        "<I", buf, foff)[0]
                                    struct.pack_into(
                                        "<I", buf, foff,
                                        _set_adrp(
                                            adrp_word, new_pc, new_page))
                                    adrp_pages[foff] = new_page
                                    fixed_offsets.add(foff)
                                elif new_page != desired_page:
                                    raise RuntimeError(
                                        "ADRP consumers require different "
                                        f"pages at {aaddr:#x}")
                            new_disp = new_target - desired_page
                            if not (0 <= new_disp < 0x1000):
                                raise RuntimeError(
                                    "ADRP consumer displacement does not fit "
                                    f"at {ins.address:#x}")
                            if (not page_aligned or new_disp != (disp or 0)):
                                if not set_consumer_disp(soff + pos, new_disp):
                                    raise RuntimeError(
                                        f"cannot rewrite ADRP consumer at {ins.address:#x}")

                    is_call = m in ("bl", "blr") or m.startswith("blra")
                    if is_call:
                        for reg in [r for r in state if _is_caller_saved(r)]:
                            del state[reg]
                    else:
                        written = set()
                        try: written.update(ins.regs_access()[1])
                        except Exception: pass
                        if (ops and ops[0].type == capstone.CS_OP_REG and
                                (m == "add" or m.startswith("ld") or
                                 m.startswith("mov"))):
                            written.add(ops[0].reg)
                        for reg in written: state.pop(reg, None)

                # TBZ/TBNZ have two immediate operands: the tested bit number
                # and then the branch destination.  The destination is always
                # the final immediate for the branch forms handled below.
                # Taking the first one made the CFG stop at bit 0/1 and skip
                # relocation of entire success paths (notably vmnet's event
                # callback setup and packet I/O globals).
                branch_immediates = [
                    op.imm - old_sa for op in ops
                    if op.type == capstone.CS_OP_IMM
                ]
                branch_target = (branch_immediates[-1]
                                 if branch_immediates else None)
                if m == "b":
                    successors = ([branch_target]
                                  if branch_target is not None else [])
                elif (m.startswith("b.") or
                      m in ("cbz", "cbnz", "tbz", "tbnz")):
                    if branch_target is not None:
                        successors.append(branch_target)
                elif m in ("ret", "br") or m.startswith("bra"):
                    successors = []
            for successor in successors:
                merge_state(successor, state)
        if os.environ.get("VZ_DBG_ADRP"):
            print(f"    -> {sname}: {len(fixed_offsets) - sec_fixed0} rewritten")
    print(f"rewrote {len(fixed_offsets)} cross-segment ADRP ({scanned} code sections)")


def _adrp_target(word, pc):
    immlo = (word >> 29) & 3
    immhi = (word >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20): imm -= (1 << 21)          # sign-extend 21-bit
    return (pc & ~0xFFF) + (imm << 12)

def _set_adrp(word, pc, target):
    imm = ((target & ~0xFFF) - (pc & ~0xFFF)) >> 12
    word &= ~((3 << 29) | (0x7FFFF << 5))
    return word | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5)

def _add_imm(word):
    return ((word >> 10) & 0xFFF) << (12 if (word >> 22) & 1 else 0)

def _set_add_imm(word, imm):                      # assume shift=0, imm fits 12 bits
    word &= ~((1 << 22) | (0xFFF << 10))
    return word | ((imm & 0xFFF) << 10)


def fix_auth_stubs(buf, osegs, text_delta, dsc, amap):
    """The cache uniques every GOT binding into a shared GOT and EMPTIES the image's own
    __auth_got (all slots zeroed). __auth_stubs come in two flavours: some still ADRP+ADD to a
    slot in the image's own (now-empty) __auth_got; others ADRP at the shared GOT (out of image).
    Both need their slot bound. Decode each stub's ORIGINAL (cache) GOT target and a2s it:
      - in-image target -> bind the EXISTING slot (amap of the target); the stub keeps pointing
        there (we repoint it; rewrite_adrp skips __auth_stubs so the cache imm is intact here).
      - out-of-image target -> allocate a FREE __auth_got slot (one NOT claimed by an in-image
        stub) and repoint the stub to it.
    Crucially the out-of-image allocator must avoid the in-image slots, else e.g. operator new's
    slot gets clobbered with another symbol. Returns [(slot_new_addr, symbol)] auth-binds."""
    def find(sect):
        for nm, va, vs, fo, fs, lc in osegs:
            ns = struct.unpack_from("<I", buf, lc+64)[0]
            for k in range(ns):
                so = lc+72+k*80
                if buf[so:so+16].split(b"\0")[0] == sect:
                    sa, ssz = struct.unpack_from("<QQ", buf, so+32)
                    return sa, ssz, struct.unpack_from("<I", buf, so+48)[0]
        return None
    st = find(b"__auth_stubs"); ag = find(b"__auth_got")
    if not st or not ag: return []
    sa, ssz, sfo = st
    ag_va, ag_sz, _ = ag
    stubs = []                                     # (fo, A, cache_got)
    for o in range(0, ssz - 12, 16):               # 16-byte arm64e auth stubs
        fo = sfo + o; A = sa + o
        adrp = struct.unpack_from("<I", buf, fo)[0]
        add = struct.unpack_from("<I", buf, fo+4)[0]
        if (adrp & 0x9F000000) != 0x90000000: continue          # not ADRP
        cache_got = _adrp_target(adrp, A - text_delta) + _add_imm(add)   # original target (cache addr)
        stubs.append((fo, A, cache_got))
    if not stubs: return []
    sym_map = a2s_batch([g for _, _, g in stubs])
    claimed = {amap(cg) for _, _, cg in stubs if amap(cg) is not None}   # in-image slots in use
    free = (ag_va + j*8 for j in range(ag_sz // 8) if (ag_va + j*8) not in claimed)
    binds = []; nin = nout = 0
    for fo, A, cg in stubs:
        name = sym_map.get(cg, (None,))[0]
        if name and name.startswith("_ptr."): name = name[5:]
        if not name: continue
        slot = amap(cg)
        if slot is not None:
            nin += 1                               # in-image: bind the stub's own (empty) slot
        else:
            slot = next(free, None)                # out-of-image: a fresh, unclaimed slot
            if slot is None: continue
            nout += 1
        struct.pack_into("<I", buf, fo,   _set_adrp(struct.unpack_from("<I", buf, fo)[0], A, slot))
        struct.pack_into("<I", buf, fo+4, _set_add_imm(struct.unpack_from("<I", buf, fo+4)[0], slot & 0xFFF))
        binds.append((slot, name))
    print(f"  ({nin} in-image-slot, {nout} fresh-slot)", end="")
    print(f"fix_auth_stubs: repointed {len(binds)}/{len(stubs)} stubs to rebuilt __auth_got")
    return binds


def objc_collect_relmethods(buf):
    """Walk the objc class/category/protocol graph on the ORIGINAL (pre-relayout)
    buffer and collect every arm64e RELATIVE method-list field. Returns
    (ti_recs, name_recs):
      ti_recs   = [(field_vmaddr, target_vmaddr)]  for the types & imp fields
                  (they target in-image type-strings / functions; fixed by amap).
      name_recs = [(field_vmaddr, old_target_vmaddr, direct_bool)]  for the name
                  field. In the cache the name targets the shared selector pool
                  (out of image) so it can't be amap'd; it must be redirected to an
                  in-image selref slot (see objc_build_selref_pool). direct_bool is
                  the method-list's RELATIVE_METHOD_SELECTORS_ARE_DIRECT flag, which
                  says whether old_target is the selector string (direct) or a selref
                  slot holding a pointer to it."""
    segs, off = [], 32
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    sects = {}
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            va, vs, fo, fs = struct.unpack_from("<QQQQ", buf, off+24)
            segs.append((va, va+vs, fo))
            ns = struct.unpack_from("<I", buf, off+64)[0]
            for k in range(ns):
                so = off+72+k*80
                nm = buf[so:so+16].split(b"\0")[0].decode()
                sa, ssz = struct.unpack_from("<QQ", buf, so+32)
                sects[nm] = (sa, ssz)
        off += sz
    def o2(a):
        for lo, hi, fo in segs:
            if lo <= a < hi: return fo + (a-lo)
        return None
    inimg = lambda a: any(lo <= a < hi for lo, hi, _ in segs)
    def rdp(a):
        o = o2(a); return struct.unpack_from("<Q", buf, o)[0] if o is not None else 0
    def rdu(a):
        o = o2(a); return struct.unpack_from("<I", buf, o)[0] if o is not None else 0
    def rdi(a):
        o = o2(a); return struct.unpack_from("<i", buf, o)[0] if o is not None else 0

    recs = []; name_recs = []
    def do_ml(ml):
        if not ml or not inimg(ml): return
        ef = rdu(ml); count = rdu(ml+4)
        if not (ef & 0x80000000): return            # pointer-based -> entries are fixups
        # Lists carry the low-2 "fixed_up/sorted" flag from the cache, so objc trusts the cache's
        # SEL-address sort order and binary-searches by it — but objc re-uniques our selref pool
        # at load to canonical SELs in a DIFFERENT order, so the search misses (respondsToSelector
        # fails). Clear the flag so objc re-fixes-up + re-sorts the list against the canonical SELs.
        # (This needs the GOT/protoref/__EXTRA_OBJC fixes to be in place first, else realization
        # crashes earlier -- those are now done.) macOS objc tolerated the stale flag; iOS doesn't.
        struct.pack_into("<I", buf, o2(ml), ef & ~0x3)
        ent = (ef & 0xFFFC) or 12
        for i in range(count):
            e = ml + 8 + i*ent
            for fo in (4, 8):                         # types, imp -> relative-offset fix (work as-is)
                fa = e + fo; rel = rdi(fa)
                if rel: recs.append((fa, fa+rel))
            # name (offset 0) -> DyldExtractor selref slot -> selector string. objc only uniques
            # selrefs that live in the real __objc_selrefs section (small lists are assumed
            # pre-uniqued), and our slot sits in synthetic __EXTRA_OBJC -> never uniqued ->
            # dispatch-by-SEL misses. Record (name_field, selector_string) so we can repoint the
            # name at a freshly-built slot inside the (extended) __objc_selrefs pool.
            rel = rdi(e)
            if rel:
                slot = e + rel
                if inimg(slot):
                    sp = rdp(slot)
                    if inimg(sp): name_recs.append((e, sp))
    def do_methods(raw):
        # class_ro baseMethods is a PointerUnion<method_list_t, relative_list_list_t>; the low
        # bit tags a list-of-lists (pre-attached categories). Walk both forms.
        raw &= 0x00FFFFFFFFFFFFFF                      # strip PAC top byte
        if not raw: return
        if raw & 1:                                   # list-of-lists
            lol = raw & ~0x7
            if not inimg(lol): return
            cnt = rdu(lol+4)
            for i in range(cnt):
                entry = lol + 8 + i*8                  # {imageIndex:16, listOffset:48 (rel to entry)}
                if not inimg(entry): continue
                v = struct.unpack_from("<q", buf, o2(entry))[0]
                do_ml(entry + (v >> 16))
        else:
            do_ml(raw & ~0x7)
    def do_class(c):
        if not c or not inimg(c): return
        for cls in (c, rdp(c)):                       # class + metaclass(isa)
            if not inimg(cls): continue
            ro = rdp(cls+32) & 0x00007ffffffffff8
            if inimg(ro): do_methods(rdp(ro+32))       # baseMethods (single list OR list-of-lists)
    if "__objc_classlist" in sects:
        sa, ssz = sects["__objc_classlist"]
        for i in range(ssz//8): do_class(rdp(sa+i*8))
    if "__objc_catlist" in sects:
        sa, ssz = sects["__objc_catlist"]
        for i in range(ssz//8):
            cat = rdp(sa+i*8)
            if inimg(cat):
                do_ml(rdp(cat+16)); do_ml(rdp(cat+24))   # instanceMethods, classMethods
    if "__objc_protolist" in sects:                      # protocols carry rel method lists too
        sa, ssz = sects["__objc_protolist"]              # (fixupProtocol reads them -> must be valid)
        for i in range(ssz//8):
            p = rdp(sa+i*8)
            if inimg(p):
                for moff in (24, 32, 40, 48):            # {inst,class,optInst,optClass}Methods
                    do_ml(rdp(p+moff))
    return recs, name_recs


def make_amap(deltas):
    def amap(a):
        for lo, hi, d in deltas:
            if lo <= a < hi: return a + d
        return None
    return amap


def parse_segments(buf):
    """[(name, vmaddr, vmsize, fileoff, filesize, lc_off)] from a mach-o buffer."""
    magic, cputype, cpusub, ft, ncmds, scmds, flags, _ = struct.unpack_from("<IIIIIIII", buf, 0)
    segs, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            name = buf[off+8:off+24].split(b"\0")[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, off+24)
            segs.append([name, vmaddr, vmsize, fileoff, filesize, off])
        off += sz
    return segs, ncmds, scmds


def main(dsc, image_substr, dex_out, final_out, mode="compact"):
    global DSC; DSC = dsc
    logging.basicConfig(level=100)
    sb = progressbar.ProgressBar(prefix="{variables.unit}", variables={"unit": "", "status": ""},
                                 widgets=[progressbar.widgets.AnimatedMarker()], redirect_stdout=True)
    logger = logging.getLogger()

    # ---- collect fixups from the cache ----
    with open(dsc, "rb") as f:
        dyldCtx = DyldContext(f)
        subs = dyldCtx.addSubCaches(__import__("pathlib").Path(dsc))
        try:
            img = next(im for im in dyldCtx.images
                       if image_substr in dyldCtx.readString(im.pathFileOffset)[:-1].decode())
            mOff, mctx = dyldCtx.convertAddr(img.address)
            machoCtx = MachOContext(mctx.fileObject, mOff, True)
            if dyldCtx.hasSubCaches():
                mp = dyldCtx.mappings
                mainMap = next(m[0] for m in mp if m[1] == mctx)
                machoCtx.addSubfiles(mainMap, ((m, c.makeCopy(copyMode=True)) for m, c in mp))
            ectx = ExtractionContext(dyldCtx, machoCtx, sb, logger)
            segs = [(s.seg.vmaddr, s.seg.vmaddr+s.seg.vmsize) for s in machoCtx.segmentsI]
            base = min(s[0] for s in segs)
            in_img = lambda a: any(lo <= a < hi for lo, hi in segs)
            dylibs = []
            o = mOff+32
            for _ in range(mach_header_64(mctx.file, mOff).ncmds):
                cmd, sz = struct.unpack_from("<II", mctx.file, o)
                if cmd == LC_LOAD_DYLIB:
                    no = struct.unpack_from("<I", mctx.file, o+8)[0]
                    dylibs.append(mctx.file[o+no:o+sz].split(b"\0")[0].decode())
                o += sz

            fx = []  # (addr, target, auth, key, div, addrdiv)
            class C(slide_info._V3Rebaser):
                def _rebasePage(self, ctx, pageOffset, delta):
                    loc = pageOffset
                    while True:
                        loc += delta
                        li = dyld_cache_slide_pointer3(self.dyldCtx.file, loc)
                        delta = li.plain.offsetToNextPointer * 8
                        a = self.mapping.address + (loc - self.mapping.fileOffset)
                        if in_img(a):
                            if li.auth.authenticated:
                                t = li.auth.offsetFromSharedCacheBase + self.slideInfo.auth_value_add
                                fx.append([a, t, 1, int(li.auth.key), int(li.auth.diversityData),
                                           int(li.auth.hasAddressDiversity)])
                            else:
                                v = li.plain.pointerValue
                                t = ((v & 0x0007F80000000000) << 13) | (v & 0x000007FFFFFFFFFF)
                                fx.append([a, t, 0, 0, 0, 0])
                        if delta == 0:
                            break
            for info in slide_info._getMappingInfo(ectx):
                if info.slideInfo.version == 3:
                    C(ectx, info).run()
        finally:
            for sf in subs:
                sf.close()
    print(f"collected {len(fx)} fixups; base={base:#x}; dylibs={len(dylibs)}")
    if os.environ.get("VZ_DBG_AUTH"):
        from collections import Counter
        c = Counter((k, d, ad) for a, t, au, k, d, ad in fx if au)
        print("  AUTH (key,div,addrDiv) histogram:", c.most_common(12))
        print("  div=0xa65 entries (key,addrDiv):", Counter((k, ad) for a, t, au, k, d, ad in fx if au and d == 0xa65))

    # ---- load DyldExtractor output + relayout (gives addr map old->new) ----
    buf = bytearray(open(dex_out, "rb").read())
    objc_recs, objc_names = objc_collect_relmethods(buf) if mode == "compact" else ([], [])
    got_targets = collect_got_refs(buf, dsc) if mode == "compact" else {}   # {addr:(sym,is_auth)}
    unwind_pers = collect_unwind_personalities(buf, dsc) if mode == "compact" else []
    lsda_type_refs = collect_lsda_type_refs(buf, dsc) if mode == "compact" else []
    got_auth = {}                                      # symbol -> is_auth (consistent per symbol)
    for _a, (s, au) in got_targets.items(): got_auth[s] = got_auth.get(s, False) or au
    for s in unwind_pers:                              # personality routines are autia'd -> auth
        if s: got_auth[s] = True
    for _field, _target, symbol, _width in lsda_type_refs:
        if symbol: got_auth[symbol] = got_auth.get(symbol, False)
    got_syms = sorted(got_auth)
    if got_syms: print(f"out-of-image GOT: {len(got_targets)} slots -> {len(got_syms)} symbols "
                       f"({sum(got_auth.values())} auth fn, {len(got_syms)-sum(got_auth.values())} data)")
    if not os.environ.get("VZ_MAC"):     # VZ_MAC: keep macOS Versions/A paths for host dlopen test
        rewrite_dylib_paths(buf)
        # iOS-absent deps we import nothing from (verified: 0 bind targets land in them).
        weaken_absent_dylibs(buf, os.environ.get("VZ_WEAKEN", "MetalSerializer").split(","))
    # objc selref pool: one slot per unique selector used by relative method lists, appended
    # into __objc_selrefs so objc uniques them at load (small lists are assumed pre-uniqued).
    uniq_sel = sorted({s for _, s in objc_names})
    pool_sect = None
    pool_seg = None
    if mode == "compact" and (uniq_sel or got_syms):
        # ObjC images need selector slots inside __objc_selrefs so objc uniques
        # them. Plain C dylibs such as vmnet have no ObjC section; append their
        # rebuilt external-data GOT pool to the existing __got instead.
        candidates = (["__objc_selrefs"] if uniq_sel else []) + [
            "__got", "__data"]
        for candidate in candidates:
            pool_seg = _section_segment(buf, candidate.encode())
            if pool_seg:
                pool_sect = candidate
                break
    if mode == "compact":
        if pool_seg:
            pool_size = (len(uniq_sel) + len(got_syms)) * 8
            # With selector slots, only that prefix belongs to the ObjC
            # section. A C dylib's whole pool is ordinary GOT data.
            section_growth = len(uniq_sel) * 8 if uniq_sel else pool_size
            buf, deltas, pool_va = relayout_compact(
                buf, insert=(pool_seg, pool_sect, pool_size,
                             section_growth))
        else:
            buf, deltas = relayout_compact(buf); pool_va = None
        amap = make_amap(deltas); nbase = 0x100000000
    elif mode == "pad":
        reorder_segments(buf); buf = relayout_pad(buf); amap = lambda a: a; nbase = base
    else:
        reorder_segments(buf); buf = relayout(buf); amap = lambda a: a; nbase = base
    osegs, ncmds, scmds = parse_segments(buf)
    objc_slot_reb = []        # (new_slot_addr, new_string_addr) objc selref-pool rebases
    auth_stub_binds = []      # (slot_addr, symbol) rebuilt __auth_got auth-binds
    got_slot = {}             # {symbol: new_slot_addr} rebuilt in-image GOT pool
    if mode == "compact" and pool_va is not None and got_syms:
        got_pool_va = pool_va + len(uniq_sel) * 8                 # GOT pool sits right after the selref pool
        got_slot = {s: got_pool_va + i * 8 for i, s in enumerate(got_syms)}
    got_ref_slot = {t: got_slot[s] for t, (s, au) in got_targets.items() if s in got_slot}
    if mode == "compact" and unwind_pers and got_slot:           # repoint __unwind_info personalities
        npr = rewrite_unwind_personalities(buf, unwind_pers, got_slot, nbase)
        if npr: print(f"repointed {npr} __unwind_info personality ref(s) to rebuilt GOT")
    if mode == "compact" and lsda_type_refs:
        nlr = rewrite_lsda_type_refs(
            buf, lsda_type_refs, amap, got_slot, nbase)
        if nlr:
            print(f"repointed {nlr} LSDA catch-type ref(s) to rebuilt GOT")
    if mode == "compact":
        rewrite_adrp(buf, osegs, deltas, got_ref_slot)
        text_delta = next(d for lo, hi, d in deltas if lo + d == nbase)
        auth_stub_binds = fix_auth_stubs(buf, osegs, text_delta, dsc, amap)
        nfix = 0                                   # fix objc relative method-list types/imp offsets
        for fa, tgt in objc_recs:
            na, nt = amap(fa), amap(tgt)
            if na is None or nt is None: continue
            struct.pack_into("<i", buf, na - nbase, nt - na)
            nfix += 1
        print(f"fixed {nfix} objc relative method-list offsets")
        # build the selref pool: each unique selector gets a slot (rebased to the string),
        # and each relative method's name field is repointed at its slot.
        if pool_va is not None:
            str_slot = {s: pool_va + i*8 for i, s in enumerate(uniq_sel)}
            for s, slot in str_slot.items():
                nt = amap(s)
                if nt is not None: objc_slot_reb.append((slot, nt))
            nrep = 0
            for nf, s in objc_names:
                na = amap(nf)
                if na is None: continue
                struct.pack_into("<i", buf, na - nbase, str_slot[s] - na)   # name -> pool slot (rel)
                nrep += 1
            print(f"objc selref pool: {len(uniq_sel)} slots, repointed {nrep} method names")
        # Clear dyld-preoptimized flags in __objc_imageinfo, else objc map_images takes
        # the shared-cache preopt path (getPreoptimizedHeaderRW -> garbage ptr -> crash).
        # OptimizedByDyld(0x8) | OptimizedByDyldClosure(0x80) | DyldCategoriesOptimized(0x1)
        o3 = 32
        for _ in range(ncmds):
            c3, s3 = struct.unpack_from("<II", buf, o3)
            if c3 == LC_SEGMENT_64:
                for k in range(struct.unpack_from("<I", buf, o3+64)[0]):
                    so3 = o3+72+k*80
                    if buf[so3:so3+16].split(b"\0")[0] == b"__objc_imageinfo":
                        ioff = struct.unpack_from("<I", buf, so3+48)[0]
                        fl = struct.unpack_from("<I", buf, ioff+4)[0]
                        struct.pack_into("<I", buf, ioff+4, fl & ~(0x1 | 0x8 | 0x80))
                        print(f"objc_imageinfo flags {fl:#x} -> {fl & ~(0x1|0x8|0x80):#x}")
            o3 += s3
    def addr2off(a):
        for nm, va, vs, fo, fs, _ in osegs:
            if va <= a < va+vs: return fo + (a-va)
        raise KeyError(hex(a))

    # ---- classify + resolve binds; emit in NEW (relocated) addr space ----
    # a2s sometimes returns an objc-class alias not exported on iOS; map to the
    # concrete-block symbol that IS exported (same address, libSystem).
    ALIAS = {
        "_OBJC_CLASS_$___NSGlobalBlock__": "__NSConcreteGlobalBlock",
        "_OBJC_CLASS_$___NSStackBlock__":  "__NSConcreteStackBlock",
        "_OBJC_CLASS_$___NSMallocBlock__": "__NSConcreteMallocBlock",
        # ipsw a2s names XPC type singleton objects after the adjacent ObjC
        # class aliases.  Code using xpc_get_type compares against the
        # singleton (`_xpc_type_*`), not the OS_xpc_* class object.  Binding
        # these rebuilt external-data GOT slots to the class leaves the type
        # test false (or NULL when the private class export is unavailable).
        "_OBJC_CLASS_$_OS_xpc_connection": "__xpc_type_connection",
        "_OBJC_CLASS_$_OS_xpc_dictionary": "__xpc_type_dictionary",
        "_OBJC_CLASS_$_OS_xpc_error":      "__xpc_type_error",
        "_OBJC_CLASS_$_OS_xpc_string":     "__xpc_type_string",
        "_OBJC_CLASS_$_OS_xpc_uint64":     "__xpc_type_uint64",
    }
    imports = []; impidx = {}
    entries = {}  # new_loc -> (kind, val, auth, key, div, addrdiv, high8)
    # PLAIN pointers carry a TBI/high8 byte in bits 56-63 (arm64e plain-rebase has a
    # dedicated high8 field). Strip it for in-image classification + target math, then
    # re-apply on emit. AUTH targets (offsetFromSharedCacheBase + auth_value_add) never
    # have high8.
    def real_t(t, auth):
        return t if auth else (t & 0x00FFFFFFFFFFFFFF)
    bind_tgts = sorted({real_t(t, auth) for _, t, auth, *_ in fx if not in_img(real_t(t, auth))})
    if os.environ.get("VZ_DUMP_BINDS"):
        open(os.environ["VZ_DUMP_BINDS"], "w").write("\n".join(hex(t) for t in bind_tgts))
    print(f"resolving {len(bind_tgts)} unique bind targets (batch a2sb)...")
    sym_map = a2s_batch(bind_tgts)
    # objc selref/string localization: the cache uniques selector & class-name strings
    # into libobjc's shared __OBJC_RO pool, so a2sb can't name them ("?"). DyldExtractor
    # already copied the strings into our local CstringLiterals sections, so repoint these
    # pointers at the local copy (in-image rebase) instead of an (impossible) named bind.
    unnamed = [rt for rt in bind_tgts if not sym_map.get(rt, (None,))[0] or sym_map[rt][0] == "?"]
    localize = {}
    if unnamed:
        local_str_va = build_local_str_va(buf)
        cstrs = read_cache_cstrs(dsc, unnamed)
        for rt in unnamed:
            s = cstrs.get(rt)
            if s and s in local_str_va:
                localize[rt] = local_str_va[s]
        miss = [rt for rt in unnamed if rt not in localize]
        print(f"localized {len(localize)}/{len(unnamed)} unnamed objc string targets")
        if miss:
            print(f"  UNLOCALIZED: {[(hex(rt), cstrs.get(rt)) for rt in miss[:8]]}")
    nreb = nbind = 0
    for addr, t, auth, key, div, ad in fx:
        nloc = amap(addr)
        high8 = 0 if auth else (t >> 56) & 0xFF
        rt = real_t(t, auth)
        if os.environ.get("VZ_DBG_PROTOREF") and addr == int(os.environ["VZ_DBG_PROTOREF"], 16):
            print(f"  PROTOREF fx: addr={addr:#x} t={t:#x} auth={auth} rt={rt:#x} in_img={in_img(rt)} sym={sym_map.get(rt)}")
        if in_img(rt):
            entries[nloc] = ("rebase", amap(rt)-nbase, auth, key, div, ad, high8); nreb += 1
        elif rt in localize:
            entries[nloc] = ("rebase", localize[rt]-nbase, auth, key, div, ad, high8); nreb += 1
        else:
            name = sym_map.get(rt, (None, None))[0]
            if name and name.startswith("_ptr."):
                name = name[5:]          # ipsw GOT-slot notation -> the real symbol
            name = ALIAS.get(name, name)
            if name == "_OBJC_CLASS_$_Protocol":
                # Protocol-uniquing reference: the cache redirects every @protocol / adopted-
                # protocol pointer to libobjc's canonical protocol_t (whose isa is
                # _OBJC_CLASS_$_Protocol), so a2sb names the slot the Protocol *class* and we'd
                # otherwise BIND it there -> objc reads class+8 as a protocol mangledName ->
                # getProtocol/_mapStrHash SIGSEGV (conformsToProtocol). DyldExtractor's objc_fixer
                # rewrote the slot to THIS image's local same-name protocol_t; trust that file
                # value. Covers protorefs, class baseProtocols, protocol incorporated-protocols,
                # category protocols — every protocol-ref site, uniformly.
                fv = struct.unpack_from("<Q", buf, nloc - nbase)[0] & 0x00FFFFFFFFFFFFFF
                dt = amap(fv)
                if dt is not None:
                    entries[nloc] = ("rebase", dt - nbase, auth, key, div, ad, high8); nreb += 1
                    continue
                print(f"  WARNING: protocol ref @{nloc:#x} file-value {fv:#x} not in-image (external?) — binding to Protocol class")
            if not name: raise SystemExit(f"unresolved bind {rt:#x} (no symbol name)")
            # Flat-namespace lookup: dyld searches ALL of PVG's loaded dylibs by name.
            # Per-symbol dylib attribution is unreliable here — the cache uniques GOTs and
            # local symbols (e.g. _OBJC_CLASS_$_NSException is a *local* CoreFoundation
            # symbol that a2sb/image_for mis-home to libc++). All deps are in LC_LOAD_DYLIB,
            # so flat lookup resolves every symbol to its true exporting image.
            ordv = 0xFE
            k = (ordv, name)
            if k not in impidx:
                impidx[k] = len(imports); imports.append(k)
            entries[nloc] = ("bind", impidx[k], auth, key, div, ad, high8); nbind += 1
    for ns, nt in objc_slot_reb:                  # objc selref slots (plain in-image rebases)
        entries[ns] = ("rebase", nt - nbase, 0, 0, 0, 0, 0); nreb += 1
    for slot, name in auth_stub_binds:            # rebuilt __auth_got: auth-binds (braa: key IA, addrDiv)
        name = ALIAS.get(name, name)
        k = (0xFE, name)
        if k not in impidx:
            impidx[k] = len(imports); imports.append(k)
        entries[slot] = ("bind", impidx[k], 1, 0, 0, 1, 0); nbind += 1
    for name, slot in got_slot.items():           # rebuilt GOT pool: data (plain) + fn ptrs (auth, braa)
        au = got_auth[name]
        name = ALIAS.get(name, name)
        k = (0xFE, name)
        if k not in impidx:
            impidx[k] = len(imports); imports.append(k)
        entries[slot] = ("bind", impidx[k], 1, 0, 0, 1, 0) if au else ("bind", impidx[k], 0, 0, 0, 0, 0)
        nbind += 1
    # (Protocol references — __objc_protorefs, class baseProtocols, protocol incorporated-protocols,
    # category protocols — are handled uniformly in the main fixup loop above: any slot that would
    # bind to _OBJC_CLASS_$_Protocol is rebased to DyldExtractor's localized file value instead.
    # That relies on the DyldExtractor objc_fixer protocol-localization patch, see
    # patches/dyldextractor-2.2.2-arm64e.patch.)
    # __EXTRA_OBJC: DyldExtractor relocates objc metadata (protocols/categories) into this synthetic
    # segment with FLAT absolute RE-addr pointers, but the cache slide-info (our only fixup source)
    # doesn't cover it -> the pointers stay stale RE addresses. iOS objc reads protocol mangledName
    # etc. EAGERLY at load and derefs them -> crash (macOS read them lazily so the VM never hit it).
    # Rebase every 8-byte slot whose value lands in an original-image segment (amap != None); small
    # fields (flags/sizes), relative-list int32 pairs, and cstring bytes fall outside that range.
    neo = 0
    if mode == "compact":
        for nm, va, vs, fo, fs, lc in osegs:
            if nm != "__EXTRA_OBJC": continue
            for p in range(0, fs - 7, 8):
                v = struct.unpack_from("<Q", buf, fo + p)[0]
                if v < 0x100000000: continue
                t = amap(v)
                if t is not None and (va + p) not in entries:
                    entries[va + p] = ("rebase", t - nbase, 0, 0, 0, 0, 0); nreb += 1; neo += 1
    print(f"{nreb} rebases ({len(objc_slot_reb)} selref + {neo} __EXTRA_OBJC), {nbind} binds ({len(auth_stub_binds)} auth-stub), {len(imports)} imports")
    if mode == "compact":
        fix_export_trie(buf, amap, nbase, deltas)      # remap stale export offsets (dyld/ld symbol resolution)

    # group by output segment; build per-segment page chains
    seg_fixups = {i: [] for i in range(len(osegs))}
    for addr in entries:
        for i, (nm, va, vs, fo, fs, lc) in enumerate(osegs):
            if va <= addr < va+vs:
                seg_fixups[i].append(addr); break

    # weave: write packed entries with next deltas (per PAGE within segment)
    seg_starts = {}  # segidx -> list of page_start (uint16)
    for i, (nm, va, vs, fo, fs, lc) in enumerate(osegs):
        addrs = sorted(seg_fixups[i])
        if not addrs: continue
        npages = (vs + PAGE - 1)//PAGE
        pstart = [START_NONE]*npages
        # bucket by page
        from collections import defaultdict
        bypage = defaultdict(list)
        for a in addrs: bypage[(a-va)//PAGE].append(a)
        for pg, plist in bypage.items():
            plist.sort()
            pstart[pg] = (plist[0]-va) - pg*PAGE   # offset within page
            for j, a in enumerate(plist):
                nxt = ((plist[j+1]-a)//8) if j+1 < len(plist) else 0
                kind, v, auth, key, div, ad, high8 = entries[a]
                if kind == "rebase":
                    word = pack_auth_rebase(v, div, ad, key, nxt) if auth else pack_rebase(v, nxt, high8)
                else:
                    word = pack_auth_bind(v, div, ad, key, nxt) if auth else pack_bind(v, 0, nxt)
                struct.pack_into("<Q", buf, addr2off(a), word)
        seg_starts[i] = pstart

    # ---- build LC_DYLD_CHAINED_FIXUPS blob ----
    def align(b, n):
        while len(b) % n: b += b"\0"
        return b
    # symbols pool
    sympool = bytearray(); symoff = {}
    for lo, n in imports:
        symoff[n] = len(sympool); sympool += n.encode()+b"\0"
    # imports (DYLD_CHAINED_IMPORT: lib_ordinal:8, weak:1, name_offset:23)
    # weak_import=1: porting a macOS framework onto iOS, a handful of imports are macOS-only
    # APIs absent from the iOS cache (e.g. AppKit's NSBitmapImageRep). Weak makes dyld bind
    # them to NULL instead of failing the load; present symbols still resolve normally.
    weak = 0 if os.environ.get("VZ_NO_WEAK_IMPORTS") else 1
    imp_blob = bytearray()
    for lo, n in imports:
        imp_blob += struct.pack("<I", (lo & 0xFF) | (weak << 8) | ((symoff[n] & 0x7FFFFF) << 9))
    # starts_in_image + per-seg starts_in_segment
    seg_count = len(osegs)
    sii = bytearray(struct.pack("<I", seg_count))           # seg_count
    sii += b"\0\0\0\0"*seg_count                             # seg_info_offset[] (fill later)
    seg_seg_blobs = {}
    for i in seg_starts:
        ps = seg_starts[i]
        b = struct.pack("<IHHQIH", 0, PAGE, PF_ARM64E_USERLAND, osegs[i][1]-nbase, 0, len(ps))
        b += b"".join(struct.pack("<H", x) for x in ps)
        b = bytearray(b)
        struct.pack_into("<I", b, 0, len(b))                # size field
        seg_seg_blobs[i] = b
    # lay out seg blobs after the seg_info_offset array
    cur = len(sii)
    for i in sorted(seg_seg_blobs):
        while cur % 4: cur += 1; sii += b"\0"
        struct.pack_into("<I", sii, 4 + i*4, cur)           # seg_info_offset[i]
        sii += seg_seg_blobs[i]; cur = len(sii)

    blob = bytearray(struct.pack("<IIIIIII", 0, 0, 0, 0, len(imports), 1, 0))  # header (fill offsets)
    blob = align(blob, 4); starts_off = len(blob); blob += sii
    blob = align(blob, 4); imports_off = len(blob); blob += imp_blob
    symbols_off = len(blob); blob += sympool
    struct.pack_into("<IIIIIII", blob, 0, 0, starts_off, imports_off, symbols_off, len(imports), 1, 0)
    blob = align(blob, 8)

    # ---- splice: place blob at the file end, point LC at it, extend last seg ----
    li = max(osegs, key=lambda s: s[3])          # highest fileoff = last segment (must be __LINKEDIT)
    assert li[0] == "__LINKEDIT", f"last segment is {li[0]} not __LINKEDIT"
    while len(buf) % 8: buf += b"\0"
    dataoff = len(buf)                           # blob goes exactly here
    buf += blob
    # extend __LINKEDIT to cover [fileoff .. end of blob] (gap before blob is harmless zeros)
    li[4] = len(buf) - li[3]                                # filesize
    vmsize = (li[4] + 0x3FFF) & ~0x3FFF
    struct.pack_into("<Q", buf, li[5]+32, vmsize)           # vmsize
    struct.pack_into("<Q", buf, li[5]+48, li[4])            # filesize (fileoff @+40 intact)

    # find space for new LC: drop LC_FUNCTION_STARTS + LC_DATA_IN_CODE if needed, then append our LC
    # simplest: append after last LC; ensure header region has room before first section data.
    first_sec_off = min((s[3] for s in osegs if s[3] > 0), default=0x4000)
    lc_end = 32 + scmds
    newlc = struct.pack("<IIII", LC_DYLD_CHAINED_FIXUPS, 16, dataoff, len(blob))
    if lc_end + 16 <= first_sec_off:
        buf[lc_end:lc_end] = b""        # write in place
        buf[lc_end:lc_end+16] = newlc
        struct.pack_into("<I", buf, 16, ncmds+1)     # ncmds
        struct.pack_into("<I", buf, 20, scmds+16)    # sizeofcmds
    else:
        raise SystemExit(f"no header room: lc_end={lc_end:#x} first_sec={first_sec_off:#x}")

    # clear MH_DYLIB_IN_CACHE (correct metadata: the dylib is no longer in the cache;
    # tolerated-if-set on 13.2/16.3.1 dyld, but cleared for correctness, as dsce does)
    flags = struct.unpack_from("<I", buf, 24)[0]
    struct.pack_into("<I", buf, 24, flags & ~MH_DYLIB_IN_CACHE)

    open(final_out, "wb").write(buf)
    print(f"wrote {final_out} ({len(buf)} bytes); blob@{dataoff:#x} size={len(blob)}")


if __name__ == "__main__":
    main(*sys.argv[1:])

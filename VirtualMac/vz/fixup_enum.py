#!/usr/bin/env python3
"""Enumerate the slide-info-v3 fixups for one image in an arm64e dyld cache.

Reuses DyldExtractor's cache parsing + V3 page-chain walk, but RECORDS each
fixup (target + auth: key/diversity/authenticated) instead of discarding it
(which is all DyldExtractor does). Classifies in-image (rebase) vs external
(bind) and tallies authenticated pointers.

Usage: python3 fixup_enum.py <main-cache> <image-path-substring>
"""
import sys, struct, logging
import progressbar

from DyldExtractor.extraction_context import ExtractionContext
from DyldExtractor.macho.macho_context import MachOContext
from DyldExtractor.dyld.dyld_context import DyldContext
from DyldExtractor.dyld.dyld_structs import dyld_cache_slide_pointer3
from DyldExtractor.dyld.dyld_constants import DYLD_CACHE_SLIDE_V3_PAGE_ATTR_NO_REBASE
from DyldExtractor.converter import slide_info


def enumerate_fixups(dsc_path, image_substr):
    logger = logging.getLogger()
    logging.basicConfig(level=100)
    statusBar = progressbar.ProgressBar(
        prefix="{variables.unit} >> {variables.status} :: [",
        variables={"unit": "--", "status": "--"},
        widgets=[progressbar.widgets.AnimatedMarker(), "]"], redirect_stdout=True)

    with open(dsc_path, "rb") as f:
        dyldCtx = DyldContext(f)
        subs = dyldCtx.addSubCaches(__import__("pathlib").Path(dsc_path))
        try:
            # locate the image
            target_img = None
            for imageData in dyldCtx.images:
                p = dyldCtx.readString(imageData.pathFileOffset)[:-1].decode("utf-8")
                if image_substr in p:
                    target_img = imageData
                    target_path = p
                    break
            if not target_img:
                print("image not found"); return
            print(f"image: {target_path}")

            machoOffset, context = dyldCtx.convertAddr(target_img.address)
            machoCtx = MachOContext(context.fileObject, machoOffset, True)
            if dyldCtx.hasSubCaches():
                mappings = dyldCtx.mappings
                mainFileMap = next(m[0] for m in mappings if m[1] == context)
                machoCtx.addSubfiles(mainFileMap, ((m, c.makeCopy(copyMode=True)) for m, c in mappings))
            extractionCtx = ExtractionContext(dyldCtx, machoCtx, statusBar, logger)

            # image segment vmaddr ranges (for in-image classification)
            seg_ranges = []
            for seg in machoCtx.segmentsI:
                s = seg.seg
                seg_ranges.append((s.vmaddr, s.vmaddr + s.vmsize, bytes(s.segname).rstrip(b"\0").decode()))
            in_image = lambda a: any(lo <= a < hi for lo, hi, _ in seg_ranges)
            print("segments:")
            for lo, hi, nm in seg_ranges:
                print(f"  {nm:16} {lo:#014x} - {hi:#014x}")

            # collector subclass of the V3 rebaser
            recs = []  # (addr, target, authenticated, key, diversity)

            class Collector(slide_info._V3Rebaser):
                def _rebasePage(self, ctx, pageOffset, delta):
                    locOff = pageOffset
                    while True:
                        locOff += delta
                        li = dyld_cache_slide_pointer3(self.dyldCtx.file, locOff)
                        delta = li.plain.offsetToNextPointer * 8
                        addr = self.mapping.address + (locOff - self.mapping.fileOffset)
                        if not in_image(addr):
                            # shared 16KB cache page: skip fixups belonging to neighbor images
                            if delta == 0:
                                break
                            continue
                        if li.auth.authenticated:
                            tgt = li.auth.offsetFromSharedCacheBase + self.slideInfo.auth_value_add
                            recs.append((addr, tgt, 1, int(li.auth.key), int(li.auth.diversityData)))
                        else:
                            v = li.plain.pointerValue
                            tgt = ((v & 0x0007F80000000000) << 13) | (v & 0x000007FFFFFFFFFF)
                            recs.append((addr, tgt, 0, 0, 0))
                        if delta == 0:
                            break

            for info in slide_info._getMappingInfo(extractionCtx):
                if info.slideInfo.version == 3:
                    Collector(extractionCtx, info).run()

            auth = sum(r[2] for r in recs)
            rebases = [r for r in recs if in_image(r[1])]
            binds = [r for r in recs if not in_image(r[1])]
            print(f"\n=== {len(recs)} fixups in image ===")
            print(f"  authenticated : {auth}")
            print(f"  non-auth      : {len(recs)-auth}")
            print(f"  in-image (REBASE): {len(rebases)}")
            print(f"  external (BIND)  : {len(binds)}")
            print("  sample binds (addr -> target):")
            for r in binds[:8]:
                print(f"    {r[0]:#014x} -> {r[1]:#014x}  auth={r[2]} key={r[3]} div={r[4]}")
            print("  sample rebases:")
            for r in rebases[:6]:
                print(f"    {r[0]:#014x} -> {r[1]:#014x}  auth={r[2]} key={r[3]} div={r[4]}")
        finally:
            for sf in subs:
                sf.close()


if __name__ == "__main__":
    enumerate_fixups(sys.argv[1], sys.argv[2])

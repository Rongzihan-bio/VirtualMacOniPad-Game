#!/usr/bin/env python3
"""Synchronize checked-in Localizable.strings files with Objective-C keys.

This maintenance command never translates or replaces reviewed text. It adds
an explicit English fallback for missing keys, then rewrites every catalog in
one deterministic alphabetical sequence. Translators can replace fallbacks
without losing format placeholders or key coverage.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "resources" / "Localizations"
SOURCE_PATTERN = re.compile(r'(?:VZL|VML)\(@"((?:[^"\\]|\\.)*)"\)')
STRINGS_PATTERN = re.compile(
    r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M
)


def source_keys() -> list[str]:
    keys: set[str] = set()
    for directory in (ROOT / "vz" / "host", ROOT / "vz" / "guest"):
        for source in directory.glob("*.m"):
            keys.update(SOURCE_PATTERN.findall(source.read_text()))
    return sorted(keys, key=str.casefold)


def quote(value: str) -> str:
    # Captured source keys already use Objective-C/.strings escaping. Preserve
    # those sequences byte-for-byte and escape only literal newlines.
    return value.replace("\n", r"\n")


keys = source_keys()
for path in sorted(RESOURCE_ROOT.glob("*.lproj/Localizable.strings")):
    contents = path.read_text()
    entries = dict(STRINGS_PATTERN.findall(contents))
    missing = [key for key in keys if key not in entries]
    for key in missing:
        entries[key] = key
    lines = []
    lines.extend(
        f'"{quote(key)}" = "{quote(entries[key])}";'
        for key in keys
    )
    path.write_text("\n".join(lines) + "\n")
    print(
        f"{path.relative_to(ROOT)}: sorted {len(keys)} keys"
        + (f", added {len(missing)}" if missing else "")
    )

#!/usr/bin/env python3
"""Fail a build when a produced Mach-O has unexpected entitlements.

Arguments are EXPECTED_PLIST BINARY pairs. Use '-' for a binary which must
have no entitlements. ldid is used for extraction because it understands the
iOS-style ad-hoc signatures used by the jailbroken-device payload.
"""

import pathlib
import plistlib
import subprocess
import sys


def load_expected(path_text: str) -> dict:
    if path_text == "-":
        return {}
    with pathlib.Path(path_text).open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise SystemExit(f"{path_text}: entitlement plist is not a dictionary")
    return value


def load_actual(binary: str) -> dict:
    result = subprocess.run(
        ["ldid", "-e", binary], check=True, capture_output=True
    )
    if not result.stdout.strip():
        return {}
    value = plistlib.loads(result.stdout)
    if not isinstance(value, dict):
        raise SystemExit(f"{binary}: embedded entitlements are not a dictionary")
    return value


def main(arguments: list[str]) -> None:
    if not arguments or len(arguments) % 2:
        raise SystemExit(
            "usage: audit-entitlements.py EXPECTED_PLIST|- BINARY [...]"
        )
    for index in range(0, len(arguments), 2):
        expected_path, binary = arguments[index : index + 2]
        expected = load_expected(expected_path)
        actual = load_actual(binary)
        if actual != expected:
            missing = sorted(set(expected) - set(actual))
            extra = sorted(set(actual) - set(expected))
            changed = sorted(
                key for key in set(expected) & set(actual)
                if expected[key] != actual[key]
            )
            raise SystemExit(
                f"{binary}: entitlement audit failed; "
                f"missing={missing} extra={extra} changed={changed}"
            )
        print(f"entitlements ok: {binary} ({len(actual)} keys)")


if __name__ == "__main__":
    main(sys.argv[1:])

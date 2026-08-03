#!/usr/bin/env python3
"""Audit packaged Mach-O dependencies/imports against an iPadOS dyld cache."""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


IPSW_TOOL = os.environ.get("VZ_IPSW_TOOL", "ipsw")


def command_output(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout.decode("utf-8", "ignore")


def dependency_label(path: str) -> str:
    basename = path.rsplit("/", 1)[-1]
    if basename.endswith(".dylib"):
        basename = basename[:-6]
    return basename


def possible_labels(path: str) -> set[str]:
    label = dependency_label(path)
    labels = {label}
    components = label.split(".")
    while len(components) > 1 and (
        components[-1].isdigit() or len(components[-1]) == 1
    ):
        components.pop()
        labels.add(".".join(components))
    return labels


def normalized_install_name(path: str) -> str:
    return path.replace(".framework/Versions/A/", ".framework/")


class SharedCache:
    def __init__(self, cache_path: Path, work_path: Path) -> None:
        self.path = cache_path
        self.tbd_root = work_path / "tbd"
        self.tbd_root.mkdir(parents=True, exist_ok=True)
        self.parsed_tbds: dict[Path, tuple[set[str], list[str]]] = {}

        listing = command_output(
            IPSW_TOOL, "dyld", "info", "-l", "--no-color", str(cache_path)
        )
        images = re.findall(r"^\s*\d+:\s+.*?(/\S+)\s*$", listing, re.MULTILINE)
        if not images:
            raise RuntimeError(f"could not enumerate images in {cache_path}")
        self.images = {normalized_install_name(image): image for image in images}

    def actual_install_name(self, requested: str) -> str | None:
        return self.images.get(normalized_install_name(requested))

    def tbd_path(self, install_name: str) -> Path:
        return self.tbd_root / (install_name.rsplit("/", 1)[-1] + ".tbd")

    def ensure_tbd(self, install_name: str) -> Path | None:
        actual_name = self.actual_install_name(install_name) or install_name
        output = self.tbd_path(actual_name)
        if output.exists():
            return output
        subprocess.run(
            [
                IPSW_TOOL,
                "dyld",
                "tbd",
                str(self.path),
                actual_name,
                "-o",
                str(self.tbd_root),
                "--no-color",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return output if output.exists() else None

    def parse_tbd(self, path: Path) -> tuple[set[str], list[str]]:
        if path in self.parsed_tbds:
            return self.parsed_tbds[path]

        text = path.read_text(errors="ignore")
        documents = text.split("--- !tapi-tbd")
        first_document = documents[1] if len(documents) > 1 else text
        exports: set[str] = set()
        for key in ("symbols", "weak-symbols"):
            for match in re.finditer(
                rf"(?m)^\s*{key}:\s*\[(.*?)\]", first_document, re.DOTALL
            ):
                exports.update(
                    token.strip().strip("'\"")
                    for token in match.group(1).split(",")
                    if token.strip()
                )

        reexports: list[str] = []
        match = re.search(
            r"(?m)^reexported-libraries:\s*(.*?)(?=^exports:|^---)",
            first_document,
            re.DOTALL,
        )
        if match:
            reexports = re.findall(r"'([^']+)'", match.group(1))
        self.parsed_tbds[path] = exports, reexports
        return exports, reexports

    def exports_symbol(
        self, install_name: str, symbol: str, visited: set[str] | None = None
    ) -> bool:
        if visited is None:
            visited = set()
        normalized = normalized_install_name(install_name)
        if normalized in visited:
            return False
        visited.add(normalized)

        tbd = self.ensure_tbd(install_name)
        if tbd is None:
            return False
        exports, reexports = self.parse_tbd(tbd)
        if symbol in exports:
            return True
        return any(self.exports_symbol(item, symbol, visited) for item in reexports)


def find_machos(roots: list[Path]) -> list[Path]:
    binaries: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for directory, _, filenames in os.walk(root, followlinks=False):
            for filename in filenames:
                candidate = Path(directory) / filename
                # Build-only macOS inputs; their restamped siblings are audited.
                if candidate.name.endswith(".macos"):
                    continue
                if candidate.is_symlink():
                    continue
                if "Mach-O" in command_output("file", str(candidate)):
                    binaries.append(candidate)
    return binaries


def linked_dependencies(binary: Path) -> list[tuple[str, bool]]:
    dependencies: list[tuple[str, bool]] = []
    for line in command_output("dyld_info", "-dependents", str(binary)).splitlines():
        columns = line.split()
        if columns and columns[-1].startswith(("/", "@")):
            dependencies.append((columns[-1], "weak-link" in columns[:-1]))
    return dependencies


def imports(binary: Path):
    pattern = re.compile(
        r"^\s+0x[0-9A-Fa-f]+\s+(\S+)"
        r"(?:\s+\[weak-import\])?\s+\(from ([^)]+)\)"
    )
    for line in command_output("dyld_info", "-imports", str(binary)).splitlines():
        match = pattern.match(line)
        if not match:
            continue
        symbol, label = match.groups()
        symbol = re.sub(r"\+0x[0-9A-Fa-f]+$", "", symbol)
        yield symbol, label, "[weak-import]" in line


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("cache", type=Path)
    parser.add_argument("work", type=Path)
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()

    cache = SharedCache(args.cache, args.work)
    binaries = find_machos(args.roots)
    if not binaries:
        raise RuntimeError("no Mach-O files found for shared-cache audit")

    # This one macOS install name is deliberately redirected to the bundled
    # extracted framework by DYLD_FRAMEWORK_PATH before Virtualization loads.
    hypervisor_name = "/System/Library/Frameworks/Hypervisor.framework/Hypervisor"
    bundled_hypervisor = next(
        (
            root / "Frameworks/Hypervisor.framework/Versions/A/Hypervisor"
            for root in args.roots
            if (root / "Frameworks/Hypervisor.framework/Versions/A/Hypervisor").is_file()
        ),
        None,
    )

    missing_dependencies: list[str] = []
    missing_imports: list[str] = []
    weak_missing_dependencies = 0
    weak_missing_imports = 0
    audited_imports = 0

    for binary in binaries:
        dependencies = linked_dependencies(binary)
        labels: dict[str, list[tuple[str, bool]]] = {}
        for dependency, weak in dependencies:
            for label in possible_labels(dependency):
                labels.setdefault(label, []).append((dependency, weak))

            if not dependency.startswith(("/System/", "/usr/", "/Library/Apple/")):
                continue
            if dependency == hypervisor_name and bundled_hypervisor is not None:
                continue
            if cache.actual_install_name(dependency) is None:
                if weak:
                    weak_missing_dependencies += 1
                else:
                    missing_dependencies.append(f"{binary}: {dependency}")

        for symbol, label, weak_import in imports(binary):
            if label.startswith("<"):
                continue
            candidates = labels.get(label, [])
            if not candidates:
                missing_imports.append(f"{binary}: cannot resolve import owner {label}")
                continue
            system_candidates = [
                item
                for item in candidates
                if item[0].startswith(("/System/", "/usr/", "/Library/Apple/"))
            ]
            if not system_candidates:
                # The owner is bundled; its own imports are audited separately.
                continue
            dependency, weak_dependency = system_candidates[0]
            if dependency == hypervisor_name and bundled_hypervisor is not None:
                continue

            audited_imports += 1
            if cache.exports_symbol(dependency, symbol):
                continue
            if weak_import or weak_dependency:
                weak_missing_imports += 1
            else:
                missing_imports.append(f"{binary}: {symbol} from {dependency}")

    for problem in missing_dependencies + missing_imports:
        print(f"error: {problem}", file=sys.stderr)
    if missing_dependencies or missing_imports:
        return 1

    print(
        "oldest-host ABI verified: "
        f"{len(binaries)} Mach-O files, {audited_imports} system imports; "
        f"{weak_missing_dependencies} absent weak dylibs and "
        f"{weak_missing_imports} absent weak imports tolerated"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

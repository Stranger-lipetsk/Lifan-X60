#!/usr/bin/env python3
"""Scan Android APK/JAR/ELF artifacts for selected DEX and native string markers.

Uses only Python's standard library. This is triage, not decompilation: DEX hits
must be followed by class/method inspection, and native strings are not proof of
runtime call paths.
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path
from typing import Iterable

DEFAULT_MARKERS = (
    "com.nforetek.bt.service.NfServiceSpp",
    "com.nforetek.bt",
    "INfCommandSpp",
    "ServiceManager.addService",
    "publishBinderService",
    "SPP",
    "RFCOMM",
    "/dev/rfcomm",
    "/dev/tty",
)
PRINTABLE = re.compile(rb"[\x20-\x7e]{4,}")


def extract_ascii_strings(data: bytes) -> Iterable[str]:
    for match in PRINTABLE.finditer(data):
        yield match.group().decode("ascii", "replace")


def scan_bytes(label: str, data: bytes, markers: tuple[str, ...]) -> list[str]:
    strings = list(extract_ascii_strings(data))
    lowered_markers = [(marker, marker.casefold()) for marker in markers]
    found = []
    for line in strings:
        folded = line.casefold()
        hits = [marker for marker, needle in lowered_markers if needle in folded]
        if hits:
            found.append(f"  {label}: [{', '.join(hits)}] {line}")
    return found


def scan_file(path: Path, markers: tuple[str, ...]) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        return [f"ERROR {path}: {exc}"]
    results = []
    if zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    # DEX is the primary Java bytecode target; scan manifests and
                    # native payloads too for service metadata and native strings.
                    if info.filename.endswith((".dex", "AndroidManifest.xml", ".so")):
                        try:
                            payload = archive.read(info)
                        except (OSError, zipfile.BadZipFile) as exc:
                            results.append(f"ERROR {path}!{info.filename}: {exc}")
                            continue
                        results.extend(scan_bytes(f"{path}!{info.filename}", payload, markers))
        except (OSError, zipfile.BadZipFile) as exc:
            return [f"ERROR {path}: {exc}"]
    else:
        results.extend(scan_bytes(str(path), data, markers))
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="files or directories to scan")
    parser.add_argument("--marker", action="append", dest="markers", help="additional marker (repeatable)")
    args = parser.parse_args(argv)
    markers = tuple(DEFAULT_MARKERS) + tuple(args.markers or ())
    files: list[Path] = []
    for path in args.paths:
        if path.is_dir():
            files.extend(sorted(p for p in path.rglob("*") if p.is_file()))
        elif path.is_file():
            files.append(path)
        else:
            print(f"ERROR not found: {path}", file=sys.stderr)
            return 2
    total = 0
    for path in files:
        hits = scan_file(path, markers)
        if hits:
            print(f"## {path}")
            print("\n".join(hits))
            total += len(hits)
    print(f"Scanned {len(files)} file(s); {total} matching string record(s).")
    print("String matches are leads only; they do not establish code ownership or runtime behavior.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

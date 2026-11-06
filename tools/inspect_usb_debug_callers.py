#!/usr/bin/env python3
"""Search extracted, trusted stock-derived system files; never execute them."""
import os
import re
import sys
import zipfile
from pathlib import Path

NEEDLES = (b'usbnet_adb_support', b'usbnet_adb', b'el_debug_tool', b'service.adb.tcp.port')
MAX_FILE = 256 * 1024 * 1024
MAX_ARCHIVE_UNCOMPRESSED = 512 * 1024 * 1024


def matches(data):
    return [needle.decode('ascii') for needle in NEEDLES
            if needle in data or needle.decode('ascii').encode('utf-16le') in data]


def scan(root):
    """Return matches and explicit scan gaps. Does not follow filesystem symlinks."""
    root = Path(root)
    found, gaps = [], []
    files = archives = entries = 0
    for parent, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not (Path(parent) / d).is_symlink())
        for name in sorted(names):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                continue
            try:
                if not path.is_file():
                    continue
                files += 1
                size = path.stat().st_size
                if size > MAX_FILE:
                    gaps.append((relative, 'file too large'))
                    continue
                data = path.read_bytes()
                for needle in matches(data):
                    found.append((relative, 'raw file', needle))
                if not zipfile.is_zipfile(path):
                    continue
                archives += 1
                with zipfile.ZipFile(path) as archive:
                    total = 0
                    for info in archive.infolist():
                        if info.is_dir():
                            continue
                        total += info.file_size
                        if info.file_size > MAX_FILE or total > MAX_ARCHIVE_UNCOMPRESSED:
                            gaps.append((relative + '!' + info.filename, 'archive size limit'))
                            continue
                        entries += 1
                        for needle in matches(archive.read(info)):
                            found.append((relative, info.filename, needle))
            except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
                gaps.append((relative, type(error).__name__))
    return found, gaps, (files, archives, entries)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_usb_debug_callers.py EXTRACTED_SYSTEM_DIR')
    root = Path(sys.argv[1])
    if not (root / 'bin' / 'el_debug_tool').is_file():
        raise SystemExit('Expected extracted system root with bin/el_debug_tool')
    found, gaps, counts = scan(root)
    print('# USB network debug callers: offline search of extracted system')
    print('No firmware code was executed, no device was accessed.')
    print('Files: %d; ZIP/APK/JAR archives: %d; archive entries: %d' % counts)
    print('Direct ASCII and UTF-16LE string search; nested archives, split/encrypted or dynamically constructed strings may be missed.')
    print('\n## Matches')
    for path, entry, needle in found:
        print('%s | %s | %s' % (path, entry, needle))
    print('\n## Skipped or failed files and entries:', len(gaps))
    for path, why in gaps:
        print(path, '|', why)
    module = root / 'lib' / 'modules' / 'asix.ko'
    if module.is_file() and not module.is_symlink():
        data = module.read_bytes()
        print('\n## ASIX module embedded metadata (not runtime compatibility)')
        for item in re.findall(rb'(?:alias=usb:[ -~]+|vermagic=[ -~]+)', data):
            print(item.decode('ascii'))
    else:
        print('\nASIX module unavailable in extracted files')
    print('\nAbsence of matches does not prove a property cannot be set through another path.')


if __name__ == '__main__':
    main()

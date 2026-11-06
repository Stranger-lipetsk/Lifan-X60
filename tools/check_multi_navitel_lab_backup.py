#!/usr/bin/env python3
"""Verify a narrowly scoped synthetic emulator archive in memory; never extract."""
import io
import sys
import tarfile
import zlib
from pathlib import Path

from tools.check_no_adb_lab_backup import verify_contents
from tools.check_synthetic_adb_backup import MARKER, PREFS

LIMIT = 32 * 1024 * 1024
NAV = 'apps/com.navitel/'
FIXTURE = 'apps/ru.lifanx60.backupfixture/'
REQUIRED = {NAV+'f/lab-marker.txt', NAV+'sp/x60_lab_probe.xml',
            FIXTURE+'f/lab-marker.txt', FIXTURE+'sp/lab_probe.xml'}


def inspect(raw):
    if len(raw) > LIMIT:
        raise ValueError('Archive too large for the synthetic test')
    header = raw.split(b'\n', 4)
    if len(header) != 5 or header[0] != b'ANDROID BACKUP' or header[1] not in (b'1', b'2', b'3', b'4', b'5') or header[2] not in (b'0', b'1') or header[3] != b'none':
        raise ValueError('Unexpected synthetic backup header')
    data = header[4]
    if header[2] == b'1':
        decomp = zlib.decompressobj()
        data = decomp.decompress(data, LIMIT + 1)
        if len(data) > LIMIT or decomp.unconsumed_tail or not decomp.eof:
            raise ValueError('Incomplete or too large backup')
    if len(data) > LIMIT:
        raise ValueError('Uncompressed payload too large')
    found = {}
    names = []
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        for member in archive:
            names.append(member.name)
            if not member.name.startswith((NAV, FIXTURE)):
                raise ValueError('Unexpected package or shared storage: ' + member.name)
            if member.name in REQUIRED:
                if not member.isfile() or member.size > 1024 or member.name in found:
                    raise ValueError('Unexpected synthetic member')
                found[member.name] = archive.extractfile(member).read()
    if set(found) != REQUIRED:
        raise ValueError('Missing synthetic files')
    if found[NAV+'f/lab-marker.txt'] != MARKER or found[NAV+'sp/x60_lab_probe.xml'] != PREFS:
        raise ValueError('Navitel synthetic bytes differ')
    verify_contents(found[FIXTURE+'f/lab-marker.txt'], found[FIXTURE+'sp/lab_probe.xml'])
    return names


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: python -m tools.check_multi_navitel_lab_backup SYNTHETIC_ARCHIVE')
    for name in inspect(Path(sys.argv[1]).read_bytes()):
        print('Lab archive entry:', name)
    print('Navitel and independent synthetic files matched; allowBackup=false target absent: yes')


if __name__ == '__main__':
    main()

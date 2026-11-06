#!/usr/bin/env python3
"""Check a disposable emulator archive in memory; never extract it."""
import io
import sys
import tarfile
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

MAX_BYTES = 16 * 1024 * 1024
PREFIX = 'apps/ru.lifanx60.backupfixture/'
EXPECTED = {PREFIX + 'f/lab-marker.txt', PREFIX + 'sp/lab_probe.xml'}


def verify_contents(marker, preferences):
    if marker != b'X60_BACKUP_ONLY_FIXTURE\n':
        raise ValueError('Synthetic marker differs')
    xml = ET.fromstring(preferences)
    if xml.tag != 'map' or len(xml) != 1 or xml[0].tag != 'string' or xml[0].get('name') != 'lab_probe' or xml[0].text != 'X60_ONLY_SYNTHETIC_PREF':
        raise ValueError('Synthetic SharedPreferences differ')


def inspect(path):
    raw = Path(path).read_bytes()
    if len(raw) > MAX_BYTES:
        raise ValueError('Unexpectedly large archive')
    parts = raw.split(b'\n', 4)
    if len(parts) != 5 or parts[0] != b'ANDROID BACKUP' or parts[1] not in (b'1', b'2', b'3', b'4', b'5'):
        raise ValueError('Unexpected Android backup header')
    if parts[2] not in (b'0', b'1') or parts[3] != b'none':
        raise ValueError('Expected unencrypted disposable backup')
    if parts[2] == b'1':
        d = zlib.decompressobj()
        payload = d.decompress(parts[4], MAX_BYTES + 1)
        if len(payload) > MAX_BYTES or d.unconsumed_tail or not d.eof:
            raise ValueError('Compressed archive incomplete or too large')
    else:
        payload = parts[4]
    if len(payload) > MAX_BYTES:
        raise ValueError('Payload too large')
    found = {}
    names = []
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:') as archive:
        for entry in archive:
            names.append(entry.name)
            if not entry.name.startswith(PREFIX):
                raise ValueError('Unexpected package or shared data in archive: ' + entry.name)
            if entry.name in EXPECTED:
                if not entry.isfile() or entry.size > 1024 or entry.name in found:
                    raise ValueError('Unexpected synthetic entry')
                found[entry.name] = archive.extractfile(entry).read()
    if set(found) != EXPECTED:
        raise ValueError('Both synthetic entries are required')
    verify_contents(found[PREFIX + 'f/lab-marker.txt'], found[PREFIX + 'sp/lab_probe.xml'])
    return names


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: check_no_adb_lab_backup.py SYNTHETIC_ARCHIVE')
    names = inspect(sys.argv[1])
    for name in names:
        print('Lab archive entry:', name)
    print('Both synthetic files verified: yes')


if __name__ == '__main__':
    main()

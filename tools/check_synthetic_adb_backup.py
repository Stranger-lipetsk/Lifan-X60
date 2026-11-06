#!/usr/bin/env python3
"""Inspect a disposable emulator's unencrypted synthetic Android backup only."""
import io
import sys
import tarfile
import zlib
from pathlib import Path

MARKER = b'X60_DISPOSABLE_MIGRATION_TEST\n'
MAX_ARCHIVE = 32 * 1024 * 1024


def inspect(path):
    raw = Path(path).read_bytes()
    if len(raw) > MAX_ARCHIVE:
        raise ValueError('Unexpectedly large backup')
    parts = raw.split(b'\n', 4)
    if len(parts) != 5 or parts[0] != b'ANDROID BACKUP' or parts[1] not in (b'1', b'2', b'3', b'4', b'5'):
        raise ValueError('Unexpected backup header')
    if parts[2] not in (b'0', b'1') or parts[3] != b'none':
        raise ValueError('Expected unencrypted lab backup')
    payload = parts[4]
    if parts[2] == b'1':
        decompressor = zlib.decompressobj()
        payload = decompressor.decompress(payload, MAX_ARCHIVE + 1)
        if len(payload) > MAX_ARCHIVE or decompressor.unconsumed_tail or not decompressor.eof:
            raise ValueError('Compressed backup incomplete or too large')
    if len(payload) > MAX_ARCHIVE:
        raise ValueError('Backup payload too large')
    found = []
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:') as tar:
        for entry in tar:
            print('Lab archive entry:', entry.name, 'bytes:', entry.size)
            if entry.name.startswith('apps/com.navitel/') and entry.name.endswith('/lab-marker.txt') and entry.isfile():
                if entry.size > 1024:
                    raise ValueError('Marker unexpectedly large')
                found.append((entry.name, tar.extractfile(entry).read()))
    return found


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: check_synthetic_adb_backup.py TEMPORARY_EMULATOR_ARCHIVE')
    found = inspect(sys.argv[1])
    print('Synthetic marker entries:', len(found))
    for name, data in found:
        print('Path:', name, 'matches:', data == MARKER)
    if len(found) != 1 or found[0][1] != MARKER:
        raise SystemExit('Synthetic marker not found intact in Android backup')


if __name__ == '__main__':
    main()

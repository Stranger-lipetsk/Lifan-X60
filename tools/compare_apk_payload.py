#!/usr/bin/env python3
"""Verify an experimental APK differs from its source only in classes.dex/signatures."""
import hashlib
import sys
import zipfile
from pathlib import PurePosixPath


def entries(path):
    with zipfile.ZipFile(path) as archive:
        names = [n for n in archive.namelist() if not n.endswith('/')]
        if len(names) != len(set(names)):
            raise ValueError('duplicate ZIP entry')
        for name in names:
            if name.startswith('/') or '..' in PurePosixPath(name).parts or '\\' in name:
                raise ValueError('unsafe ZIP entry')
        return {n: hashlib.sha256(archive.read(n)).hexdigest()
                for n in names if not n.upper().startswith('META-INF/')}


def compare(original, candidate, expected='classes.dex'):
    if expected not in ('classes.dex', 'AndroidManifest.xml'):
        raise ValueError('unsupported allowed change')
    left, right = entries(original), entries(candidate)
    if set(left) != set(right):
        raise ValueError(f'payload names differ: {sorted(set(left) ^ set(right))}')
    changed = [n for n in sorted(left) if left[n] != right[n]]
    if changed != [expected]:
        raise ValueError(f'expected only {expected} to change, got {changed}')
    print('Non-signature entries compared:', len(left))
    print('Only changed entry:', expected)
    print('Original changed entry SHA-256:', left[expected])
    print('Candidate changed entry SHA-256:', right[expected])
    unchanged = 'AndroidManifest.xml' if expected == 'classes.dex' else 'classes.dex'
    print('Unchanged', unchanged, 'SHA-256:', left[unchanged])


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        raise SystemExit('usage: compare_apk_payload.py ORIGINAL.apk MODIFIED.apk [classes.dex|AndroidManifest.xml]')
    compare(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else 'classes.dex')

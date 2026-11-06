#!/usr/bin/env python3
"""Inspect a tiny, disposable archive-copy model; never operates on a device.

The CI shell creates both trees and invokes the stock-derived tar binary. This
module does no archiving or deletion and only compares explicitly named files.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys

FILES = (
    'data/com.navitel/files/lab-marker.txt',
    'data/com.navitel/shared_prefs/probe.xml',
    'data/ru.lifanx60.fixture/files/marker.txt',
    'system/packages.xml',
    'app/com.navitel-1.apk',
)


def metadata(path: Path) -> dict:
    st = path.lstat()
    result = {'mode': stat.S_IMODE(st.st_mode), 'uid': st.st_uid, 'gid': st.st_gid}
    if stat.S_ISREG(st.st_mode):
        result['kind'] = 'file'
        result['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISLNK(st.st_mode):
        result['kind'] = 'symlink'
        result['target'] = os.readlink(path)
    elif stat.S_ISDIR(st.st_mode):
        result['kind'] = 'directory'
    else:
        raise ValueError(f'unexpected file type: {path}')
    return result


def compare(source: Path, destination: Path) -> None:
    # The source files below remain unchanged during this comparison. No
    # blanket equivalence claim is made about ACLs, SELinux, sparse data etc.
    for relative in (*FILES, 'data/com.navitel', 'data/com.navitel/files/link-to-marker'):
        left, right = metadata(source / relative), metadata(destination / relative)
        if left != right:
            raise AssertionError(f'{relative}: {left} != {right}')
        print(f'MATCH {relative}: {left}')
    a = destination / FILES[0]
    b = destination / 'data/com.navitel/files/hardlink-to-marker'
    print('Hardlink relationship retained:', a.stat().st_ino == b.stat().st_ino)
    print('Test user xattr on source:', os.listxattr(source / FILES[0]))
    print('Test user xattr on extracted file:', os.listxattr(a))
    print('SELinux labels and ACLs were not tested.')


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit('requires source and destination fixture paths')
    compare(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == '__main__':
    main()

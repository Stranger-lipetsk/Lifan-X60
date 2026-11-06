#!/usr/bin/env python3
"""Compare all ZIP payload bytes except standard JAR V1 signing records."""
import hashlib
import re
import sys
import zipfile
from pathlib import PurePosixPath

# Only top-level JAR signature artifacts can change. META-INF library metadata
# and nested entries are still checked, unlike ignoring the whole directory.
SIGNATURE = re.compile(r'^META-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))$', re.I)


def hashes(path):
    with zipfile.ZipFile(path) as archive:
        names = [entry.filename for entry in archive.infolist() if not entry.is_dir()]
        if len(names) != len(set(names)):
            raise ValueError('duplicate ZIP entry')
        result = {}
        for name in names:
            if name.startswith('/') or '\\' in name or '..' in PurePosixPath(name).parts:
                raise ValueError('unsafe ZIP entry')
            if SIGNATURE.fullmatch(name):
                continue
            result[name] = hashlib.sha256(archive.read(name)).hexdigest()
        return result


def compare(original, resigned):
    left, right = hashes(original), hashes(resigned)
    if set(left) != set(right):
        raise ValueError('payload entries differ: ' + repr(sorted(set(left) ^ set(right))))
    changed = [name for name in sorted(left) if left[name] != right[name]]
    if changed:
        raise ValueError('payload bytes differ: ' + repr(changed))
    if not {'AndroidManifest.xml', 'classes.dex'} <= set(left):
        raise ValueError('required APK files missing')
    return len(left)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: compare_resigned_apk.py SOURCE RESIGNED')
    print('Uncompressed payload entries identical, excluding JAR signing records:', compare(sys.argv[1], sys.argv[2]))
    print('This does not verify ZIP offsets, metadata, V2/V3 signing block or runtime signature checks.')

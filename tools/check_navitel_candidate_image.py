#!/usr/bin/env python3
"""Compare extracted image trees for the laboratory-only Navitel replacement."""
import argparse
from pathlib import Path
from compare_firmware_releases import tree

DEST = 'priv-app/Navitel-large.apk'
ORIGINAL = '6e216ab39aacaafacda1ebb09f6edc8726e4d1eb6b4985256ccd18aeb5046c44'
CANDIDATE = '96876415d8b4342952558fd30d6e11b0ca9355c802060c0a9740b6cc84fc4e1b'


def validate(before: Path, after: Path):
    old, new = tree(before), tree(after)
    changes = [p for p in sorted(set(old) | set(new)) if old.get(p) != new.get(p)]
    if changes != [DEST]:
        raise ValueError(f'unexpected image content differences: {changes}')
    for label, values, digest in [('old', old, ORIGINAL), ('new', new, CANDIDATE)]:
        if DEST not in values or values[DEST][0] != 'file' or values[DEST][2] != digest:
            raise ValueError(f'{label} Navitel SHA/type mismatch')
    print('Old entries:', len(old), 'New entries:', len(new))
    print('Only changed file/symlink:', DEST)
    print('Old bytes/SHA:', old[DEST][1], old[DEST][2])
    print('New bytes/SHA:', new[DEST][1], new[DEST][2])
    print('File contents and symlink targets only; other inode metadata is not compared.')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('before', type=Path)
    p.add_argument('after', type=Path)
    args = p.parse_args()
    validate(args.before, args.after)

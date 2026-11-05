#!/usr/bin/env python3
"""Fail-closed comparison of extracted trees for the disposable integrated image."""
import argparse
from pathlib import Path
from compare_firmware_releases import digest, tree

OLD = {
    'priv-app/EL830LF01_Home.apk': '75ee685d5399e4c394146cac593ec2ed4bfbd5f6cc9151f9ae479992c84011a6',
    'priv-app/Launcher2.apk': '82787a6007589a169242f2c1391252342a9824748a8b469d1d522acab83458e6',
    'priv-app/Navitel-large.apk': '6e216ab39aacaafacda1ebb09f6edc8726e4d1eb6b4985256ccd18aeb5046c44',
}
PANEL = 'app/LifanLauncherPanel.apk'
AMAZE = 'app/AmazeFileManager.apk'
AMAZE_SHA = '2a9bc50c6672b1cb6efdfbd9bd9149bf280274e386305663163cc365abd393f3'
NAVITEL_SHA = '96876415d8b4342952558fd30d6e11b0ca9355c802060c0a9740b6cc84fc4e1b'


def validate(before: Path, after: Path, expected: dict):
    required = set(OLD) | {PANEL}
    if set(expected) != required or expected['priv-app/Navitel-large.apk'] != NAVITEL_SHA:
        raise ValueError('invalid expected replacement set')
    old, new = tree(before), tree(after)
    changes = {p for p in set(old) | set(new) if old.get(p) != new.get(p)}
    if changes != required:
        raise ValueError(f'unexpected image differences: {sorted(changes)}')
    for path, sha in OLD.items():
        if path not in old or old[path][0] != 'file' or old[path][2] != sha:
            raise ValueError(f'baseline file mismatch: {path}')
    if PANEL in old:
        raise ValueError('panel already present in baseline')
    if AMAZE not in old or old[AMAZE][0] != 'file' or old[AMAZE][2] != AMAZE_SHA or new.get(AMAZE) != old[AMAZE]:
        raise ValueError('Amaze baseline changed or missing')
    for path, sha in expected.items():
        if path not in new or new[path][0] != 'file' or new[path][2] != sha:
            raise ValueError(f'new file mismatch: {path}')
    print(f'Entries before: {len(old)}; after: {len(new)}')
    for path in sorted(required):
        print(f'{path}: {old.get(path, "not present")} -> {new[path]}')
    print('Amaze and every other extracted file/symlink unchanged. Inode metadata not compared by tree walk.')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('before', type=Path)
    p.add_argument('after', type=Path)
    p.add_argument('--home', type=Path, required=True)
    p.add_argument('--launcher', type=Path, required=True)
    p.add_argument('--panel', type=Path, required=True)
    p.add_argument('--navitel', type=Path, required=True)
    a = p.parse_args()
    validate(a.before, a.after, {
        'priv-app/EL830LF01_Home.apk': digest(a.home),
        'priv-app/Launcher2.apk': digest(a.launcher),
        'priv-app/Navitel-large.apk': digest(a.navitel),
        PANEL: digest(a.panel),
    })

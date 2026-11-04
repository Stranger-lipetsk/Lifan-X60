#!/usr/bin/env python3
"""Compare read-only extracted file trees of known stock and launcher system images."""
import os
import sys
from pathlib import Path
from compare_firmware_releases import tree


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: compare_launcher_system.py STOCK_TREE LAUNCHER_TREE')
    base, test = (Path(x) for x in sys.argv[1:])
    old, new = tree(base), tree(test)
    changes = [(path, old.get(path), new.get(path)) for path in sorted(set(old) | set(new))
               if old.get(path) != new.get(path)]
    print('# Stock vs published launcher system: regular files and symlinks')
    print('Content, sizes and symlink targets only; inode metadata and runtime are not compared.')
    print('Boot image and data partition are not included in the published image.')
    print('File/symlink counts:', len(old), len(new))
    print('Differences:', len(changes))
    for path, before, after in changes:
        print(f'{path}: {before} -> {after}')
    print('\n## Paths related to Wi-Fi / networking, content only')
    terms = ('wifi', 'wlan', 'wpa', 'hostapd', 'dhcpcd', 'wl12', 'wl18', 'ti-connectivity')
    relevant = [p for p in sorted(set(old) | set(new)) if any(x in p.lower() for x in terms)]
    changed = [p for p in relevant if old.get(p) != new.get(p)]
    print('Matching paths examined:', len(relevant))
    print('Changed paths:', len(changed))
    for path in changed:
        print(f'{path}: {old.get(path)} -> {new.get(path)}')
    print('Matching path names do not cover every Wi-Fi dependency; only content is checked.')


if __name__ == '__main__':
    main()

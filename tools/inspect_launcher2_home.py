#!/usr/bin/env python3
"""Inventory HOME intent assumptions in stock-derived Launcher2 smali, read only."""
import re
import sys
from pathlib import Path

MATCH = re.compile(r'android\.intent\.category\.HOME|ACTION_MAIN|CATEGORY_HOME|android\.intent\.action\.MAIN|'
                   r'android\.intent\.action\.BOOT_COMPLETED|startActivity|onNewIntent|onCreate\(|onResume\(')


def main(root):
    root = Path(root)
    files = sorted(root.glob('smali*/**/*.smali'))
    if not files:
        raise ValueError('no decoded smali')
    print('# Launcher2 HOME intent references: static, not runtime')
    print('Literal hits do not prove a particular intent or execution path.')
    counts = 0
    for path in files:
        lines = path.read_text(encoding='utf8', errors='replace').splitlines()
        for idx, line in enumerate(lines):
            if not MATCH.search(line):
                continue
            # Limit generic lifecycle / startActivity contexts to the main Launcher class.
            exact = 'android.intent.category.HOME' in line or 'CATEGORY_HOME' in line or 'BOOT_COMPLETED' in line
            if not exact and path.name != 'Launcher.smali':
                continue
            counts += 1
            print('\n##', path.relative_to(root), 'line', idx + 1)
            print('\n'.join(lines[max(0, idx-12):idx+18]))
    print('\nMatching contexts:', counts)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_launcher2_home.py DECODED_DIRECTORY')
    main(sys.argv[1])

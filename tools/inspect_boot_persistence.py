#!/usr/bin/env python3
"""Inspect data mounts and quickboot configuration in stock boot ramdisk, read only."""
import re
import sys
import tempfile
from pathlib import Path
from compare_firmware_releases import unpack_ramdisk

PATTERN = re.compile(r'(?i)(?:/data|userdata|quick.?boot|hibernat|fs_sync|\bmount\b|\bfsck\b|snapshot|checkpoint)')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_boot_persistence.py BOOT_IMAGE')
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'ramdisk'
        result = unpack_ramdisk(Path(sys.argv[1]), root)
        if not result.startswith('kernel='):
            raise SystemExit(result)
        print('# Boot ramdisk data and hibernation configuration: static, not device state')
        print(result)
        selected = [p for p in root.rglob('*') if p.is_file() and not p.is_symlink()
                    and (p.name.endswith('.rc') or 'fstab' in p.name.lower())]
        if not selected:
            raise SystemExit('No init files found')
        total = 0
        for path in sorted(selected):
            lines = path.read_text(errors='replace').splitlines()
            indices = [i for i, line in enumerate(lines) if PATTERN.search(line)]
            if not indices:
                continue
            print('\n##', path.relative_to(root))
            ranges = []
            for i in indices:
                lo, hi = max(0, i - 3), min(len(lines), i + 4)
                if ranges and lo <= ranges[-1][1]:
                    ranges[-1] = (ranges[-1][0], max(hi, ranges[-1][1]))
                else:
                    ranges.append((lo, hi))
            for lo, hi in ranges:
                print(f'-- {lo+1}..{hi} --')
                print('\n'.join(f'{i+1}: {lines[i]}' for i in range(lo, hi)))
            total += len(indices)
        print(f'\nMatched lines: {total}')
        print('Configuration does not prove what ran or why installed apps disappeared.')
        if not total:
            raise SystemExit('No persistence-related lines found')


if __name__ == '__main__':
    main()

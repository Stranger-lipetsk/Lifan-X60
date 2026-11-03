#!/usr/bin/env python3
"""Accept only the known inode-bitmap padding warning in stock 2021.

Run e2fsck read-only first; this is not a filesystem repair utility.
Any new warning, unexpected output, or exit status is rejected.
"""
import re
import sys
from pathlib import Path


def validate(text: str, status: int) -> None:
    if status not in (0, 4):
        raise ValueError(f'expected clean status or known stock warning, got {status}')
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    patterns = (
        r'e2fsck [0-9.]+ \([^\n]+\)',
        r'Pass [1-5]: .+',
        r'Padding at end of inode bitmap is not set\. Fix\? no',
        r'.+: \*+ WARNING: Filesystem still has errors \*+',
        r'.+: [0-9]+/[0-9]+ files \([0-9.]+% non-contiguous\), [0-9]+/[0-9]+ blocks',
    )
    for line in lines:
        if not any(re.fullmatch(pattern, line) for pattern in patterns):
            raise ValueError(f'unexpected e2fsck output: {line}')
    for i in range(1, 6):
        if sum(line.startswith(f'Pass {i}: ') for line in lines) != 1:
            raise ValueError(f'missing or duplicate pass {i}')
    warning = 'Padding at end of inode bitmap is not set. Fix? no'
    expected_warnings = 1 if status == 4 else 0
    if lines.count(warning) != expected_warnings:
        raise ValueError('unexpected padding warning count')
    if sum('WARNING: Filesystem still has errors' in line for line in lines) != expected_warnings:
        raise ValueError('unexpected filesystem warning count')
    if sum(re.fullmatch(patterns[-1], line) is not None for line in lines) != 1:
        raise ValueError('missing or duplicate filesystem summary')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: check_stock_fsck.py LOG STATUS')
    try:
        validate(Path(sys.argv[1]).read_text(), int(sys.argv[2]))
    except (ValueError, OSError) as exc:
        raise SystemExit(str(exc))
    print('Check passed: clean, or only the previously observed stock inode-bitmap padding warning.')


if __name__ == '__main__':
    main()

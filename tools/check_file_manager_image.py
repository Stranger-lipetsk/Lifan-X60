#!/usr/bin/env python3
"""Validate extracted trees of a copied system image; does not check all ext4 metadata."""
import argparse
from pathlib import Path
from compare_firmware_releases import tree

DEST = 'app/AmazeFileManager.apk'


def validate(base: Path, result: Path, expected_sha: str):
    before, after = tree(base), tree(result)
    if DEST in before:
        raise ValueError('candidate APK already exists in base image')
    changes = [name for name in sorted(set(before) | set(after)) if before.get(name) != after.get(name)]
    if changes != [DEST]:
        raise ValueError(f'unexpected added/removed/changed files or symlinks: {changes}')
    value = after[DEST]
    if value[0] != 'file' or value[2] != expected_sha:
        raise ValueError(f'candidate hash or type mismatch: {value}')
    print(f'Base entries: {len(before)}; result entries: {len(after)}')
    print(f'Only changed regular file/symlink: {DEST}, {value[1]} bytes, SHA-256 {value[2]}')
    print('File contents and symlink targets checked; other inode/ext4 metadata not compared.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('base', type=Path)
    parser.add_argument('result', type=Path)
    parser.add_argument('sha256')
    args = parser.parse_args()
    if len(args.sha256) != 64 or any(c not in '0123456789abcdef' for c in args.sha256):
        parser.error('sha256 must be 64 lowercase hexadecimal characters')
    validate(args.base, args.result, args.sha256)


if __name__ == '__main__':
    main()

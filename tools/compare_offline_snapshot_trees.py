#!/usr/bin/env python3
"""Compare synthetic source and extracted filesystem, never a real device.

Reports aggregate content/metadata/xattr counts without exposing file paths or
attribute values. Omits special files from the compared path set.
"""
import collections
import hashlib
import os
import stat
import sys
from pathlib import Path


def inventory(root):
    result = {}
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            st = os.lstat(path)
            if stat.S_ISDIR(st.st_mode): kind = 'dirs'
            elif stat.S_ISLNK(st.st_mode): kind = 'symlinks'
            elif stat.S_ISREG(st.st_mode): kind = 'files'
            else: continue
            result[path.relative_to(root).as_posix()] = (path, st, kind)
    return result


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.digest()


def attrs(path):
    return {name: os.getxattr(path, name, follow_symlinks=False)
            for name in os.listxattr(path, follow_symlinks=False)}


def compare(source, dest):
    src, dst = inventory(Path(source)), inventory(Path(dest))
    counts = collections.Counter()
    names = collections.Counter()
    counts['missing'] = len(set(src) - set(dst))
    counts['extra'] = len(set(dst) - set(src))
    for key in sorted(src.keys() & dst.keys()):
        a, ast, kind = src[key]
        b, bst, bkind = dst[key]
        counts['compared_' + kind] += 1
        if kind != bkind:
            counts['type_mismatch'] += 1
            continue
        if kind == 'files' and (ast.st_size != bst.st_size or digest(a) != digest(b)):
            counts['content_mismatch'] += 1
        if kind == 'symlinks' and os.readlink(a) != os.readlink(b):
            counts['content_mismatch'] += 1
        if (ast.st_uid, ast.st_gid, stat.S_IMODE(ast.st_mode)) != (bst.st_uid, bst.st_gid, stat.S_IMODE(bst.st_mode)):
            counts['metadata_mismatch_' + kind] += 1
        try:
            ax, bx = attrs(a), attrs(b)
        except OSError:
            counts['xattr_read_errors'] += 1
            continue
        if ax:
            counts['source_entries_with_xattrs'] += 1
            for attr in ax: names[attr] += 1
        if bx: counts['destination_entries_with_xattrs'] += 1
        if ax != bx: counts['xattr_mismatch'] += 1
    return counts, names


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: compare_offline_snapshot_trees.py source destination')
    counts, names = compare(*sys.argv[1:])
    for key in ('compared_files', 'compared_dirs', 'compared_symlinks', 'missing', 'extra', 'type_mismatch',
                'content_mismatch', 'metadata_mismatch_files', 'metadata_mismatch_dirs', 'metadata_mismatch_symlinks',
                'source_entries_with_xattrs', 'destination_entries_with_xattrs', 'xattr_mismatch', 'xattr_read_errors'):
        print(f'{key}: {counts[key]}')
    print('Source xattr names (aggregate counts):', dict(sorted(names.items())))
    print('Special files excluded. This does not prove consistency against live writes or real-device SELinux behavior.')
    if any(counts[k] for k in ('missing', 'extra', 'type_mismatch', 'content_mismatch', 'metadata_mismatch_files', 'metadata_mismatch_dirs')):
        raise SystemExit('Regular files/directories did not match after extraction')


if __name__ == '__main__': main()

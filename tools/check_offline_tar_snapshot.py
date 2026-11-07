#!/usr/bin/env python3
"""Compare a synthetic offline tar with its immutable source without extracting it.

CI fixture checker only: checks pathname sets, regular-file bytes, symlink
contents, numeric uid/gid and mode for regular files, directories and symlinks.
It does not assert preservation of xattrs, ACLs, SELinux, timestamps or live
writers. Never invoke on a device or user files.
"""
import hashlib
import os
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


def archive_name(name):
    while name.startswith('./'):
        name = name[2:]
    name = name.rstrip('/')
    if not name or name == '.':
        return ''
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '.' in p.parts:
        raise ValueError('unsafe archive path: ' + name)
    return str(p)


def digest(stream):
    sha = hashlib.sha256()
    while True:
        buf = stream.read(1024 * 1024)
        if not buf:
            return sha.hexdigest()
        sha.update(buf)


def verify(source, archive):
    root = Path(source)
    entries = {}
    other = set()
    xattrs = 0
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            key = path.relative_to(root).as_posix()
            st = os.lstat(path)
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                other.add(key)
                continue
            entries[key] = (path, st)
            try:
                if os.listxattr(path, follow_symlinks=False):
                    xattrs += 1
            except OSError as exc:
                raise ValueError('Cannot inspect source xattrs: ' + key) from exc
    seen = set()
    counts = {'files': 0, 'dirs': 0, 'symlinks': 0}
    with tarfile.open(archive, 'r:') as ar:
        for member in ar:
            name = archive_name(member.name)
            if not name:
                continue
            if name in other:
                continue  # Explicitly excluded from content and metadata claims.
            if name not in entries or name in seen:
                raise ValueError('unexpected or duplicate archive path: ' + name)
            seen.add(name)
            path, st = entries[name]
            if (member.uid, member.gid, member.mode & 0o7777) != (st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)):
                raise ValueError('metadata mismatch: ' + name)
            if stat.S_ISDIR(st.st_mode):
                if not member.isdir(): raise ValueError('directory type mismatch: ' + name)
                counts['dirs'] += 1
            elif stat.S_ISLNK(st.st_mode):
                if not member.issym() or member.linkname != os.readlink(path):
                    raise ValueError('symlink mismatch: ' + name)
                counts['symlinks'] += 1
            else:
                if not (member.isfile() or member.islnk()): raise ValueError('file type mismatch: ' + name)
                if member.islnk():
                    linkname = archive_name(member.linkname)
                    if linkname not in entries or os.lstat(entries[linkname][0]).st_ino != st.st_ino:
                        raise ValueError('hardlink target mismatch: ' + name)
                elif member.size != st.st_size:
                    raise ValueError('file size mismatch: ' + name)
                with open(path, 'rb') as src, ar.extractfile(member) as payload:
                    if digest(src) != digest(payload): raise ValueError('file content mismatch: ' + name)
                counts['files'] += 1
    missing = set(entries) - seen
    if missing:
        raise ValueError('archive omitted source paths: ' + repr(sorted(missing)[:8]))
    return counts, len(other), xattrs


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: check_offline_tar_snapshot.py source archive')
    counts, other, xattrs = verify(*sys.argv[1:])
    print('Verified all regular files, directories and symlinks:', counts)
    print('Source special files excluded from this verification:', other)
    print('Source entries with at least one xattr:', xattrs)
    print('No claim that tar preserves xattrs, ACL, SELinux, timestamps, special files or concurrently modified data.')


if __name__ == '__main__':
    main()

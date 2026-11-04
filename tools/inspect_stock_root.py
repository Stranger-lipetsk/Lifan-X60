#!/usr/bin/env python3
"""Read-only checks for superuser executables and boot defaults in stock images."""
import gzip
import struct
import subprocess
import sys
from pathlib import Path


def main():
    system, boot, scratch = map(Path, sys.argv[1:4])
    print('# Static stock root/ADB indicators, not proof of runtime access')
    for path in ('/xbin/su', '/bin/su', '/bin/bin/su', '/app/Superuser.apk', '/app/SuperSU.apk'):
        result = subprocess.run(['debugfs', '-R', 'stat ' + path, str(system)],
                                capture_output=True, text=True)
        print('\n## /system' + path, 'debugfs exit:', result.returncode)
        lines = (result.stdout + result.stderr).splitlines()
        for line in lines:
            if any(t in line for t in ('Inode:', 'User:', 'Links:', 'security.selinux', 'Fast link dest:',
                                       'File not found', 'not found by ext2_lookup')):
                print(line.strip())
    data = boot.read_bytes()
    if data[:8] != b'ANDROID!':
        raise SystemExit('Unexpected boot header')
    kernel, _, ramdisk, _, _, _, _, page = struct.unpack('<8I', data[8:40])
    start = page + ((kernel + page - 1) // page) * page
    raw = gzip.decompress(data[start:start + ramdisk])
    scratch.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(['cpio', '-id', '--no-absolute-filenames', 'default.prop'],
                          input=raw, cwd=scratch, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print('\n## boot.img default.prop extraction exit:', proc.returncode)
    if proc.returncode:
        raise SystemExit('Unable to extract default.prop')
    prop = scratch / 'default.prop'
    if not prop.is_file():
        raise SystemExit('No default.prop in boot.img')
    for line in prop.read_text(errors='replace').splitlines():
        if line.startswith(('ro.secure=', 'ro.debuggable=', 'persist.sys.usb.config=', 'ro.adb.secure=')):
            print(line)
    print('\nThese properties and files do not demonstrate that a command can run as root on the device.')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Inspect boot-time service definition and recovery script in stock, read-only."""
import gzip
import struct
import subprocess
import sys
from pathlib import Path


def main():
    system, boot, scratch = map(Path, sys.argv[1:4])
    print('# Stock boot service entry point; static inspection only')
    print('Expected image sha256 and archive must be checked by caller.')
    for path in ('/etc/install-recovery.sh', '/bin/install-recovery.sh', '/bin/pm', '/bin/sh'):
        proc = subprocess.run(['debugfs', '-R', 'stat ' + path, str(system)], capture_output=True, text=True)
        print('\n## /system' + path)
        text = proc.stdout + proc.stderr
        print('\n'.join(line for line in text.splitlines() if any(x in line for x in
            ('Inode:', 'User:', 'Links:', 'File not found', 'not found by ext2_lookup', 'Fast link dest:', 'security.selinux'))))
    data = boot.read_bytes()
    if data[:8] != b'ANDROID!':
        raise SystemExit('Unsupported boot image')
    ks, _, rs, _, _, _, _, page = struct.unpack('<8I', data[8:40])
    start = page + ((ks + page - 1) // page) * page
    ramdisk = gzip.decompress(data[start:start+rs])
    scratch.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(['cpio', '-id', '--no-absolute-filenames', 'init.rc', 'init.el_imx6_solo_v2.rc'],
                          input=ramdisk, cwd=scratch, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode:
        raise SystemExit('Failed to extract init files')
    for init in sorted(scratch.glob('init*.rc')):
        print('\n##', init.name)
        lines = init.read_text(errors='replace').splitlines()
        for i, line in enumerate(lines):
            if 'service flash_recovery' in line:
                print('\n'.join(lines[i:min(i+12, len(lines))]))
            if 'class_start main' in line or 'sys.boot_completed' in line:
                print(f'line {i+1}: {line}')
    print('\nNo assumption of actual execution, permissions or successful boot can be made from this report.')


if __name__ == '__main__':
    main()

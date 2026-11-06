#!/usr/bin/env python3
"""Offline inspection of su from a trusted extracted system image; never run it."""
import hashlib
import re
import subprocess
import sys
from pathlib import Path

HINTS = re.compile(r'(?i)(root|shell|uid|denied|permission|superuser|supersu|usage|policy|socket|daemon|selinux|setenforce|exec|caller|allow)')


def selected_strings(data):
    return [s.decode('ascii') for s in re.findall(rb'[\x20-\x7e]{4,}', data)
            if HINTS.search(s.decode('ascii'))]


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_su_static.py EXTRACTED_SU')
    file = Path(sys.argv[1])
    data = file.read_bytes()
    print('# Offline su inspection; no su or firmware code executed')
    print('Size:', len(data), 'SHA-256:', hashlib.sha256(data).hexdigest())
    print('ELF:', data.startswith(b'\x7fELF'))
    print('\n## Selected readable strings (not runtime evidence)')
    for line in selected_strings(data)[:250]:
        print(line)
    if data.startswith(b'\x7fELF'):
        for args in (['readelf', '-h'], ['readelf', '-sW'],
                     ['arm-linux-gnueabihf-objdump', '-d'],
                     ['arm-linux-gnueabihf-objdump', '-d', '-M', 'force-thumb']):
            out = subprocess.run(args + [str(file)], capture_output=True, text=True, check=False)
            print('\n##', ' '.join(args), '(exit', out.returncode, ')')
            lines = out.stdout.splitlines()
            if args[0] == 'readelf' and '-sW' in args:
                lines = [line for line in lines if HINTS.search(line)]
            print('\n'.join(lines[:450]))
            if len(lines) > 450:
                print('... output truncated')
            if out.returncode:
                print(out.stderr.strip())
    if hashlib.sha256(data).hexdigest() == '13ac24ca792e36c9d0c32ec79bfaa03490492e71e9dfa11d712390e613dc7fb4':
        for args in (
            ['arm-linux-gnueabihf-objdump', '-d', '-M', 'force-thumb', '--start-address=0x82ac', '--stop-address=0x8400'],
            ['arm-linux-gnueabihf-objdump', '-d', '--start-address=0x8844', '--stop-address=0x8870'],
        ):
            out = subprocess.run(args + [str(file)], capture_output=True, text=True, check=False)
            print('\n## Targeted disassembly of known binary:', ' '.join(args))
            print(out.stdout)
    print('\nStatic evidence does not establish execution rights, SELinux behavior, data access, or a safe backup.')


if __name__ == '__main__':
    main()

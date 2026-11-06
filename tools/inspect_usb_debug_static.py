#!/usr/bin/env python3
"""Inspect a release image offline; never run extracted code or contact a device."""
import hashlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

INTERESTING = re.compile(
    r'adb|usb|debug|tcp|socket|port|ifconfig|dhcp|wlan|ether|ipaddr|'
    r'property|setprop|service|mount|format|mkfs|mke2fs|mmcblk|reboot', re.I)


def relevant_strings(data):
    """Printable ASCII hints are clues, not proof of execution or behavior."""
    strings = re.findall(rb'[\x20-\x7e]{4,}', data)
    return [s.decode('ascii') for s in strings if INTERESTING.search(s.decode('ascii'))]


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_usb_debug_static.py SYSTEM_IMAGE')
    image = Path(sys.argv[1])
    print('# Offline inspection of USB debug helper in a release system image')
    print('No helper executed; no device or network interfaces were accessed.')
    for path in ('/bin/el_debug_tool', '/bin/check_usb_iface.sh'):
        print('\n## /system' + path)
        stat = subprocess.run(['debugfs', '-R', 'stat ' + path, str(image)],
                              capture_output=True, text=True, check=False)
        print('debugfs stat:', stat.returncode)
        print((stat.stdout + stat.stderr).strip())
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'extracted'
            dump = subprocess.run(['debugfs', '-R', 'dump ' + path + ' ' + str(target), str(image)],
                                  capture_output=True, text=True, check=False)
            if not target.is_file():
                print('File unavailable; no conclusions about runtime behavior.')
                print((dump.stdout + dump.stderr).strip())
                continue
            data = target.read_bytes()
            print('Size:', len(data), 'SHA-256:', hashlib.sha256(data).hexdigest())
            print('ELF:', data.startswith(b'\x7fELF'))
            print('Selected printable strings (not execution evidence):')
            for line in relevant_strings(data)[:200]:
                print(line)
    print('\nNo conclusion about physical USB connector wiring, runtime properties,')
    print('availability of root, network transport, or access to user data is implied.')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Inspect a release image offline; never run extracted code or contact a device."""
import hashlib
import re
import struct
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


def nearby_strings(data, needle, radius=3):
    strings = [s.decode('ascii') for s in re.findall(rb'[\x20-\x7e]{3,}', data)]
    nearby = set()
    for index, text in enumerate(strings):
        if needle in text:
            nearby.update(range(max(0, index - radius), min(len(strings), index + radius + 1)))
    return [strings[index] for index in sorted(nearby)]


def elf32_bytes_at(data, address, length):
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    phoff = struct.unpack_from('<I', data, 28)[0]
    entsize, count = struct.unpack_from('<HH', data, 42)
    for index in range(count):
        ptype, offset, vaddr, _, filesz, _, _, _ = struct.unpack_from('<8I', data, phoff + index * entsize)
        if ptype == 1 and vaddr <= address and address + length <= vaddr + filesz:
            start = offset + address - vaddr
            return data[start:start + length]
    raise ValueError('Address not in a file-backed ELF load segment')


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
            if data.startswith(b'\x7fELF'):
                for needle in ('service.adb.tcp.port', '/system/bin/ifconfig'):
                    print('\nStrings near:', needle)
                    for line in nearby_strings(data, needle):
                        print(line)
                print('\nSelected ELF symbols:')
                symbols = subprocess.run(['readelf', '-sW', str(target)], capture_output=True, text=True, check=False)
                print('\n'.join(line for line in symbols.stdout.splitlines()
                                if re.search(r'\b(main|__system_property_set|system|execve)\b', line)))
                header = subprocess.run(['readelf', '-h', str(target)], capture_output=True, text=True, check=False)
                print('\nELF header:', header.stdout.strip())
                print('\nBeginning of static disassembly (not execution):')
                obj = subprocess.run(['arm-linux-gnueabihf-objdump', '-d', str(target)],
                                     capture_output=True, text=True, check=False)
                print('\n'.join(obj.stdout.splitlines()[:120]))
                if obj.returncode:
                    print('objdump error:', obj.stderr.strip())
                print('\nCandidate Thumb code immediately following startup (heuristic):')
                thumb = subprocess.run(['arm-linux-gnueabihf-objdump', '-d', '-M', 'force-thumb',
                                        '--start-address=0x3dbc', '--stop-address=0x4180', str(target)],
                                       capture_output=True, text=True, check=False)
                print(thumb.stdout)
                if thumb.returncode:
                    print('thumb disassembly error:', thumb.stderr.strip())
                if hashlib.sha256(data).hexdigest() == '43153248a5bdaa566dd0d425c7a13509100a900b3aeaaeec72939182aa7285b8':
                    print('\nCandidate argv tables from PC-relative Thumb addresses:')
                    for address in (0x17044, 0x1700c, 0x1702c, 0x17038):
                        print('Table at', hex(address))
                        for index in range(8):
                            ptr = struct.unpack('<I', elf32_bytes_at(data, address + index * 4, 4))[0]
                            if not ptr:
                                print('  NULL'); break
                            try:
                                raw = elf32_bytes_at(data, ptr, 128).split(b'\x00', 1)[0]
                                print(' ', hex(ptr), repr(raw.decode('ascii')))
                            except (ValueError, UnicodeDecodeError):
                                print(' ', hex(ptr), '(not resolved)'); break
    print('\nNo conclusion about physical USB connector wiring, runtime properties,')
    print('availability of root, network transport, or access to user data is implied.')


if __name__ == '__main__':
    main()

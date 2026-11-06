#!/usr/bin/env python3
"""Inspect a legacy Android boot image header offline; do not execute the image."""
import hashlib
import sys
from pathlib import Path


def inspect(data):
    if len(data) < 608 or data[:8] != b'ANDROID!':
        raise ValueError('not a sufficiently long legacy Android boot image')
    # boot_img_hdr v0: 8 magic, ten 32-bit fields, 16-byte name, 512-byte cmdline
    cmdline = data[64:576].split(b'\0', 1)[0].decode('ascii', errors='strict')
    return cmdline


def main():
    image = Path(sys.argv[1]).read_bytes()
    line = inspect(image)
    print('# Static boot image kernel command line')
    print('SHA-256:', hashlib.sha256(image).hexdigest())
    print('Header cmdline:', line)
    print('androidboot.selinux tokens:', ', '.join(x for x in line.split() if x.startswith('androidboot.selinux=')) or '(none)')
    print('Image header only: bootloader, live kernel parameters, policy and real-device enforcement are not tested.')


if __name__ == '__main__':
    main()

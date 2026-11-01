#!/usr/bin/env python3
"""Определяет, какой Wi-Fi-драйвер вкомпилирован в ядро (zImage)."""
import re
import sys
import zlib

KEYS = ['bcmdhd', 'wl12xx', 'wlcore', 'wl1271', 'wl18xx', 'brcmfmac',
        'dhd_bus', 'dhd_module', 'wl12xx_sdio']


def find_kernel_blob(path):
    data = open(path, 'rb').read()
    for m in re.finditer(rb'\x1f\x8b\x08', data):
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            out = d.decompress(data[m.start():m.start() + 8_000_000], 40_000_000)
            if len(out) > 1_000_000:
                return out
        except Exception:
            continue
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'reports/deep2/kernel/zImage'
    blob = find_kernel_blob(path)
    if blob is None:
        print('ядро распаковать не удалось')
        return

    print(f'распаковано: {len(blob)} байт')
    text = blob.decode('latin-1').lower()
    print()
    print('=== вхождения драйверов Wi-Fi ===')
    for k in KEYS:
        n = text.count(k)
        mark = '  <-- ЕСТЬ' if n else ''
        print(f'  {k:14s} {n}{mark}')

    print()
    print('=== контекст вокруг wl12xx (если есть) ===')
    for m in list(re.finditer('wl12xx', text))[:5]:
        s = max(0, m.start() - 90)
        frag = blob[s:m.start() + 90]
        clean = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in frag)
        print('  ...', ' '.join(clean.split()))


if __name__ == '__main__':
    main()

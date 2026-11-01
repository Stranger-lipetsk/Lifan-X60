#!/usr/bin/env python3
"""
Определяет, какой Wi-Fi-драйвер вкомпилирован в ядро.

Принимает либо zImage, либо boot.img (тогда ядро вытаскивается из загрузочного
образа по заголовку Android boot image v0).

Использование: python3 tools/probe_kernel_wifi.py <boot.img|zImage>
"""
import re
import struct
import sys
import zlib

KEYS = ['bcmdhd', 'wl12xx', 'wlcore', 'wl1271', 'wl18xx', 'brcmfmac',
        'dhd_bus', 'dhd_module', 'wl12xx_sdio']
MAGIC = b'ANDROID!'


def kernel_from_bootimg(data):
    """Возвращает (kernel_bytes, cmdline) из Android boot image v0."""
    if len(data) < 64 or data[:8] != MAGIC:
        return None, None
    # заголовок v0: 8 байт магии + 10*4 (поля) + 16 (name) + 512 (cmdline) + 32 (id) + 1024 (extra)
    fields = struct.unpack('<10I16s512s', data[8:8 + 40 + 16 + 512])
    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, page_size, _unused, os_version,
     name, cmdline) = fields
    if page_size < 512 or page_size > 65536:
        return None, None
    start = page_size
    kernel = data[start:start + kernel_size]
    return kernel, cmdline.split(b'\x00')[0].decode('latin-1', 'replace')


def gunzip_any(blob):
    """Ищет gzip-поток и распаковывает."""
    for m in re.finditer(rb'\x1f\x8b\x08', blob):
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            out = d.decompress(blob[m.start():m.start() + 8_000_000], 40_000_000)
            if len(out) > 500_000:
                return out
        except Exception:
            continue
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'boot.img'
    data = open(path, 'rb').read()
    print(f'файл: {path} ({len(data)} байт)')

    kernel = None
    if data[:8] == MAGIC:
        kernel, cmdline = kernel_from_bootimg(data)
        print(f'это boot.img, ядро: {len(kernel or b"")} байт')
        if cmdline:
            print(f'cmdline: {cmdline[:120]}')
    else:
        kernel = data

    blob = gunzip_any(kernel or b'')
    if blob is None:
        print('ядро распаковать не удалось (не gzip)')
        blob = kernel or b''
    else:
        print(f'ядро распаковано: {len(blob)} байт')

    text = blob.decode('latin-1').lower()
    print()
    print('=== вхождения драйверов Wi-Fi ===')
    for k in KEYS:
        n = text.count(k)
        print(f'  {k:14s} {n}{"   <-- ЕСТЬ" if n else ""}')

    print()
    print('=== контекст вокруг wl12xx ===')
    seen = 0
    for m in re.finditer('wl12xx', text):
        s = max(0, m.start() - 100)
        frag = blob[s:m.start() + 100]
        clean = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in frag)
        print('  ...', ' '.join(clean.split()))
        seen += 1
        if seen >= 6:
            break
    if not seen:
        print('  нет вхождений')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Compare ARM native imports with stock libraries; static evidence only."""
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

LIBS = ('libandroid.so', 'liblog.so', 'libdl.so', 'libm.so', 'libc.so')


def symbols(path):
    result = subprocess.run(['readelf', '--dyn-syms', '--wide', str(path)],
                            check=True, capture_output=True, text=True)
    records = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 8 or not parts[0].endswith(':'):
            continue
        if parts[4] not in ('GLOBAL', 'WEAK'):
            continue
        # Version suffixes are not part of the C name; symbol version matching
        # and the process-wide runtime scope are not proven by this comparison.
        records.append((parts[7].split('@')[0], parts[4], parts[6]))
    return records


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: inspect_navitel_native.py APK STOCK_LIB_DIR')
    apk, stock = map(Path, sys.argv[1:])
    with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(apk) as z:
        lib = Path(tmp) / 'libnative-lib.so'
        name = 'lib/armeabi-v7a/libnative-lib.so'
        lib.write_bytes(z.read(name))
        print('# Native ARM import scan, static only')
        print('APK library:', name, 'bytes:', lib.stat().st_size)
        dynamic = subprocess.run(['readelf', '-dW', str(lib)], check=True,
                                 capture_output=True, text=True).stdout
        needed = re.findall(r'Shared library: \[(.*?)\]', dynamic)
        print('DT_NEEDED:', ', '.join(needed))
        if set(needed) != set(LIBS):
            raise SystemExit('Unexpected dependency list; comparison must be updated')
        exported = set()
        for name in LIBS:
            path = stock / name
            if not path.is_file() or path.stat().st_size == 0:
                raise SystemExit('Missing stock library: ' + str(path))
            defined = {n for n, b, i in symbols(path) if i not in ('UND', 'ABS')}
            exported.update(defined)
            print(f'{name}: {len(defined)} defined global/weak dynamic symbols')
        imports = symbols(lib)
        strong = {n for n, b, i in imports if i == 'UND' and b == 'GLOBAL' and n}
        weak = {n for n, b, i in imports if i == 'UND' and b == 'WEAK' and n}
        missing = sorted(strong - exported)
        print(f'Strong imports: {len(strong)}, weak imports: {len(weak)}')
        print(f'Strong imports not found by name in direct dependencies: {len(missing)}')
        for name in missing:
            print('  MISSING', name)
        print('This is not a runtime link test: versions, process-global symbols,')
        print('other load-time dependencies, optional code and actual device state may differ.')


if __name__ == '__main__':
    main()

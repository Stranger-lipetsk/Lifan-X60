#!/usr/bin/env python3
"""Static inspection of adbd in a verified boot image, never executes it."""
import gzip
import hashlib
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    data = Path(sys.argv[1]).read_bytes()
    if hashlib.sha256(data).hexdigest() != '060d291a523bbe0d40c86537f070ed0feb90e04e0db0efef2a3e4594e9223b4b':
        raise SystemExit('Unexpected boot image')
    if data[:8] != b'ANDROID!': raise SystemExit('Unsupported boot header')
    ks, _, rs, _, _, _, _, page = struct.unpack('<8I', data[8:40])
    start = page + ((ks + page - 1) // page) * page
    raw = gzip.decompress(data[start:start + rs])
    with tempfile.TemporaryDirectory() as tmp:
        proc = subprocess.run(['cpio', '-id', '--no-absolute-filenames', 'sbin/adbd', 'init', 'default.prop', 'init.rc'],
                              input=raw, cwd=tmp, capture_output=True, check=True)
        root = Path(tmp)
        print('# Stock-derived boot adbd and init, static only')
        print('No binary was executed; a configured image does not prove actual device state.')
        print('Boot image SHA-256:', hashlib.sha256(data).hexdigest())
        for name in ('sbin/adbd', 'init'):
            path = root / name
            blob = path.read_bytes()
            print('\n##', name, 'bytes', len(blob), 'SHA-256:', hashlib.sha256(blob).hexdigest())
            for opts in (['readelf', '-h'], ['readelf', '-lW'], ['readelf', '-sW']):
                result = subprocess.run(opts + [str(path)], text=True, capture_output=True)
                lines = result.stdout.splitlines()
                if '-sW' in opts:
                    lines = [x for x in lines if re.search(r'property|privilege|secure|auth|listen|control', x, re.I)]
                print(' '.join(opts), 'exit', result.returncode)
                print('\n'.join(lines[:100]))
            strings = re.findall(rb'[\x20-\x7e]{4,}', blob)
            selected = sorted({s.decode('ascii') for s in strings if re.search(rb'(?:adb\.tcp|adb\.root|ro\.secure|ro\.debuggable|ro\.kernel\.qemu|ro\.adb\.secure|qemud|property|privilege|auth_required|ctl\.)', s, re.I)})
            print('Selected strings:'); print('\n'.join(selected[:100]))
        print('\n## Selected configured boot properties')
        for line in (root / 'default.prop').read_text().splitlines():
            if re.match(r'(ro\.(secure|debuggable|adb\.secure)|persist\.sys\.usb\.config)=', line): print(line)
        print('No inference of runtime authentication, network reachability, root privilege, or backup safety.')

if __name__ == '__main__': main()

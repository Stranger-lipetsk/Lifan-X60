#!/usr/bin/env python3
"""Extract static evidence from trusted update ramdisk; execute no firmware code."""
import hashlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from compare_firmware_releases import unpack_ramdisk

EXPECTED = '734f6b6442108916df89303ec5f52ceaa0ebb927d3b984a1e8a85ef2a6c12597'
INTEREST = re.compile(r'(?i)(fw.?upgrade|firmware|build_emmc|fw_status|socket|'
                      r'update.?status|sendbroadcast|startservice|oncreate|'
                      r'onclick|onreceive|exec_fw|opcod|/fw_data)')
METHOD = re.compile(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$')


def command(*args):
    print('\n$ ' + ' '.join(str(x) for x in args))
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('exit:', result.returncode)
    print(result.stdout.rstrip())
    if result.returncode:
        raise RuntimeError('Static inspection command failed')
    return result.stdout


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def inspect_smali(root):
    paths = sorted(root.rglob('*.smali'))
    if not paths:
        raise RuntimeError('No decoded smali')
    print('\n## App smali files:', len(paths))
    selected = 0
    for path in paths:
        text = path.read_text(encoding='utf-8', errors='replace')
        for method in METHOD.findall(text):
            if not INTEREST.search(method):
                continue
            selected += 1
            print('\n###', path.relative_to(root), method.splitlines()[0])
            lines = method.splitlines()
            if len(lines) > 1400:
                print(f'Method is {len(lines)} lines; only first 1400 shown')
            print('\n'.join(lines[:1400]))
    print('\nSelected methods:', selected)
    print('Keyword selection is incomplete and does not establish a runtime call path.')


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: inspect_sd_update_control.py SD_BOOT_IMG APKTOOL_JAR AAPT')
    img, apktool, aapt = map(Path, sys.argv[1:])
    digest = sha256(img)
    if digest != EXPECTED:
        raise SystemExit('Unexpected image SHA-256: ' + digest)
    print('# Update launcher and native executable: static investigation only')
    print('sd_boot SHA-256:', digest)
    print('No firmware code is executed. Static call paths do not show what happened on a device.')
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'ramdisk'
        summary = unpack_ramdisk(img, root)
        if not summary.startswith('kernel='):
            raise RuntimeError(summary)
        print('Boot header:', summary)
        binary = root / 'system/bin/fw_upgrade'
        apk = root / 'system/app/fw_launcher_2016.08.12.01.apk'
        for p in (binary, apk):
            if not p.is_file() or p.is_symlink():
                raise RuntimeError('Missing expected regular file: ' + str(p))
            print('Input:', p.relative_to(root), 'size:', p.stat().st_size, 'sha256:', sha256(p))
        print('\n## ARM ELF header and selected native symbols')
        command('readelf', '-h', str(binary))
        symbols = subprocess.run(['arm-linux-gnueabihf-nm', '-an', str(binary)],
                                 check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
        chosen = ('main', 'exec_fw_upgrade', 'handle_start_fw_upgrade', 'fw_upgrade_loop_thread',
                  'init_fw_upgrade_obj', 'peek_fw_upgrade_status')
        present = set()
        for line in symbols.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[-1] in chosen:
                present.add(parts[-1])
                print(line)
        if not present:
            raise RuntimeError('No expected native symbols found')
        for symbol in chosen:
            if symbol in present:
                command('arm-linux-gnueabihf-objdump', '-d', '--disassemble=' + symbol, str(binary))
        print('\n## Firmware app manifest: binary AXML as decoded by aapt')
        command(str(aapt), 'dump', 'badging', str(apk))
        command(str(aapt), 'dump', 'xmltree', str(apk), 'AndroidManifest.xml')
        decoded = Path(tmp) / 'decoded'
        command('java', '-jar', str(apktool), 'd', '-f', '-r', str(apk), '-o', str(decoded))
        inspect_smali(decoded)


if __name__ == '__main__':
    main()

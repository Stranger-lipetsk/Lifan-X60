#!/usr/bin/env python3
"""Extract static evidence from trusted update ramdisk; execute no firmware code."""
import hashlib
import re
import struct
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


def literal_addresses(path, needles):
    """Resolve file strings through ELF32 PT_LOAD segments without executing ELF."""
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    phoff = struct.unpack_from('<I', data, 28)[0]
    phentsize, phnum = struct.unpack_from('<HH', data, 42)
    segments = [struct.unpack_from('<8I', data, phoff + n * phentsize)
                for n in range(phnum)]
    results = []
    for needle in needles:
        start = 0
        while True:
            pos = data.find(needle.encode(), start)
            if pos < 0:
                break
            for ptype, offset, vaddr, _, filesz, _, _, _ in segments:
                if ptype == 1 and offset <= pos < offset + filesz:
                    results.append((needle, pos, vaddr + pos - offset))
            start = pos + 1
    return results


def read_elf32_vaddr(path, address, size):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    phoff = struct.unpack_from('<I', data, 28)[0]
    entsize, count = struct.unpack_from('<HH', data, 42)
    for n in range(count):
        ptype, offset, vaddr, _, filesz, _, _, _ = struct.unpack_from('<8I', data, phoff + n * entsize)
        if ptype == 1 and vaddr <= address and address + size <= vaddr + filesz:
            begin = offset + address - vaddr
            return data[begin:begin + size]
    raise ValueError('Address is not in a file-backed load segment')


def inspect_smali(root):
    paths = sorted(root.rglob('*.smali'))
    if not paths:
        raise RuntimeError('No decoded smali')
    print('\n## App smali files:', len(paths))
    selected = 0
    for path in paths:
        # Ignore Android support libraries; the target package is under tw/com/elead.
        if 'tw/com/elead/' not in path.relative_to(root).as_posix():
            continue
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
            elif len(parts) >= 3 and re.search(r'(?i)(handle|packet|socket|client|protocol|recv|upgrade)', parts[-1]):
                print(line)
        if not present:
            raise RuntimeError('No expected native symbols found')
        for symbol in chosen:
            if symbol in present:
                command('arm-linux-gnueabihf-objdump', '-d', '--disassemble=' + symbol, str(binary))
        print('\n## DWARF function records (when available)')
        debug = subprocess.run(['readelf', '--debug-dump=info', '--wide', str(binary)],
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
        all_records = re.split(r'(?=^ <\d+><[0-9a-f]+>: Abbrev Number:)', debug, flags=re.M)
        records = [record for record in all_records if re.search(
            r'DW_AT_name\s*:.*(?:exec_fw_upgrade|handle_start_fw_upgrade|fw_upgrade_loop_thread|init_fw_upgrade_obj)', record)]
        print('Matching debug records:', len(records))
        for record in records:
            print(record.rstrip())
        offsets = []
        for record in records:
            match = re.search(r'^ <\d+><([0-9a-f]+)>:.*DW_TAG_subprogram', record, re.M)
            if match:
                offsets.append(match.group(1))
        for offset in offsets:
            instances = [r for r in all_records if 'DW_TAG_inlined_subroutine' in r.splitlines()[0]
                         and re.search(r'DW_AT_abstract_origin\s*:.*<0x' + offset + r'>', r)]
            print(f'\nInline instances referencing <0x{offset}>: {len(instances)}')
            for record in instances:
                print(record.rstrip())
        print('\n## Selected ELF string addresses')
        for needle, offset, address in literal_addresses(binary, (
                '/system/bin/build_emmc.sh', 'OPCODE_START_FW_UPGRADE', 'exec_fw_upgrade error')):
            print(f'{needle!r}: file offset {offset:#x}, virtual address {address:#x}')
        print('\n## Opcode dispatch table words from the file-backed load segment')
        print('handle_op_code uses table base 0x7f96c + 0x94 + index * 4')
        table = struct.unpack('<15I', read_elf32_vaddr(binary, 0x7f96c + 0x94, 60))
        for index, word in enumerate(table):
            print(f'index {index}: {word:#010x}')
        print('\n## Code around inlined native update handler')
        command('arm-linux-gnueabihf-objdump', '-d', '--start-address=0x8b00',
                '--stop-address=0x9200', str(binary))
        command('arm-linux-gnueabihf-objdump', '-d', '--start-address=0x9900',
                '--stop-address=0x9d00', str(binary))
        print('\n## Vendor code leading into opcode handler')
        command('arm-linux-gnueabihf-objdump', '-d', '--start-address=0x8120',
                '--stop-address=0xa1f0', str(binary))
        print('\n## Firmware app manifest: binary AXML as decoded by aapt')
        command(str(aapt), 'dump', 'badging', str(apk))
        command(str(aapt), 'dump', 'xmltree', str(apk), 'AndroidManifest.xml')
        decoded = Path(tmp) / 'decoded'
        command('java', '-jar', str(apktool), 'd', '-f', '-r', str(apk), '-o', str(decoded))
        inspect_smali(decoded)


if __name__ == '__main__':
    main()

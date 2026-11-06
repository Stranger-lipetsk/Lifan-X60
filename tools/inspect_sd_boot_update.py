#!/usr/bin/env python3
"""Static inspection of the trusted sd_boot ramdisk. Never run its programs."""
import hashlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from compare_firmware_releases import unpack_ramdisk

PATTERN = re.compile(
    r'(?i)(?:mmcblk\d|/dev/block|system\.img|boot\.img|u-boot|mcu_fw|'
    r'config\.ini|\b(?:mkfs|mke2fs|format|flash|updat(?:e|er|ing)|recovery)\b|'
    r'/data\b|build_emmc|boot_mode_check|fw_upgrade|para_fw|data\.tar|'
    r'\b(?:mount|mount_all|service|exec|import)\b)'
)
BINARY_PATTERN = re.compile(
    r'(?i)(?:mmcblk\d|/dev/block|system\.img|sd_boot\.img|boot\.img|'
    r'u-boot\.bin|mcu_fw\.hex|config\.ini|mke2fs|mkfs\.|updater-script|'
    r'recovery\.fstab|formatting|writing system|update\.zip|build_emmc|'
    r'boot_mode_check|fw_upgrade|para_fw|data\.tar|system/bin/[^ ]+\.sh)'
)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as src:
        for block in iter(lambda: src.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def text_matches(text):
    lines = text.splitlines()
    return [(i + 1, line) for i, line in enumerate(lines) if PATTERN.search(line)]


def inspect(root):
    files = [p for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()]
    print(f'Files inspected: {len(files)}; symlinks are listed but not followed.')
    links = [p for p in sorted(root.rglob('*')) if p.is_symlink()]
    print(f'Symlinks: {len(links)}')
    text_hits = binary_hits = 0
    for p in files:
        rel = p.relative_to(root)
        if p.stat().st_size > 50 * 1024 * 1024:
            print(f'\n## {rel} skipped: over 50 MiB')
            continue
        data = p.read_bytes()
        # Text scan includes scripts without an extension; binary strings are
        # a separate heuristic, not a disassembly or complete control flow.
        try:
            text = data.decode('utf-8') if b'\0' not in data else None
        except UnicodeDecodeError:
            text = None
        if text is not None:
            matches = text_matches(text)
            if matches:
                text_hits += len(matches)
                print(f'\n## Text: {rel} ({len(matches)} matching lines)')
                for number, line in matches[:250]:
                    print(f'{number}: {line[:500]}')
                if len(matches) > 250:
                    print('... further matches omitted')
        else:
            result = subprocess.run(['strings', '-a', '-n', '5', str(p)],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
            strings = result.stdout.decode('utf-8', 'replace').splitlines()
            matches = [line for line in strings if BINARY_PATTERN.search(line)]
            if matches:
                binary_hits += len(matches)
                print(f'\n## Binary strings: {rel} ({len(matches)} matches; not proof of execution)')
                for line in matches[:80]:
                    print(line[:500])
                if len(matches) > 80:
                    print('... further matches omitted')
    print(f'\nText matched lines: {text_hits}; binary matched strings: {binary_hits}')
    for name in ('system/bin/build_emmc.sh', 'system/bin/boot_mode_check.sh', 'init.rc'):
        p = root / name
        if p.is_file() and not p.is_symlink():
            print(f'\n## Full text for control flow: {name}')
            for number, line in enumerate(p.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
                print(f'{number}: {line}')
    print('\nStatic search only: no guarantee of complete coverage, control flow, runtime device state, or data preservation.')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_sd_boot_update.py SD_BOOT_IMAGE')
    image = Path(sys.argv[1])
    expected = '734f6b6442108916df89303ec5f52ceaa0ebb927d3b984a1e8a85ef2a6c12597'
    digest = sha256(image)
    if digest != expected:
        raise SystemExit(f'Unexpected sd_boot image SHA-256: {digest}')
    print('# sd_boot update ramdisk: read-only static investigation')
    print('Trusted stock image SHA-256:', digest)
    print('Nothing in this image is executed. Never execute its update programs on a device based on this report.')
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'ramdisk'
        result = unpack_ramdisk(image, root)
        if not result.startswith('kernel='):
            raise SystemExit(result)
        print('Android boot image:', result)
        inspect(root)


if __name__ == '__main__':
    main()

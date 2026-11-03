#!/usr/bin/env python3
"""Read-only comparison of extracted firmware images and APK metadata."""
import difflib
import gzip
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

LABELS = ('dealer', 'dealer-time', 'enthusiast')
TEXT_EXT = ('.prop', '.rc', '.sh', '.ini', '.conf', '.xml', '.txt')
APK_INTEREST = re.compile(r'navitel|launcher2|home\.apk|settings\.apk|mirrorlink|packageinstaller', re.I)


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def tree(root):
    result = {}
    for cur, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            p = Path(cur) / name
            rel = p.relative_to(root).as_posix()
            if p.is_symlink():
                result[rel] = ('symlink', os.readlink(p))
            elif p.is_file():
                result[rel] = ('file', p.stat().st_size, digest(p))
    return result


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout


def show_apk(path, aapt, signer):
    print('\n###', path.name, 'size=', path.stat().st_size, 'sha256=', digest(path))
    rc, out = command(aapt, 'dump', 'badging', str(path))
    print('aapt exit:', rc)
    for line in out.splitlines():
        if line.startswith(('package:', 'sdkVersion:', 'targetSdkVersion:', 'launchable-activity:', 'native-code:', 'application:')):
            print(line)
    rc, out = command(signer, 'verify', '--min-sdk-version', '19', '--max-sdk-version', '19', '--print-certs', str(path))
    print('apksigner verify Android API 19 exit:', rc)
    for line in out.splitlines():
        if re.search(r'Signer|SHA-256|ERROR|WARNING|Exception|does not verify', line, re.I):
            print(line[:400])
    try:
        with zipfile.ZipFile(path) as apk:
            print('zip test:', apk.testzip() or 'OK')
            for name in ('AndroidManifest.xml', 'classes.dex'):
                try:
                    data = apk.read(name)
                    print(name, 'sha256=', hashlib.sha256(data).hexdigest(), 'size=', len(data))
                except KeyError:
                    print(name, 'missing')
            libs = [n for n in apk.namelist() if n.startswith('lib/') and n.endswith('.so')]
            print('native ABIs:', ', '.join(sorted({n.split('/')[1] for n in libs})) or 'none')
            print('native library count:', len(libs))
            if 'navitel' in path.name.lower():
                for name in libs:
                    h = hashlib.sha256()
                    with apk.open(name) as lib:
                        for data in iter(lambda: lib.read(1024 * 1024), b''):
                            h.update(data)
                    print('APK native library:', name, 'sha256=', h.hexdigest())
    except (zipfile.BadZipFile, OSError) as exc:
        print('ZIP error:', exc)


def compare_trees(label, aroot, broot):
    a, b = tree(aroot), tree(broot)
    print('\n##', label)
    added, removed, changed = [], [], []
    for path in sorted(set(a) | set(b)):
        if path not in a:
            added.append(path)
        elif path not in b:
            removed.append(path)
        elif a[path] != b[path]:
            changed.append(path)
    print('unique files/symlinks before/after:', len(a), '/', len(b))
    for title, paths in (('Removed', removed), ('Added', added), ('Changed', changed)):
        print('\n###', title, len(paths))
        for path in paths:
            print(path, '|', a.get(path, '-'), '=>', b.get(path, '-'))
    print('\n### Text differences (UTF-8, bounded)')
    for path in changed:
        if not path.lower().endswith(TEXT_EXT):
            continue
        left, right = aroot / path, broot / path
        if not left.is_file() or not right.is_file() or max(left.stat().st_size, right.stat().st_size) > 100000:
            continue
        try:
            old = left.read_text(encoding='utf-8').splitlines()
            new = right.read_text(encoding='utf-8').splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        delta = list(difflib.unified_diff(old, new, fromfile='before/' + path, tofile='after/' + path, lineterm=''))
        if delta:
            print('\n'.join(delta[:500]))
            if len(delta) > 500:
                print('... diff truncated')


def unpack_ramdisk(img, output):
    try:
        data = img.read_bytes()
        if data[:8] != b'ANDROID!':
            return 'not an Android boot image'
        ks, _, rs, _, _, _, _, page = struct.unpack('<8I', data[8:40])
        if not (512 <= page <= 65536 and rs > 0):
            return f'unsupported header: page={page}, ramdisk={rs}'
        start = page + ((ks + page - 1) // page) * page
        raw = gzip.decompress(data[start:start + rs])
        output.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run(['cpio', '-id', '--no-absolute-filenames'], input=raw, cwd=output,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode:
            return f'cpio failed: {proc.stderr.decode(errors="replace")[:500]}'
        return f'kernel={ks} ramdisk={rs} page={page}'
    except (ValueError, OSError, struct.error, EOFError) as exc:
        return f'ramdisk not decoded: {exc}'


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: compare_firmware_releases.py ROOT AAPT APKSIGNER')
    root, aapt, signer = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    bundles = {label: root / label for label in LABELS}
    images = {label: root / (label + '-system') for label in LABELS}
    print('# Сравнение прошивок: дилер / дилер-время / энтузиаст')
    print('Это статический анализ содержимого; результат не подтверждает работоспособность на устройстве.')
    for label in LABELS:
        print('\n## Состав', label)
        for path in sorted(bundles[label].rglob('*')):
            if path.is_file():
                print(path.relative_to(bundles[label]), path.stat().st_size, digest(path))
        print('\n## Config.ini в архиве', label)
        configs = list(bundles[label].rglob('config.ini'))
        if not configs:
            print('нет файла config.ini')
        for config in configs:
            print('путь:', config.relative_to(bundles[label]))
            for line in config.read_text(errors='replace').splitlines():
                line = line.strip()
                if '=' in line and not line.startswith(('#', ';')):
                    key, value = line.split('=', 1)
                    print('ключ:', key.strip(), ('значение: ' + value.strip()) if re.search(r'time|zone|gmt|clock', key, re.I) else '(значение скрыто)')
                elif line.startswith('[') and line.endswith(']'):
                    print('секция:', line)
        print('\n## Свойства', label)
        prop = images[label] / 'build.prop'
        if prop.exists():
            for line in prop.read_text(errors='replace').splitlines():
                if re.match(r'^(ro\.build\.|ro\.product\.|persist\.(sys\.|.*time)|ro\.debuggable)', line):
                    print(line)
        print('\n## Интересующие APK', label)
        for folder in ('app', 'priv-app'):
            for path in sorted((images[label] / folder).glob('*')):
                if path.is_file() and APK_INTEREST.search(path.name):
                    show_apk(path, aapt, signer)
    for a, b in ((LABELS[0], LABELS[1]), (LABELS[1], LABELS[2]), (LABELS[0], LABELS[2])):
        compare_trees(a + ' system -> ' + b + ' system', images[a], images[b])
    with tempfile.TemporaryDirectory() as tmp:
        for name in ('boot.img', 'sd_boot.img'):
            extracted = {}
            for label in LABELS:
                paths = list(bundles[label].rglob(name))
                if len(paths) != 1:
                    print('\nramdisk', label, name, 'expected one image, found', len(paths))
                    continue
                out = Path(tmp) / label / name
                print('\nramdisk', label, name, unpack_ramdisk(paths[0], out))
                if out.is_dir():
                    extracted[label] = out
            for a, b in ((LABELS[0], LABELS[1]), (LABELS[1], LABELS[2])):
                if a in extracted and b in extracted:
                    compare_trees(a + ' ' + name + ' ramdisk -> ' + b, extracted[a], extracted[b])


if __name__ == '__main__':
    main()

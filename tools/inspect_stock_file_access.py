#!/usr/bin/env python3
"""Read-only trace of file-picker and installer intent references in selected APKs.

String hits and same-method context are clues, not proof of UI reachability.
"""
import re
import sys
import zipfile
from pathlib import Path

PATTERN = re.compile(
    r'android\.intent\.action\.(?:OPEN_DOCUMENT|CREATE_DOCUMENT|GET_CONTENT|INSTALL_PACKAGE|VIEW)'
    r'|android\.credentials\.INSTALL(?:_AS_USER)?'
    r'|android\.provider\.action\.MANAGE_ROOT'
    r'|application/(?:vnd\.android\.package-archive|x-pkcs12|x-x509|x-pem-file|pkix-cert)'
    r'|(?:\.apk\b|EXTRA_MIME_TYPES)', re.I)


def inspect(root):
    print('# Stock Android file-picker and installer static trace')
    print('Exact image source and hashes are checked by workflow; runtime reachability is not proved.')
    for app in sorted(p for p in root.iterdir() if p.is_dir()):
        files = sorted(app.rglob('*.smali'))
        if not files:
            raise SystemExit('No smali for ' + app.name)
        hits = []
        for path in files:
            lines = path.read_text(errors='replace').splitlines()
            method = '(outside method)'
            for i, line in enumerate(lines):
                if line.startswith('.method '):
                    method = line
                if PATTERN.search(line):
                    hits.append((path.relative_to(app), i + 1, method, line.strip()))
                if line.startswith('.end method'):
                    method = '(outside method)'
        print('\n##', app.name, 'files:', len(files), 'hits:', len(hits))
        for path, number, method, line in hits[:250]:
            print(f'{path}:{number} {method}\n  {line}')
        if len(hits) > 250:
            print('... truncated at 250 hits')
        # Full methods for narrowly selected classes, to show handling rather than strings alone.
        wanted = {
            'CertInstaller': ('CertInstallerMain.smali',),
            'DocumentsUI': ('DocumentsActivity.smali',),
            'Settings': ('SecuritySettings.smali', 'CredentialStorage.smali',
                         'StorageVolumePreferenceCategory.smali', 'AdvancedWifiSettings.smali'),
            'Downloads': ('DownloadList.smali', 'OpenHelper.smali'),
            'PackageInstaller': ('PackageInstallerActivity.smali',),
        }.get(app.name, ())
        for path in files:
            if path.name not in wanted and app.name not in ('Camera2', 'Music'):
                continue
            content = path.read_text(errors='replace')
            if app.name in ('Camera2', 'Music') and 'android.intent.action.GET_CONTENT' not in content:
                continue
            for match in re.finditer(r'(?ms)^\.method [^\n]+\n.*?^\.end method', content):
                method = match.group()
                if PATTERN.search(method) or (app.name == 'DocumentsUI' and re.search(r'(onDocumentPicked|onDocumentsPicked|onFinished|finishPicking|finishWithResult)', method[:180], re.I)) or (app.name == 'PackageInstaller' and re.search(r'\bonCreate\(', method[:180])):
                    print('\n### Full method', path.relative_to(app))
                    lines = method.splitlines()
                    print('\n'.join(lines[:300]))
                    if len(lines) > 300:
                        print('... method truncated at 300 lines')


def scan_apks(root):
    print('\n## APK DEX literal scan: file and installer intents')
    print('NUL-terminated literal byte hits are leads only: they do not prove a call, a UI path, or runtime availability.')
    print('Dynamic construction, native code, external packages, data and boot are not scanned.')
    patterns = {
        'MANAGE_ROOT': b'android.provider.action.MANAGE_ROOT',
        'OPEN_DOCUMENT': b'android.intent.action.OPEN_DOCUMENT',
        'GET_CONTENT': b'android.intent.action.GET_CONTENT',
        'INSTALL_PACKAGE': b'android.intent.action.INSTALL_PACKAGE',
        'APK_MIME': b'application/vnd.android.package-archive',
        'CREATE_SHORTCUT': b'android.intent.action.CREATE_SHORTCUT',
    }
    count = 0
    matches = {key: [] for key in patterns}
    for path in sorted(root.rglob('*')):
        if not path.is_file() or not zipfile.is_zipfile(path):
            continue
        count += 1
        with zipfile.ZipFile(path) as apk:
            dexes = [n for n in apk.namelist() if re.fullmatch(r'classes(?:[0-9]+)?\.dex', n)]
            found = set()
            for name in dexes:
                dex = apk.read(name)
                found.update(key for key, literal in patterns.items() if literal + b'\x00' in dex)
            for key in found:
                matches[key].append(str(path.relative_to(root)))
    if count < 10:
        raise SystemExit('Too few APKs extracted for scan')
    print('ZIP/APK files scanned:', count)
    for key, paths in matches.items():
        print(f'\n### {key}: {len(paths)} APK(s)')
        for path in paths:
            print('literal match:', path)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: inspect_stock_file_access.py DECODED_DIR EXTRACTED_APPS_DIR')
    inspect(Path(sys.argv[1]))
    scan_apks(Path(sys.argv[2]))

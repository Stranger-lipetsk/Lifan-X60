#!/usr/bin/env python3
"""Read-only trace of file-picker and installer intent references in selected APKs.

String hits and same-method context are clues, not proof of UI reachability.
"""
import re
import sys
from pathlib import Path

PATTERN = re.compile(
    r'android\.intent\.action\.(?:OPEN_DOCUMENT|CREATE_DOCUMENT|GET_CONTENT|INSTALL_PACKAGE|VIEW)'
    r'|android\.credentials\.INSTALL(?:_AS_USER)?'
    r'|android\.provider\.action\.MANAGE_ROOT'
    r'|application/(?:vnd\.android\.package-archive|x-pkcs12|x-x509|x-pem-file|pkix-cert)'
    r'|(?:\.apk\b|CertInstaller|EXTRA_MIME_TYPES)', re.I)


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
            'Settings': ('SecuritySettings.smali', 'CredentialStorage.smali'),
        }.get(app.name, ())
        for path in files:
            if path.name not in wanted:
                continue
            content = path.read_text(errors='replace')
            for match in re.finditer(r'(?ms)^\.method [^\n]+\n.*?^\.end method', content):
                method = match.group()
                if PATTERN.search(method) or (app.name == 'DocumentsUI' and re.search(r'(onDocumentPicked|onDocumentsPicked|onFinished|finishPicking|finishWithResult)', method[:180], re.I)):
                    print('\n### Full method', path.relative_to(app))
                    lines = method.splitlines()
                    print('\n'.join(lines[:300]))
                    if len(lines) > 300:
                        print('... method truncated at 300 lines')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_stock_file_access.py DECODED_DIR')
    inspect(Path(sys.argv[1]))

#!/usr/bin/env python3
"""Identify candidate launch/install paths in decompiled stock app code.

Matches are clues only: this is not a control-flow reachability analysis.
"""
import re
import sys
from pathlib import Path

PATTERNS = [
    ('APK extension or MIME', re.compile(r'(?i)(\.apk\b|vnd\.android\.package-archive|INSTALL_PACKAGE)')),
    ('Open/download actions', re.compile(r'android\.intent\.action\.(VIEW|GET_CONTENT|OPEN_DOCUMENT|DOWNLOAD_COMPLETE)')),
    ('Android settings launch', re.compile(r'(android\.settings\.(SETTINGS|APPLICATION_SETTINGS|SECURITY_SETTINGS)|com\.android\.settings)')),
    ('Media file filters', re.compile(r'(?i)(\.mp3\b|\.mp4\b|\.avi\b|\.wma\b|mime.?type|audio/|video/)')),
]


def main():
    root = Path(sys.argv[1])
    print('# Поиск путей запуска в штатных APK')
    print('Совпадения строк не доказывают доступность метода с экрана.')
    for appdir in sorted(p for p in root.iterdir() if p.is_dir()):
        files = list(appdir.rglob('*.smali'))
        print('\n##', appdir.name, '- файлов smali:', len(files))
        if not files:
            print('ОШИБКА: код приложения не разобран')
            continue
        for label, pattern in PATTERNS:
            hits = []
            for path in files:
                lines = path.read_text(errors='replace').splitlines()
                method = '(outside method)'
                for i, line in enumerate(lines):
                    if line.startswith('.method '):
                        method = line
                    if pattern.search(line):
                        hits.append((path.relative_to(appdir), i + 1, method, lines[max(0, i-5):i+7]))
                    if line.startswith('.end method'):
                        method = '(outside method)'
            print('\n###', label, '- совпадений:', len(hits))
            for path, line_no, method, context in hits[:30]:
                print('\n---', path, 'строка', line_no, method)
                print('\n'.join(context))
            if len(hits) > 30:
                print('... показаны первые 30 совпадений')


if __name__ == '__main__':
    main()

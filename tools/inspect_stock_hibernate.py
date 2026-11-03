#!/usr/bin/env python3
"""Find stock Home code related to the pre-hibernation screen."""
import re
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

root, apk, aapt = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
patterns = [
    ('message string resource', re.compile(r'0x7f0c0114')),
    ('pre-hibernate state and actions', re.compile(r'(?i)pre.?hibernat|discalimer_prehibernate|disclaimer_prehibernate')),
    ('hibernate screen', re.compile(r'(?i)discalimer|disclaimer|hibernate')),
]
print('# Поиск кода экрана system optimization в оболочке')
print('Статический поиск; наличие ссылки не подтверждает фактический путь выполнения.')
for label, pattern in patterns:
    hits = []
    for path in sorted(root.rglob('*.smali')):
        if '/tw/com/elead/el830/home/' not in path.as_posix():
            continue
        lines = path.read_text(errors='replace').splitlines()
        method = '(outside method)'
        for index, line in enumerate(lines):
            if line.startswith('.method '):
                method = line
            if pattern.search(line):
                hits.append((path.relative_to(root), index, method, lines))
            if line.startswith('.end method'):
                method = '(outside method)'
    print('\n##', label, 'matches=', len(hits))
    for path, index, method, lines in hits[:120]:
        print('\n###', path, 'line', index + 1, method)
        print('\n'.join(lines[max(0, index-20):min(len(lines), index+35)]))
    if len(hits) > 120:
        print('... truncated')

print('\n## Layout XML references to prehibernate resource')
with zipfile.ZipFile(apk) as z:
    for name in z.namelist():
        if name.startswith('res/layout') and name.endswith('.xml') and struct.pack('<I', 0x7f0c0114) in z.read(name):
            print('\n###', name)
            proc = subprocess.run([aapt, 'dump', 'xmltree', str(apk), name], capture_output=True, text=True)
            print(proc.stdout[:30000])

#!/usr/bin/env python3
"""Find network ADB property references in offline-decoded SystemUI smali."""
import re
import sys
from pathlib import Path

METHOD = re.compile(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$')
NEEDLE = 'service.adb.tcp.port'


def inspect(root):
    files = sorted(Path(root).rglob('*.smali'))
    hits = []
    classes = set()
    for path in files:
        text = path.read_text(encoding='utf-8', errors='replace')
        for method in METHOD.findall(text):
            if NEEDLE in method:
                descriptor = re.search(r'(?m)^\.class [^\n]*\s(L[^;]+;)', text)
                if descriptor:
                    classes.add(descriptor.group(1))
                hits.append((path.relative_to(root).as_posix(), method))
    return files, hits, classes


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_systemui_network_adb.py DECODED_SYSTEMUI')
    root = Path(sys.argv[1])
    files, hits, classes = inspect(root)
    if not files:
        raise SystemExit('No smali files found')
    print('# Offline SystemUI network ADB property references')
    print('No application code was run. Methods show possible code paths, not runtime settings or user-visible access.')
    print('Smali files:', len(files), 'property-bearing methods:', len(hits))
    for name, method in hits:
        print('\n##', name)
        lines = method.splitlines()
        print('\n'.join(lines[:600]))
        if len(lines) > 600:
            print('... method truncated; total lines:', len(lines))
    print('\n## Other methods referencing property-bearing classes')
    for path in files:
        text = path.read_text(encoding='utf-8', errors='replace')
        for method in METHOD.findall(text):
            matched = sorted(c for c in classes if c in method)
            if not matched:
                continue
            print('\n###', path.relative_to(root), method.splitlines()[0], 'references', ', '.join(matched))
            lines = method.splitlines()
            print('\n'.join(lines[:250]))
            if len(lines) > 250:
                print('... method truncated; total lines:', len(lines))
    print('\nNo assertion of availability, physical connectivity, security or backup safety.')


if __name__ == '__main__':
    main()

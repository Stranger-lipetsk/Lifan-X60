#!/usr/bin/env python3
"""Capture stock Home carousel construction and persistence references."""
import re
import sys
from pathlib import Path

METHOD = re.compile(r'^\.method[^\n]*\n.*?^\.end method', re.M | re.S)
TARGETS = ('initDefault_EL830CLF01(', 'loadEleadApplications(', 'gotoEleadApplication(')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_home_carousel.py APKTOOL_OUTPUT')
    root = Path(sys.argv[1])
    path = root / 'smali/tw/com/elead/el830/home/HomeApp.smali'
    text = path.read_text(encoding='utf8')
    methods = METHOD.findall(text)
    for target in TARGETS:
        hits = [m for m in methods if target in m.splitlines()[0]]
        if len(hits) != 1:
            raise SystemExit(f'Expected exactly one definition for {target}, got {len(hits)}')
        print('\n##', hits[0].splitlines()[0])
        print(hits[0])
    print('\n## Other methods referencing carousel lists (headers and matching lines)')
    for f in sorted(root.glob('smali*/tw/com/elead/el830/home/**/*.smali')):
        src = f.read_text(encoding='utf8')
        for method in METHOD.findall(src):
            if any(t in method.splitlines()[0] for t in TARGETS):
                continue
            lines = [line.strip() for line in method.splitlines()
                     if re.search(r'mEleadApps(_default)?[:;]|(?:get|set|save|load)EleadApps', line)]
            if lines:
                print('\n', f.relative_to(root), method.splitlines()[0])
                for line in lines:
                    print(line)
    print('\nStatic source inspection only; no proof of runtime behavior.')


if __name__ == '__main__':
    main()

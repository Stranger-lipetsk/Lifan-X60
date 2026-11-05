#!/usr/bin/env python3
"""Inspect stock Home preferences and PackageManager upgrade code, without mutation."""
import re
import sys
from pathlib import Path

METHOD = re.compile(r'(?ms)^\.method [^\n]+\n.*?^\.end method')


def methods(path):
    return METHOD.findall(path.read_text(encoding='utf-8', errors='replace'))


def selected(path, names):
    all_methods = methods(path)
    for name in names:
        hits = [m for m in all_methods if re.search(r'(?:\s|^)' + re.escape(name) + r'\(', m.splitlines()[0])]
        if not hits:
            raise ValueError(f'{path.name}: no definition of {name}')
        for item in hits:
            print('\n##', path.name, item.splitlines()[0])
            print(item)


def contexts(path, phrases, radius=45, filter_names=()):
    matched = 0
    for method in methods(path):
        lines = method.splitlines()
        if filter_names and not any(re.search(r'\b' + re.escape(name) + r'\(', lines[0]) for name in filter_names):
            continue
        found = [i for i, line in enumerate(lines) if any(s in line for s in phrases)]
        if not found:
            continue
        matched += len(found)
        print('\n##', path.name, lines[0], 'matching contexts:', len(found))
        ranges = []
        for i in found:
            lo, hi = max(0, i-radius), min(len(lines), i+radius+1)
            if ranges and lo <= ranges[-1][1]:
                ranges[-1] = (ranges[-1][0], max(hi, ranges[-1][1]))
            else:
                ranges.append((lo, hi))
        for lo, hi in ranges:
            print(f'-- lines {lo+1}..{hi} / {len(lines)} --')
            print('\n'.join(lines[lo:hi]))
    if not matched:
        raise ValueError(f'{path.name}: no matches: {phrases}')


def callers(root, patterns):
    count = 0
    print('\n## Cross-references for selected methods')
    for file in sorted(root.glob('smali*/**/*.smali')):
        text = file.read_text(encoding='utf-8', errors='replace')
        for method in METHOD.findall(text):
            lines = [x.strip() for x in method.splitlines() if any(p in x for p in patterns)]
            if lines:
                count += 1
                print('\n', file.relative_to(root), method.splitlines()[0])
                print('\n'.join(lines))
    if not count:
        raise ValueError('No selected cross-references found')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: inspect_stock_transition.py HOME_DECODED SERVICES_DECODED')
    home, services = map(Path, sys.argv[1:])
    homepkg = home / 'smali/tw/com/elead/el830/home'
    pm = services / 'smali/com/android/server/pm/PackageManagerService.smali'
    print('# Stock code analysis; read-only, not a runtime test')
    print('\n# Home list persistence and allowed changes')
    selected(homepkg / 'HomeApp.smali', ['loadPreferences', 'savePreferences', 'setAppsOrder'])
    selected(homepkg / 'ApplicationInfo.smali', ['<init>'])
    callers(home, ['->setAppsOrder(', '->resetToDefault(', '->loadPreferences(', '->savePreferences('])
    print('\n# Package signature checks and system replacement handling')
    selected(pm, ['verifySignaturesLP'])
    contexts(pm, ['->verifySignaturesLP(', 'signature changed; retaining data',
                  '->removeDataDirsLI(', '->deletePackageLI('], 45, ('scanPackageLI',))


if __name__ == '__main__':
    main()

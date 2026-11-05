#!/usr/bin/env python3
"""Static inspection of PackageManager preferred-activity logic, not a device test."""
import re
import sys
from pathlib import Path


def inspect(root, out=sys.stdout):
    pm = root / 'smali/com/android/server/pm'
    if not pm.is_dir():
        raise ValueError('PackageManager smali directory missing')
    targets = {
        'pm/Settings.smali': re.compile(r'\b(readDefaultPreferredAppsLPw|readDefaultPreferredActivitiesLPw|applyDefaultPreferredActivityLPw)\('),
        'pm/PreferredActivity.smali': re.compile(r'<init>\('),
        'PreferredComponent.smali': re.compile(r'<init>\('),
    }
    print('# Preferred HOME: stock services.jar static analysis', file=out)
    print('Code presence does not prove activation on this device or on an existing data partition.', file=out)
    total = 0
    for name, wanted in targets.items():
        path = pm.parent / name
        if not path.exists():
            print(f'\n## {name}: not found', file=out)
            continue
        text = path.read_text(errors='replace')
        for m in re.finditer(r'(?ms)^\.method [^\n]+\n.*?^\.end method', text):
            method = m.group()
            if not wanted.search(method.splitlines()[0]):
                continue
            total += 1
            lines = method.splitlines()
            print(f'\n## {name}: {lines[0]}', file=out)
            print('\n'.join(lines[:500]), file=out)
            if len(lines) > 500:
                print('... truncated at 500 lines', file=out)
    pms = pm / 'PackageManagerService.smali'
    if pms.exists():
        text = pms.read_text(errors='replace')
        for m in re.finditer(r'(?ms)^\.method [^\n]+\n.*?^\.end method', text):
            method = m.group()
            if '->readDefaultPreferredAppsLPw(' not in method:
                continue
            total += 1
            lines = method.splitlines()
            print(f'\n## PackageManagerService: {lines[0]}', file=out)
            for i, line in enumerate(lines):
                if '->readDefaultPreferredAppsLPw(' in line:
                    print('\n'.join(lines[max(0, i - 40):i + 25]), file=out)
    print(f'\nMethods or contexts selected: {total}', file=out)
    if total == 0:
        raise ValueError('No expected preferred activity methods found; inspect framework separately')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_preferred_home.py DECODED_DIR')
    inspect(Path(sys.argv[1]))

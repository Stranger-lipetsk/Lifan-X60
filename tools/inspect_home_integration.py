#!/usr/bin/env python3
"""Read-only inventory of stock Home UI and extension surfaces.

Works on an apktool decompilation. Selected complete methods and contextual
references are evidence of static control flow, not a guarantee on the device.
"""
import re
import sys
from pathlib import Path

METHOD = re.compile(r'(?ms)^\.method [^\n]+\n.*?^\.end method')
HOME = 'tw/com/elead/el830/home'
DIRECT_METHODS = {
    'Home.smali': {'loadApplications', 'updateEleadAppsOrder', 'onCreate', 'onResume'},
    'HomeApp.smali': {'findMainActivityForPackage', 'initDefault', 'initDefault_EL830CLF01',
                      'loadEleadApplications', 'gotoEleadApplication', 'onCreate', 'getEleadApps'},
    'ApplicationInfo.smali': {'<init>', 'setActivity'},
}
REFS = ('->getEleadApps(', '->getEleadApplication(', '->gotoEleadApplication(',
        '->loadApplications(', '->loadEleadApplications(', '->setAppsOrder(',
        '->mEleadApps:', '->mEleadApplications:', 'Landroid/content/Context;->registerReceiver(',
        'Landroid/app/Activity;->registerReceiver(', 'Landroid/app/Application;->registerReceiver(')
MATCH = re.compile(r'(?i)APP_NO_|getEleadApps|mEleadApps|mEleadApplications|gotoEleadApplication|'
                   r'add\w*Application|package_added|package_changed|registerReceiver|onReceive|'
                   r'reflect|loadClass|loadDex|instrument|\bbMenuItem\b|intent-filter|'
                   r'BOOT_COMPLETED|sharedUserId|permission')


def name(method):
    head = method.splitlines()[0]
    match = re.search(r'([^\s(]+)\(', head)
    return match.group(1) if match else ''


def main(root):
    root = Path(root)
    files = sorted(root.glob('smali*/**/*.smali'))
    if not files:
        raise ValueError('no smali files')
    print('# Stock Home extension and UI control flow — static, read-only')
    manifest = root / 'AndroidManifest.xml'
    if manifest.exists():
        content = manifest.read_bytes()
        print('\n## Manifest availability')
        if b'\x00' in content:
            print('Binary manifest: see aapt xmltree output at the start of this report.')
        else:
            print(content.decode('utf8', errors='replace'))
    chosen = []
    for path in files:
        text = path.read_text(encoding='utf8', errors='replace')
        for method in METHOD.findall(text):
            direct = path.name in DIRECT_METHODS and name(method) in DIRECT_METHODS[path.name] and HOME in path.as_posix()
            linked = HOME in path.as_posix() and any(ref in method for ref in REFS)
            if direct or linked:
                chosen.append((path.relative_to(root), method, direct))
    if not any(str(p).endswith('/Home.smali') and name(m) == 'loadApplications' for p, m, _ in chosen):
        raise ValueError('Home.loadApplications not found')
    print('\n## Full selected methods (with contexts for exceptionally large methods)')
    for path, method, direct in chosen:
        lines = method.splitlines()
        print('\n###', path, lines[0], '(direct)' if direct else '(reference)')
        if len(lines) <= 3000:
            print(method)
        else:
            hits = [i for i, line in enumerate(lines) if MATCH.search(line)]
            print('Full method too large:', len(lines), 'lines; contexts:', len(hits))
            regions = []
            for i in hits:
                lo, hi = max(0, i - 25), min(len(lines), i + 26)
                if regions and lo <= regions[-1][1]:
                    regions[-1] = (regions[-1][0], max(regions[-1][1], hi))
                else:
                    regions.append((lo, hi))
            for lo, hi in regions:
                print('-- lines', lo + 1, '..', hi)
                print('\n'.join(lines[lo:hi]))
    print('\n## Inventory of relevant references in all Home classes')
    for path in files:
        if HOME not in path.as_posix():
            continue
        lines = path.read_text(encoding='utf8', errors='replace').splitlines()
        signature = '(field or class)'
        printed = False
        for number, line in enumerate(lines, 1):
            if line.startswith('.method '):
                signature = line
            if MATCH.search(line):
                if not printed:
                    print('\n###', path.relative_to(root))
                    printed = True
                print(number, signature, line.strip())
            if line.startswith('.end method'):
                signature = '(field or class)'
    print('\nMethods selected:', len(chosen))
    print('No runtime, signature bypass, or firmware modification performed.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_home_integration.py APKTOOL_OUTPUT')
    main(sys.argv[1])

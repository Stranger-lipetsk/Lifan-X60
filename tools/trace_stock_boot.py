#!/usr/bin/env python3
"""Dump selected stock Home startup methods for manual control-flow analysis.

Reads apktool output only. No APKs or firmware are modified. The report is
static evidence, not a trace of what ran on the device.
"""
import re
import sys
from pathlib import Path


def methods(path):
    text = path.read_text(errors='replace')
    return re.findall(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$', text)


def signature(method):
    return method.splitlines()[0]


def main():
    root = Path(sys.argv[1]) / 'smali/tw/com/elead/el830/home'
    if not root.is_dir():
        raise SystemExit('Home smali directory is missing')
    files = sorted(root.glob('*.smali'))
    found = [(p, method) for p in files for method in methods(p)]
    wrappers = set()
    for p, method in found:
        if p.name == 'HomeService.smali' and '->sysPreHibernate()V' in method:
            m = re.search(r'\b(access\$\d+)\(', signature(method))
            if m:
                wrappers.add(m.group(1))
    print('# Stock Home: selected complete methods')
    print('Static code only; absence of a match or call does not establish runtime behavior.')
    print('sysPreHibernate wrappers:', ', '.join(sorted(wrappers)) or '(none)')
    selected = []
    for p, method in found:
        sig = signature(method)
        reason = None
        if p.name == 'Disclaimer.smali' and re.search(r'\b(show|hide|enablePreHibernateMode)\(', sig):
            reason = 'disclaimer display'
        elif p.name == 'Disclaimer$2.smali' and 'handleMessage(' in sig:
            reason = 'disclaimer message handler'
        elif p.name.startswith('Disclaimer$') and 'onClick(' in sig:
            reason = 'disclaimer click'
        elif p.name == 'HomeService$31.smali' and 'onActivityResumed(' in sig:
            reason = 'activity observer'
        elif p.name == 'HomeService.smali' and ('sysPreHibernate(' in sig or '->sysPreHibernate()V' in method):
            reason = 'pre-hibernate and wrappers'
        elif p.name.startswith('HomeService') and any('->' + w + '(' in method for w in wrappers):
            reason = 'pre-hibernate wrapper caller'
        elif '->enablePreHibernateMode()V' in method:
            reason = 'enable pre-hibernate caller'
        if reason:
            selected.append((p, method, reason))
    if not selected:
        raise SystemExit('No selected methods found')
    for p, method, reason in selected:
        print('\n##', p.relative_to(root), reason, signature(method))
        lines = method.splitlines()
        if len(lines) > 1600:
            print('Method too large to dump fully; 60-line contexts around relevant calls follow.')
            keywords = ['->sysPreHibernate(', '->enablePreHibernateMode('] + ['->' + w + '(' for w in wrappers]
            indices = [i for i, line in enumerate(lines) if any(k in line for k in keywords)]
            for i in indices:
                print('\n--- context at method line', i + 1)
                print('\n'.join(lines[max(0, i-60):i+61]))
        else:
            print(method)
    print('\n## Methods selected:', len(selected))


if __name__ == '__main__':
    main()

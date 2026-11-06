#!/usr/bin/env python3
"""Offline checks for signature-based BACKUP on the stock-derived framework."""
import re
import sys
from pathlib import Path

METHOD = re.compile(r'(?ms)^\.method [^\n]+\n.*?^\.end method')
ELEMENT = re.compile(r'^(\s*)E: permission \(line=')


def find_backup_permission(xmltree):
    lines = xmltree.splitlines()
    for i, line in enumerate(lines):
        hit = ELEMENT.match(line)
        if not hit:
            continue
        indent = len(hit.group(1))
        end = i + 1
        while end < len(lines):
            next_element = re.match(r'^(\s*)E: ', lines[end])
            if next_element and len(next_element.group(1)) <= indent:
                break
            end += 1
        block = '\n'.join(lines[i:end])
        if '"android.permission.BACKUP"' in block:
            return block
    raise ValueError('BACKUP permission declaration not found')


def method(path, name):
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    hits = [m for m in METHOD.findall(text) if re.search(r'\b' + re.escape(name) + r'\(', m.splitlines()[0])]
    if len(hits) != 1:
        raise ValueError('Expected one ' + name + ' method, got ' + str(len(hits)))
    return hits[0]


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: inspect_backup_signature_static.py FRAMEWORK_XMLTREE PACKAGE_MANAGER_SMALI BACKUP_MANAGER_SMALI')
    xml, pm, backup = map(Path, sys.argv[1:])
    print('# Stock-derived framework permission and backup service, static inspection')
    print('No device or firmware application was run; grants and UI behavior on the actual head unit remain unverified.')
    print('\n## android.permission.BACKUP declaration')
    print(find_backup_permission(xml.read_text(encoding='utf-8', errors='replace')))
    print('\n## grantSignaturePermission')
    print(method(pm, 'grantSignaturePermission'))
    print('\n## grantPermissionsLPw context around grantSignaturePermission')
    text = method(pm, 'grantPermissionsLPw').splitlines()
    indices = [i for i, line in enumerate(text) if '->grantSignaturePermission(' in line]
    if not indices:
        raise ValueError('No signature permission grant call found')
    for i in indices:
        print('\n'.join(text[max(0, i-55):min(len(text), i+60)]))
    print('\n## fullBackup permission / confirmation path')
    print(method(backup, 'fullBackup'))
    print('\nStatic code does not prove the permission is granted or an archive can be saved or restored on the head unit.')


if __name__ == '__main__':
    main()

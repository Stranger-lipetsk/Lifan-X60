#!/usr/bin/env python3
"""Inspect stock storage permission definitions and group mappings offline."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PERMISSIONS = ('android.permission.READ_EXTERNAL_STORAGE',
               'android.permission.WRITE_EXTERNAL_STORAGE',
               'android.permission.WRITE_MEDIA_STORAGE',
               'android.permission.MOUNT_UNMOUNT_FILESYSTEMS')
ELEMENT = re.compile(r'^(\s*)E: permission \(line=')


def definition(xmltree, name):
    lines = xmltree.splitlines()
    matches = []
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
        if f'"{name}"' in block:
            matches.append(block)
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one declaration of {name}, found {len(matches)}')
    return matches[0]


def mappings(directory, names=PERMISSIONS):
    found = {name: [] for name in names}
    for path in sorted(Path(directory).glob('*.xml')):
        root = ET.parse(path).getroot()
        for element in root.findall('permission'):
            name = element.get('name')
            if name in found:
                groups = [item.get('gid') for item in element.findall('group')]
                if any(not group for group in groups):
                    raise ValueError('Missing group gid in ' + path.name)
                found[name].append((path.name, groups))
    return found


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: inspect_stock_storage_permissions.py FRAMEWORK_XMLTREE PERMISSIONS_DIR')
    xml = Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace')
    groups = mappings(sys.argv[2])
    print('# Stock-derived storage permissions and supplementary GID mappings (static)')
    print('Not a runtime permission grant, USB mount or write test; no device modified.')
    for name in PERMISSIONS:
        print('\n##', name)
        print(definition(xml, name))
        for filename, gids in groups[name]:
            print('Mapping:', filename, 'groups:', ', '.join(gids) or '(none)')
        if not groups[name]:
            print('No explicit group mapping in extracted permission XML files.')
    print('\nAccess also depends on actual USB mounts, modes, groups and SELinux at runtime.')


if __name__ == '__main__':
    main()

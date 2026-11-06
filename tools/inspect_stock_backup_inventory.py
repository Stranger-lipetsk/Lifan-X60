#!/usr/bin/env python3
"""Read-only stock APK manifest inventory; not a device backup or eligibility guarantee."""
import argparse
from collections import Counter
from pathlib import Path
import re
import subprocess

ATTR = re.compile(r'^\s*A: (?:android:)?([\w]+)(?:\([^)]*\))?=(.*)$')
ELEMENT = re.compile(r'^(\s*)E: ([\w-]+)\b')
QUOTED = re.compile(r'^"([^"]*)"')


def parse_manifest(text):
    stack = []
    attrs = {'manifest': {}, 'application': {}}
    counts = Counter()
    for line in text.splitlines():
        elem = ELEMENT.match(line)
        if elem:
            indent, name = len(elem.group(1)), elem.group(2)
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, name))
            if name in attrs and ((name == 'manifest' and len(stack) == 1) or
                                  (name == 'application' and len(stack) == 2 and stack[0][1] == 'manifest')):
                counts[name] += 1
            continue
        attr = ATTR.match(line)
        if not attr or not stack:
            continue
        names = tuple(x[1] for x in stack)
        if names not in [('manifest',), ('manifest', 'application')]:
            continue
        key, value = attr.groups()
        current = attrs[names[-1]]
        if key in current:
            raise ValueError('duplicate manifest attribute: ' + key)
        current[key] = value
    if counts['manifest'] != 1 or counts['application'] != 1:
        raise ValueError('expected one manifest and application element')
    def string(key, source):
        value = attrs[source].get(key)
        if value is None:
            return None
        match = QUOTED.match(value)
        return match.group(1) if match else '?'  # resources or unresolved values
    package = string('package', 'manifest')
    if not package or package == '?':
        raise ValueError('missing or unresolved package')
    raw = attrs['application'].get('allowBackup')
    if raw is None:
        allowed = 'default-true'
    elif re.match(r'^\(type 0x12\)0x0+(?:\s|$)', raw):
        allowed = 'false'
    elif re.match(r'^\(type 0x12\)0x[fF]{8}(?:\s|$)', raw):
        allowed = 'true'
    else:
        allowed = 'unknown'
    return package, allowed, string('sharedUserId', 'manifest') or '-', string('backupAgent', 'application') or '-'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('aapt')
    parser.add_argument('dirs', nargs='+', type=Path)
    args = parser.parse_args()
    files = sorted(p for directory in args.dirs for p in directory.rglob('*.apk'))
    if not files:
        raise SystemExit('No APK files found')
    print('# Static APK backup inventory in stock-derived system image')
    print('Manifest declarations only; no device, user applications, app data or actual backup tested.')
    print('For all-apps backup, system apps require includeSystem; allowBackup=false is excluded.')
    print('Stock framework also filters UID < 10000 without a backup agent; a declared shared UID is not proof of runtime UID.')
    print('Default true is the Android 4.4 manifest default, not proof of backup contents or successful restore.')
    print('APK path | package | allowBackup | sharedUserId | backupAgent')
    errors = []
    counts = Counter()
    for path in files:
        try:
            result = subprocess.run([args.aapt, 'dump', 'xmltree', str(path), 'AndroidManifest.xml'], check=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=45)
            package, allowed, shared, agent = parse_manifest(result.stdout)
            counts[allowed] += 1
            print(f'{path.parent.name}/{path.name} | {package} | {allowed} | {shared} | {agent}')
        except (ValueError, subprocess.SubprocessError) as exc:
            errors.append((path.name, str(exc)))
            print(f'{path.parent.name}/{path.name} | UNREADABLE | unknown | - | -')
    print('\nCounts:', dict(sorted(counts.items())), 'unreadable:', len(errors), 'total APKs:', len(files))
    for name, error in errors:
        print('Error:', name, error)
    print('No inference about third-party apps or absent packages is possible from this image.')
    if errors:
        raise SystemExit('Unreadable manifest(s); see report')


if __name__ == '__main__':
    main()

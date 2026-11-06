#!/usr/bin/env python3
"""Read-only APK manifest and framework backup eligibility investigation."""
import re
import subprocess
import sys
from pathlib import Path

METHOD = re.compile(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$')
INTEREST = re.compile(r'(?i)(?:adbBackup|fullBackup|fullRestore|backupOnePackage|'
                      r'BackupManagerService\$PerformAdbBackupTask|BackupManagerService\$PerformAdbRestoreTask|'
                      r'0x8000|allowBackup|signaturesMatch|access\$1900)')


def application_manifest(aapt, apk):
    def run(*args):
        result = subprocess.run([aapt, 'dump', *args, str(apk)], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return result.stdout
    print('\n##', apk.name)
    badging = run('badging')
    for line in badging.splitlines():
        if line.startswith(('package:', 'sdkVersion:', 'targetSdkVersion:', 'uses-permission:')):
            print(line)
    xml = subprocess.run([aapt, 'dump', 'xmltree', str(apk), 'AndroidManifest.xml'],
                         check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout
    lines = xml.splitlines()
    found = False
    for i, line in enumerate(lines):
        if re.match(r'^\s*E: application\b', line):
            found = True
            print('### application element and attributes')
            print(line)
            for attr in lines[i + 1:]:
                if re.match(r'^\s*E:', attr):
                    break
                print(attr)
            break
    if not found:
        raise RuntimeError('Application element missing: ' + str(apk))
    print('### Backup-related attributes, receivers or services (any element)')
    hits = [line for line in lines if re.search(r'(?i)allowBackup|backupAgent|backupInForeground|fullBackup|BackupAgent|BackupService|sharedUserId', line)]
    print('\n'.join(hits) if hits else '(none explicitly present)')
    print('Attribute absence requires applying Android API 19 defaults; it is not proof of a successful backup.')


def scan_framework(decoded):
    root = Path(decoded) / 'smali/com/android/server'
    files = sorted(root.rglob('*Backup*.smali'))
    if not files:
        raise RuntimeError('No backup manager smali found')
    print('\n# Stock backup framework selected methods; static code only')
    selected = 0
    for path in files:
        methods = METHOD.findall(path.read_text(encoding='utf-8', errors='replace'))
        for method in methods:
            if not INTEREST.search(method):
                continue
            selected += 1
            print('\n##', path.relative_to(root), method.splitlines()[0])
            lines = method.splitlines()
            if len(lines) > 2500:
                print(f'Method length {len(lines)}; first 2500 lines shown')
            print('\n'.join(lines[:2500]))
    print('\nSelected methods:', selected)
    if not selected:
        raise RuntimeError('No framework methods selected')
    print('No Android command or firmware code was run. Static eligibility is not a tested recovery.')


def show_agent(decoded):
    root = Path(decoded)
    agents = sorted(root.glob('smali*/**/SharedInfoBackupAgent.smali'))
    print('\n# Declared Navitel backup agent:', root.name)
    if len(agents) != 1:
        raise RuntimeError(f'Expected exactly one agent, found {len(agents)}')
    print('Path:', agents[0].relative_to(root))
    print(agents[0].read_text(encoding='utf-8', errors='replace'))
    print('Agent name or implementation alone does not prove backup contents or restoration.')


def main():
    if len(sys.argv) != 8:
        raise SystemExit('usage: inspect_backup_feasibility.py AAPT DECODED_SERVICES OLD_APK NEW_APK AMAZE_APK OLD_DECODED NEW_DECODED')
    aapt, decoded, old, new, amaze, old_decoded, new_decoded = sys.argv[1:]
    apks = [old, new, amaze]
    print('# Stock ADB backup feasibility: static investigation only')
    print('No real device data, Navitel license, SD card or Android command used.')
    for apk in apks:
        application_manifest(aapt, Path(apk))
    scan_framework(decoded)
    show_agent(old_decoded)
    show_agent(new_decoded)


if __name__ == '__main__':
    main()

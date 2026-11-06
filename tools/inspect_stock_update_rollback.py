#!/usr/bin/env python3
"""Read the stock PackageManager downgrade/removal methods without executing Android."""
import sys
from pathlib import Path
try:
    from tools.inspect_backup_signature_static import method
except ModuleNotFoundError:
    from inspect_backup_signature_static import method


def report(path):
    delete_system = method(path, 'deleteSystemPackageLI')
    delete_installed = method(path, 'deleteInstalledPackageLI')
    for needle in ('->versionCode:I', '->deleteInstalledPackageLI(', '->enableSystemPackageLPw('):
        if needle not in delete_system:
            raise ValueError('Expected stock rollback reference absent: ' + needle)
    return delete_system, delete_installed


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: inspect_stock_update_rollback.py PACKAGE_MANAGER_SMALI')
    system, installed = report(Path(sys.argv[1]))
    print('# Stock-derived PackageManager rollback code (static analysis only)')
    print('No device or APK executed; see control flow and flag logic, not a runtime test.')
    print('\n## deleteSystemPackageLI\n' + system)
    print('\n## deleteInstalledPackageLI\n' + installed)
    print('\nAn app update or its rollback is not a full data backup. Actual device state and behavior remain untested.')


if __name__ == '__main__':
    main()

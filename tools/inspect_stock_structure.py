#!/usr/bin/env python3
"""Read-only static inspection of stock APK identity, certificates and USB script."""
import hashlib
import re
import subprocess
import sys
from pathlib import Path


def run(args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main():
    apkdir, aapt, apksigner, usb = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
    print('# Stock components: manifest, APK signatures and USB readiness')
    print('Static evidence only: file presence does not prove installation or UI reachability.')
    for apk in sorted(apkdir.glob('*.apk')):
        print('\n##', apk.name)
        print('sha256:', hashlib.sha256(apk.read_bytes()).hexdigest())
        result = run([aapt, 'dump', 'badging', str(apk)])
        if result.returncode:
            raise SystemExit('aapt badging failed for ' + apk.name)
        for line in result.stdout.splitlines():
            if line.startswith(('package:', 'sdkVersion:', 'targetSdkVersion:', 'launchable-activity:')):
                print(line)
        result = run([aapt, 'dump', 'xmltree', str(apk), 'AndroidManifest.xml'])
        if result.returncode:
            raise SystemExit('manifest dump failed for ' + apk.name)
        for line in result.stdout.splitlines():
            if re.search(r'android:(sharedUserId|debuggable)\(', line):
                print(line.strip())
        result = run([apksigner, 'verify', '--verbose', '--print-certs',
                      '--min-sdk-version', '19', '--max-sdk-version', '19', str(apk)])
        print('apksigner API19 exit:', result.returncode)
        for line in result.stdout.splitlines():
            if ('Verified using v1' in line or 'Signer #' in line and 'SHA-256 digest' in line
                    or line.startswith(('ERROR', 'DOES NOT VERIFY', 'WARNING'))):
                print(line)
    print('\n## /system/bin/check_usb_iface.sh')
    if not usb.is_file():
        print('Not extracted: no conclusion about absence or runtime behavior.')
        return
    lines = usb.read_text(errors='replace').splitlines()
    print('SHA-256:', hashlib.sha256(usb.read_bytes()).hexdigest())
    keys = ('NOTIFICATION_USB_IFACE_', '/sys/class/net/usbH0', 'netcfg usbH0',
            'dhcpcd usbH0', 'am broadcast', 'IFACE_IS_DOWN')
    for i, line in enumerate(lines, 1):
        if any(key in line for key in keys):
            print(f'{i}: {line.strip()}')
    print('Presence of this script does not prove it starts or that any phone is compatible.')


if __name__ == '__main__':
    main()

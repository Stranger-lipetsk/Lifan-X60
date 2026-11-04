#!/usr/bin/env python3
"""Read-only inspection of the stock AUX launch path and original AUX APK."""
import hashlib
import re
import subprocess
import sys
from pathlib import Path


def main():
    root, apk, aapt, apksigner = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    if not apk.is_file():
        raise SystemExit('Original AUX APK missing')
    print('# Stock AUX launcher path; static evidence, not an on-device trace')
    print('AUX APK sha256:', hashlib.sha256(apk.read_bytes()).hexdigest())
    for args, label in [([aapt, 'dump', 'badging', str(apk)], 'badging'),
                        ([apksigner, 'verify', '--verbose', '--print-certs', '--min-sdk-version', '19', '--max-sdk-version', '19', str(apk)], 'signature')]:
        result = subprocess.run(args, capture_output=True, text=True)
        print('\n## AUX', label, 'exit:', result.returncode)
        for line in (result.stdout + result.stderr).splitlines():
            if line.startswith(('package:', 'sdkVersion:', 'targetSdkVersion:', 'launchable-activity:',
                                'uses-permission:', 'Verified using v1', 'V1 Signer: certificate SHA-256',
                                'ERROR', 'DOES NOT VERIFY')):
                print(line)
    proc = subprocess.run([aapt, 'dump', 'xmltree', str(apk), 'AndroidManifest.xml'], capture_output=True, text=True)
    if proc.returncode:
        raise SystemExit('Cannot inspect AUX manifest')
    print('\n## AUX manifest component/action attributes')
    for line in proc.stdout.splitlines():
        if re.search(r'android:(name|sharedUserId|exported|permission)\(', line):
            print(line.strip())
    for name in ('HomeApp.smali', 'Home.smali', 'ApplicationInfo.smali', 'HomeService.smali'):
        path = root / 'smali/tw/com/elead/el830/home' / name
        if not path.is_file():
            raise SystemExit(f'Missing {path}')
        text = path.read_text(errors='replace')
        methods = re.findall(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$', text)
        for method in methods:
            sig = method.splitlines()[0]
            selected = ('tw.com.elead.el830.avin' in method or
                        name == 'HomeApp.smali' and any(x in sig for x in ('gotoEleadApplication(', 'findMainActivityForPackage(')) or
                        name == 'Home.smali' and 'switchNewMode(' in sig or
                        name == 'ApplicationInfo.smali' and ' setActivity(' in sig)
            if not selected:
                continue
            lines = method.splitlines()
            print('\n##', name, sig, 'lines:', len(lines))
            if len(lines) <= 800:
                print(method)
            else:
                indices = [i for i, line in enumerate(lines) if 'tw.com.elead.el830.avin' in line]
                if not indices:
                    print('Long method; no targeted AUX context found.')
                for i in indices[:10]:
                    print('\n-- context at method line', i+1)
                    print('\n'.join(lines[max(0, i-70):min(len(lines), i+135)]))
    print('\nNo modification or firmware image was produced.')


if __name__ == '__main__':
    main()

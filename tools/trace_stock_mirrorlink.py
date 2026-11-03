#!/usr/bin/env python3
"""Inspect static MirrorLink readiness and home-screen launch code, read-only."""
import re
import sys
from pathlib import Path


def main():
    root = Path(sys.argv[1])
    print('# Stock MirrorLink readiness and launch: static code only')
    print('No conclusions about device behavior can be made without runtime evidence.')
    for app in ('Home', 'MirrorLink'):
        appdir = root / app
        if not appdir.is_dir():
            raise SystemExit(f'Missing {appdir}')
        selected = []
        for path in sorted(appdir.rglob('*.smali')):
            if '/android/support/' in path.as_posix():
                continue
            text = path.read_text(errors='replace')
            for method in re.findall(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$', text):
                sig = method.splitlines()[0]
                keywords = ('vn.com.fsoft.UsbIfaceReady', 'vn.com.fsoft.UsbIfaceDown',
                            '->enableMirrorLinkIcon(')
                if any(k in method for k in keywords) or ' enableMirrorLinkIcon(' in sig:
                    selected.append((path, method, 'readiness'))
                elif app == 'Home' and path.name == 'Home.smali' and ' onClick(' in sig:
                    selected.append((path, method, 'launcher click'))
        print('\n##', app, 'selected methods:', len(selected))
        for path, method, reason in selected:
            lines = method.splitlines()
            print('\n###', path.relative_to(appdir), reason, lines[0], 'lines:', len(lines))
            if len(lines) <= 900:
                print(method)
            else:
                needles = ('vn.com.fsoft.UsbIfaceReady', 'vn.com.fsoft.UsbIfaceDown',
                           '->enableMirrorLinkIcon(', 'com.fpt.mirrorlink.android',
                           'isEnabled', '->enabled:Z', '->enable:Z', 'getEnableEleadApplication')
                indices = [i for i, line in enumerate(lines) if any(s in line for s in needles)]
                if not indices:
                    print('Large method; no matching context found.')
                last = -1
                for i in indices:
                    if i <= last:
                        continue
                    lo, hi = max(0, i-70), min(len(lines), i+100)
                    print('\n--- context at method line', i+1)
                    print('\n'.join(lines[lo:hi]))
                    last = hi - 1


if __name__ == '__main__':
    main()

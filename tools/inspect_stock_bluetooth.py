#!/usr/bin/env python3
"""Extract static Bluetooth OPP/profile clues; this does not test running hardware."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
print('# Bluetooth.apk static profile / object-push inspection')
print('Presence and static flags do not prove runtime activation, pairing or file transfer.')
files = sorted(root.rglob('*.smali'))
if not files:
    raise SystemExit('Bluetooth smali missing')
print('Smali files:', len(files))
for path in files:
    if re.search(r'BluetoothOpp|OppService|AdapterService|Config\.smali|ProfileService', path.name):
        print('\n##', path.relative_to(root))
        text = path.read_text(errors='replace')
        for match in re.finditer(r'(?ms)^\.method [^\n]+\n.*?^\.end method', text):
            method = match.group()
            head = method.splitlines()[0]
            if re.search(r'\b(onCreate|onStartCommand|start|init|isSupported|isAvailable|check|listen|accept|enable|disable|startRfcommSocketListener|parse)\b|<clinit>', head, re.I) or re.search(r'(OBEX|OPP|BluetoothOppService|isEnabled|setComponentEnabledSetting|listenUsing|listenUsingInsecure)', method, re.I):
                lines = method.splitlines()
                print('\n'.join(lines[:200]))
                if len(lines) > 200:
                    print('... method truncated')
print('\n# Selected strings in profile configuration and OPP classes')
for path in files:
    if re.search(r'(Config|AdapterService|BluetoothOpp|OppService)', path.name):
        for i, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
            if re.search(r'(profile_supported|OppService|ObexObjectPush|OPP|isEnabled|setComponentEnabledSetting)', line, re.I):
                print(f'{path.relative_to(root)}:{i}: {line.strip()}')

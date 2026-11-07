#!/usr/bin/env python3
"""Validate only disposable emulator UI snapshots; not a device utility."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _rounded_size_kib(value):
    match = re.fullmatch(r'(\d+(?:\.\d+)?)([KMG])', value)
    if not match:
        raise ValueError('Unexpected Android toolbox df unit: ' + value)
    return float(match.group(1)) * {'K': 1, 'M': 1024, 'G': 1024 * 1024}[match.group(2)]


def validate(xml_text, mounts_text, df_text):
    root = ET.fromstring(xml_text)
    texts = [node.attrib.get('text', '') for node in root.iter()]
    candidates = [text for text in texts if 'PROBE_MOUNTS_BEGIN' in text]
    if len(candidates) != 1:
        raise ValueError('Probe text not uniquely visible in UI')
    view = candidates[0]
    if 'LAB ONLY' not in view or 'STATFS_UNAVAILABLE' in view or 'MOUNTS_UNAVAILABLE' in view:
        raise ValueError('Probe unavailable or missing emulator-only guard')
    values = {}
    for field in ('TOTAL_KIB', 'FREE_KIB', 'AVAILABLE_KIB'):
        matches = re.findall(r'(?m)^' + field + r'=(\d+)$', view)
        if len(matches) != 1:
            raise ValueError('Missing or duplicated ' + field)
        values[field] = int(matches[0])
    if not (values['TOTAL_KIB'] > 0 and 0 <= values['AVAILABLE_KIB'] <= values['FREE_KIB'] <= values['TOTAL_KIB']):
        raise ValueError('Impossible statfs values')
    data_mounts = [line.split()[:4] for line in mounts_text.splitlines() if len(line.split()) >= 4 and line.split()[1] == '/data']
    if len(data_mounts) != 1:
        raise ValueError('Expected a single /data mount in emulator shell namespace')
    mount_line = ' '.join(data_mounts[0])
    if mount_line not in view.splitlines():
        raise ValueError('Probe /data mount differs from shell: ' + mount_line)
    df_lines = [line.split() for line in df_text.splitlines() if line.split() and line.split()[0] == '/data']
    if len(df_lines) != 1 or len(df_lines[0]) < 5:
        raise ValueError('Unexpected Android toolbox df output')
    total, free = _rounded_size_kib(df_lines[0][1]), _rounded_size_kib(df_lines[0][3])
    # Toolbox rounds to a tenth of a unit; usage may also change between reads.
    if abs(total - values['TOTAL_KIB']) > max(128, total * 0.001):
        raise ValueError('Total does not agree with df')
    if abs(free - values['FREE_KIB']) > 16384:
        raise ValueError('Free space does not reasonably agree with df')
    return values, mount_line


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: validate_storage_probe_ui.py ui.xml mounts.txt df.txt')
    values, mount = validate(*(Path(path).read_text(encoding='utf-8') for path in sys.argv[1:]))
    print('UI values:', values)
    print('UI mount matches shell:', mount)
    print('df total and free agree within rounding/measurement tolerance; available <= free <= total.')
    print('This does not independently validate available blocks or real-device behavior.')


if __name__ == '__main__':
    main()

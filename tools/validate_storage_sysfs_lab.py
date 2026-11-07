#!/usr/bin/env python3
"""Cross-check a fixed emulated block-device capacity; never inspect real devices."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def validate(ui, shell_sectors, partitions):
    root = ET.fromstring(ui)
    matches = [n.attrib.get('text', '') for n in root.iter() if 'PROBE_MOUNTS_BEGIN' in n.attrib.get('text', '')]
    if len(matches) != 1:
        raise ValueError('Expected exactly one probe view')
    view = matches[0]
    sd = re.findall(r'(?m)^LAB_SD_CAPACITY_BYTES=(UNKNOWN|[0-9]+)$', view)
    p5 = re.findall(r'(?m)^P5_CAPACITY_BYTES=(UNKNOWN|[0-9]+)$', view)
    if len(sd) != 1 or len(p5) != 1:
        raise ValueError('Missing or duplicated capacity field')
    sectors = shell_sectors.strip()
    if not sectors.isdigit():
        if sd[0] != 'UNKNOWN':
            raise ValueError('App claims capacity while shell cannot read device')
        return 'Virtual mmcblk0 absent/unreadable to shell and probe; capacity UNKNOWN.'
    size = int(sectors) * 512
    parts = [line.split() for line in partitions.splitlines() if len(line.split()) == 4 and line.split()[3] == 'mmcblk0']
    if len(parts) != 1 or int(parts[0][2]) * 1024 != size:
        raise ValueError('Emulator /proc/partitions does not match sysfs')
    if sd[0] == 'UNKNOWN':
        return f'Virtual mmcblk0 size {size} bytes visible to shell but UNKNOWN to app; real p5 still unknown.'
    if int(sd[0]) != size:
        raise ValueError('App capacity disagrees with sysfs and /proc/partitions')
    return f'Virtual mmcblk0 size: {size} bytes; app, shell sysfs and /proc/partitions agree. Not physical p5. Probe p5: {p5[0]}.'


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: validate_storage_sysfs_lab.py ui.xml sectors.txt partitions.txt')
    print(validate(*(Path(p).read_text(encoding='utf-8') for p in sys.argv[1:])))


if __name__ == '__main__':
    main()

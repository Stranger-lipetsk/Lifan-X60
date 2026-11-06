#!/usr/bin/env python3
"""Find an explicit AOSP backup confirmation button in lab emulator XML."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def coordinates(path, expected):
    root = ET.fromstring(Path(path).read_bytes())
    matches = []
    for node in root.iter('node'):
        if node.get('text', '').strip().casefold() != expected.casefold():
            continue
        if node.get('enabled') != 'true' or node.get('clickable') != 'true':
            continue
        bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
        if not bounds:
            continue
        x1, y1, x2, y2 = map(int, bounds.groups())
        if x2 > x1 and y2 > y1:
            matches.append(((x1 + x2) // 2, (y1 + y2) // 2))
    if len(matches) != 1:
        raise ValueError('Expected exactly one enabled clickable confirmation button')
    return matches[0]


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: emulator_backup_confirmation.py XML EXPECTED_BUTTON_TEXT')
    x, y = coordinates(sys.argv[1], sys.argv[2])
    print(x, y)


if __name__ == '__main__':
    main()

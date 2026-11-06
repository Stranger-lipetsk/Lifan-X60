#!/usr/bin/env python3
"""Locate a unique enabled clickable ancestor of an exact text in emulator UI XML."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def coordinates(data, text):
    root = ET.fromstring(data)
    parents = {child: parent for parent in root.iter() for child in parent}
    matches = set()
    for node in root.iter('node'):
        if node.get('text', '').strip() != text:
            continue
        current = node
        while current is not None and current.tag == 'node':
            if current.get('enabled') == 'true' and current.get('clickable') == 'true':
                bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', current.get('bounds', ''))
                if bounds:
                    x1, y1, x2, y2 = map(int, bounds.groups())
                    if x2 > x1 and y2 > y1:
                        matches.add(((x1+x2)//2, (y1+y2)//2))
                break
            current = parents.get(current)
    if len(matches) != 1:
        raise ValueError('expected exactly one enabled clickable target for the exact filename')
    return next(iter(matches))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: emulator_ui_clickable.py XML EXACT_TEXT')
    print(*coordinates(Path(sys.argv[1]).read_bytes(), sys.argv[2]))

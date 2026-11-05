#!/usr/bin/env python3
"""Remove one HOME category from a known Launcher2 binary manifest, offline only.

Not an installer; preserve the stock component and other filters. The caller
must verify the source APK digest and independently validate the result.
"""
import argparse
import struct
from dataclasses import dataclass, field
from pathlib import Path

HOME = 'android.intent.category.HOME'
ACTIVITY = 'com.android.launcher2.Launcher'
PACKAGE = 'com.android.launcher'
NO_INDEX = 0xffffffff


def u16(data, offset):
    return struct.unpack_from('<H', data, offset)[0]


def u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def length8(data, offset):
    val = data[offset]
    if val & 0x80:
        return ((val & 0x7f) << 8) | data[offset + 1], offset + 2
    return val, offset + 1


def length16(data, offset):
    val = u16(data, offset)
    if val & 0x8000:
        return ((val & 0x7fff) << 16) | u16(data, offset + 2), offset + 4
    return val, offset + 2


def strings_from_pool(data, offset, size):
    if u16(data, offset + 2) < 28 or size < 28:
        raise ValueError('invalid string pool header')
    count, styles, flags, start, style_start = struct.unpack_from('<IIIII', data, offset + 8)
    header = u16(data, offset + 2)
    if count > 100000 or header + 4 * (count + styles) > size or start >= size:
        raise ValueError('invalid string pool indexes')
    values = []
    for i in range(count):
        at = offset + start + u32(data, offset + header + i * 4)
        if at >= offset + size:
            raise ValueError('string offset outside pool')
        if flags & 0x100:
            _, at = length8(data, at)
            byte_len, at = length8(data, at)
            end = at + byte_len
            if end >= offset + size or data[end] != 0:
                raise ValueError('invalid UTF-8 string terminator')
            values.append(data[at:end].decode('utf8'))
        else:
            chars, at = length16(data, at)
            end = at + 2 * chars
            if end + 2 > offset + size or u16(data, end) != 0:
                raise ValueError('invalid UTF-16 string terminator')
            values.append(data[at:end].decode('utf-16le'))
    return values


@dataclass
class Element:
    name: str
    attrs: dict
    start: int
    after_start: int
    end: int = 0
    children: list = field(default_factory=list)

    def semantic(self):
        return (self.name, self.attrs, [child.semantic() for child in self.children])


def parse(data):
    if len(data) < 8 or u16(data, 0) != 3 or u16(data, 2) != 8 or u32(data, 4) != len(data):
        raise ValueError('invalid binary XML root')
    pos, strings, stack, roots = 8, None, [], []
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError('truncated chunk')
        kind, header, size = struct.unpack_from('<HHI', data, pos)
        if header < 8 or size < header or size % 4 or pos + size > len(data):
            raise ValueError('invalid chunk bounds')
        if kind == 1:
            if strings is not None:
                raise ValueError('duplicate string pool')
            strings = strings_from_pool(data, pos, size)
        elif kind == 0x102:
            if strings is None or header != 16 or size < 36:
                raise ValueError('invalid start element')
            ext = pos + header
            ns, name_id, attr_start, attr_size, attr_count = struct.unpack_from('<IIHHH', data, ext)
            if name_id >= len(strings) or attr_size < 20 or attr_start < 20:
                raise ValueError('invalid element attributes')
            begin = ext + attr_start
            if begin + attr_size * attr_count > pos + size:
                raise ValueError('attributes exceed chunk')
            attrs = {}
            for i in range(attr_count):
                attr = begin + i * attr_size
                _, attr_name, raw = struct.unpack_from('<III', data, attr)
                if attr_name >= len(strings) or u16(data, attr + 12) != 8:
                    raise ValueError('invalid attribute')
                typ, value = data[attr + 15], u32(data, attr + 16)
                key = strings[attr_name]
                if key in attrs:
                    raise ValueError('duplicate attribute name')
                if raw != NO_INDEX:
                    if raw >= len(strings): raise ValueError('invalid raw string')
                    value = strings[raw]
                elif typ == 3:
                    if value >= len(strings): raise ValueError('invalid typed string')
                    value = strings[value]
                else:
                    value = (typ, value)
                attrs[key] = value
            node = Element(strings[name_id], attrs, pos, pos + size)
            if stack: stack[-1].children.append(node)
            else: roots.append(node)
            stack.append(node)
        elif kind == 0x103:
            if not stack or strings is None or header != 16 or size < 24:
                raise ValueError('invalid end element')
            name_id = u32(data, pos + header + 4)
            if name_id >= len(strings) or stack[-1].name != strings[name_id]:
                raise ValueError('mismatched end element')
            stack.pop().end = pos + size
        pos += size
    if stack or len(roots) != 1 or roots[0].name != 'manifest':
        raise ValueError('invalid element nesting')
    return roots[0]


def walk(node, parents=()):
    yield node, parents
    for child in node.children:
        yield from walk(child, parents + (node,))


def remove_home(data):
    root = parse(data)
    if root.attrs.get('package') != PACKAGE:
        raise ValueError('unexpected launcher package')
    found = [(node, parents) for node, parents in walk(root)
             if node.name == 'category' and node.attrs.get('name') == HOME]
    if len(found) != 1:
        raise ValueError(f'expected one HOME category, got {len(found)}')
    node, parents = found[0]
    if [p.name for p in parents] != ['manifest', 'application', 'activity', 'intent-filter']:
        raise ValueError('HOME category in unexpected location')
    if parents[-2].attrs.get('name') != ACTIVITY:
        raise ValueError('HOME category in unexpected activity')
    siblings = parents[-1].children
    if not any(n.name == 'action' and n.attrs.get('name') == 'android.intent.action.MAIN' for n in siblings):
        raise ValueError('HOME filter missing MAIN')
    if not any(n.name == 'category' and n.attrs.get('name') == 'android.intent.category.DEFAULT' for n in siblings):
        raise ValueError('HOME filter missing DEFAULT')
    if node.children or node.end <= node.after_start or node.after_start + 24 != node.end:
        raise ValueError('category is not an empty adjacent element')
    parents[-1].children.remove(node)
    expected = root.semantic()
    result = bytearray(data[:node.start] + data[node.end:])
    struct.pack_into('<I', result, 4, len(result))
    if parse(bytes(result)).semantic() != expected:
        raise ValueError('unexpected semantic change')
    return bytes(result)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    result = remove_home(args.input.read_bytes())
    args.output.write_bytes(result)
    print('One HOME category removed; activity and other manifest elements preserved. NOT DEVICE TESTED.')


if __name__ == '__main__':
    main()

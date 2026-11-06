#!/usr/bin/env python3
"""Compare public APK storage hints, without licenses, maps or executing APKs."""
import re
import sys
import zipfile
from pathlib import Path

MAX_ENTRY = 128 * 1024 * 1024
HINT = re.compile(rb'(?i)navitelcontent|\.nm7\b|license\.txt|activation\.key')


def inspect(apk):
    hits = []
    skipped = []
    count = 0
    with zipfile.ZipFile(apk) as archive:
        for item in archive.infolist():
            name = item.filename
            is_dex = bool(re.fullmatch(r'classes\d*\.dex', name))
            is_arm = name.startswith(('lib/armeabi/', 'lib/armeabi-v7a/')) and name.endswith('.so')
            # Localized catalogs often duplicate one English source string.
            is_resource = (name == 'resources.arsc' or
                           (name.startswith('assets/') and
                            (not name.endswith('.mo') or name.endswith(('en_US.mo', 'ru_RU.mo')))))
            if item.is_dir() or not (is_dex or is_arm or is_resource):
                continue
            if item.file_size > MAX_ENTRY:
                skipped.append(name)
                continue
            data = archive.read(item)
            count += 1
            tokens = sorted({match.group().decode('ascii').lower() for match in HINT.finditer(data)})
            if not tokens:
                continue
            examples = []
            for text in re.findall(rb'[\x20-\x7e]{4,}', data):
                if HINT.search(text) and len(text) <= 160:
                    decoded = text.decode('ascii')
                    if decoded not in examples:
                        examples.append(decoded)
                if len(examples) >= 20:
                    break
            hits.append((name, tokens, examples))
    return hits, skipped, count


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: inspect_navitel_sd_static.py OLD_APK NEW_APK')
    print('# Old and new Navitel APKs: static SD-related strings')
    print('Only APK files were read. No user license, maps, device, or app execution.')
    print('ASCII evidence only from selected DEX, ARM libraries, assets and resources; localized catalogs are limited to en_US/ru_RU.')
    print('Application strings are not instructions to change anything; absence is not proof.')
    for label, path in [('old', Path(sys.argv[1])), ('new', Path(sys.argv[2]))]:
        print('\n##', label)
        hits, skipped, count = inspect(path)
        print('Selected entries scanned:', count, 'skipped oversized:', len(skipped))
        for name in skipped:
            print('SKIPPED:', name)
        for entry, tokens, examples in hits:
            print('\nEntry:', entry, '| hints:', ', '.join(tokens))
            for example in examples:
                print('  ', example)
    print('\nA string does not prove a file is searched, license accepted, map compatibility or actual SD paths.')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Find possible routes from the stock Navitel UI; static clues only."""
import re
import sys
from pathlib import Path

PATTERNS = [
    ('intent actions', re.compile(r'android\.intent\.action\.(VIEW|GET_CONTENT|OPEN_DOCUMENT|INSTALL_PACKAGE)')),
    ('settings and package installer', re.compile(r'android\.settings\.|vnd\.android\.package-archive|com\.android\.packageinstaller|\.apk\b', re.I)),
    ('browser and help', re.compile(r'com\.android\.browser|android\.webkit\.WebView|shouldOverrideUrlLoading', re.I)),
]


def main():
    root = Path(sys.argv[1])
    files = sorted(root.rglob('*.smali'))
    if not files:
        raise SystemExit('No Navitel smali files found')
    print('# Navitel stock: possible UI exit routes; static search only')
    print('A match does not prove that a screen, browser or installer is reachable.')
    print('Files:', len(files))
    for label, pattern in PATTERNS:
        hits = []
        for path in files:
            lines = path.read_text(errors='replace').splitlines()
            sig = '(outside method)'
            for i, line in enumerate(lines):
                if line.startswith('.method '):
                    sig = line
                if pattern.search(line):
                    hits.append((path.relative_to(root), i, sig, lines))
                if line.startswith('.end method'):
                    sig = '(outside method)'
        print('\n##', label, 'matches:', len(hits))
        for path, i, sig, lines in hits[:30]:
            print('\n###', path, 'line', i+1, sig)
            # Avoid logging URLs, tokens, or app-specific data by printing
            # only class/method location and matching instruction.
            print(lines[i].strip()[:250])
        if len(hits) > 30:
            print('... first 30 shown')
    print('\n## Candidate methods and callers (selected, static)')
    for path in files:
        text = path.read_text(errors='replace')
        for method in re.findall(r'(?ms)^\.method [^\n]*\n.*?^\.end method\s*$', text):
            sig = method.splitlines()[0]
            targeted = (path.name == 'PackageControl.smali' and ' installPackage(' in sig)
            targeted |= (path.name in ('Navitel$a.smali', 'a$b.smali') and ' onClick(' in sig
                         and ('android.settings.' in method))
            targeted |= ('Lcom/oslib/PackageControl;->installPackage(' in method)
            targeted |= ('Lcom/navitel/content/activity/a$b;' in method and '<init>' in method)
            targeted |= ('Lcom/navitel/content/activity/a;-><init>' in method)
            targeted |= (path.as_posix().endswith('/com/navitel/content/activity/a.smali') and ' constructor <init>(' in sig)
            targeted |= ('Lcom/navitel/Navitel$a;' in method and '<init>' in method)
            if targeted:
                lines = method.splitlines()
                print('\n###', path.relative_to(root), sig, 'lines:', len(lines))
                if len(lines) <= 300:
                    print(method)
                else:
                    # Do not publish arbitrary strings from very large methods.
                    print('Long method omitted; see class and method above.')


if __name__ == '__main__':
    main()

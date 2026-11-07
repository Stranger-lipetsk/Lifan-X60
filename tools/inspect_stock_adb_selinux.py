#!/usr/bin/env python3
"""Query exact stock Android SELinux allow rules without executing the policy."""
import hashlib
import subprocess
import sys
from pathlib import Path

EXPECTED_SHA = '3122f20c153352becde492e88409c719325c8db3d594bdcc8c7021ed4987a500'
QUERIES = (
    ('system_server', 'shell_prop', 'property_service', 'set', 'adb service properties'),
    ('system_server', 'ctl_default_prop', 'property_service', 'set', 'generic init control properties'),
    ('system_server', 'ctl_rildaemon_prop', 'property_service', 'set', 'specific init control properties'),
)


def query(policy, source, target, klass, perm):
    result = subprocess.run(
        ['sesearch', '--allow', '--source', source, '--target', target,
         '--class', klass, '--perm', perm, str(policy)],
        text=True, capture_output=True,
    )
    if result.returncode == 1 and not result.stderr:
        return ''  # SETools uses status 1 for a valid query with no matching rules.
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f'sesearch returned {result.returncode}')
    return result.stdout.strip()


def main():
    policy = Path(sys.argv[1]) if len(sys.argv) == 2 else Path('reports/deep2/update/sepolicy')
    blob = policy.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != EXPECTED_SHA:
        raise SystemExit(f'Unexpected policy SHA-256: {digest}')
    print('# Read-only queries against pinned compiled head-unit SELinux policy')
    print(f'Policy SHA-256: {digest}; bytes: {len(blob)}')
    print('No policy was loaded on a device; these are static allow-rule queries only.')
    for source, target, klass, perm, purpose in QUERIES:
        print(f'\n## {purpose}: {source} -> {target}:{klass} {perm}')
        output = query(policy, source, target, klass, perm)
        print(output if output else 'NO matching allow rule found')
    print('\nA missing allow rule suggests this SELinux path is denied; it does not prove the runtime policy matches this file or exclude other mechanisms.')

if __name__ == '__main__':
    main()

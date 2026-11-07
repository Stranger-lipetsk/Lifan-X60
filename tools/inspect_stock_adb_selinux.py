#!/usr/bin/env python3
"""Query exact stock Android SELinux allow rules without executing the policy."""
import hashlib
import subprocess
import sys
from pathlib import Path

EXPECTED_SHA = '3122f20c153352becde492e88409c719325c8db3d594bdcc8c7021ed4987a500'
EXPECTED_SEAPP_SHA = '154fcc9fe7d738cbb32591a6362b89351471705fc6f46a3fe029f2b86c1a6ef9'
EXPECTED_PROPERTY_CONTEXTS_SHA = '7010fe1aa8eff4b11de292838329f72ea8a0850df4844fe2624ee666e77e35c0'
QUERIES = (
    ('system_app', 'shell_prop', 'property_service', 'set', 'system-UID app -> adb service properties'),
    ('system_app', 'ctl_default_prop', 'property_service', 'set', 'system-UID app -> generic init control properties'),
    ('system', 'shell_prop', 'property_service', 'set', 'framework system domain -> adb service properties'),
    ('system', 'ctl_default_prop', 'property_service', 'set', 'framework system domain -> generic init control properties'),
)


def query(policy, source, target, klass, perm):
    result = subprocess.run(
        ['sesearch', '--allow', '--expand', '--source', source, '--target', target,
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
    seapp_path = policy.parent / 'seapp_contexts'
    property_contexts_path = policy.parent / 'property_contexts'
    seapp = seapp_path.read_bytes()
    property_contexts = property_contexts_path.read_bytes()
    if hashlib.sha256(seapp).hexdigest() != EXPECTED_SEAPP_SHA:
        raise SystemExit('Unexpected seapp_contexts SHA-256')
    if hashlib.sha256(property_contexts).hexdigest() != EXPECTED_PROPERTY_CONTEXTS_SHA:
        raise SystemExit('Unexpected property_contexts SHA-256')
    seapp_lines = seapp.decode().splitlines()
    if 'user=system domain=system_app type=system_data_file' not in seapp_lines:
        raise SystemExit('Expected system-UID app domain mapping not found')
    props = property_contexts.decode().splitlines()
    if not any(line.split()[:2] == ['service.adb.root', 'u:object_r:shell_prop:s0'] for line in props):
        raise SystemExit('ADB root property label not found')
    if not any(line.split()[:2] == ['service.adb.tcp.port', 'u:object_r:shell_prop:s0'] for line in props):
        raise SystemExit('ADB TCP property label not found')
    if not any(line.split()[:2] == ['ctl.', 'u:object_r:ctl_default_prop:s0'] for line in props):
        raise SystemExit('Default init-control property label not found')
    print('# Read-only queries against pinned compiled head-unit SELinux policy')
    print(f'Policy SHA-256: {digest}; bytes: {len(blob)}')
    print('Pinned seapp_contexts maps user=system apps to system_app; ADB property labels are shell_prop and generic ctl.* is ctl_default_prop.')
    print('No policy was loaded on a device; these are static allow-rule queries only.')
    for source, target, klass, perm, purpose in QUERIES:
        print(f'\n## {purpose}: {source} -> {target}:{klass} {perm}')
        output = query(policy, source, target, klass, perm)
        print(output if output else 'NO matching allow rule found')
    print('\nA missing allow rule suggests this SELinux path is denied; it does not prove the runtime policy matches this file or exclude other mechanisms.')

if __name__ == '__main__':
    main()

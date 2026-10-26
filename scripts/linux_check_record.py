# SPDX-License-Identifier: GPL-3.0-only
"""Package gate for a completed Linux-only synthetic check record."""
def validate_linux_check_record(checks, build):
    if (checks.get('schema') != 1 or checks.get('status') != 'passed' or checks.get('platform') != 'ubuntu-24.04' or
        checks.get('machine') != 'x86_64' or checks.get('sha256') != build.get('sha256') or
        checks.get('sourceManifest') != build.get('sourceManifest') or type(checks.get('testsRun')) is not int or checks['testsRun'] < 16 or
        any(checks.get(k) is not True for k in ('gtkBindingsImported', 'dpkgMetadataValidated', 'inventoryValidated', 'installationTested', 'removalTested'))):
        raise ValueError('A successful exact-source Ubuntu Linux package/fixture check is required')

# Exact installed entry -> corresponding source and mode. No maintainer/root scripts.
LINUX_PAYLOAD_SOURCES = {
    **{'usr/lib/deskbridge-linux/' + name: ('host/linux/' + name, 0o644)
       for name in ('policy.py', 'runtime.py', 'lifetime.py', 'containment.py', 'ui.py', 'SunshineDependency.json')},
    'usr/bin/deskbridge-linux': ('packaging/linux/deskbridge-linux', 0o755),
    'usr/share/applications/org.deskbridge.LinuxHost.desktop': ('packaging/linux/org.deskbridge.LinuxHost.desktop', 0o644),
    'usr/share/icons/hicolor/1024x1024/apps/org.deskbridge.LinuxHost.png': ('Assets/Brand/knot.png', 0o644),
    'usr/share/doc/deskbridge-linux-host/copyright': ('LICENSE', 0o644),
    'usr/share/doc/deskbridge-linux-host/README.ko.md': ('host/linux/README.md', 0o644),
}


def payload_directories():
    from pathlib import PurePosixPath
    directories = {'.'}
    for name in LINUX_PAYLOAD_SOURCES:
        directories.update(str(p) for p in PurePosixPath(name).parents)
    return sorted(directories, key=lambda name: (name.count('/'), name))


def validate_payload_sources(build, inventory):
    expected = {target: source for target, (source, mode) in LINUX_PAYLOAD_SOURCES.items()}
    if build.get('sourceEntries') != expected or set(inventory) != set(expected) or build.get('directories') != payload_directories():
        raise ValueError('Linux payload source inventory differs')
    for target, (source, mode) in LINUX_PAYLOAD_SOURCES.items():
        if inventory[target] != {'sha256': build.get('sourceManifest', {}).get(source), 'mode': mode}:
            raise ValueError('Linux installed bytes differ from their corresponding source: ' + target)

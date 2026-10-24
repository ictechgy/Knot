# SPDX-License-Identifier: GPL-3.0-only
"""Offline, exact-byte native updater staging. Build never downloads dependencies."""
from pathlib import Path, PurePosixPath
import base64, hashlib, json, os, plistlib, shutil, tarfile, zipfile
from urllib.parse import urlsplit
from update_version import build_number

PINS = {
    'Sparkle': ('2.10.0', 16319840, 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'),
    'WinSparkle': ('0.9.4', 27366440, '6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976'),
}

def dependency(root, name):
    folder = Path(root) / 'Vendor/UpdateRuntime'
    record = json.loads((folder / 'UPSTREAM.json').read_text())['dependencies'][name]
    version, size, digest = PINS[name]
    if (record['version'], record['bytes'], record['sha256']) != (version, size, digest):
        raise ValueError('Updater dependency pin differs from reviewed code')
    archive = folder / record['archive']
    if archive.is_symlink() or archive.stat().st_size != size or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError('Updater archive integrity mismatch')
    return archive, record


def _record(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def verify_runtime(root, name):
    archive, record = dependency(root, name)
    actual = {}
    if name == 'Sparkle':
        with tarfile.open(archive, 'r:xz') as source:
            for member in source:
                if member.isdir(): continue
                path = member.name.removeprefix('./')
                if path in actual: raise ValueError('Duplicate updater archive path')
                if member.isfile(): actual[path] = _record(source.extractfile(member).read())
                elif member.issym(): actual[path] = {'symlink': member.linkname}
                else: raise ValueError('Unsupported updater archive entry')
    else:
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                if member.is_dir(): continue
                if member.filename in actual: raise ValueError('Duplicate updater archive path')
                actual[member.filename] = _record(source.read(member))
    if actual != record['inventory']: raise ValueError('Updater full archive inventory mismatch')
    return archive, record


def sparkle_links(root):
    _, record = dependency(root, 'Sparkle')
    return {path: entry['symlink'] for path, entry in record['inventory'].items()
            if path.startswith('Sparkle.framework/') and 'symlink' in entry}


def stage_sparkle(root, frameworks):
    archive, _ = verify_runtime(root, 'Sparkle')
    destination = Path(frameworks)
    if (destination / 'Sparkle.framework').exists(): raise ValueError('Updater destination must be fresh')
    destination.mkdir(parents=True, exist_ok=True)
    links = []
    with tarfile.open(archive, 'r:xz') as source:
        for member in source:
            path = member.name.removeprefix('./')
            if not path.startswith('Sparkle.framework/') or member.isdir(): continue
            parts = PurePosixPath(path)
            if parts.is_absolute() or '..' in parts.parts or str(parts) != path: raise ValueError('Unsafe updater archive path')
            output = destination / path
            output.parent.mkdir(parents=True, exist_ok=True)
            if member.issym():
                links.append((output, member.linkname)); continue
            if not member.isfile(): raise ValueError('Unsafe updater archive file')
            with output.open('xb') as target: target.write(source.extractfile(member).read())
            output.chmod(member.mode & 0o755)
    # All ordinary files are installed first; symlinks cannot redirect extraction.
    for output, target in links:
        resolved = (output.parent / target).resolve()
        if not resolved.is_relative_to((destination / 'Sparkle.framework').resolve()):
            raise ValueError('Updater symlink leaves framework')
        output.symlink_to(target)
    return destination / 'Sparkle.framework'


def stage_winsparkle(root, destination):
    archive, _ = verify_runtime(root, 'WinSparkle')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for origin, output in [('WinSparkle-0.9.4/x64/Release/WinSparkle.dll', 'WinSparkle.dll'),
                               ('WinSparkle-0.9.4/COPYING', 'WinSparkle-LICENSE.txt'),
                               ('WinSparkle-0.9.4/COPYING.expat', 'WinSparkle-Expat-LICENSE.txt')]:
            data = source.read(origin)
            with (destination / output).open('xb') as target: target.write(data)
    return destination / 'WinSparkle.dll'


def publisher_config(root):
    path = Path(root) / 'packaging/updates/publisher.json'
    record = json.loads(path.read_text())
    if set(record) != {'schema', 'macFeedURL', 'windowsFeedURL', 'publicEDKey', 'windowsPublisherCertificateSHA256'} or record['schema'] != 1:
        raise ValueError('Invalid publisher configuration')
    values = [record[name] for name in record if name != 'schema']
    if all(value is None for value in values): return None
    if not all(isinstance(value, str) and value for value in values): raise ValueError('Publisher configuration must be complete or entirely unconfigured')
    key = base64.b64decode(record['publicEDKey'], validate=True)
    if len(key) != 32 or not any(key) or base64.b64encode(key).decode() != record['publicEDKey']:
        raise ValueError('Invalid update Ed25519 public key')
    cert = record['windowsPublisherCertificateSHA256']
    if len(cert) != 64 or any(c not in '0123456789abcdef' for c in cert): raise ValueError('Invalid Windows publisher certificate pin')
    for name in ['macFeedURL', 'windowsFeedURL']:
        url = urlsplit(record[name])
        if (url.scheme != 'https' or not url.hostname or url.hostname in ('localhost', '127.0.0.1', '::1')
                or url.username or url.password or url.fragment or url.port not in (None, 443)
                or any(ord(c) <= 32 or ord(c) == 127 for c in record[name])):
            raise ValueError('Updater feeds must be public HTTPS URLs without credentials')
    return record


def sparkle_info(root, *, enabled=True):
    record = publisher_config(root)
    if not enabled: record = None
    info = {'CFBundleVersion': build_number((Path(root) / 'VERSION').read_text().strip()),
            'KnotUpdatesConfigured': bool(record)}
    if record:
        info.update(SUFeedURL=record['macFeedURL'], SUPublicEDKey=record['publicEDKey'],
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0)
    return info


def sign_sparkle(framework, run, identity='-', release=False):
    framework = Path(framework)
    for label, path in [('downloader', 'Versions/B/XPCServices/Downloader.xpc'),
                        ('installer', 'Versions/B/XPCServices/Installer.xpc'),
                        ('autoupdate', 'Versions/B/Autoupdate'),
                        ('updater', 'Versions/B/Updater.app'), ('framework', '.')]:
        command = ['/usr/bin/codesign', '--force', '--options', 'runtime', '--preserve-metadata=entitlements', '--sign', identity]
        if release: command.append('--timestamp')
        run('sign-sparkle-' + label + ('-release' if release else ''), command + [str(framework / path)])
    run('verify-sparkle' + ('-release' if release else ''), ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(framework)])

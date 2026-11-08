#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Native Preview update publishing: explicit offline RSA signing, never key discovery/upload."""
from pathlib import Path
from urllib.parse import urlsplit
import argparse, base64, hashlib, json, os, re, subprocess, time

MAXIMUM_BYTES = 512 * 1024 * 1024
FIELDS = {'schema', 'macFeedURL', 'windowsFeedURL', 'rsaModulus', 'rsaExponent'}

def https(value):
    if not isinstance(value, str) or not value or any(ord(c) <= 32 or ord(c) >= 127 for c in value):
        raise ValueError('Update URL must be ASCII public HTTPS')
    p = urlsplit(value)
    if (p.scheme != 'https' or not p.hostname or p.username or p.password or p.query or p.fragment or
            p.port not in (None, 443) or p.hostname.lower() in ('localhost', '127.0.0.1', '::1')):
        raise ValueError('Update URL must be public HTTPS without credentials/query/fragment')
    return value

def version(value):
    m = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-native\.([1-9][0-9]*)', value)
    if not m or any(int(n) > 65535 for n in m.groups()):
        raise ValueError('Invalid native preview version')
    result = 0
    for n in m.groups(): result = result * 65536 + int(n)
    return result

def publisher(root):
    value = json.loads((Path(root) / 'packaging/updates/native-publisher.json').read_text())
    if set(value) != FIELDS or type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Invalid native publisher configuration')
    if all(value[k] is None for k in FIELDS - {'schema'}): return None
    for key in ('macFeedURL', 'windowsFeedURL'): https(value[key])
    for key, size in [('rsaModulus', 256), ('rsaExponent', 3)]:
        raw = base64.b64decode(value[key], validate=True)
        if len(raw) != size or base64.b64encode(raw).decode() != value[key]:
            raise ValueError('Publisher needs a canonical RSA-2048 public key with exponent 65537')
        if key == 'rsaModulus' and (raw[0] < 128 or raw[-1] % 2 == 0): raise ValueError('Invalid RSA modulus')
        if key == 'rsaExponent' and raw != b'\x01\x00\x01': raise ValueError('Invalid RSA exponent')
    return value

def build_resource(root, current_version):
    version(current_version)
    p = publisher(root)
    return '\n'.join([current_version, *(p[k] if p else '' for k in
        ['macFeedURL', 'windowsFeedURL', 'rsaModulus', 'rsaExponent'])]) + '\n'

def manifest(current_version, platform, url, size, sha256, expires, now=None):
    build = version(current_version); https(url); now = int(time.time()) if now is None else now
    suffix = '-macos-arm64.zip' if platform == 'macos-arm64' else '-windows-x64-setup.exe'
    if platform not in ('macos-arm64', 'windows-x64') or urlsplit(url).path.rsplit('/', 1)[-1] != 'Knot-Native-' + current_version + suffix:
        raise ValueError('Native artifact identity/platform mismatch')
    if type(size) is not int or not 1 <= size <= MAXIMUM_BYTES or not re.fullmatch('[0-9a-f]{64}', sha256):
        raise ValueError('Invalid artifact size/hash')
    if type(expires) is not int or not now < expires <= now + 30 * 86400:
        raise ValueError('Manifest must expire within 30 days')
    return ('\n'.join(['KNOT-NATIVE-UPDATE-1', current_version, str(build), platform, url,
                       str(size), sha256, str(expires)]) + '\n').encode('ascii')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform', choices=['macos-arm64', 'windows-x64'], required=True)
    p.add_argument('--version', required=True); p.add_argument('--artifact', type=Path, required=True)
    p.add_argument('--url', required=True); p.add_argument('--key-file', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True); p.add_argument('--expires', type=int, required=True)
    args = p.parse_args(); root = Path(__file__).resolve().parent.parent; conf = publisher(root)
    if not conf: raise SystemExit('Configure native-publisher.json with reviewed public key and feeds first.')
    key = args.key_file.resolve(strict=True)
    if key.is_relative_to(root) or key.stat().st_mode & 0o077: raise SystemExit('Use an explicit owner-only signing key outside repository.')
    artifact = args.artifact
    if artifact.is_symlink() or not artifact.is_file() or args.output.exists(): raise SystemExit('Use ordinary artifact and fresh output.')
    expected = 'Knot-Native-' + args.version + ('-macos-arm64.zip' if args.platform == 'macos-arm64' else '-windows-x64-setup.exe')
    if artifact.name != expected: raise SystemExit('Native artifact filename mismatch.')
    body = manifest(args.version, args.platform, args.url, artifact.stat().st_size,
                    hashlib.file_digest(artifact.open('rb'), 'sha256').hexdigest(), args.expires)
    public = subprocess.run(['/usr/bin/openssl', 'rsa', '-in', str(key), '-noout', '-modulus'],
                            capture_output=True, check=True).stdout.decode().strip()
    if public != 'Modulus=' + base64.b64decode(conf['rsaModulus']).hex().upper(): raise SystemExit('Signing key differs from pinned public key.')
    signature = subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-sign', str(key)], input=body,
                               capture_output=True, check=True).stdout
    if len(signature) != 256: raise SystemExit('Expected RSA-2048 signature.')
    with args.output.open('xb') as out: out.write(base64.b64encode(body) + b'\n' + base64.b64encode(signature) + b'\n')
    print('Prepared signed Native Preview update feed (not uploaded): ' + str(args.output))

if __name__ == '__main__': main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare one signed, platform-specific update feed; never upload or generate keys.

Private keys must be explicitly supplied outside this repository. The upstream
signer always receives --ed-key-file, so it never searches an existing Keychain.
"""
from pathlib import Path
import argparse, base64, hashlib, os, subprocess, sys, tarfile, tempfile
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit
from update_runtime import publisher_config, verify_runtime
from update_version import build_number
ROOT = Path(__file__).resolve().parent.parent
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)

def make_feed(version, platform, url, size, signature):
    parts=urlsplit(url)
    expected = '.dmg' if platform=='macos-arm64' else '-windows-x64-setup.exe'
    if (parts.scheme!='https' or not parts.hostname or parts.username or parts.password or parts.fragment or parts.query
            or parts.port not in (None,443) or not parts.path.endswith(expected) or size<=0 or size>512*1024*1024
            or any(ord(c)<=32 or ord(c)==127 for c in url)):
        raise ValueError('Invalid platform-specific HTTPS update URL/size')
    if len(base64.b64decode(signature,validate=True)) != 64: raise ValueError('Invalid Ed25519 signature')
    rss=ET.Element('rss',version='2.0'); channel=ET.SubElement(rss,'channel')
    ET.SubElement(channel,'title').text='Knot '+platform+' updates'
    item=ET.SubElement(channel,'item'); ET.SubElement(item,'title').text='Knot '+version
    ET.SubElement(item,'{'+NS+'}minimumSystemVersion').text='26.0' if platform=='macos-arm64' else '10.0.22000'
    ET.SubElement(item,'enclosure',{'url':url,'length':str(size),'type':'application/octet-stream',
                                  '{'+NS+'}version':build_number(version),'{'+NS+'}shortVersionString':version,
                                  '{'+NS+'}edSignature':signature,
                                  '{'+NS+'}os':'macos' if platform=='macos-arm64' else 'windows'})
    return ET.tostring(rss,encoding='utf-8',xml_declaration=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform',choices=['macos-arm64','windows-x64'],required=True)
    parser.add_argument('--artifact',type=Path,required=True)
    parser.add_argument('--download-url',required=True)
    parser.add_argument('--key-file',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(); config=publisher_config(ROOT)
    if not config: raise SystemExit('Configure reviewed public publisher keys/HTTPS feeds before signing.')
    key=args.key_file.resolve(strict=True)
    if key.is_relative_to(ROOT) or key.stat().st_mode&0o077: raise SystemExit('Private signing key must be outside the repository and owner-only (0600).')
    if args.artifact.is_symlink() or not args.artifact.is_file() or args.output.exists(): raise SystemExit('Use an ordinary artifact and a fresh output path.')
    version=(ROOT/'VERSION').read_text().strip()
    expected='Knot-'+version+('-macos-arm64.dmg' if args.platform=='macos-arm64' else '-windows-x64-setup.exe')
    if args.artifact.name!=expected: raise SystemExit('Artifact identity/version/platform mismatch; preview packages cannot enter the production feed.')
    archive,_=verify_runtime(ROOT,'Sparkle')
    with tempfile.TemporaryDirectory(prefix='knot-publish-sign-') as temporary:
        folder=Path(temporary); signer=folder/'sign_update'
        with tarfile.open(archive) as source: signer.write_bytes(source.extractfile('./bin/sign_update').read())
        signer.chmod(0o700)
        def invoke(arguments):
            result=subprocess.run([str(signer),'--ed-key-file',str(key),*arguments],capture_output=True,timeout=120)
            if result.returncode: raise SystemExit('Upstream Ed25519 signer failed; no feed published.')
            return result.stdout
        signature=invoke(['-p',str(args.artifact)]).decode().strip()
        # Verify with the embedded PUBLIC key independently of the private signer.
        source=folder/'verify.swift'; source.write_text('''import Foundation
import CryptoKit
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
let signature = Data(base64Encoded: CommandLine.arguments[2])!
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
exit(key.isValidSignature(signature, for: data) ? 0 : 1)
''')
        result=subprocess.run(['/usr/bin/swiftc',str(source),'-o',str(folder/'verify')],capture_output=True)
        if result.returncode: raise SystemExit('Public-key verifier compilation failed.')
        result=subprocess.run([str(folder/'verify'),config['publicEDKey'],signature,str(args.artifact)],capture_output=True)
        if result.returncode: raise SystemExit('Signing key does not match the reviewed publisher public key.')
        feed=folder/'appcast.xml'; feed.write_bytes(make_feed(version,args.platform,args.download_url,args.artifact.stat().st_size,signature))
        invoke(['-p',str(feed)])
        invoke(['--verify',str(feed)])
        # Exclusive create: never silently overwrite a published or manually edited feed.
        with args.output.open('xb') as output: output.write(feed.read_bytes())
    print('Prepared signed feed: '+str(args.output)+' (not uploaded)')

if __name__=='__main__': main()

# SPDX-License-Identifier: GPL-3.0-only
import base64, importlib.util, json, tempfile, unittest
from pathlib import Path
spec = importlib.util.spec_from_file_location('native_updates', Path(__file__).resolve().parents[1] / 'native_updates.py')
u = importlib.util.module_from_spec(spec); spec.loader.exec_module(u)

class NativeUpdates(unittest.TestCase):
    def test_version_order_and_invalid(self):
        self.assertLess(u.version('0.1.0-native.10'), u.version('0.1.0-native.11'))
        self.assertLess(u.version('0.1.0-native.65535'), u.version('0.1.1-native.1'))
        for x in ['0.1.0', '0.1.0-native.0', '0.1.0-native.01', '0.1.0-native.65536', '1.1.1-native.1\n']:
            with self.assertRaises(ValueError): u.version(x)
    def test_signed_manifest_contract(self):
        m = u.manifest('0.1.0-native.11', 'macos-arm64', 'https://example.com/Knot-Native-0.1.0-native.11-macos-arm64.zip', 10, 'a'*64, 150, 100)
        self.assertEqual(len(m.decode().splitlines()), 8)
        self.assertTrue(m.endswith(b'\n'))
        for changes in [dict(platform='windows-x64'),dict(size=0),dict(size=u.MAXIMUM_BYTES+1),dict(sha256='A'*64),dict(expires=99),dict(expires=100+30*86400+1)]:
            args = dict(current_version='0.1.0-native.11', platform='macos-arm64', url='https://example.com/Knot-Native-0.1.0-native.11-macos-arm64.zip', size=10, sha256='a'*64, expires=150, now=100); args.update(changes)
            with self.assertRaises(ValueError): u.manifest(**args)
    def test_unconfigured_and_partial_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'packaging/updates'; p.mkdir(parents=True); f=p/'native-publisher.json'
            d={k:None for k in u.FIELDS}; d['schema']=1; f.write_text(json.dumps(d)); self.assertIsNone(u.publisher(t))
            d['macFeedURL']='https://example.com/feed'; f.write_text(json.dumps(d))
            with self.assertRaises((ValueError,TypeError)): u.publisher(t)
    def test_bad_urls(self):
        for x in ['http://example.com/x', 'https://user@example.com/x', 'https://localhost/x', 'https://example.com:12/x', 'https://example.com/x?q=1', 'https://example.com/x\n']:
            with self.assertRaises(ValueError): u.https(x)

if __name__ == '__main__': unittest.main()

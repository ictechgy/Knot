#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pure synthetic notice provenance tests; no compiler or Windows process runs."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_windows_launcher import verify_runtime_notices, verify_virtual_display_inputs
from windows_resources import resource_file, validate_version_resource, version_resource


class NativeBrandMetadata(unittest.TestCase):
    def test_release_version_and_brand_are_native_resources(self):
        # Parse the actual .res records independently of the VERSIONINFO writer.
        # A valid ICO containing one inert image is sufficient; no image codec runs.
        icon = struct.pack('<HHHBBBBHHII', 0, 1, 1, 1, 1, 0, 0, 1, 32, 4, 22) + b'icon'
        raw = resource_file(b'synthetic managed image', b'<assembly/>', icon, '9.8.7-preview.synthetic')
        resources = {}
        offset = 0
        while offset < len(raw):
            size, header_size, marker, kind, marker2, name = struct.unpack_from('<IIHHHH', raw, offset)
            self.assertEqual((header_size, marker, marker2), (32, 0xffff, 0xffff))
            resources[kind, name] = raw[offset + header_size:offset + header_size + size]
            offset = (offset + header_size + size + 3) & ~3
        self.assertEqual(offset, len(raw))
        self.assertEqual(resources[10, 101], b'synthetic managed image')
        self.assertEqual(resources[3, 1], b'icon')
        version = resources[16, 1]
        self.assertEqual(struct.unpack_from('<HHH', version), (len(version), 52, 0))
        key_end = 6 + len('VS_VERSION_INFO\0'.encode('utf-16le'))
        fixed_offset = (key_end + 3) & ~3
        fixed = struct.unpack_from('<13I', version, fixed_offset)
        self.assertEqual(fixed[:8], (0xfeef04bd, 0x10000, 9 << 16 | 8, 7 << 16,
                                   9 << 16 | 8, 7 << 16, 0x3f, 2))
        for text in ('Knot', 'Knot Windows', 'Knot contributors', '9.8.7-preview.synthetic'):
            self.assertIn((text + '\0').encode('utf-16le'), version)
        self.assertNotIn('DeskBridge'.encode('utf-16le'), version)
        self.assertEqual(validate_version_resource(version, '9.8.7-preview.synthetic'), '9.8.7-preview.synthetic')

    def test_mismatched_or_tampered_product_metadata_is_rejected(self):
        version = version_resource('1.2.3')
        with self.assertRaisesRegex(ValueError, 'release VERSION'):
            validate_version_resource(version, '1.2.4')
        for value in (version[:-1], version + b'\0', version.replace('Knot Windows'.encode('utf-16le'), 'Old  Windows'.encode('utf-16le'))):
            with self.subTest(value=value[:12]), self.assertRaises(ValueError):
                validate_version_resource(value)

    def test_fixed_version_cannot_overflow_or_accept_unbounded_text(self):
        for version in ('65536.0.0', '1.2', '1.2.3.4', '1.2.3-"bad', '1.2.3-' + 'x' * 129):
            with self.subTest(version=version), self.assertRaises(ValueError):
                version_resource(version)



class RuntimeNotices(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='deskbridge-runtime-notices-')
        self.root = Path(self.fixture.name)
        self.vendor = self.root / 'Vendor/WindowsRuntime'
        self.vendor.mkdir(parents=True)
        self.texts = {'Zig-LICENSE': b'Synthetic Zig notice\n', 'Mingw-COPYING': b'Synthetic CRT notice\n'}
        self.pins = {name: hashlib.sha256(data).hexdigest() for name, data in self.texts.items()}
        for name, data in self.texts.items():
            (self.vendor / name).write_bytes(data)
        (self.vendor / 'NOTICE').write_bytes(b'Fixture notice\n' + b'\n'.join(self.texts.values()))
        self.write_pins()

    def tearDown(self):
        self.fixture.cleanup()

    def write_pins(self):
        (self.vendor / 'UPSTREAM.json').write_text(json.dumps({'files': self.pins}))

    def test_actual_verifier_accepts_matching_notice_sources(self):
        hashes = verify_runtime_notices(self.root)
        self.assertEqual(set(hashes), {'Zig-LICENSE', 'Mingw-COPYING', 'NOTICE'})
        self.assertEqual(hashes['Zig-LICENSE'], self.pins['Zig-LICENSE'])

    def test_modified_upstream_text_is_rejected(self):
        (self.vendor / 'Zig-LICENSE').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_missing_notice_block_is_rejected(self):
        (self.vendor / 'NOTICE').write_bytes(self.texts['Zig-LICENSE'])
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_unknown_inventory_is_rejected(self):
        self.pins['outside'] = '0' * 64
        self.write_pins()
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_bad_recorded_digest_is_rejected(self):
        self.pins['Mingw-COPYING'] = '0' * 64
        self.write_pins()
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)


class VirtualDisplayPolicy(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='knot-vdd-policy-')
        self.root = Path(self.fixture.name)
        self.folder = self.root / 'host/windows'
        self.folder.mkdir(parents=True)
        source = Path(__file__).resolve().parents[2] / 'host/windows'
        for name in ('VirtualDisplayDependency.json', 'VirtualDisplayFiles.json',
                     'Knot-vdd_settings.xml', 'VirtualDisplay-NOTICE.txt', 'VirtualDisplayDeployments.json', 'HeadlessNative.cs',
                     'HeadlessSetup.psm1', 'Show-HeadlessSetup.ps1'):
            (self.folder / name).write_bytes((source / name).read_bytes())
        self.pin = json.loads((self.folder / 'VirtualDisplayDependency.json').read_text())

    def tearDown(self):
        self.fixture.cleanup()

    def write_pin(self, pin):
        (self.folder / 'VirtualDisplayDependency.json').write_text(json.dumps(pin))

    def test_current_blocked_candidate_is_packaged(self):
        self.assertIs(verify_virtual_display_inputs(self.root)['deviceRuntimeTested'], False)

    def test_deployment_identity_or_files_cannot_drift_from_current_pins(self):
        path = self.folder / 'VirtualDisplayDeployments.json'
        original = json.loads(path.read_text())
        import copy
        for field in ('archiveSha256', 'catalogSignerCertificateSha256', 'driverVersion', 'files'):
            changed = copy.deepcopy(original)
            changed['profiles'][0][field] = [] if field == 'files' else ('1.2.3.4' if field == 'driverVersion' else '0' * 64)
            path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify_virtual_display_inputs(self.root)
        path.write_text(json.dumps(original))

    def test_profile_and_file_unknown_fields_match_runtime_rejection(self):
        path = self.folder / 'VirtualDisplayDeployments.json'
        original = json.loads(path.read_text())
        import copy
        for target in ('profile', 'file'):
            changed = copy.deepcopy(original)
            record = changed['profiles'][0]
            if target == 'file':
                record = record['files'][0]
            record['annotation'] = 'synthetic future metadata'
            path.write_text(json.dumps(changed))
            with self.subTest(target=target), self.assertRaises(ValueError):
                verify_virtual_display_inputs(self.root)
        path.write_text(json.dumps(original))

    def test_native_verification_version_is_bound_to_current_driver(self):
        path = self.folder / 'HeadlessNative.cs'
        path.write_text(path.read_text().replace('11.30.4.434', '1.2.3.4'))
        with self.assertRaisesRegex(ValueError, 'Native virtual display verification version'):
            verify_virtual_display_inputs(self.root)

    def test_json_alone_cannot_enable_candidate(self):
        for key, values in {
            'installEnabled': (True, None, 0, 'false', 'true'),
            'driverSafetyReviewStatus': ('accepted', 'BLOCKED', False, None),
            'installBlockedReason': ('', 'reviewed', False, None),
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.write_pin({**self.pin, key: value})
                    with self.assertRaisesRegex(ValueError, 'must remain blocked'):
                        verify_virtual_display_inputs(self.root)

    def test_powershell_pin_drift_is_rejected_before_packaging(self):
        cases = [('HeadlessSetup.psm1', "$dependency.bytes -ne 132118", "$dependency.bytes -ne 132117"),
                 ('HeadlessSetup.psm1', "$dependency.driverVersion -cne '11.30.4.434'", "$dependency.driverVersion -cne '1.2.3.4'"),
                 ('Show-HeadlessSetup.ps1', "$dep.bytes -ne 132118", "$dep.bytes -ne 132117"),
                 ('Show-HeadlessSetup.ps1', self.pin['url'], 'https://example.invalid/driver.zip')]
        for name, old, new in cases:
            path = self.folder / name
            original = path.read_text(encoding='utf-8-sig')
            self.assertIn(old, original)
            path.write_text(original.replace(old, new), encoding='utf-8-sig')
            with self.subTest(name=name, old=old), self.assertRaisesRegex(ValueError, 'PowerShell virtual display verification pin'):
                verify_virtual_display_inputs(self.root)
            path.write_text(original, encoding='utf-8-sig')

    def test_missing_policy_field_is_rejected(self):
        for key in ('installEnabled', 'driverSafetyReviewStatus', 'installBlockedReason'):
            with self.subTest(key=key):
                pin = self.pin.copy()
                del pin[key]
                self.write_pin(pin)
                with self.assertRaisesRegex(ValueError, 'must remain blocked'):
                    verify_virtual_display_inputs(self.root)


if __name__ == '__main__':
    unittest.main()

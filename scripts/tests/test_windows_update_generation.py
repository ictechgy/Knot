# SPDX-License-Identifier: GPL-3.0-only
"""Fresh source-only fixtures for the actual Windows updater policy generator."""
from pathlib import Path
import base64
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from update_windows import configuration_source


class WindowsUpdateGenerationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='knot-win-update-generation-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'packaging/updates').mkdir(parents=True)
        (self.root / 'VERSION').write_text('0.2.0-preview.17')
        self.config = {'schema': 1, 'macFeedURL': None, 'windowsFeedURL': None,
                       'publicEDKey': None, 'windowsPublisherCertificateSHA256': None}

    def write(self):
        (self.root / 'packaging/updates/publisher.json').write_text(json.dumps(self.config))

    def test_unconfigured_is_explicit_and_no_feed(self):
        self.write()
        source = configuration_source(self.root, 'a' * 64, 'b' * 64)
        self.assertIn('Configured = false;', source)
        self.assertIn('FeedURL = "";', source)
        self.assertIn('BuildNumber = "1000100017";', source)
        self.assertNotIn('http', source)

    def test_complete_publisher_pins_are_compile_time_only(self):
        self.config.update(macFeedURL='https://updates.example.org/mac.xml', windowsFeedURL='https://updates.example.org/windows.xml',
                           publicEDKey=base64.b64encode(bytes(range(32))).decode(), windowsPublisherCertificateSHA256='c' * 64)
        self.write()
        source = configuration_source(self.root, 'a' * 64, 'b' * 64)
        self.assertIn('Configured = true;', source)
        for value in [self.config['windowsFeedURL'], self.config['publicEDKey'], 'c' * 64, 'a' * 64, 'b' * 64]:
            self.assertIn(json.dumps(value), source)

    def test_partial_publisher_refused(self):
        self.config['windowsFeedURL'] = 'https://updates.example.org/windows.xml'
        self.write()
        with self.assertRaises(ValueError): configuration_source(self.root, 'a' * 64)

    def test_malformed_binary_pins_refused(self):
        self.write()
        for bad in ['', 'a' * 63, 'a' * 65, 'A' * 64, 'g' * 64, 'a' * 64 + '\n']:
            with self.subTest(pin=bad):
                with self.assertRaises(ValueError): configuration_source(self.root, bad)
        for bad in ['a' * 63, 'A' * 64]:
            with self.assertRaises(ValueError): configuration_source(self.root, 'a' * 64, bad)


if __name__ == '__main__':
    unittest.main()

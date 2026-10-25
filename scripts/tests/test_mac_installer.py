#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the actual installer core on fresh, inert signed bundles only."""
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MacInstallerTests(unittest.TestCase):
    def test_signed_bundle_transactions_and_ui_compilation(self):
        # Resolve /var's system symlink before passing paths to the strict core.
        with tempfile.TemporaryDirectory(prefix="knot-installer-fixture-", dir=Path(tempfile.gettempdir()).resolve()) as directory:
            fixture = Path(directory)
            inert = fixture / "inert"
            subprocess.run(["/usr/bin/clang", "-x", "c", "-o", str(inert), "-"], input="int main(void) { return 0; }\n", text=True, check=True)
            for name, build, identifier in (("old", "200", "org.deskbridge.app"), ("payload", "201", "org.deskbridge.app"), ("foreign", "201", "org.example.fixture")):
                bundle = fixture / name / "Knot.app"
                (bundle / "Contents/MacOS").mkdir(parents=True)
                shutil.copy2(inert, bundle / "Contents/MacOS/DeskBridge")
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": "DeskBridge", "CFBundlePackageType": "APPL", "CFBundleVersion": build, "DeskBridgeVersion": "synthetic-" + build}))
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)
            shutil.copytree(fixture / "payload", fixture / "tampered")
            with (fixture / "tampered/Knot.app/Contents/MacOS/DeskBridge").open("ab") as handle:
                handle.write(b"synthetic tamper")
            core = ROOT / "packaging/macos/KnotInstallerCore.swift"
            checker = fixture / "checks"
            subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", str(core), str(ROOT / "scripts/tests/MacInstallerChecks.swift"), "-o", str(checker)], check=True)
            result = subprocess.run([str(checker), str(fixture)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("29 checks passed", result.stdout)
            print(result.stdout.strip())
            # Compile the real AppKit entry point without running its installer.
            subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", str(core), str(ROOT / "packaging/macos/KnotInstaller.swift"), "-o", str(fixture / "KnotInstaller")], check=True)


if __name__ == "__main__":
    unittest.main()

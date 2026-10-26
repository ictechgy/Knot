# SPDX-License-Identifier: GPL-3.0-only
"""Byte-provenance regression checks using only newly generated Git repositories."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_snapshot import BuildSnapshotError
from check_source_checkout import validate_checkout


class SourceCheckoutChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="knot-source-checkout-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.root.mkdir()
        self.git("init", "--quiet")
        self.git("config", "core.autocrlf", "false")
        self.git("config", "user.name", "Synthetic fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        attributes = (Path(__file__).resolve().parents[2] / ".gitattributes").read_bytes()
        for name, data in {".gitattributes": attributes, "LICENSE": b"synthetic license\n",
                           "INSTALLATION.md": b"synthetic instructions\n", "VERSION": b"0.0.0-fixture\n",
                           "scripts/fixture.py": b"first line\nsecond line\n"}.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.commit()

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root, stderr=subprocess.PIPE)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "synthetic source")

    def autocrlf_checkout(self):
        checkout = Path(self.temporary.name) / "windows-checkout"
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", str(self.root), str(checkout)],
                       check=True, capture_output=True)
        subprocess.run(["git", "config", "core.autocrlf", "true"], cwd=checkout, check=True, capture_output=True)
        subprocess.run(["git", "checkout", "--quiet", "HEAD"], cwd=checkout, check=True, capture_output=True)
        return checkout

    def test_autocrlf_checkout_preserves_committed_bytes(self):
        checkout = self.autocrlf_checkout()
        self.assertEqual((checkout / "scripts/fixture.py").read_bytes(), b"first line\nsecond line\n")
        result = validate_checkout(checkout)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["sourceFiles"], 5)
        self.assertEqual(result["revision"], self.git("rev-parse", "HEAD").decode().strip())

    def test_autocrlf_without_exact_byte_policy_is_rejected(self):
        (self.root / ".gitattributes").write_bytes(b"/Vendor/** -text\n")
        self.commit()
        checkout = self.autocrlf_checkout()
        self.assertEqual((checkout / "scripts/fixture.py").read_bytes(), b"first line\r\nsecond line\r\n")
        with self.assertRaisesRegex(BuildSnapshotError, "Build inputs do not match corresponding source"):
            validate_checkout(checkout)

    def test_line_ending_transformation_is_rejected(self):
        path = self.root / "scripts/fixture.py"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        with self.assertRaisesRegex(BuildSnapshotError, "Build inputs do not match corresponding source"):
            validate_checkout(self.root)

    def test_staged_content_is_not_treated_as_committed_source(self):
        (self.root / "scripts/fixture.py").write_bytes(b"staged replacement\n")
        self.git("add", "scripts/fixture.py")
        with self.assertRaises(BuildSnapshotError):
            validate_checkout(self.root)

    def test_uncommitted_compiler_input_is_rejected(self):
        (self.root / "scripts/added.py").write_bytes(b"new uncommitted input\n")
        with self.assertRaises(BuildSnapshotError):
            validate_checkout(self.root)

    def test_missing_tracked_source_is_rejected(self):
        (self.root / "scripts/fixture.py").unlink()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing build input"):
            validate_checkout(self.root)

    def test_linked_input_is_refused_without_reading_target(self):
        path = self.root / "scripts/fixture.py"
        target = Path(self.temporary.name) / "outside-source.txt"
        target.write_bytes(b"fresh synthetic outside target\n")
        path.unlink()
        try:
            path.symlink_to(target)
        except (OSError, NotImplementedError):
            self.skipTest("Creating source symlinks is unavailable on this runner")
        read_bytes = Path.read_bytes
        def refuse_target_read(candidate):
            if candidate == path or candidate == target:
                raise AssertionError("Source link target was read")
            return read_bytes(candidate)
        with patch.object(Path, "read_bytes", refuse_target_read):
            with self.assertRaisesRegex(BuildSnapshotError, "Symlink is not a build input"):
                validate_checkout(self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)

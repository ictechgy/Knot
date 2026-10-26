# SPDX-License-Identifier: GPL-3.0-only
"""Byte-provenance regression checks using only newly generated Git repositories."""
from pathlib import Path
import os
import shlex
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
        # Fixture-only Git isolation: never route writes into a developer repo,
        # read their Git configuration, copy their templates, or run their hooks.
        empty_hooks = Path(self.temporary.name) / "empty-hooks"
        empty_hooks.mkdir()
        self.git_env = {key: value for key, value in os.environ.items() if not key.upper().startswith("GIT_")}
        self.git_env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_ATTR_NOSYSTEM="1",
                            GIT_TEMPLATE_DIR=str(empty_hooks), GIT_CONFIG_COUNT="3",
                            GIT_CONFIG_KEY_0="core.excludesFile", GIT_CONFIG_VALUE_0=os.devnull,
                            GIT_CONFIG_KEY_1="core.attributesFile", GIT_CONFIG_VALUE_1=os.devnull,
                            GIT_CONFIG_KEY_2="core.hooksPath", GIT_CONFIG_VALUE_2=str(empty_hooks))
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
        return subprocess.check_output(["git", *arguments], cwd=self.root, env=self.git_env, stderr=subprocess.PIPE)

    def validate(self, root=None):
        # The production helper starts Git subprocesses too. Apply exactly the
        # same fixture environment rather than letting those inherit the caller.
        with patch.dict(os.environ, self.git_env, clear=True):
            return validate_checkout(self.root if root is None else root)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "synthetic source")

    def autocrlf_checkout(self):
        checkout = Path(self.temporary.name) / "windows-checkout"
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", str(self.root), str(checkout)],
                       cwd=self.temporary.name, env=self.git_env, check=True, capture_output=True)
        subprocess.run(["git", "config", "core.autocrlf", "true"], cwd=checkout, env=self.git_env, check=True, capture_output=True)
        subprocess.run(["git", "checkout", "--quiet", "HEAD"], cwd=checkout, env=self.git_env, check=True, capture_output=True)
        return checkout

    def test_autocrlf_checkout_preserves_committed_bytes(self):
        checkout = self.autocrlf_checkout()
        self.assertEqual((checkout / "scripts/fixture.py").read_bytes(), b"first line\nsecond line\n")
        result = self.validate(checkout)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["sourceFiles"], 5)
        self.assertEqual(result["revision"], self.git("rev-parse", "HEAD").decode().strip())

    def test_autocrlf_without_exact_byte_policy_is_rejected(self):
        (self.root / ".gitattributes").write_bytes(b"/Vendor/** -text\n")
        self.commit()
        checkout = self.autocrlf_checkout()
        self.assertEqual((checkout / "scripts/fixture.py").read_bytes(), b"first line\r\nsecond line\r\n")
        with self.assertRaisesRegex(BuildSnapshotError, "Build inputs do not match corresponding source"):
            self.validate(checkout)

    def test_line_ending_transformation_is_rejected(self):
        path = self.root / "scripts/fixture.py"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        with self.assertRaisesRegex(BuildSnapshotError, "Build inputs do not match corresponding source"):
            self.validate()

    def test_staged_content_is_not_treated_as_committed_source(self):
        (self.root / "scripts/fixture.py").write_bytes(b"staged replacement\n")
        self.git("add", "scripts/fixture.py")
        with self.assertRaises(BuildSnapshotError):
            self.validate()

    def test_uncommitted_compiler_input_is_rejected(self):
        (self.root / "scripts/added.py").write_bytes(b"new uncommitted input\n")
        with self.assertRaises(BuildSnapshotError):
            self.validate()

    def test_missing_tracked_source_is_rejected(self):
        (self.root / "scripts/fixture.py").unlink()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing build input"):
            self.validate()

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
                self.validate()

    def test_fixture_ignores_ambient_git_routing_and_global_hooks(self):
        foreign = Path(self.temporary.name) / "foreign"
        foreign.mkdir()
        subprocess.run(["git", "init", "--quiet", str(foreign)], cwd=foreign, env=self.git_env, check=True, capture_output=True)
        hooks = foreign / "synthetic-hooks"
        hooks.mkdir()
        sentinel = foreign / "hook-ran"
        hook = hooks / "reference-transaction"
        hook.write_text("#!/bin/sh\nprintf called >> " + shlex.quote(sentinel.as_posix()) + "\nexit 99\n")
        hook.chmod(0o755)
        config = foreign / "synthetic-global-config"
        subprocess.run(["git", "config", "--file", str(config), "core.hooksPath", str(hooks)],
                       cwd=foreign, env=self.git_env, check=True, capture_output=True)
        before = {path.relative_to(foreign).as_posix(): path.read_bytes()
                  for path in foreign.rglob("*") if path.is_file()}
        poisoned = {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                    "GIT_INDEX_FILE": str(foreign / "foreign-index"), "GIT_CONFIG_GLOBAL": str(config),
                    "GIT_CONFIG_SYSTEM": str(config), "GIT_CONFIG_NOSYSTEM": "0",
                    "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": str(hooks),
                    "GIT_TEMPLATE_DIR": str(hooks), "XDG_CONFIG_HOME": str(foreign)}
        nested = SourceCheckoutChecks("test_autocrlf_checkout_preserves_committed_bytes")
        try:
            with patch.dict(os.environ, poisoned):
                nested.setUp()
                checkout = nested.autocrlf_checkout()
                self.assertEqual(nested.validate(checkout)["status"], "passed")
            after = {path.relative_to(foreign).as_posix(): path.read_bytes()
                     for path in foreign.rglob("*") if path.is_file()}
            self.assertEqual(after, before)
            self.assertFalse((foreign / "foreign-index").exists())
            self.assertFalse((foreign / ".git/index").exists())
            self.assertFalse(sentinel.exists())
            # Positive control: load only the deliberately enabled synthetic
            # global config and prove its reachable hook really does execute.
            tree = subprocess.check_output(["git", "-C", str(foreign), "mktree"], input=b"", env=self.git_env).decode().strip()
            commit = subprocess.check_output(["git", "-C", str(foreign), "-c", "user.name=Synthetic fixture",
                "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                "commit-tree", tree, "-m", "Synthetic hook control"], env=self.git_env).decode().strip()
            control_env = dict(self.git_env, GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_COUNT="2")
            control = subprocess.run(["git", "-C", str(foreign), "update-ref", "refs/heads/synthetic-probe", commit],
                                     env=control_env, capture_output=True)
            self.assertNotEqual(control.returncode, 0)
            self.assertIn("called", sentinel.read_text())
        finally:
            nested.doCleanups()


if __name__ == "__main__":
    unittest.main(verbosity=2)

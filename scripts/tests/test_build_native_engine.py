"""Fresh, inert rebuild fixtures; no compiler, certificate store, media or input."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_native_engine as native


class NativeRebuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="knot-native-rebuild-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_ATTR_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="Synthetic", GIT_AUTHOR_EMAIL="synthetic@example.invalid",
                   GIT_COMMITTER_NAME="Synthetic", GIT_COMMITTER_EMAIL="synthetic@example.invalid",
                   ProgramFiles=str(self.root), INNO_COMPILER=str(self.root / "fake-iscc"))
        env["ProgramFiles(x86)"] = str(self.root)
        environment = patch.dict(os.environ, env, clear=True)
        environment.start(); self.addCleanup(environment.stop)
        root = patch.object(native, "ROOT", self.root)
        root.start(); self.addCleanup(root.stop)
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        for name in ["LICENSE", "INSTALLATION.md", "VERSION", ".gitignore", "fake-iscc",
                     "Assets/Brand/AppIcon.ico", "native-engine/windows/Native.iss", "scripts/verify_native_installer.ps1",
                     *["native-engine/windows/media/" + name for name in
                       ["media.cpp", "capture.cpp", "encoder.cpp", "h264.cpp", "synthetic_codec_test.cpp",
                        "h264_parser_test.cpp", "media_pacing_test.cpp", "media_activation_test.cpp"]]]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("build/\n" if name == ".gitignore" else "Fresh inert fixture\n")
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        commit = self.git("commit-tree", tree, input=b"Fresh fixture\n").decode().strip()
        self.git("update-ref", "HEAD", commit)
        self.output = self.root / "build/native-engine/windows"

    def git(self, *args, **kwargs):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.PIPE, **kwargs)

    def build_with_inert_tools(self, corrupt_public_pin=False, corrupt_installer_version=False):
        builder = native.Builder("windows", self.output)
        actual_run = builder.run

        def inert_run(label, argv, **kwargs):
            if label == "native-synthetic-codec":
                Path(argv[-2]).write_bytes(b"INERT synthetic codec fixture")
                Path(argv[-1]).write_text('{"hardwareEncoder":false}')
            elif label == "native-host-checks":
                self.assertEqual(argv[1], "--export-certificate")
                with Path(argv[2]).open("xb") as fixture:
                    fixture.write(b"INERT public certificate fixture")
                pin = "0" * 64 if corrupt_public_pin else native.digest(Path(argv[2]))
                with Path(argv[2]).with_suffix(".sha256").open("x") as fixture:
                    fixture.write(pin + "\n")
                return json.dumps(dict(status="passed", freshSyntheticOnly=True,
                                       actualCapture=False, actualSendInput=False)).encode()
            elif label == "native-installer":
                self.assertIn("/DNativeVersion=" + native.VERSION, argv)
                self.assertIn("/DNativeNumericVersion=" + native.NUMERIC_VERSION, argv)
                (self.output / ("Knot-Native-" + native.VERSION + "-windows-x64-setup.exe")).write_bytes(b"INERT installer")
            elif label == "native-installer-metadata":
                self.assertEqual(argv[0:4], ["powershell.exe", "-NoProfile", "-NonInteractive", "-File"])
                self.assertEqual(argv[5:], ["-Installer", self.output / ("Knot-Native-" + native.VERSION + "-windows-x64-setup.exe"),
                    "-ExpectedVersion", native.VERSION, "-ExpectedNumericVersion", native.NUMERIC_VERSION])
                parts = [int(part) for part in native.NUMERIC_VERSION.split(".")]
                return json.dumps(dict(status="passed", productName="Knot Native Preview",
                    productVersion="0.1.0" if corrupt_installer_version else native.VERSION,
                    fileVersion=native.NUMERIC_VERSION, fileParts=parts, productParts=parts,
                    inspectionOnly=True, installerExecuted=False,
                    inspector="INERT lifecycle test substitute; no PE inspected")).encode()
            elif label in ["native-parser-checks", "native-pacing-checks", "native-activation-checks"]:
                return b"INERT external-tool substitute for lifecycle checks only\n"
            else:
                return actual_run(label, argv, **kwargs)
            return b""

        def inert_csharp(label, *args):
            path = self.output / (label + ".exe")
            path.write_bytes(b"INERT managed image")
            return path

        def inert_msvc(*args):
            (self.output / "KnotNativeMedia.dll").write_bytes(b"INERT native image")

        with patch.object(builder, "run", side_effect=inert_run), \
             patch.object(builder, "csharp", side_effect=inert_csharp), \
             patch.object(builder, "msvc", side_effect=inert_msvc):
            builder.finish(builder.windows())

    def test_same_owned_output_can_rebuild_with_create_new_public_fixture(self):
        self.build_with_inert_tools()
        self.build_with_inert_tools()
        record = json.loads((self.output / "NATIVE-BUILD.json").read_text())
        self.assertTrue(record["checksPassed"])
        self.assertIn("native-test-public.cer", record["products"])
        self.assertIn("native-installer-metadata.json", record["products"])
        metadata = json.loads((self.output / "native-installer-metadata.json").read_text())
        self.assertEqual(metadata["productVersion"], native.VERSION)
        self.assertIn("INERT", metadata["inspector"])

    def test_failed_rebuild_cannot_retain_prior_success_claim(self):
        self.build_with_inert_tools()
        path = self.root / "native-engine/windows/uncommitted.cs"
        path.write_text("Fresh changed fixture\n")
        with self.assertRaises(ValueError):
            native.Builder("windows", self.output)
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "SHA256SUMS").exists())
        self.assertTrue((self.output / "native-test-public.cer").is_file())

    def test_exported_public_pin_must_match_its_certificate(self):
        with self.assertRaisesRegex(ValueError, "pin differs from exported public DER"):
            self.build_with_inert_tools(corrupt_public_pin=True)
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())

    def test_mislabeled_installer_cannot_retain_prior_success_claim(self):
        self.build_with_inert_tools()
        with self.assertRaisesRegex(ValueError, "installer version metadata differs"):
            self.build_with_inert_tools(corrupt_installer_version=True)
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "SHA256SUMS").exists())
        self.assertFalse((self.output / "native-installer-metadata.json").exists())

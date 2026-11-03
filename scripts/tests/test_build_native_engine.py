"""Fresh, inert rebuild fixtures; no compiler, certificate store, media or input."""
from pathlib import Path
import json
import os
import subprocess
import struct
import sys
import tempfile
import unittest
import zlib
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
                     "native-engine/pairing/tests/ManagedCryptoChecks.cs",
                     "native-engine/windows/tests/NativeVisualFixtures.cs",
                     *["native-engine/windows/media/" + name for name in
                       ["media.cpp", "capture.cpp", "encoder.cpp", "h264.cpp", "synthetic_codec_test.cpp",
                        "h264_parser_test.cpp", "media_pacing_test.cpp", "media_activation_test.cpp", "media_limits.h",
                        "media_wait.h", "media_wait_test.cpp"]]]:
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

    def build_with_inert_tools(self, corrupt_public_pin=False, corrupt_installer_version=False, invalid_visual=None,
                               invalid_four_k=None, invalid_four_k60=None, invalid_wait=None):
        builder = native.Builder("windows", self.output)
        actual_run = builder.run

        def inert_run(label, argv, **kwargs):
            if label == "native-synthetic-codec":
                Path(argv[-2]).write_bytes(b"INERT synthetic codec fixture")
                Path(argv[-1]).write_text('{"hardwareEncoder":false}')
            elif label == "native-media-synthetic-4k":
                self.assertEqual(argv[1], "--software-4k")
                Path(argv[-2]).write_bytes(b"INERT 4K codec fixture; no media executed")
                data = dict(v=1, synthetic=True, captureInvoked=False, hardwareEncoder=False,
                            codec="h264-annexb", width=3840, height=2160, fps=30,
                            bitrate=40000000, frames=6, keyframes=1, parserChecks=True,
                            peakEncoderInFlight=1, encoderCapacity=2, peakOutputScratchBytes=0)
                if invalid_four_k == "dimensions": data["width"] = 1920
                elif invalid_four_k == "capture": data["captureInvoked"] = True
                elif invalid_four_k == "scratch": data["peakOutputScratchBytes"] = 24883201
                Path(argv[-1]).write_text(json.dumps(data))
            elif label == "native-media-synthetic-4k60":
                self.assertEqual(argv[1], "--software-4k60")
                self.assertEqual(Path(argv[-2]).name, "synthetic-4k60.h264")
                self.assertEqual(Path(argv[-1]).name, "synthetic-4k60.json")
                Path(argv[-2]).write_bytes(b"INERT 4K60 codec fixture; no media executed")
                data = dict(v=1, synthetic=True, captureInvoked=False, hardwareEncoder=False,
                            codec="h264-annexb", width=3840, height=2160, fps=60,
                            bitrate=40000000, frames=12, keyframes=1, parserChecks=True,
                            peakEncoderInFlight=1, encoderCapacity=2, peakOutputScratchBytes=0)
                if invalid_four_k60 == "thirty-fps": data["fps"] = 30
                elif invalid_four_k60 == "six-frames": data["frames"] = 6
                Path(argv[-1]).write_text(json.dumps(data))
            elif label == "native-wait-checks":
                self.assertEqual(argv[1], "--json")
                data = dict(schema=1, status="PASS", freshSyntheticOnly=True,
                            captureInvoked=False, inputInvoked=False, codecInvoked=False,
                            clock="QueryPerformanceCounter", iterations=64, requestedMicros=1000,
                            unstartedRejected=True, expiredBudgetSkipped=True,
                            idempotentStartSingleHandle=True, handlesRestored=True,
                            scope="INERT lifecycle substitute; no timer or timing executed")
                for method in ["baselineSleep1", "ownedHighResolutionTimer"]:
                    data[method] = dict(p50Micros=1000, p95Micros=1500, maximumMicros=2000,
                                        totalMicros=64000, over16667Micros=0)
                if invalid_wait == "capture": data["captureInvoked"] = True
                elif invalid_wait == "distribution": data["ownedHighResolutionTimer"]["p95Micros"] = 999
                elif invalid_wait == "boolean": data["baselineSleep1"]["totalMicros"] = True
                with Path(argv[-1]).open("x") as report:
                    json.dump(data, report)
            elif label == "native-host-checks":
                self.assertEqual(argv[1], "--export-certificate")
                with Path(argv[2]).open("xb") as fixture:
                    fixture.write(b"INERT public certificate fixture")
                pin = "0" * 64 if corrupt_public_pin else native.digest(Path(argv[2]))
                with Path(argv[2]).with_suffix(".sha256").open("x") as fixture:
                    fixture.write(pin + "\n")
                return json.dumps(dict(status="passed", freshSyntheticOnly=True,
                                       actualCapture=False, actualSendInput=False)).encode()
            elif label == "native-pairing-managed-checks":
                return json.dumps(dict(status="passed", checks=7, freshSyntheticOnly=True,
                    networkInvoked=False, captureInvoked=False, actualInputInvoked=False)).encode()
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
            elif label == "native-ui-visual-checks":
                self.assertEqual(argv[1], "--output")
                visual_output = Path(argv[2])
                self.assertEqual(argv[3:], ["--brand-icon", self.root / "Assets/Brand/AppIcon.ico"])
                data = self.inert_visual_png()
                rows = []
                for state in ["idle", "invitation", "request", "preparing", "sharing", "failure", "help"]:
                    image = visual_output / ("windows-" + state + ".png")
                    image.write_bytes(data)
                    rows.append(dict(name=image.name, sha256=native.digest(image), bytes=len(data), width=640, height=480))
                report = dict(schema=1, status="passed", freshSyntheticOnly=True,
                    productionEntryInvoked=False, networkInvoked=False, clipboardInvoked=False,
                    certificateCreationInvoked=False, captureInvoked=False, actualInputInvoked=False,
                    screenCaptureInvoked=False, existingUserUIRead=False, syntheticWindowsShown=False,
                    visualAcceptance="manual-review-required", images=rows,
                    renderMethod="INERT lifecycle test substitute; no native UI rendered")
                if invalid_visual == "effects": report["networkInvoked"] = True
                elif invalid_visual == "shown-synthetic": report["syntheticWindowsShown"] = True
                elif invalid_visual == "digest": rows[0]["sha256"] = "0" * 64
                elif invalid_visual == "path": rows[0]["name"] = "../not-owned.png"
                (visual_output / "visual-checks.json").write_text(json.dumps(report) + "\n")
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

        def inert_pairing():
            paths = [self.output / name for name in ["KnotNativePairing.dll", "native-pairing-crypto-checks.json",
                                                     "KnotNativePairing-LICENSE.txt"]]
            for path in paths:
                path.write_bytes(b"INERT lifecycle-only substitute; no crypto compiled or invoked")
            return paths

        with patch.object(builder, "run", side_effect=inert_run), \
             patch.object(builder, "csharp", side_effect=inert_csharp), \
             patch.object(builder, "msvc", side_effect=inert_msvc), \
             patch.object(builder, "pairing_crypto", side_effect=inert_pairing):
            builder.finish(builder.windows())

    @staticmethod
    def inert_visual_png():
        """Valid synthetic bytes for build-boundary tests, never a UI screenshot."""
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
        row = b"\0" + b"".join(bytes([x % 256, x * 3 % 256, x * 7 % 256]) for x in range(640))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 640, 480, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(row * 480)) + chunk(b"IEND", b""))

    def test_same_owned_output_can_rebuild_with_create_new_public_fixture(self):
        self.build_with_inert_tools()
        self.build_with_inert_tools()
        record = json.loads((self.output / "NATIVE-BUILD.json").read_text())
        self.assertTrue(record["checksPassed"])
        self.assertIn("native-test-public.cer", record["products"])
        self.assertIn("native-installer-metadata.json", record["products"])
        self.assertIn("native-ui-visual-checks.json", record["products"])
        self.assertIn("synthetic-4k.h264", record["products"])
        self.assertIn("synthetic-codec-4k.json", record["products"])
        self.assertIn("synthetic-4k60.h264", record["products"])
        self.assertIn("synthetic-4k60.json", record["products"])
        self.assertIn("native-wait-checks.json", record["products"])
        metadata = json.loads((self.output / "native-installer-metadata.json").read_text())
        self.assertEqual(metadata["productVersion"], native.VERSION)
        self.assertIn("INERT", metadata["inspector"])
        visual = json.loads((self.output / "native-ui-visual-checks.json").read_text())
        self.assertEqual(visual["visualAcceptance"], "manual-review-required")
        self.assertIn("INERT", visual["rendererReport"]["renderMethod"])
        self.assertEqual(len(visual["rendererReport"]["images"]), 7)

    def test_failed_rebuild_cannot_retain_prior_success_claim(self):
        self.build_with_inert_tools()
        nested = [self.output / "visuals/visual-checks.json", self.output / "evidence/invocations.json",
                  self.output / "evidence/native-host-checks.stdout"]
        for record in nested:
            record.parent.mkdir(exist_ok=True)
            record.write_text('{"status":"passed","scope":"INERT previous run"}')
        path = self.root / "native-engine/windows/uncommitted.cs"
        path.write_text("Fresh changed fixture\n")
        with self.assertRaises(ValueError):
            native.Builder("windows", self.output)
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "SHA256SUMS").exists())
        for name in ["NATIVE-INPUTS.json", "native-ui-visual-checks.json", "native-cpp-checks.json",
                     "native-host-checks.json", "native-installer-metadata.json",
                     "native-pairing-crypto-checks.json", "native-pairing-managed-checks.json",
                     "synthetic-codec.json", "synthetic-codec-4k.json", "synthetic-4k60.json",
                     "native-wait-checks.json"]:
            self.assertFalse((self.output / name).exists(), name)
        self.assertTrue((self.output / "native-test-public.cer").is_file())
        for record in nested:
            self.assertFalse(record.exists(), str(record))

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

    def test_renderer_effect_claim_cannot_publish_success(self):
        self.build_with_inert_tools()
        with self.assertRaisesRegex(ValueError, "without production effects"):
            self.build_with_inert_tools(invalid_visual="effects")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "native-ui-visual-checks.json").exists())

    def test_renderer_digest_mismatch_cannot_publish_success(self):
        with self.assertRaisesRegex(ValueError, "image bytes differ"):
            self.build_with_inert_tools(invalid_visual="digest")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_renderer_cannot_reference_outside_owned_output(self):
        with self.assertRaisesRegex(ValueError, "Unsafe UI fixture image name"):
            self.build_with_inert_tools(invalid_visual="path")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "native-ui-visual-checks.json").exists())

    def test_four_k_fixture_must_have_actual_four_k_dimensions(self):
        self.build_with_inert_tools()
        with self.assertRaisesRegex(ValueError, "4K codec evidence"):
            self.build_with_inert_tools(invalid_four_k="dimensions")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_four_k_fixture_cannot_claim_real_capture(self):
        with self.assertRaisesRegex(ValueError, "4K codec evidence"):
            self.build_with_inert_tools(invalid_four_k="capture")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())

    def test_four_k_fixture_cannot_exceed_output_scratch_budget(self):
        with self.assertRaisesRegex(ValueError, "4K codec evidence"):
            self.build_with_inert_tools(invalid_four_k="scratch")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())

    def test_four_k60_fixture_cannot_relabel_thirty_fps_or_six_frames(self):
        for corrupt in ["thirty-fps", "six-frames"]:
            with self.subTest(corrupt=corrupt), self.assertRaisesRegex(ValueError, "4K codec evidence"):
                self.build_with_inert_tools(invalid_four_k60=corrupt)
            self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
            self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_timer_evidence_cannot_claim_capture_or_invalid_measurements(self):
        for corrupt in ["capture", "distribution", "boolean"]:
            with self.subTest(corrupt=corrupt), self.assertRaisesRegex(ValueError, "Wait evidence"):
                self.build_with_inert_tools(invalid_wait=corrupt)
            self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
            self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_synthetic_windows_may_be_shown_only_by_windows_fixture(self):
        self.build_with_inert_tools(invalid_visual="shown-synthetic")
        report = json.loads((self.output / "native-ui-visual-checks.json").read_text())
        self.assertTrue(report["rendererReport"]["syntheticWindowsShown"])

    def test_mac_secondary_validator_rejects_a_shown_window_claim(self):
        self.build_with_inert_tools(invalid_visual="shown-synthetic")
        report_path = self.output / "visuals/visual-checks.json"
        report = json.loads(report_path.read_text())
        builder = native.Builder("macos", self.output)
        report_path.parent.mkdir()
        report["images"] = []
        for state in ["idle", "reviewed", "approval", "streaming", "input-paused", "failed", "help", "compact", "dark"]:
            image = self.output / "visuals" / ("mac-" + state + ".png")
            image.write_bytes(self.inert_visual_png())
            report["images"].append(dict(name=image.name, sha256=native.digest(image), bytes=image.stat().st_size,
                                        width=640, height=480))
        report_path.write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "without production effects"):
            builder.record_visual_checks(self.output / "visuals", [])
        report["syntheticWindowsShown"] = False
        report_path.write_text(json.dumps(report))
        self.assertTrue(builder.record_visual_checks(self.output / "visuals", []).is_file())

    def test_rebuild_refuses_unsafe_owned_evidence_directory(self):
        self.build_with_inert_tools()
        evidence = self.output / "evidence"
        import shutil
        shutil.rmtree(evidence)
        with tempfile.TemporaryDirectory(prefix="knot-native-foreign-inert-") as temporary:
            foreign = Path(temporary)
            sentinel = foreign / "synthetic-sentinel.txt"
            sentinel.write_text("Fresh foreign fixture must survive")
            try:
                evidence.symlink_to(foreign, target_is_directory=True)
            except OSError:
                # Some Windows accounts cannot create directory symlinks. The
                # ordinary-file branch must still reject a non-directory owner.
                evidence.write_text("Fresh non-directory fixture")
            with self.assertRaisesRegex(ValueError, "Linked or non-directory native evidence"):
                native.Builder("windows", self.output)
            self.assertEqual(sentinel.read_text(), "Fresh foreign fixture must survive")
            self.assertTrue(evidence.is_symlink() or evidence.is_file())
            self.assertFalse((self.output / "NATIVE-BUILD.json").exists())

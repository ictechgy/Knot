"""Fresh, inert rebuild fixtures; no compiler, certificate store, media or input."""
from pathlib import Path
import base64
import copy
import hashlib
import json
import os
import shutil
import stat
import subprocess
import struct
import sys
import tempfile
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_native_engine as native
from test_windows_updates import stable_net8_runtime


def inert_reconfiguration_codec():
    """Record-shape fixture only; it never executes or proves an encoder."""
    segments, units = [], []
    for epoch, (width, height, fps, bitrate) in enumerate([(320, 180, 30, 2000000), (640, 360, 60, 4000000), (320, 180, 30, 2000000)]):
        segments.append(dict(epoch=epoch, width=width, height=height, fps=fps, bitrate=bitrate,
            firstSequence=epoch * 12 + 1, frames=12, drainComplete=True, drainInFlight=1, firstOutputIDR=True))
        for index in range(12):
            sequence = epoch * 12 + index + 1
            units.append(dict(sequence=sequence, offset=sequence - 1, length=1, flags=int(index == 0),
                timestampMicros=1000000 + epoch * 1000000 + index * 1000000 // fps, epoch=epoch))
    return dict(v=1, synthetic=True, captureInvoked=False, hardwareEncoder=False, codec="h264-annexb",
        frames=36, keyframes=3, parserChecks=True, reconfigurationFixture=True, drainChecks=True,
        emptyDrainChecks=True, segments=segments, accessUnits=units)


class CompilerAndCodecAdmissionTests(unittest.TestCase):
    def test_bad_explicit_compiler_does_not_select_installed_fallback(self):
        with tempfile.TemporaryDirectory(prefix="knot-compiler-admission-") as folder:
            root = Path(folder)
            fallback = root / "Inno Setup 7/ISCC.exe"
            fallback.parent.mkdir(); fallback.write_bytes(b"inert fixture")
            for override in ["", str(root / "missing")]:
                with patch.dict(os.environ, {"ProgramFiles": folder, "INNO_COMPILER": override}), self.assertRaisesRegex(ValueError, "Explicit INNO_COMPILER"):
                    native.inno_compiler()
            with patch.dict(os.environ, {"INNO_COMPILER": str(fallback)}):
                self.assertEqual(native.inno_compiler(), fallback)

    def test_small_codec_metadata_is_not_software_boolean_only(self):
        with tempfile.TemporaryDirectory(prefix="knot-codec-admission-") as folder:
            fixture = Path(folder) / "inert.h264"; fixture.write_bytes(b"not executed")
            valid = dict(v=1, synthetic=True, captureInvoked=False, hardwareEncoder=False,
                         codec="h264-annexb", width=320, height=180, fps=30,
                         bitrate=2000000, frames=120, keyframes=2, parserChecks=True)
            native.validate_codec_fixture(valid, fixture, 320, 180, 30, 120, 2000000)
            for delta in [dict(captureInvoked=True), dict(width=1920), dict(frames=True),
                          dict(keyframes=1), dict(parserChecks=False), dict(synthetic=False)]:
                with self.subTest(delta=delta), self.assertRaises(ValueError):
                    native.validate_codec_fixture(dict(valid, **delta), fixture, 320, 180, 30, 120, 2000000)

    def test_legacy_runtime_selection_ignores_prerelease_and_other_majors(self):
        with tempfile.TemporaryDirectory(prefix="knot-runtime-admission-") as folder:
            root = Path(folder)
            for name in ["8.0.5", "8.0.12", "9.0.0-preview.7", "10.0.1"]: (root / name).mkdir()
            self.assertEqual(stable_net8_runtime(root), "8.0.12")
            (root / "8.0.5").rmdir(); (root / "8.0.12").rmdir()
            with self.assertRaisesRegex(ValueError, "stable .NET 8"):
                stable_net8_runtime(root)

    def test_reconfiguration_record_binds_three_drained_epochs_and_all_bytes(self):
        with tempfile.TemporaryDirectory(prefix="knot-video-reconfigure-record-") as folder:
            fixture = Path(folder) / "inert.h264"; fixture.write_bytes(b"x" * 36)
            valid = inert_reconfiguration_codec()
            native.validate_reconfiguration_fixture(valid, fixture)
            changes = [lambda r: r.update(captureInvoked=True), lambda r: r.update(hardwareEncoder=True),
                lambda r: r.update(emptyDrainChecks=False), lambda r: r.update(frames=True),
                lambda r: r["segments"][1].update(width=1920), lambda r: r["segments"][2].update(drainComplete=False),
                lambda r: r["segments"][0].update(drainInFlight=3), lambda r: r["accessUnits"][12].update(flags=0),
                lambda r: r["accessUnits"][24].update(epoch=1), lambda r: r["accessUnits"][3].update(offset=0),
                lambda r: r["accessUnits"][20].update(timestampMicros=1), lambda r: r["accessUnits"][-1].update(length=2)]
            for change in changes:
                invalid = copy.deepcopy(valid); change(invalid)
                with self.assertRaises(ValueError): native.validate_reconfiguration_fixture(invalid, fixture)


def inert_file_vectors():
    """Lifecycle-validator substitute only; never evidence of a C# execution."""
    def packet(kind, body):
        return bytes([kind]) + struct.pack(">I", len(body)) + body

    def control(value):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()

    def encoded(value):
        return base64.b64encode(value).decode()

    empty_hash = hashlib.sha256(b"").hexdigest()
    payloads = {
        0x40: control(dict(v=2, token=base64.urlsafe_b64encode(bytes(32)).decode().rstrip("="))),
        0x41: control(dict(v=2)), 0x42: b"",
        0x43: control(dict(entry="a" * 32, name="fixture.txt", size=0, kind="file")),
        0x44: control(dict(count=1, truncated=False)),
        0x45: control(dict(name="fixture.txt", size=0)),
        0x46: control(dict(entry="a" * 32)),
        0x47: control(dict(name="fixture.txt", size=0, kind="file", count=0)),
        0x48: struct.pack(">Q", 0) + b"X",
        0x49: struct.pack(">Q", 0) + hashlib.sha256(b"").digest(),
        0x4a: control(dict(name="fixture.txt", size=0, sha256=empty_hash)),
        0x4b: control(dict(name="folder", size=0, count=0)),
        0x4c: control(dict(id=1, parent=0, name="child", kind="folder", size=0)),
        0x4d: control(dict(count=0, size=0, sha256=empty_hash)),
        0x4e: control(dict(nonce="a" * 32)), 0x4f: control(dict(nonce="a" * 32)),
        0x7f: control(dict(code="protocol")),
    }
    vectors = [dict(name="inert-kind-%02x" % kind, kind=kind, payloadBase64=encoded(body),
                    encodedBase64=encoded(packet(kind, body))) for kind, body in payloads.items()]
    files, transfers = [], []
    for name, filename, body in [("empty", "empty.txt", b""), ("unicode", "한글.txt", "Knot 파일\n".encode()),
                                 ("boundary", "boundary.bin", bytes(i % 251 for i in range(65541)))]:
        digest = hashlib.sha256(body).hexdigest()
        files.append(dict(name=filename, bytesBase64=encoded(body), sha256=digest, size=len(body)))
        stream = packet(0x47, control(dict(name=filename, size=len(body), kind="file", count=0)))
        for offset in range(0, len(body), 65536):
            stream += packet(0x48, struct.pack(">Q", offset) + body[offset:offset + 65536])
        stream += packet(0x49, struct.pack(">Q", len(body)) + hashlib.sha256(body).digest())
        transfers.append(dict(name=name, fileName=filename, size=len(body), sha256=digest,
                              bytesBase64=encoded(body), encodedBase64=encoded(stream)))
    trees = [inert_tree_vector("empty", "empty folder", []),
             inert_tree_vector("nested", "개발 자료", [(0, "빈 폴더", "folder", b""), (0, "한글.txt", "file", "안녕\n".encode())]),
             inert_tree_vector("boundary", "boundary", [(0, "boundary.bin", "file", bytes(i % 251 for i in range(65541)))])]
    return dict(schema=1, status="passed", freshSyntheticOnly=True, actualCapture=False, actualInput=False,
                vectors=vectors, files=files, transfers=transfers, trees=trees,
                rejectedFolderNames=["Rejected." + ext for ext in ["app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "rtfd", "photoslibrary", "playground", "pkg"]] + ["HELPER.XPC", ".app"])


def inert_tree_vector(name, folder_name, node_data):
    """Explicit inert transcript; never a substitute for the actual C# vectors."""
    def packet(kind, body): return bytes([kind]) + struct.pack(">I", len(body)) + body
    def control(obj): return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
    def encoded(body): return base64.b64encode(body).decode()
    total = sum(len(body) for _, _, _, body in node_data)
    stream = packet(0x47, control(dict(name=folder_name, size=total, kind="folder", count=len(node_data))))
    digest, nodes = hashlib.sha256(), []
    for index, (parent, child, kind, body) in enumerate(node_data, 1):
        raw = control(dict(id=index, parent=parent, name=child, kind=kind, size=len(body)))
        nodes.append(dict(jsonBase64=encoded(raw), bytesBase64=encoded(body)))
        stream += packet(0x4c, raw); digest.update(struct.pack(">I", len(raw))); digest.update(raw); digest.update(body)
        if kind == "file":
            for offset in range(0, len(body), 65536):
                stream += packet(0x48, struct.pack(">Q", offset) + body[offset:offset + 65536])
            stream += packet(0x49, struct.pack(">Q", len(body)) + hashlib.sha256(body).digest())
    stream += packet(0x4d, control(dict(count=len(nodes), size=total, sha256=digest.hexdigest())))
    return dict(name=name, folderName=folder_name, count=len(nodes), size=total, sha256=digest.hexdigest(),
                nodes=nodes, encodedBase64=encoded(stream))


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
                     "native-engine/windows/MonitorGeometry.cs",
                     "native-engine/windows/tests/NativeVisualFixtures.cs",
                     "native-engine/windows/tests/PreviewButtonPaintChecks.cs",
                     *["native-engine/windows/media/" + name for name in
                       ["media.cpp", "capture.cpp", "encoder.cpp", "h264.cpp", "synthetic_codec_test.cpp",
                        "h264_parser_test.cpp", "media_pacing_test.cpp", "media_activation_test.cpp", "media_limits.h",
                        "media_wait.h", "media_wait_test.cpp", "audio.cpp", "audio_convert.h", "kn_audio.h", "audio_convert_test.cpp"]]]:
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
                Path(argv[-1]).write_text(json.dumps(dict(v=1, synthetic=True, captureInvoked=False,
                    hardwareEncoder=False, codec="h264-annexb", width=320, height=180, fps=30,
                    bitrate=2000000, frames=120, keyframes=2, parserChecks=True)))
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
            elif label == "native-media-synthetic-reconfigure":
                self.assertEqual(argv[1], "--software-reconfigure")
                Path(argv[-2]).write_bytes(b"x" * 36)
                Path(argv[-1]).write_text(json.dumps(inert_reconfiguration_codec()))
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
                self.assertEqual(argv[3], "--export-persistent-certificate")
                with Path(argv[4]).open("xb") as fixture:
                    fixture.write(b"INERT production-path public certificate fixture")
                with Path(argv[4]).with_suffix(".sha256").open("x") as fixture:
                    fixture.write(native.digest(Path(argv[4])) + "\n")
                with (self.output / "native-file-vectors.json").open("x") as fixture:
                    json.dump(inert_file_vectors(), fixture)
                return json.dumps(dict(status="passed", freshSyntheticOnly=True,
                                       actualCapture=False, actualSendInput=False, actualAudioCapture=False, actualAudioPlayback=False,
                                       actualFreshExplorerInputFixtures=1, actualFreshExplorerOleFixtures=1,
                                       actualFreshTreeFixtures=9, actualFreshTreeTlsFixtures=28, actualPersistentCertificateFixtures=3,
                                       actualCrossProcessCertificateLeaseFixtures=1, actualFreshAudioFixtures=13,
                                       actualFreshAudioTlsFixtures=30, actualSyntheticAudioCaptureFixtures=6,
                                       actualFreshAudioHostFixtures=3, actualFreshVideoControlTlsFixtures=8)).encode()
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
                for state in ["idle", "invitation", "request", "preparing", "sharing", "failure", "help",
                              "short-idle", "short-code", "short-code-compact", "short-help-compact",
                              "short-idle-scale150", "short-idle-scale200", "files-sharing", "files-sharing-compact", "files-unavailable", "certificate-migration", "certificate-migration-compact",
                              "audio-ready", "audio-ready-compact", "audio-sharing", "audio-sharing-scale200"]:
                    image = visual_output / ("windows-" + state + ".png")
                    image.write_bytes(data)
                    rows.append(dict(name=image.name, sha256=native.digest(image), bytes=len(data), width=640, height=480,
                                     appBuildVersion=native.VERSION, buildVersionVisible=True))
                report = dict(schema=1, status="passed", freshSyntheticOnly=True,
                    productionEntryInvoked=False, networkInvoked=False, clipboardInvoked=False,
                    certificateCreationInvoked=False, captureInvoked=False, actualInputInvoked=False,
                    screenCaptureInvoked=False, existingUserUIRead=False, syntheticWindowsShown=False,
                    visualAcceptance="manual-review-required", images=rows,
                    monitorIllustrationChecks=dict(status="PASS", boundsCases=6, rasterCases=36,
                        minimumDpi=96, maximumDpi=288, centered=True, paneAspectPreserved=True,
                        panesContained=True, sameBoundsDpiPixelIdentity=True, degenerateBoundsSkipped=True,
                        scope="INERT geometry evidence substitute; no Windows renderer executed"),
                    buttonSurfaceChecks=dict(status="PASS", rasterCases=600, repaintCases=20, partialClipCases=20,
                        minimumDpi=96, maximumDpi=288, buttonKinds=4, opaqueCorners=True, parentBackdrop=True,
                        transparentAncestors=True, partialClipPreserved=True, actualGraphicsDpi=True,
                        allPixelsInitialized=True, inheritedOpaqueObserved=True, freshSyntheticOnly=True,
                        productionEntryInvoked=False, actualInputInvoked=False, screenCaptureInvoked=False),
                    fileAdaptersInvoked=0, renderMethod="INERT lifecycle test substitute; no native UI rendered")
                if invalid_visual == "effects": report["networkInvoked"] = True
                elif invalid_visual == "shown-synthetic": report["syntheticWindowsShown"] = True
                elif invalid_visual == "digest": rows[0]["sha256"] = "0" * 64
                elif invalid_visual == "path": rows[0]["name"] = "../not-owned.png"
                elif invalid_visual == "monitor-missing": del report["monitorIllustrationChecks"]
                elif invalid_visual == "monitor-false": report["monitorIllustrationChecks"]["panesContained"] = False
                elif invalid_visual == "monitor-count": report["monitorIllustrationChecks"]["rasterCases"] = 35
                elif invalid_visual == "monitor-bool": report["monitorIllustrationChecks"]["boundsCases"] = True
                elif invalid_visual == "monitor-scale-state": rows.pop()
                elif invalid_visual == "button-missing": del report["buttonSurfaceChecks"]
                elif invalid_visual == "button-corners": report["buttonSurfaceChecks"]["opaqueCorners"] = False
                elif invalid_visual == "button-count": report["buttonSurfaceChecks"]["rasterCases"] = 599
                elif invalid_visual == "version-missing": del rows[0]["appBuildVersion"]
                elif invalid_visual == "version-old": rows[0]["appBuildVersion"] = "0.1.0-native.17"
                elif invalid_visual == "version-hidden": rows[0]["buildVersionVisible"] = False
                (visual_output / "visual-checks.json").write_text(json.dumps(report) + "\n")
            elif label in ["native-parser-checks", "native-pacing-checks", "native-activation-checks"]:
                return b"INERT external-tool substitute for lifecycle checks only\n"
            elif label == "native-audio-conversion-checks":
                return json.dumps(dict(status="passed", freshSyntheticOnly=True, actualAudioCapture=False,
                    actualAudioPlayback=False, audioConversionFixtures=15, assertions=542)).encode()
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
        self.assertIn("native-file-vectors.json", record["products"])
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
        self.assertEqual(len(visual["rendererReport"]["images"]), 22)

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

    def test_embedded_update_resource_is_utf8_lf_on_every_platform(self):
        target = self.root / "synthetic-native-update-config.txt"
        canonical = native.VERSION + "\n\n\n\n\n"
        with patch.object(native, "native_update_resource", return_value=canonical), \
             patch.object(Path, "write_text", side_effect=AssertionError("Text-mode output can translate LF on Windows")):
            native.write_native_update_resource(target)
        self.assertEqual(target.read_bytes(), canonical.encode("utf-8"))
        self.assertNotIn(b"\r", target.read_bytes())
        self.assertEqual(target.read_bytes().split(b"\n")[0], native.VERSION.encode("ascii"))

    def test_windows_full_build_version_must_match_and_remain_visible(self):
        for invalid in ["version-missing", "version-old", "version-hidden"]:
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "build|version"):
                self.build_with_inert_tools(invalid_visual=invalid)
            self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
            self.assertFalse((self.output / "native-ui-visual-checks.json").exists())

    def test_windows_monitor_geometry_evidence_is_required_and_measured(self):
        for invalid in ["monitor-missing", "monitor-false", "monitor-count", "monitor-bool"]:
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "fresh measured geometry"):
                self.build_with_inert_tools(invalid_visual=invalid)
            self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
            self.assertFalse((self.output / "native-ui-visual-checks.json").exists())

    def test_windows_monitor_scaled_state_is_required(self):
        with self.assertRaisesRegex(ValueError, "omitted a required task state"):
            self.build_with_inert_tools(invalid_visual="monitor-scale-state")
        self.assertFalse((self.output / "NATIVE-BUILD.json").exists())
        self.assertFalse((self.output / "native-ui-visual-checks.json").exists())

    def test_windows_button_corner_evidence_is_required(self):
        for invalid in ["button-missing", "button-corners", "button-count"]:
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "complete-surface"):
                    self.build_with_inert_tools(invalid_visual=invalid)
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
        for state in ["idle", "reviewed", "approval", "streaming", "input-paused", "failed", "help", "compact", "dark", "fullscreen-text-rejected",
                      "searching", "empty", "nearby", "number", "number-working", "number-error",
                      "nearby-compact", "number-compact", "number-dark", "help-compact",
                      "files", "files-compact", "files-fullscreen", "files-working", "files-error", "files-empty",
                      "saved-devices", "saved-devices-compact", "number-remembered", "work-tools", "files-complete", "files-retry", "certificate-policy", "certificate-pin-mismatch",
                      "audio-on", "audio-muted", "audio-unavailable", "audio-on-compact", "audio-muted-compact", "audio-unavailable-compact",
                      "audio-connecting", "audio-connecting-compact", "fullscreen-audio-connecting-controls",
                      "wake-reconnect", "wake-reconnect-compact",
                      "sleep-recovery-compact", "storage-error", "storage-error-compact", "storage-streaming",
                      "storage-streaming-compact", "fullscreen-storage-error", "fullscreen-storage-error-controls",
                      "fullscreen-audio-on-controls", "fullscreen-audio-muted-controls", "fullscreen-audio-unavailable-controls",
                      "video-settings", "video-settings-compact", "video-settings-dark", "video-streaming", "video-paused-auto",
                      "video-paused-manual-compact", "fullscreen-video-applying", "fullscreen-video-paused", "video-rollback-settings", "video-unsupported-settings"]:
            image = self.output / "visuals" / ("mac-" + state + ".png")
            image.write_bytes(self.inert_visual_png())
            row = dict(name=image.name, sha256=native.digest(image), bytes=image.stat().st_size,
                       width=640, height=480, appBuildVersion=native.VERSION,
                       storageWarningVisible="storage-" in state)
            if state.startswith(("video-", "fullscreen-video-")):
                row.update(videoControlVisible=True, videoControlSyntheticOnly=True,
                           videoControlPaused="paused" in state, videoControlApplying="applying" in state)
            report["images"].append(row)
        report_path.write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "without production effects"):
            builder.record_visual_checks(self.output / "visuals", [])
        report["syntheticWindowsShown"] = False
        report.update(audioDeviceInvoked=False, audioEngineInvoked=False, audioAdaptersInvoked=0)
        baseline = copy.deepcopy(report)
        accepted_record = self.output / "native-ui-visual-checks.json"
        self.assertFalse(accepted_record.exists())
        for delta in [dict(audioDeviceInvoked=True), dict(audioEngineInvoked=True),
                      dict(audioAdaptersInvoked=1)]:
            with self.subTest(delta=delta):
                invalid_report = copy.deepcopy(baseline)
                invalid_report.update(delta)
                report_path.write_text(json.dumps(invalid_report))
                with self.assertRaisesRegex(ValueError, "must never invoke audio devices or output engines"):
                    builder.record_visual_checks(self.output / "visuals", [])
                self.assertFalse(accepted_record.exists())
        missing_storage = copy.deepcopy(baseline)
        missing_storage["images"] = [row for row in missing_storage["images"] if row["name"] != "mac-storage-error.png"]
        report_path.write_text(json.dumps(missing_storage))
        with self.assertRaisesRegex(ValueError, "omitted a required task state"):
            builder.record_visual_checks(self.output / "visuals", [])
        self.assertFalse(accepted_record.exists())
        wrong_build = copy.deepcopy(baseline)
        wrong_build["images"][0]["appBuildVersion"] = "0.1.0-native.17"
        report_path.write_text(json.dumps(wrong_build))
        with self.assertRaisesRegex(ValueError, "exact source build"):
            builder.record_visual_checks(self.output / "visuals", [])
        report_path.write_text(json.dumps(baseline))
        self.assertTrue(builder.record_visual_checks(self.output / "visuals", []).is_file())

    def test_rebuild_refuses_unsafe_owned_evidence_directory(self):
        self.build_with_inert_tools()
        evidence = self.output / "evidence"
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

    def assert_no_success_seals(self):
        for name in ["NATIVE-BUILD.json", "SHA256SUMS", "NATIVE-INPUTS.json"]:
            self.assertFalse((self.output / name).exists(), name)

    def link_fixture(self, link, target, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except OSError as error:
            self.skipTest("Synthetic symlink fixture unavailable: " + str(error))

    def test_rebuild_refuses_linked_product_destinations_before_writes(self):
        self.build_with_inert_tools()
        foreign = self.root / "fresh-foreign-products"
        foreign.mkdir()
        for name in ["LICENSE", "AppIcon.ico", "KnotNativePairing.dll", "KnotNativePairing-LICENSE.txt"]:
            with self.subTest(product=name):
                sentinel = foreign / name
                sentinel.write_bytes(b"Fresh foreign bytes must survive")
                product = self.output / name
                product.unlink(missing_ok=True)
                self.link_fixture(product, sentinel)
                try:
                    with self.assertRaisesRegex(ValueError, "Linked or reparse native output"):
                        self.build_with_inert_tools()
                    self.assertEqual(sentinel.read_bytes(), b"Fresh foreign bytes must survive")
                    self.assertTrue(product.is_symlink())
                    self.assert_no_success_seals()
                finally:
                    product.unlink()

    def test_rebuild_refuses_nested_pairing_library_link(self):
        self.build_with_inert_tools()
        library = self.output / "pairing/lib/libcrypto.a"
        library.parent.mkdir(parents=True)
        sentinel = self.root / "fresh-foreign-library"
        sentinel.write_bytes(b"Fresh foreign static library")
        self.link_fixture(library, sentinel)
        with self.assertRaisesRegex(ValueError, "Linked or reparse native output"):
            self.build_with_inert_tools()
        self.assertEqual(sentinel.read_bytes(), b"Fresh foreign static library")
        self.assertTrue(library.is_symlink())
        self.assert_no_success_seals()

    def test_rebuild_refuses_shared_product_file(self):
        self.build_with_inert_tools()
        product = self.output / "LICENSE"
        sentinel = self.root / "fresh-foreign-hardlink"
        sentinel.write_bytes(b"Fresh foreign shared bytes")
        product.unlink()
        try:
            os.link(sentinel, product)
        except OSError as error:
            self.skipTest("Synthetic hardlink fixture unavailable: " + str(error))
        with self.assertRaisesRegex(ValueError, "Non-regular or shared native output"):
            self.build_with_inert_tools()
        self.assertEqual(sentinel.read_bytes(), b"Fresh foreign shared bytes")
        self.assert_no_success_seals()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires a POSIX filesystem")
    def test_rebuild_refuses_nonregular_product_before_copy_can_block(self):
        self.build_with_inert_tools()
        product = self.output / "LICENSE"
        product.unlink()
        os.mkfifo(product)
        with self.assertRaisesRegex(ValueError, "Non-regular or shared native output"):
            native.Builder("windows", self.output)
        self.assertTrue(stat.S_ISFIFO(product.lstat().st_mode))
        self.assert_no_success_seals()

    def test_reparse_directory_is_rejected_without_traversal(self):
        self.build_with_inert_tools()
        directory = self.output / "pairing/lib"
        directory.mkdir(parents=True)
        sentinel = directory / "fresh-reparse-target-sentinel"
        sentinel.write_bytes(b"Fresh reparse target bytes")
        actual_stat = native.output_stat
        actual_iterdir = Path.iterdir

        def reparse_stat(path):
            info = actual_stat(path)
            if path == directory:
                return SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_nlink=1,
                                       st_file_attributes=0x410)
            return info

        def guarded_iterdir(path):
            if path == directory:
                self.fail("Builder traversed a Windows reparse directory")
            return actual_iterdir(path)

        with patch.object(native, "output_stat", reparse_stat), patch.object(Path, "iterdir", guarded_iterdir):
            with self.assertRaisesRegex(ValueError, "Linked or reparse native output"):
                self.build_with_inert_tools()
        self.assertEqual(sentinel.read_bytes(), b"Fresh reparse target bytes")
        self.assert_no_success_seals()

    @unittest.skipUnless(os.name == "nt", "Actual directory junction requires Windows")
    def test_windows_pairing_junction_cannot_write_foreign_directory(self):
        self.build_with_inert_tools()
        foreign = self.root / "fresh-foreign-junction-target"
        foreign.mkdir()
        sentinel = foreign / "libcrypto.a"
        sentinel.write_bytes(b"Fresh foreign junction bytes")
        pairing = self.output / "pairing"
        pairing.mkdir()
        junction = pairing / "lib"
        result = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(junction), str(foreign)],
                                capture_output=True)
        if result.returncode:
            self.skipTest("Synthetic junction fixture unavailable")
        try:
            with self.assertRaisesRegex(ValueError, "Linked or reparse native output"):
                self.build_with_inert_tools()
            self.assertEqual(sentinel.read_bytes(), b"Fresh foreign junction bytes")
            self.assert_no_success_seals()
        finally:
            junction.rmdir()

    def test_linked_ownership_marker_is_rejected_before_read(self):
        self.build_with_inert_tools()
        marker = self.output / ".native-build-owned.json"
        sentinel = self.root / "fresh-foreign-marker"
        sentinel.write_text(marker.read_text())
        marker.unlink()
        self.link_fixture(marker, sentinel)
        actual_read = Path.read_text

        def guarded_read(path, *args, **kwargs):
            if path == marker:
                self.fail("Builder read linked ownership marker")
            return actual_read(path, *args, **kwargs)

        with patch.object(Path, "read_text", guarded_read):
            with self.assertRaisesRegex(ValueError, "ownership marker must be an ordinary"):
                native.Builder("windows", self.output)
        self.assertEqual(sentinel.read_text(), '{"owner": "KnotNativeBuild", "schema": 1}\n')

    def test_output_ancestor_link_is_rejected_before_target_is_touched(self):
        (self.root / "build").mkdir()
        # Stay within build/ so lexical confinement must detect the link;
        # resolving it first would silently populate this unrelated directory.
        foreign = self.root / "build/fresh-output-target"
        foreign.mkdir()
        sentinel = foreign / "fresh-sentinel"
        sentinel.write_bytes(b"Fresh output ancestor bytes")
        self.link_fixture(self.root / "build/native-engine", foreign, directory=True)
        with self.assertRaisesRegex(ValueError, "Linked, reparse or non-directory native build output"):
            native.Builder("windows", self.output)
        self.assertEqual(sorted(p.name for p in foreign.iterdir()), [sentinel.name])
        self.assertEqual(sentinel.read_bytes(), b"Fresh output ancestor bytes")

    def test_stale_nested_evidence_and_mac_scratch_links_are_removed_without_following(self):
        self.build_with_inert_tools()
        foreign = self.root / "fresh-scratch-foreign"
        foreign.mkdir()
        sentinel = foreign / "fresh-sentinel"
        sentinel.write_bytes(b"Fresh scratch target bytes")
        for relative in ["evidence/old", "visuals/old", "swift/release", "dmg-input/Applications"]:
            link = self.output / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            self.link_fixture(link, foreign, directory=True)
        # Failed source validation must still retire all old success records and
        # remove nested scratch links, without traversing their foreign target.
        (self.root / "native-engine/windows/fresh-uncommitted.cs").write_text("Fresh source mismatch")
        with self.assertRaisesRegex(ValueError, "tracked|committed|source"):
            native.Builder("windows", self.output)
        self.assertEqual(sorted(p.name for p in foreign.iterdir()), [sentinel.name])
        self.assertEqual(sentinel.read_bytes(), b"Fresh scratch target bytes")
        self.assert_no_success_seals()
        for relative in ["evidence/old", "visuals", "swift", "dmg-input"]:
            self.assertFalse((self.output / relative).exists(), relative)

    def test_legitimate_owned_rebuild_discards_mac_generated_scratch_links(self):
        self.build_with_inert_tools()
        scratch = self.output / "swift"
        scratch.mkdir()
        target = scratch / "x86_64-apple-macosx/release"
        target.mkdir(parents=True)
        (target / "fresh-scratch-file").write_bytes(b"Fresh owned scratch bytes")
        self.link_fixture(scratch / "release", target, directory=True)
        staging = self.output / "dmg-input"
        staging.mkdir()
        # The real staging link points to /Applications; use a fresh empty
        # synthetic target here, never inspect an actual application directory.
        applications = self.root / "fresh-applications"
        applications.mkdir()
        self.link_fixture(staging / "Applications", applications, directory=True)
        self.build_with_inert_tools()
        self.assertTrue((self.output / "NATIVE-BUILD.json").is_file())
        self.assertEqual(list(applications.iterdir()), [])
        self.assertFalse(scratch.exists())
        self.assertFalse(staging.exists())


class NativeFileVectorTests(unittest.TestCase):
    def check_vectors(self, value, error=None):
        with tempfile.TemporaryDirectory(prefix="knot-inert-file-vectors-") as directory:
            path = Path(directory) / "native-file-vectors.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            if error:
                with self.assertRaisesRegex(ValueError, error):
                    native.validate_native_file_vectors(path)
            else:
                self.assertEqual(native.validate_native_file_vectors(path), value)

    def test_accepts_empty_unicode_and_chunk_boundary_sequences(self):
        self.check_vectors(inert_file_vectors())

    def test_rejects_live_effects_and_boolean_schema_or_size(self):
        original = inert_file_vectors()
        for field in ["actualCapture", "actualInput", "schema", "size"]:
            value = copy.deepcopy(original)
            if field == "size":
                value["files"][0]["size"] = False
            else:
                value[field] = True
            with self.subTest(field=field):
                self.check_vectors(value, "Native file")

    def test_rejects_missing_kind_and_truncated_packet(self):
        value = inert_file_vectors(); value["vectors"].pop()
        self.check_vectors(value, "coverage")
        value = inert_file_vectors()
        value["vectors"][0]["encodedBase64"] = base64.b64encode(b"\x40\0\0\0\x02X").decode()
        self.check_vectors(value, "bounds")

    def test_rejects_file_and_finish_hash_tampering(self):
        value = inert_file_vectors(); value["files"][0]["sha256"] = "0" * 64
        self.check_vectors(value, "hash")
        value = inert_file_vectors()
        body = bytearray(base64.b64decode(value["transfers"][2]["encodedBase64"]))
        body[-1] ^= 1
        value["transfers"][2]["encodedBase64"] = base64.b64encode(body).decode()
        self.check_vectors(value, "Finish")

    def test_rejects_transfer_offset_gap(self):
        value = inert_file_vectors()
        body = bytearray(base64.b64decode(value["transfers"][2]["encodedBase64"]))
        chunk_header = 5 + struct.unpack_from(">I", body, 1)[0]
        body[chunk_header + 5:chunk_header + 13] = struct.pack(">Q", 1)
        value["transfers"][2]["encodedBase64"] = base64.b64encode(body).decode()
        self.check_vectors(value, "offset")

    def test_rejects_missing_tree_or_boolean_count(self):
        value = inert_file_vectors(); value.pop("trees")
        self.check_vectors(value, "Native tree")
        value = inert_file_vectors(); value["trees"][0]["count"] = False
        self.check_vectors(value, "Native tree declared")

    def test_rejects_tree_parent_collisions_and_depth(self):
        value = inert_file_vectors()
        value["trees"][1] = inert_tree_vector("nested", "폴더", [(7, "빈 폴더", "folder", b"")])
        self.check_vectors(value, "Native tree parent")
        for names in [["A", "a"], ["é", "e\u0301"]]:
            value = inert_file_vectors()
            value["trees"][1] = inert_tree_vector("nested", "폴더", [(0, n, "folder", b"") for n in names])
            self.check_vectors(value, "Native tree sibling")
        value = inert_file_vectors()
        value["trees"][1] = inert_tree_vector("nested", "폴더", [(i, "깊은 폴더", "folder", b"") for i in range(17)])
        self.check_vectors(value, "Native tree sibling/depth")

    def test_rejects_tree_hash_and_node_data_tampering(self):
        value = inert_file_vectors(); value["trees"][2]["sha256"] = "0" * 64
        self.check_vectors(value, "Native tree terminal")
        value = inert_file_vectors()
        value["trees"][2]["nodes"][0]["bytesBase64"] = base64.b64encode(b"different").decode()
        self.check_vectors(value, "Native tree file size")

    def test_rejects_tree_unsafe_names_and_folder_payload(self):
        value = inert_file_vectors()
        value["trees"][1] = inert_tree_vector("nested", "폴더", [(0, "../escape", "folder", b"")])
        self.check_vectors(value, "Native tree basename")
        value = inert_file_vectors()
        value["trees"][1] = inert_tree_vector("nested", "폴더", [(0, "빈 폴더", "folder", b"data")])
        self.check_vectors(value, "Native tree folder bytes")

    def test_rejects_package_roots_nodes_and_missing_rejection_cases(self):
        value = inert_file_vectors(); value["rejectedFolderNames"].pop()
        self.check_vectors(value, "portable package rejection")
        for name in ["Helper.xpc", "Nested.app", ".app", "Doc.RTFD"]:
            value = inert_file_vectors()
            value["trees"][1] = inert_tree_vector("nested", name, [])
            self.check_vectors(value, "package root")
            value = inert_file_vectors()
            value["trees"][1] = inert_tree_vector("nested", "普通 폴더", [(0, name, "folder", b"")])
            self.check_vectors(value, "package node")

    def test_rejects_oversized_artifact_before_json_decode(self):
        with tempfile.TemporaryDirectory(prefix="knot-inert-file-vector-budget-") as directory:
            path = Path(directory) / "native-file-vectors.json"
            path.write_bytes(b" " * (1024 * 1024 + 1))
            with self.assertRaisesRegex(ValueError, "bounded"):
                native.validate_native_file_vectors(path)


class AudioConversionEvidenceTests(unittest.TestCase):
    def test_requires_synthetic_conversion_and_rejects_device_access(self):
        valid = dict(status="passed", freshSyntheticOnly=True, actualAudioCapture=False,
                     actualAudioPlayback=False, audioConversionFixtures=15, assertions=542)
        native.validate_audio_conversion(valid)
        for delta in [dict(actualAudioCapture=True), dict(actualAudioPlayback=True),
                      dict(audioConversionFixtures=True), dict(audioConversionFixtures=14), dict(assertions=541)]:
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                native.validate_audio_conversion(dict(valid, **delta))

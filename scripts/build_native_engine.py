#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the independent engine and fresh synthetic UI fixtures; never run production GUI/capture."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zlib
from datetime import datetime, timezone

sys.dont_write_bytecode = True
from build_snapshot import source_snapshot, validate_corresponding_source

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.0-native.5"
VERSION_BASE, PREVIEW_BUILD = VERSION.split("-native.", 1)
NUMERIC_VERSION = VERSION_BASE + "." + PREVIEW_BUILD


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def png_dimensions(data):
    """Bound and validate a fresh fixture PNG without third-party image code."""
    if not 1024 <= len(data) <= 32 * 1024 * 1024 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("UI fixture must be an ordinary nonempty PNG")
    at, dimensions, image_data, ended = 8, None, False, False
    while at < len(data):
        if at + 12 > len(data):
            raise ValueError("Truncated UI fixture PNG")
        size, kind = struct.unpack_from(">I4s", data, at)
        if size > 32 * 1024 * 1024 or at + 12 + size > len(data):
            raise ValueError("Oversized or truncated UI fixture PNG chunk")
        body = data[at + 8:at + 8 + size]
        if zlib.crc32(kind + body) & 0xffffffff != struct.unpack_from(">I", data, at + 8 + size)[0]:
            raise ValueError("UI fixture PNG checksum differs")
        if dimensions is None:
            if kind != b"IHDR" or size != 13:
                raise ValueError("UI fixture PNG has no initial dimensions")
            width, height = struct.unpack_from(">II", body)
            if not 320 <= width <= 8192 or not 240 <= height <= 8192 or width * height > 20_000_000:
                raise ValueError("UI fixture dimensions are outside the bounded preview scope")
            dimensions = width, height
        elif kind == b"IHDR":
            raise ValueError("Duplicate UI fixture PNG dimensions")
        if kind == b"IDAT":
            image_data = image_data or size > 0
        if kind == b"IEND":
            if size != 0 or at + 12 != len(data):
                raise ValueError("UI fixture PNG has trailing data")
            ended = True
            break
        at += 12 + size
    if not dimensions or not image_data or not ended:
        raise ValueError("UI fixture PNG is incomplete")
    return dimensions


class Builder:
    def __init__(self, platform, output, media_only=False):
        self.platform = platform
        self.media_only = media_only
        self.output = output.resolve()
        if self.output == ROOT or not self.output.is_relative_to(ROOT / "build"):
            raise ValueError("Native outputs must be in this checkout's build directory")
        marker = self.output / ".native-build-owned.json"
        if self.output.exists() and any(self.output.iterdir()) and not marker.is_file():
            raise ValueError("Refusing an existing output directory without our ownership marker")
        self.output.mkdir(parents=True, exist_ok=True)
        if self.output.is_symlink():
            raise ValueError("Linked native build output is unsupported")
        if marker.exists():
            if json.loads(marker.read_text()) != {"owner": "KnotNativeBuild", "schema": 1}:
                raise ValueError("Native build ownership marker differs")
        else:
            marker.write_text(json.dumps({"owner": "KnotNativeBuild", "schema": 1}) + "\n")
        # A failed rebuild must never leave an earlier success claim in place.
        for name in ["NATIVE-BUILD.json", "SHA256SUMS", "native-ui-visual-checks.json"]:
            (self.output / name).unlink(missing_ok=True)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir(exist_ok=True)
        self.commands = []
        self.sources = source_snapshot(ROOT)
        validate_corresponding_source(ROOT, self.sources)
        self.head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        (self.output / "NATIVE-INPUTS.json").write_text(json.dumps({
            "schema": 1, "head": self.head, "sourceManifest": self.sources,
            "scope": "Build inputs only; not successful checks or runtime acceptance"
        }, indent=2) + "\n")

    def run(self, label, argv, cwd=None, env=None, timeout=600, command_inputs=()):
        print(label, flush=True)
        start = datetime.now(timezone.utc).isoformat()
        result = subprocess.run([str(x) for x in argv], cwd=cwd or ROOT, env=env,
                                capture_output=True, timeout=timeout)
        (self.evidence / (label + ".stdout")).write_bytes(result.stdout)
        (self.evidence / (label + ".stderr")).write_bytes(result.stderr)
        self.commands.append({"label": label, "argv": [str(x) for x in argv],
                              "cwd": str(cwd or ROOT), "startedUTC": start,
                              "endedUTC": datetime.now(timezone.utc).isoformat(),
                              "exitCode": result.returncode,
                              "commandInputs": {p.name: digest(p) for p in command_inputs},
                              "stdoutSHA256": hashlib.sha256(result.stdout).hexdigest(),
                              "stderrSHA256": hashlib.sha256(result.stderr).hexdigest()})
        (self.evidence / "invocations.json").write_text(json.dumps(self.commands, indent=2) + "\n")
        if result.returncode:
            sys.stderr.write(result.stdout.decode("utf-8", errors="replace")[-12000:])
            sys.stderr.write(result.stderr.decode("utf-8", errors="replace")[-12000:])
            raise RuntimeError("Native build/check failed: " + label)
        return result.stdout

    def input(self, path):
        relative = Path(path).relative_to(ROOT).as_posix()
        if self.sources.get(relative) != digest(path):
            raise ValueError("Uncommitted or changed compiler input: " + relative)
        return path

    def visual_directory(self):
        path = self.output / "visuals"
        if path.is_symlink() or path.exists() and not path.is_dir():
            raise ValueError("Linked or non-directory native visual output is unsupported")
        if path.exists():
            shutil.rmtree(path)
        path.mkdir()
        return path

    def record_visual_checks(self, directory, source_inputs):
        report_path = directory / "visual-checks.json"
        if not report_path.is_file() or report_path.is_symlink() or report_path.stat().st_size > 2 * 1024 * 1024:
            raise ValueError("Fresh UI renderer report is missing or unsafe")
        raw = report_path.read_bytes()
        report = json.loads(raw.decode("utf-8-sig"))
        false_flags = ["productionEntryInvoked", "networkInvoked", "clipboardInvoked",
                       "certificateCreationInvoked", "captureInvoked", "actualInputInvoked",
                       "screenCaptureInvoked", "existingUserUIRead"]
        if (report.get("schema") != 1 or report.get("status") != "passed" or
                report.get("freshSyntheticOnly") is not True or
                any(report.get(flag) is not False for flag in false_flags) or
                type(report.get("syntheticWindowsShown")) is not bool or
                report.get("visualAcceptance") != "manual-review-required" or
                not isinstance(report.get("renderMethod"), str) or not report["renderMethod"].strip()):
            raise ValueError("UI checks must identify fresh synthetic rendering without production effects")
        rows = report.get("images")
        if not isinstance(rows, list) or not 7 <= len(rows) <= 32:
            raise ValueError("UI fixture state coverage is missing or excessive")
        names = set()
        for row in rows:
            name = row.get("name") if isinstance(row, dict) else None
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.png", name):
                raise ValueError("Unsafe UI fixture image name")
            if name.casefold() in names:
                raise ValueError("Duplicate UI fixture image name")
            names.add(name.casefold())
            image = directory / name
            if not image.is_file() or image.is_symlink() or image.stat().st_size > 32 * 1024 * 1024:
                raise ValueError("UI fixture image is missing or unsafe")
            data = image.read_bytes()
            width, height = png_dimensions(data)
            if (row.get("sha256") != hashlib.sha256(data).hexdigest() or row.get("bytes") != len(data) or
                    row.get("width") != width or row.get("height") != height):
                raise ValueError("UI fixture image bytes differ from the renderer report")
        required = ({"mac-" + name + ".png" for name in
                     ["idle", "reviewed", "approval", "streaming", "input-paused", "failed", "help", "compact", "dark"]}
                    if self.platform == "macos" else
                    {"windows-" + name + ".png" for name in
                     ["idle", "invitation", "request", "preparing", "sharing", "failure", "help"]})
        if not required.issubset(names):
            raise ValueError("UI fixture omitted a required task state")
        bound_sources = {self.input(path).relative_to(ROOT).as_posix(): digest(path) for path in source_inputs}
        record = {"schema": 1, "status": "passed", "platform": self.platform,
                  "head": self.head, "invocationLabel": "native-ui-visual-checks",
                  "sourceManifest": bound_sources, "rendererReportSHA256": hashlib.sha256(raw).hexdigest(),
                  "rendererReport": report, "imageDirectory": "visuals",
                  "visualAcceptance": "manual-review-required",
                  "scope": "Fresh synthetic UI rendering/layout and image-byte checks only; visual and physical-device acceptance are separate"}
        path = self.output / "native-ui-visual-checks.json"
        path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        return path

    def pairing_crypto(self):
        source = ROOT / "native-engine/pairing"
        provenance_path = self.input(source / "PROVENANCE.json")
        provenance = json.loads(provenance_path.read_text())
        if (provenance.get("commit") != "ed9209cff8b5a2fbc6c10050f29b3355048bda85" or
                provenance.get("tree") != "81d696d1f8cbc5a4b635bac55105a6f97b7a538c" or
                provenance.get("archive", {}).get("sha256") !=
                "4e3d008e36c65c7cfdde0909879e1b113cae8a8cbd6f445c22209a37c239fc16"):
            raise ValueError("Native pairing crypto provenance differs from the pinned source")
        vendor_prefix = "native-engine/pairing/vendor/boringssl/"
        vendored = {key[len(vendor_prefix):]: value for key, value in self.sources.items()
                    if key.startswith(vendor_prefix)}
        if not vendored or vendored != provenance.get("files"):
            raise ValueError("Native pairing vendor bytes differ from their complete pinned manifest")
        cmake_name = os.environ.get("KNOT_NATIVE_CMAKE") or shutil.which("cmake")
        if not cmake_name or not Path(cmake_name).is_file():
            raise ValueError("CMake3.22+ is required; set KNOT_NATIVE_CMAKE to its trusted executable")
        cmake = Path(cmake_name).resolve()
        version = self.run("pairing-cmake-version", [cmake, "--version"]).decode("utf-8-sig")
        found = re.search(r"cmake version (\d+)\.(\d+)", version)
        if not found or tuple(map(int, found.groups())) < (3, 22):
            raise ValueError("Native pairing crypto requires CMake3.22 or newer")
        build = self.output / "pairing"
        if build.is_symlink() or build.exists() and not build.is_dir():
            raise ValueError("Unsupported native pairing build output")
        if build.exists():
            shutil.rmtree(build)
        configure = [cmake, "-S", source, "-B", build, "-DCMAKE_BUILD_TYPE=Release",
                     "-DOPENSSL_NO_ASM=ON", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF"]
        if self.platform == "macos":
            configure.extend(["-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0"])
        else:
            # Match the installed MSVC instance instead of assuming one VS release
            # remains present on the runner or a contributor's machine.
            installer = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
            instances = json.loads(self.run("pairing-find-visual-studio", [installer, "-latest", "-products", "*",
                "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-format", "json"]).decode("utf-8-sig"))
            capabilities = json.loads(self.run("pairing-cmake-capabilities", [cmake, "-E", "capabilities"]).decode("utf-8-sig"))
            if not isinstance(instances, list) or len(instances) != 1:
                raise ValueError("One installed Visual Studio C++ x64 instance is required")
            instance = instances[0]
            major = str(instance.get("installationVersion", "")).split(".")[0]
            generators = [item["name"] for item in capabilities.get("generators", [])
                          if re.fullmatch(r"Visual Studio " + re.escape(major) + r" [0-9]{4}", item.get("name", ""))]
            installation = Path(instance.get("installationPath", ""))
            if not major.isdigit() or len(generators) != 1 or not installation.is_dir():
                raise ValueError("Installed MSVC release needs a matching supported CMake generator")
            configure.extend(["-G", generators[0], "-A", "x64", "-DCMAKE_GENERATOR_INSTANCE=" + str(installation)])
        inputs = [self.input(path) for path in [source / "CMakeLists.txt", source / "knot_pairing.cpp",
                  source / "include/knot_pairing.h", provenance_path,
                  source / "tests/crypto_checks.cpp", source / "tests/upstream_main.cpp"]]
        self.run("configure-native-pairing", configure, timeout=600, command_inputs=inputs)
        self.run("compile-native-pairing", [cmake, "--build", build, "--config", "Release", "--target",
                 "KnotNativePairing", "KnotPairingCryptoChecks", "KnotPairingUpstreamSpakeChecks", "--parallel", "4"],
                 timeout=1200, command_inputs=inputs)
        extension = ".exe" if self.platform == "windows" else ""
        checked = json.loads(self.run("native-pairing-crypto-checks",
                            [build / "bin" / ("KnotPairingCryptoChecks" + extension)], timeout=120).decode("utf-8-sig"))
        if (checked.get("status") != "passed" or checked.get("freshSyntheticOnly") is not True or
                any(checked.get(key) is not False for key in ["networkInvoked", "captureInvoked", "actualInputInvoked"]) or
                checked.get("abiVersion") != 2 or type(checked.get("checks")) is not int or checked["checks"] < 85 or
                any(checked.get(key) is not True for key in
                    ["hkdfKnownAnswer", "aesGcmKnownAnswer", "mutualConfirmation", "replayRejected"])):
            raise ValueError("Native pairing crypto checks did not prove the required synthetic contract")
        upstream = self.run("native-pairing-upstream-spake-checks",
                            [build / "bin" / ("KnotPairingUpstreamSpakeChecks" + extension)], timeout=120)
        if not re.search(rb"\[\s*PASSED\s*\]\s+6 tests?\.", upstream):
            raise ValueError("Pinned upstream SPAKE2 checks did not complete all six tests")
        if self.platform == "windows":
            libraries = [self.output / "KnotNativePairing.dll"]
            shutil.copy2(build / "bin/KnotNativePairing.dll", libraries[0])
        else:
            libraries = [self.output / name for name in ["libKnotNativePairing.a", "libcrypto.a"]]
            for path in libraries:
                shutil.copy2(build / "lib" / path.name, path)
        license_path = self.output / "KnotNativePairing-LICENSE.txt"
        shutil.copy2(self.input(source / "THIRD-PARTY-NOTICES.txt"), license_path)
        record = self.output / "native-pairing-crypto-checks.json"
        record.write_text(json.dumps({"schema": 1, "status": "passed", "platform": self.platform,
            "upstreamCommit": provenance["commit"], "upstreamTree": provenance["tree"],
            "archiveSHA256": provenance["archive"]["sha256"], "vendorFiles": len(vendored),
            "provenanceSHA256": digest(provenance_path), "checks": checked,
            "upstreamTests": 6, "upstreamOutputSHA256": hashlib.sha256(upstream).hexdigest(),
            "libraries": {path.name: {"sha256": digest(path), "bytes": path.stat().st_size} for path in libraries},
            "scope": "Actual pinned crypto implementation and fresh synthetic checks; no device capture/input or peer authorization"
        }, indent=2) + "\n")
        return [*libraries, record, license_path]

    def macos(self):
        package = ROOT / "native-engine/macos"
        scratch = self.output / "swift"
        media = ROOT / "native-engine/windows/media"
        self.input(media / "media_limits.h")
        crypto_products = self.pairing_crypto()
        swift_environment = dict(os.environ, KNOT_NATIVE_PAIRING_LIBDIR=str(self.output))
        parser_checks = self.output / "KnotNativeParserChecks"
        self.run("compile-native-parser-checks", ["/usr/bin/clang++", "-std=c++17", "-O1", "-g",
                 "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                 self.input(media / "h264.cpp"), self.input(media / "h264_parser_test.cpp"), "-o", parser_checks])
        self.run("native-parser-checks", [parser_checks], timeout=60)
        pacing_checks = self.output / "KnotNativePacingChecks"
        self.run("compile-native-pacing-checks", ["/usr/bin/clang++", "-std=c++17", "-O1", "-g",
                 "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                 self.input(media / "media_pacing_test.cpp"), "-o", pacing_checks])
        self.run("native-pacing-checks", [pacing_checks], timeout=60)
        activation_checks = self.output / "KnotNativeActivationChecks"
        self.run("compile-native-activation-checks", ["/usr/bin/clang++", "-std=c++17", "-O1", "-g",
                 "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                 self.input(media / "media_activation_test.cpp"), "-o", activation_checks])
        self.run("native-activation-checks", [activation_checks], timeout=60)
        cpp_record = self.record_cpp_checks()
        self.run("swift-version", ["/usr/bin/swift", "--version"])
        self.run("swift-build", ["/usr/bin/swift", "build", "--package-path", package,
                                 "--scratch-path", scratch, "-c", "release"], env=swift_environment)
        self.run("swift-checks", ["/usr/bin/swift", "test", "--package-path", package,
                                  "--scratch-path", scratch, "-c", "release"], timeout=600, env=swift_environment)
        binary_dir = Path(self.run("swift-bin-path", ["/usr/bin/swift", "build", "--package-path", package,
                                                     "--scratch-path", scratch, "-c", "release",
                                                     "--show-bin-path"], env=swift_environment).decode().strip())
        visuals = self.visual_directory()
        renderer = self.input(ROOT / "scripts/render_native_visual_fixture.py")
        visual_inputs = [renderer, package / "Package.swift", ROOT / "Assets/Brand/AppIcon.icns",
                         package / "Sources/CKnotPairing/module.modulemap", package / "Sources/CKnotPairing/shim.h",
                         ROOT / "native-engine/pairing/include/knot_pairing.h", ROOT / "native-engine/pairing/knot_pairing.cpp",
                         ROOT / "native-engine/pairing/CMakeLists.txt", ROOT / "native-engine/pairing/PROVENANCE.json",
                         *sorted((package / "Sources").rglob("*.swift")),
                         *sorted((package / "VisualFixtures").rglob("*.swift"))]
        self.run("native-ui-visual-checks", [sys.executable, renderer, "--output", visuals],
                 timeout=600, env=swift_environment, command_inputs=[self.input(path) for path in visual_inputs])
        visual_record = self.record_visual_checks(visuals, visual_inputs)
        app = self.output / "Knot Native Preview.app"
        if app.exists():
            shutil.rmtree(app)
        executable = app / "Contents/MacOS/KnotNativePreview"
        executable.parent.mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        shutil.copy2(binary_dir / "KnotNativePreview", executable)
        executable.chmod(0o755)
        shutil.copy2(self.input(ROOT / "Assets/Brand/AppIcon.icns"), resources / "AppIcon.icns")
        shutil.copy2(self.input(ROOT / "LICENSE"), resources / "LICENSE")
        shutil.copy2(self.output / "KnotNativePairing-LICENSE.txt", resources / "KnotNativePairing-LICENSE.txt")
        info = {"CFBundleExecutable": "KnotNativePreview", "CFBundleIdentifier": "org.knot.native-preview",
                "CFBundleName": "Knot Native Preview", "CFBundleDisplayName": "Knot Native Preview",
                "CFBundlePackageType": "APPL", "CFBundleVersion": PREVIEW_BUILD, "CFBundleShortVersionString": VERSION_BASE,
                "KnotNativeVersion": VERSION, "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "26.0",
                "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
                "NSLocalNetworkUsageDescription": "Connect securely to the Windows PC you select and explicitly approve."}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        self.run("sign-native-app", ["/usr/bin/codesign", "--force", "--sign", "-", app])
        self.run("verify-native-app", ["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        deps = self.run("inspect-native-dependencies", ["/usr/bin/otool", "-L", executable]).decode()
        if any(x in deps for x in ["Glimmer", "Sunshine", "Moonlight", "Sparkle", "libcrypto.", "libssl."]):
            raise ValueError("Experiment accidentally links a production engine")
        zip_path = self.output / ("Knot-Native-" + VERSION + "-macos-arm64.zip")
        self.run("zip-native-app", ["/usr/bin/ditto", "-c", "-k", "--keepParent", app, zip_path])
        image_root = self.output / "dmg-input"
        if image_root.exists():
            shutil.rmtree(image_root)
        image_root.mkdir()
        self.run("stage-native-dmg", ["/usr/bin/ditto", app, image_root / app.name])
        (image_root / "Applications").symlink_to("/Applications")
        dmg = self.output / ("Knot-Native-" + VERSION + "-macos-arm64.dmg")
        self.run("native-dmg", ["/usr/bin/hdiutil", "create", "-ov", "-format", "UDZO", "-volname",
                                "Knot Native Preview", "-srcfolder", image_root, dmg])
        self.run("verify-native-dmg", ["/usr/bin/hdiutil", "verify", dmg])
        return [zip_path, dmg, cpp_record, visual_record, *crypto_products]

    def record_cpp_checks(self):
        path = self.output / "native-cpp-checks.json"
        path.write_text(json.dumps({"schema": 1, "status": "passed", "platform": self.platform,
            "invocationLabels": ["native-parser-checks", "native-pacing-checks", "native-activation-checks"],
            "sanitizers": "address,undefined" if self.platform == "macos" else "none",
            "scope": "Fresh portable parser/pacing/activation ownership checks; no desktop capture, hardware encoder or input"
        }, indent=2) + "\n")
        return path

    def msvc(self, label, arguments):
        installer = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        vs = Path(self.run("find-visual-studio-" + label, [installer, "-latest", "-products", "*", "-requires",
                        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"]).decode("utf-8-sig").strip())
        if not vs.is_dir():
            raise ValueError("Visual Studio C++ x64 tools are required")
        compilers = sorted((vs / "VC/Tools/MSVC").glob("*/bin/Hostx64/x64/cl.exe"))
        if not compilers:
            raise ValueError("MSVC cl.exe is unavailable")
        compiler = compilers[-1]
        rsp = self.output / (label + ".rsp")
        rsp.write_text("\n".join(subprocess.list2cmdline([str(a)]) for a in arguments) + "\n", encoding="utf-16")
        cmd = self.output / (label + ".cmd")
        # All paths are our immutable checkout or a trusted vswhere result. A
        # response file keeps compiler inputs out of cmd.exe's command syntax.
        for p in [vs, compiler, rsp]:
            if any(c in str(p) for c in '\r\n%!&|<>^"'):
                raise ValueError("Unsupported shell metacharacter in native tool path")
        cmd.write_text('@echo off\ncall "' + str(vs / "Common7/Tools/VsDevCmd.bat") +
                       '" -arch=x64 -host_arch=x64 >nul\nif errorlevel 1 exit /b 1\n"' +
                       str(compiler) + '" @"' + str(rsp) + '"\nexit /b %errorlevel%\n', encoding="utf-8")
        recorded_inputs = []
        for path in [cmd, rsp]:
            recorded = self.evidence / path.name
            shutil.copy2(path, recorded)
            recorded_inputs.append(recorded)
        self.run(label, [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(cmd)],
                 cwd=self.output, command_inputs=recorded_inputs)

    def csharp(self, label, sources, main, target):
        refs = Path(os.environ["ProgramFiles(x86)"]) / "Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8"
        compiler = Path(os.environ["SystemRoot"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        if not compiler.is_file() or not refs.is_dir():
            raise ValueError(".NET Framework 4.8 x64 compiler/reference assemblies required")
        argv = [compiler, "/nologo", "/noconfig", "/nostdlib+", "/langversion:5", "/platform:x64",
                "/optimize+", "/target:" + target, "/main:" + main, "/out:" + str(self.output / (label + ".exe"))]
        for name in ["mscorlib", "System", "System.Core", "System.Security", "System.Drawing", "System.Windows.Forms"]:
            argv.append("/reference:" + str(refs / (name + ".dll")))
        if target == "winexe":
            argv.extend(["/win32icon:" + str(self.input(ROOT / "Assets/Brand/AppIcon.ico")),
                         "/win32manifest:" + str(self.input(ROOT / "native-engine/windows/Native.manifest"))])
        argv.extend(self.input(p) for p in sources)
        self.run("compile-" + label, argv)
        return self.output / (label + ".exe")

    def windows(self):
        media = ROOT / "native-engine/windows/media"
        self.input(media / "media_limits.h")
        crypto_products = self.pairing_crypto() if not self.media_only else []
        libs = ["d3d11.lib", "dxgi.lib", "mfplat.lib", "mf.lib", "mfuuid.lib", "ole32.lib",
                "oleaut32.lib", "uuid.lib", "user32.lib", "strmiids.lib"]
        common = ["/nologo", "/EHsc", "/std:c++17", "/O2", "/MT", "/W4", "/utf-8", "/DUNICODE", "/D_UNICODE",
                  "/D_WIN32_WINNT=0x0A00", "/I" + str(media)]
        parser_checks = self.output / "KnotNativeParserChecks.exe"
        self.msvc("compile-native-parser-checks", [*common, *map(self.input,
                  [media / "h264.cpp", media / "h264_parser_test.cpp"]), "/Fe:" + str(parser_checks)])
        self.run("native-parser-checks", [parser_checks], timeout=60)
        pacing_checks = self.output / "KnotNativePacingChecks.exe"
        self.msvc("compile-native-pacing-checks", [*common, self.input(media / "media_pacing_test.cpp"),
                  "/Fe:" + str(pacing_checks)])
        self.run("native-pacing-checks", [pacing_checks], timeout=60)
        activation_checks = self.output / "KnotNativeActivationChecks.exe"
        self.msvc("compile-native-activation-checks", [*common, self.input(media / "media_activation_test.cpp"),
                  "/Fe:" + str(activation_checks)])
        self.run("native-activation-checks", [activation_checks], timeout=60)
        cpp_record = self.record_cpp_checks()
        cpp = [media / n for n in ["media.cpp", "capture.cpp", "encoder.cpp", "h264.cpp"]]
        self.msvc("compile-native-media", [*common, "/LD", "/DKN_MEDIA_EXPORTS", *map(self.input, cpp),
                  "/Fe:" + str(self.output / "KnotNativeMedia.dll"), "/link", *libs])
        self.msvc("compile-native-codec-checks", [*common, *map(self.input, [media / "synthetic_codec_test.cpp",
                  media / "encoder.cpp", media / "h264.cpp"]), "/Fe:" + str(self.output / "KnotNativeMediaSynthetic.exe"),
                  "/link", *libs])
        fixture = self.output / "synthetic.h264"
        fixture_record = self.output / "synthetic-codec.json"
        self.run("native-synthetic-codec", [self.output / "KnotNativeMediaSynthetic.exe", "--software", fixture, fixture_record])
        native_record = json.loads(fixture_record.read_text())
        if native_record.get("hardwareEncoder") is not False or not fixture.is_file() or not fixture.stat().st_size:
            raise ValueError("Synthetic codec evidence must explicitly identify its software-only fixture")
        fixture_4k = self.output / "synthetic-4k.h264"
        fixture_record_4k = self.output / "synthetic-codec-4k.json"
        self.run("native-media-synthetic-4k", [self.output / "KnotNativeMediaSynthetic.exe", "--software-4k",
                                             fixture_4k, fixture_record_4k], timeout=180)
        native_record_4k = json.loads(fixture_record_4k.read_text())
        if (native_record_4k.get("v") != 1 or native_record_4k.get("synthetic") is not True or
                native_record_4k.get("captureInvoked") is not False or
                native_record_4k.get("hardwareEncoder") is not False or
                native_record_4k.get("codec") != "h264-annexb" or
                any(native_record_4k.get(key) != value for key, value in
                    {"width": 3840, "height": 2160, "fps": 30, "bitrate": 40000000, "frames": 6}.items()) or
                native_record_4k.get("parserChecks") is not True or
                native_record_4k.get("encoderCapacity") != 2 or
                type(native_record_4k.get("peakOutputScratchBytes")) is not int or
                not 0 <= native_record_4k["peakOutputScratchBytes"] <= 24883200 or
                type(native_record_4k.get("peakEncoderInFlight")) is not int or
                not 1 <= native_record_4k["peakEncoderInFlight"] <= 2 or
                type(native_record_4k.get("keyframes")) is not int or
                not 1 <= native_record_4k["keyframes"] <= 6 or
                not fixture_4k.is_file() or not fixture_4k.stat().st_size):
            raise ValueError("4K codec evidence must prove its exact fresh software-only synthetic profile")
        if self.media_only:
            return [self.output / "KnotNativeMedia.dll", fixture, fixture_record, fixture_4k, fixture_record_4k, cpp_record]
        sources = sorted((ROOT / "native-engine/windows").glob("*.cs"))
        executable = self.csharp("Knot-Native-Preview", sources, "Knot.NativePreview.Program", "winexe")
        managed_crypto = self.csharp("KnotNativePairingBridgeChecks",
            sources + [self.input(ROOT / "native-engine/pairing/tests/ManagedCryptoChecks.cs")],
            "Knot.NativePreview.NativePairingBridgeChecks", "exe")
        managed_result = json.loads(self.run("native-pairing-managed-checks", [managed_crypto],
                                             timeout=120).decode("utf-8-sig"))
        if (managed_result.get("status") != "passed" or managed_result.get("checks") != 7 or
                managed_result.get("freshSyntheticOnly") is not True or
                any(managed_result.get(key) is not False for key in
                    ["networkInvoked", "captureInvoked", "actualInputInvoked"])):
            raise ValueError("Native pairing managed bridge did not pass its actual synthetic ABI checks")
        managed_record = self.output / "native-pairing-managed-checks.json"
        managed_record.write_text(json.dumps(managed_result, indent=2) + "\n")
        checks = self.csharp("KnotNativeChecks", sources + sorted((ROOT / "native-engine/windows/tests").glob("*.cs")),
                             "Knot.NativePreview.NativeChecks", "exe")
        public_certificate = self.output / "native-test-public.cer"
        public_pin = self.output / "native-test-public.sha256"
        # NativeChecks deliberately creates only a new, owned fixture file.
        public_certificate.unlink(missing_ok=True)
        public_pin.unlink(missing_ok=True)
        result = self.run("native-host-checks", [checks, "--export-certificate", public_certificate],
                          timeout=180).decode("utf-8-sig").strip()
        parsed = json.loads(result)
        if (parsed.get("status") != "passed" or parsed.get("freshSyntheticOnly") is not True or
                parsed.get("actualCapture") is not False or parsed.get("actualSendInput") is not False):
            raise ValueError("Native host checks must prove their fresh/inert capture and input scope")
        (self.output / "native-host-checks.json").write_text(json.dumps(parsed, indent=2) + "\n")
        if public_pin.read_text().strip() != digest(public_certificate):
            raise ValueError("Fresh Windows certificate pin differs from exported public DER")
        visuals = self.visual_directory()
        visual_fixture = ROOT / "native-engine/windows/tests/NativeVisualFixtures.cs"
        visual_checks = self.csharp("KnotNativeVisualFixtures", sources + [visual_fixture],
                                    "Knot.NativePreview.NativeVisualFixtures", "exe")
        brand_icon = self.input(ROOT / "Assets/Brand/AppIcon.ico")
        visual_inputs = [*sources, visual_fixture, brand_icon]
        self.run("native-ui-visual-checks", [visual_checks, "--output", visuals, "--brand-icon", brand_icon],
                 timeout=180, command_inputs=[self.input(path) for path in visual_inputs])
        visual_record = self.record_visual_checks(visuals, visual_inputs)
        shutil.copy2(self.input(ROOT / "Assets/Brand/AppIcon.ico"), self.output / "AppIcon.ico")
        shutil.copy2(self.input(ROOT / "LICENSE"), self.output / "LICENSE")
        candidates = [Path(os.environ[k]) / (version + "/ISCC.exe")
                      for k in ["ProgramFiles", "ProgramFiles(x86)"]
                      for version in ["Inno Setup 7", "Inno Setup 6"]]
        if os.environ.get("INNO_COMPILER"):
            candidates.insert(0, Path(os.environ["INNO_COMPILER"]))
        iscc = next((p for p in candidates if p.is_file()), None)
        if not iscc:
            raise ValueError("Inno Setup compiler is required for the native experiment installer")
        self.run("native-installer", [iscc, "/DNativeOutput=" + str(self.output), "/DNativeVersion=" + VERSION,
                                       "/DNativeNumericVersion=" + NUMERIC_VERSION,
                                       self.input(ROOT / "native-engine/windows/Native.iss")])
        setup = self.output / ("Knot-Native-" + VERSION + "-windows-x64-setup.exe")
        if not setup.is_file():
            raise ValueError("Native installer output is missing")
        installer_metadata = self.output / "native-installer-metadata.json"
        installer_metadata.unlink(missing_ok=True)
        inspected = json.loads(self.run("native-installer-metadata", ["powershell.exe", "-NoProfile", "-NonInteractive",
            "-File", self.input(ROOT / "scripts/verify_native_installer.ps1"), "-Installer", setup,
            "-ExpectedVersion", VERSION, "-ExpectedNumericVersion", NUMERIC_VERSION], timeout=60).decode("utf-8-sig"))
        expected_parts = [int(part) for part in NUMERIC_VERSION.split(".")]
        if (inspected.get("status") != "passed" or inspected.get("productName") != "Knot Native Preview" or
                inspected.get("productVersion") != VERSION or inspected.get("fileVersion") != NUMERIC_VERSION or
                inspected.get("fileParts") != expected_parts or inspected.get("productParts") != expected_parts or
                inspected.get("inspectionOnly") is not True or inspected.get("installerExecuted") is not False):
            raise ValueError("Native installer version metadata differs from the checked preview version")
        installer_metadata.write_text(json.dumps(inspected, indent=2) + "\n")
        return [executable, self.output / "KnotNativeMedia.dll", setup, fixture, fixture_record, fixture_4k, fixture_record_4k,
                self.output / "native-host-checks.json", public_certificate, public_pin, cpp_record, installer_metadata,
                visual_record, managed_record, *crypto_products]

    def finish(self, files):
        if source_snapshot(ROOT) != self.sources:
            raise ValueError("Source changed during native build")
        source = self.output / ("Knot-Native-" + VERSION + "-source.tar.gz")
        self.run("native-corresponding-source", ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf",
                 "archive", "--format=tar.gz", "--prefix=Knot-Native-source/", "--output", source, self.head])
        files = [*files, source, self.output / "NATIVE-INPUTS.json"]
        record = {"schema": 1, "version": VERSION, "platform": self.platform, "head": self.head,
                  "mode": "media-only" if self.media_only else "complete-experiment",
                  "checksPassed": True, "sourceManifest": self.sources, "invocations": self.commands,
                  "products": {p.name: {"sha256": digest(p), "bytes": p.stat().st_size} for p in files},
                  "scope": "Compiled independent engine plus fresh synthetic/TLS/codec checks; no production capture or input",
                  "acceptance": {"hardwareCaptureTested": False, "hardwareEncodeTested": False,
                                 "realWindowsHomeTested": False, "twoDeviceStreamingTested": False,
                                 "trustedSigning": False, "productionFallbackModified": False}}
        (self.output / "NATIVE-BUILD.json").write_text(json.dumps(record, indent=2) + "\n")
        files.append(self.output / "NATIVE-BUILD.json")
        (self.output / "SHA256SUMS").write_text("".join(digest(p) + "  " + p.name + "\n" for p in files))
        print("Native experiment built and checked: " + str(self.output), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=["macos", "windows"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--media-only", action="store_true", help="Compile Windows DLL and run synthetic codec only; no host app proof")
    args = parser.parse_args()
    if args.media_only and args.platform != "windows":
        parser.error("--media-only requires --platform windows")
    builder = Builder(args.platform, args.output or ROOT / "build/native-engine" / args.platform, args.media_only)
    builder.finish(builder.macos() if args.platform == "macos" else builder.windows())


if __name__ == "__main__":
    main()

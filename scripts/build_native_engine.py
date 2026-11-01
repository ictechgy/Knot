#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build only the independent native-engine experiment; never launch its GUI/capture."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone

sys.dont_write_bytecode = True
from build_snapshot import source_snapshot, validate_corresponding_source

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.0-native.3"
VERSION_BASE, PREVIEW_BUILD = VERSION.split("-native.", 1)
NUMERIC_VERSION = VERSION_BASE + "." + PREVIEW_BUILD


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


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
        for name in ["NATIVE-BUILD.json", "SHA256SUMS"]:
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

    def macos(self):
        package = ROOT / "native-engine/macos"
        scratch = self.output / "swift"
        media = ROOT / "native-engine/windows/media"
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
                                 "--scratch-path", scratch, "-c", "release"])
        self.run("swift-checks", ["/usr/bin/swift", "test", "--package-path", package,
                                  "--scratch-path", scratch, "-c", "release"], timeout=600)
        binary_dir = Path(self.run("swift-bin-path", ["/usr/bin/swift", "build", "--package-path", package,
                                                     "--scratch-path", scratch, "-c", "release",
                                                     "--show-bin-path"]).decode().strip())
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
        if any(x in deps for x in ["Glimmer", "Sunshine", "Moonlight", "Sparkle"]):
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
        return [zip_path, dmg, cpp_record]

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
        if self.media_only:
            return [self.output / "KnotNativeMedia.dll", fixture, fixture_record, cpp_record]
        sources = sorted((ROOT / "native-engine/windows").glob("*.cs"))
        executable = self.csharp("Knot-Native-Preview", sources, "Knot.NativePreview.Program", "winexe")
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
        return [executable, self.output / "KnotNativeMedia.dll", setup, fixture, fixture_record,
                self.output / "native-host-checks.json", public_certificate, public_pin, cpp_record, installer_metadata]

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

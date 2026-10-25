#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline build/check path. Does not disable a sandbox or launch the GUI/network."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, plistlib, shutil, subprocess, sys
from build_snapshot import host_supervisor_snapshot, source_snapshot, tree_snapshot
from system_dependencies import SystemDependencyError, parse_system_dependencies
from update_runtime import publisher_config, sign_sparkle, sparkle_info, stage_sparkle
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--skip-checks", action="store_true")
parser.add_argument("--configuration", choices=["release", "debug"], default="release")
args = parser.parse_args()
update_publisher = publisher_config(ROOT)
signing_identity = os.environ.get("MACOS_SIGNING_IDENTITY", "-")
if update_publisher and not signing_identity.startswith("Developer ID Application:"):
    # PR/unsigned preview builds must remain runnable without release credentials.
    # Never weaken Library Validation or activate the updater in an ad-hoc app.
    update_publisher = None
    print("Unsigned preview: automatic updating is disabled; Developer ID release build required.", flush=True)
BUILD = ROOT / "build" / args.configuration
LIB = BUILD / "lib"
CACHE = BUILD / "module-cache"
EVIDENCE = ROOT / "evidence" / ("build-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
for p in [BUILD, LIB, CACHE, EVIDENCE]: p.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env["CLANG_MODULE_CACHE_PATH"] = str(CACHE)
env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(CACHE)
sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
common = ["-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-sdk", sdk, "-module-cache-path", str(CACHE)]
common += ["-O"] if args.configuration == "release" else ["-Onone", "-g", "-D", "DEBUG"]
records = []
snapshot = source_snapshot(ROOT)
(EVIDENCE / "source-manifest.json").write_text(json.dumps(snapshot, indent=2))
def run(label, argv):
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    print(label, flush=True)
    p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True)
    (EVIDENCE / (label + ".stdout")).write_bytes(p.stdout)
    (EVIDENCE / (label + ".stderr")).write_bytes(p.stderr)
    record = dict(label=label, argv=argv, cwd=str(ROOT), startUTC=start,
                  endUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(), exitCode=p.returncode)
    records.append(record)
    (EVIDENCE / "build-invocations.json").write_text(json.dumps(records, indent=2))
    (ROOT / "evidence/latest-build.json").write_text(json.dumps({"directory": str(EVIDENCE.relative_to(ROOT)), "lastStage": label, "exitCode": p.returncode}, indent=2))
    if p.returncode:
        sys.stderr.write(p.stderr.decode(errors="replace")[-12000:])
        sys.stdout.write(p.stdout.decode(errors="replace")[-4000:])
        raise SystemExit(p.returncode)
    return p.stdout
def compile_module(name, folder, package):
    sources = sorted(folder.rglob("*.swift"))
    signature = hashlib.sha256(json.dumps(common).encode())
    signature.update(b"static-private-archives-v1")
    for source in sources:
        signature.update(str(source.relative_to(ROOT)).encode()); signature.update(source.read_bytes())
    digest = signature.hexdigest()
    stamp = LIB / (name + ".hash")
    library = LIB / ("lib" + name + ".a")
    module = LIB / (name + ".swiftmodule")
    if stamp.exists() and stamp.read_text() == digest and library.exists() and module.exists():
        print(name + ": unchanged module", flush=True); return
    rsp = BUILD / (name + ".sources")
    rsp.write_text("".join(json.dumps(str(s)) + "\n" for s in sources))
    argv = ["/usr/bin/swiftc", "-parse-as-library", "-emit-library", "-static", "-emit-module",
            "-module-name", name, "-package-name", package, "-D", "SWIFT_PACKAGE",
            *common, "@" + str(rsp), "-emit-module-path", str(module), "-o", str(library)]
    run("compile-" + name, argv); stamp.write_text(digest)
run("verify-vendor", ["/usr/bin/python3", str(ROOT / "scripts/verify_vendor.py")])
if not args.skip_checks:
    run("connection-qr-checks", [sys.executable, str(ROOT / "scripts/tests/test_connection_qr.py")])
    run("enrollment-protocol-checks", [sys.executable, str(ROOT / "scripts/tests/test_enrollment.py")])
    run("update-policy-checks", [sys.executable, str(ROOT / "scripts/tests/test_update_policy.py")])
    run("build-contract-checks", [sys.executable, str(ROOT / "scripts/tests/test_build_snapshot.py")])
    run("system-dependency-policy-checks", [sys.executable, str(ROOT / "scripts/tests/test_system_dependencies.py")])
    run("input-batching-checks", [sys.executable, str(ROOT / "scripts/tests/test_input_batching.py")])
    run("control-hardening-checks", [sys.executable, str(ROOT / "scripts/tests/test_control_hardening.py")])
    run("desktop-input-backpressure-checks", [sys.executable, str(ROOT / "scripts/tests/test_desktop_input_backpressure.py")])
    run("video-frame-lifecycle-checks", [sys.executable, str(ROOT / "scripts/tests/test_video_frame_lifecycle.py")])
    run("video-color-checks", [sys.executable, str(ROOT / "scripts/tests/test_video_color.py")])
    run("video-prepare-checks", [sys.executable, str(ROOT / "scripts/benchmarks/video_prepare.py"), "--checks-only"])
    run("media-receive-lifecycle-checks", [sys.executable, str(ROOT / "scripts/tests/test_media_lifecycle.py")])
    run("audio-notice-power-checks", [sys.executable, str(ROOT / "scripts/tests/test_audio_notice_power.py")])
    run("stream-launch-lifecycle-checks", [sys.executable, str(ROOT / "scripts/tests/test_stream_launch_lifecycle.py")])
    run("rtsp-replay-checks", [sys.executable, str(ROOT / "scripts/tests/test_rtsp_replay.py")])
    run("private-storage-checks", [sys.executable, str(ROOT / "scripts/check_private_storage.py")])
compile_module("GlimmerEngine", ROOT / "Vendor/Glimmer/GlimmerEngine", "Glimmer")
compile_module("DeskBridgeCore", ROOT / "Sources/DeskBridgeCore", "DeskBridge")
app = ROOT / "dist/Knot.app"
if app.exists(): shutil.rmtree(app)
macos = app / "Contents/MacOS"
frameworks = app / "Contents/Frameworks"
resources = app / "Contents/Resources"
helpers = app / "Contents/Helpers"
if frameworks.exists(): shutil.rmtree(frameworks)
for p in [macos, frameworks, resources, helpers]: p.mkdir(parents=True, exist_ok=True)
supervisor = helpers / "KnotHostSupervisor"
run("compile-host-supervisor", ["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
    "-arch", "arm64", "-mmacosx-version-min=26.0", "-isysroot", sdk,
    str(ROOT / "host/macos/KnotHostSupervisor.c"), "-o", str(supervisor)])
run("sign-host-supervisor", ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(supervisor)])
run("verify-host-supervisor", ["/usr/bin/codesign", "--verify", "--strict", str(supervisor)])
helper_entitlements = run("inspect-host-supervisor-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(supervisor)])
if helper_entitlements.strip() and plistlib.loads(helper_entitlements) != {}:
    raise SystemExit("The host supervisor must have no entitlements.")
try:
    helper_dependencies = parse_system_dependencies(
        run("inspect-host-supervisor-dependencies", ["/usr/bin/otool", "-L", str(supervisor)]), supervisor)
except SystemDependencyError as error:
    raise SystemExit(str(error))
host_supervisor_snapshot(app)
if not args.skip_checks:
    run("mac-host-lifetime-checks", [sys.executable, str(ROOT / "scripts/tests/test_mac_host_lifetime.py"), "--supervisor", str(supervisor)])
sparkle = stage_sparkle(ROOT, frameworks)
sign_sparkle(sparkle, run, signing_identity, release=signing_identity != "-")
shutil.copy2(ROOT / "Vendor/UpdateRuntime/Sparkle-LICENSE", resources / "Sparkle-LICENSE.txt")
update_flags = (["-D", "KNOT_SIGNED_UPDATES", "-F", str(frameworks), "-framework", "Sparkle",
                 "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"] if update_publisher else [])
app_sources = sorted((ROOT / "Sources/DeskBridgeApp").rglob("*.swift"))
run("compile-DeskBridge", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeApp",
    "-package-name", "DeskBridge", *common, *update_flags, "-I", str(LIB), "-L", str(LIB),
    str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
    *map(str, app_sources), "-o", str(macos / "DeskBridge")])
if not args.skip_checks:
    checks = sorted((ROOT / "Sources/DeskBridgeChecks").glob("*.swift"))
    run("compile-checks", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeChecks",
        "-package-name", "DeskBridge", *common, *update_flags, "-I", str(LIB), "-L", str(LIB),
        str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
        *map(str, checks), "-o", str(BUILD / "DeskBridgeChecks")])
    model_sources = [s for s in app_sources if s.name != "DeskBridgeApp.swift"]
    model_sources += sorted((ROOT / "Sources/DeskBridgeAppChecks").glob("*.swift"))
    run("compile-model-checks", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeAppChecks",
        "-package-name", "DeskBridge", *common, *update_flags, "-I", str(LIB), "-L", str(LIB),
        str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
        *map(str, model_sources), "-o", str(BUILD / "DeskBridgeAppChecks")])
info = {
    "CFBundleExecutable": "DeskBridge", "CFBundleIdentifier": "org.deskbridge.app",
    "CFBundleName": "Knot", "CFBundleDisplayName": "Knot",
    "CFBundleIconFile": "AppIcon",
    "CFBundleVersion": sparkle_info(ROOT, enabled=bool(update_publisher))["CFBundleVersion"], "CFBundleShortVersionString": (ROOT / "VERSION").read_text().strip().split("-")[0],
    "DeskBridgeVersion": (ROOT / "VERSION").read_text().strip(),
    "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "26.0",
    "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    "NSLocalNetworkUsageDescription": "같은 Wi-Fi의 Sunshine PC를 찾고 선택한 Windows PC의 화면·파일 또는 Linux PC의 화면에 연결합니다.",
    "NSBonjourServices": ["_nvstream._tcp", "_nvstream-tcp._tcp"],
    "NSCameraUsageDescription": "선택한 Windows 또는 Linux PC의 연결 QR을 스캔합니다. 이미지를 저장하거나 전송하지 않습니다.",
    "NSScreenCaptureUsageDescription": "직접 시작한 이 Mac 공유에서 화면을 선택한 Windows 기기에 전송합니다.",
    "NSAudioCaptureUsageDescription": "직접 시작한 이 Mac 공유에서 시스템 오디오를 선택한 Windows 기기에 전송합니다.",
    "NSMicrophoneUsageDescription": "이 Mac 공유의 Sunshine 설정에서 직접 선택한 오디오 입력을 전송할 때 사용합니다.",
    "CFBundleURLTypes": [{"CFBundleURLName": "Knot connection", "CFBundleURLSchemes": ["deskbridge"], "CFBundleTypeRole": "Viewer"}],
    "NSHumanReadableCopyright": "GPLv3. DeskBridge contributors; Glimmer/ugfugl.io; Moonlight contributors.",
}
info.update(sparkle_info(ROOT, enabled=bool(update_publisher)))
with (app / "Contents/Info.plist").open("wb") as handle: plistlib.dump(info, handle)
shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
shutil.copy2(ROOT / "LICENSE", resources / "LICENSE.txt")
shutil.copy2(ROOT / "Assets/Brand/AppIcon.icns", resources / "AppIcon.icns")
shutil.copy2(ROOT / "Assets/Brand/knot.png", resources / "BrandMark.png")
shutil.copy2(ROOT / "Vendor/Glimmer/CREDITS.md", resources / "GLIMMER_CREDITS.md")
shutil.copy2(ROOT / "Vendor/QRCodegen/NOTICE", resources / "QR_CODEGEN_LICENSE.txt")
if (ROOT / "host/windows/README.md").exists():
    shutil.copy2(ROOT / "host/windows/README.md", resources / "WINDOWS_SETUP.md")
if (ROOT / "host/macos/README.md").exists():
    shutil.copy2(ROOT / "host/macos/README.md", resources / "MACOS_HOST_SETUP.md")
if (ROOT / "host/windows").exists():
    shutil.copytree(ROOT / "host/windows", resources / "WindowsSetup", dirs_exist_ok=True, ignore=shutil.ignore_patterns("tests"))
if not args.skip_checks:
    # Exercise the same static dependency linkage/hardened signing policy, without App.main/UI.
    runtime = BUILD / "runtime-check/Contents"
    (runtime / "MacOS").mkdir(parents=True, exist_ok=True)
    (runtime / "Helpers").mkdir(parents=True, exist_ok=True)
    shutil.copy2(supervisor, runtime / "Helpers/KnotHostSupervisor")
    if (runtime / "Frameworks").exists(): shutil.rmtree(runtime / "Frameworks")
    shutil.copytree(frameworks, runtime / "Frameworks", symlinks=True)
    checker = runtime / "MacOS/DeskBridgeChecks"
    shutil.copy2(BUILD / "DeskBridgeChecks", checker)
    run("sign-runtime-check", ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--options", "runtime", str(checker)])
    run("synthetic-checks", [str(checker)])
    model_checker = runtime / "MacOS/DeskBridgeAppChecks"
    shutil.copy2(BUILD / "DeskBridgeAppChecks", model_checker)
    run("sign-model-check", ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--options", "runtime", str(model_checker)])
    run("synthetic-model-checks", [str(model_checker)])
run("sign-app", ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--options", "runtime",
    "--entitlements", str(ROOT / "packaging/macos/DeskBridge.entitlements"), str(app)])
run("verify-app", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
entitlements = run("inspect-app-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
if plistlib.loads(entitlements) != {"com.apple.security.device.camera": True}:
    raise SystemExit("The signed app must contain exactly the camera permission entitlement.")
try:
    dependencies = parse_system_dependencies(
        run("inspect-dependencies", ["/usr/bin/otool", "-L", str(macos / "DeskBridge")]), macos / "DeskBridge",
        allowed_frameworks=("@rpath/Sparkle.framework/Versions/B/Sparkle",) if update_publisher else ())
except SystemDependencyError as error:
    raise SystemExit(str(error))
if source_snapshot(ROOT) != snapshot:
    raise SystemExit("Source changed during build; rebuild this snapshot before delivery.")
(EVIDENCE / "completed-build.json").write_text(json.dumps({
    "schema": 1, "configuration": args.configuration, "checksPassed": not args.skip_checks,
    "appManifest": tree_snapshot(app),
    "hostSupervisor": host_supervisor_snapshot(app),
}, indent=2))
print("Built " + str(app), flush=True)
print("GUI/capture host not launched. Windows, Mac host permissions, IME, Space and network acceptance remain manual.", flush=True)


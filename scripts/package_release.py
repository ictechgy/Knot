#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline packaging. Only explicit release mode calls Apple's notarization service."""
from pathlib import Path
from urllib.parse import urlsplit
import argparse, datetime, gzip, hashlib, io, json, os, plistlib, re, shutil, subprocess, tarfile, tempfile, zipfile
from build_snapshot import BuildSnapshotError, host_supervisor_snapshot, source_snapshot, supervisor_package_record, tree_snapshot, validate_completed_build, validate_corresponding_source
from windows_resources import NativePE, validate_bootstrap
from windows_check_record import validate_windows_check_record
from linux_check_record import validate_linux_check_record, validate_payload_sources
from test_linux_host import archive_inventory
from system_dependencies import SystemDependencyError, parse_system_dependencies
from update_runtime import sign_sparkle


def render_installation_links(text, revision):
    """Render the distribution guide independently of its extracted directory."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Installation guide links require an exact source commit.")
    relative_targets = {"host/windows/README.md", "docs/BRAND_COMPATIBILITY.md", "docs/FILE_ENROLLMENT.md",
                        "docs/RELEASING.md", "docs/HEADLESS_WINDOWS.md"}

    def render_target(target):
        enclosed = target.startswith("<") and target.endswith(">")
        if enclosed:
            target = target[1:-1]
        if not target or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in target):
            raise ValueError("Invalid installation guide link target.")
        if target.startswith("#"):
            rendered = target
        else:
            parsed = urlsplit(target)
            if parsed.scheme == "https" and parsed.hostname:
                _ = parsed.port  # Invalid ports must not pass as valid HTTPS links.
                rendered = target
            else:
                if parsed.scheme or parsed.netloc or parsed.query or parsed.path not in relative_targets:
                    raise ValueError("Unknown installation guide link target: " + target)
                fragment = "#" + parsed.fragment if "#" in target else ""
                rendered = "https://github.com/ictechgy/Knot/blob/" + revision + "/" + parsed.path + fragment
        return "<" + rendered + ">" if enclosed else rendered

    def replace_link(match):
        title = r'''(?:"[^"\r\n]*"|'[^'\r\n]*')'''
        suffix = r"[ \t]*(?:" + title + r"[ \t]*)?"
        if match.group(1).startswith("]("):
            suffix += r"\)"
        if not re.fullmatch(suffix, match.group(3)):
            raise ValueError("Invalid installation guide link title or whitespace.")
        return match.group(1) + render_target(match.group(2)) + match.group(3)

    text = re.sub(r"(\]\([ \t]*)(<[^>\r\n]*>|[^)\s]*)([^)]*\))", replace_link, text)
    return re.sub(r"(?m)^([ \t]{0,3}\[[^\]\r\n]+\]:[ \t]*)(<[^>\r\n]*>|[^ \t\r\n]+)([^\r\n]*)",
                  replace_link, text)


ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--mode", choices=["preview", "release"], default="preview")
parser.add_argument("--mac-format", choices=["dmg", "zip", "both"], default="both")
parser.add_argument("--identity", default=os.environ.get("MACOS_SIGNING_IDENTITY"))
parser.add_argument("--notary-profile", default=os.environ.get("MACOS_NOTARY_PROFILE"))
parser.add_argument("--windows-launcher", type=Path, help="Include an exact-source single-file Windows helper built by build_windows_launcher.py")
parser.add_argument("--linux-package", type=Path, help="Include an exact-source checked Linux host Debian package")
args = parser.parse_args()
version = (ROOT / "VERSION").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?", version):
    raise SystemExit("Invalid VERSION")
if args.mode == "release" and (not args.identity or not args.identity.startswith("Developer ID Application:") or not args.notary_profile):
    raise SystemExit("Release requires Developer ID Application identity and a preconfigured notary profile.")
if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT):
    raise SystemExit("Commit the exact source before packaging; the corresponding source archive must match.")
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
latest = json.loads((ROOT / "evidence/latest-build.json").read_text())
build = ROOT / latest["directory"]
if latest["lastStage"] != "inspect-mac-installer-dependencies":
    raise SystemExit("A complete successful build with checks is required.")
try:
    completed, checks = validate_completed_build(ROOT, build, require_release=args.mode == "release")
except (BuildSnapshotError, ValueError) as error:
    raise SystemExit(str(error))
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
# Each invocation owns a fresh directory, so old versions/signing modes cannot mix with this set.
output = ROOT / "dist/release" / (version + "-" + args.mode + "-" + stamp + "-" + head[:12])
output.mkdir(parents=True, exist_ok=False)
(ROOT / "evidence/latest-package.json").unlink(missing_ok=True)
evidence = ROOT / "evidence" / ("package-" + stamp); evidence.mkdir()
records = []
launcher_record = None
if args.windows_launcher:
    launcher_record = json.loads(args.windows_launcher.with_suffix('.build.json').read_text())
    if (launcher_record.get('schema') != 1 or launcher_record.get('version') != version or
            launcher_record.get('sourceManifest') != source_snapshot(ROOT) or
            launcher_record.get('compilerExitCode') != 0 or
            launcher_record.get('nativeCompilerExitCode') != 0 or
            launcher_record.get('nativeCLRHeaderAbsent') is not True or
            hashlib.sha256(args.windows_launcher.read_bytes()).hexdigest() != launcher_record.get('sha256')):
        raise SystemExit('Windows helper differs from its successful exact-source build; rebuild before packaging')
    native_bytes = args.windows_launcher.read_bytes()
    managed_bytes = NativePE(native_bytes).resource(10, 101)
    validate_bootstrap(native_bytes, managed_bytes)
    if hashlib.sha256(managed_bytes).hexdigest() != launcher_record.get('managedSha256'):
        raise SystemExit('Windows managed payload differs from the native build manifest')
    try:
        validate_windows_check_record(json.loads(args.windows_launcher.with_suffix('.checks.json').read_text()), launcher_record)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
if args.linux_package:
    linux_record = json.loads(args.linux_package.with_suffix('.build.json').read_text())
    linux_data = args.linux_package.read_bytes()
    if (linux_record.get('schema') != 1 or linux_record.get('version') != version or
        linux_record.get('sourceManifest') != source_snapshot(ROOT) or linux_record.get('sha256') != hashlib.sha256(linux_data).hexdigest() or
        archive_inventory(linux_data) != linux_record.get('inventory')):
        raise SystemExit('Linux host differs from its exact-source build; rebuild')
    validate_payload_sources(linux_record, archive_inventory(linux_data))
    validate_linux_check_record(json.loads(args.linux_package.with_suffix('.checks.json').read_text()), linux_record)
def run(label, argv):
    print(label, flush=True)
    result = subprocess.run(argv, cwd=ROOT, capture_output=True)
    (evidence / (label + ".stdout")).write_bytes(result.stdout)
    (evidence / (label + ".stderr")).write_bytes(result.stderr)
    records.append({"label": label, "argv": argv, "exitCode": result.returncode})
    (evidence / "invocations.json").write_text(json.dumps(records, indent=2))
    if result.returncode:
        raise SystemExit(label + " failed: " + result.stderr.decode(errors="replace")[-2000:])
    return result.stdout
suffix = "-preview" if args.mode == "preview" else ""
name = "Knot-" + version
generated = []
with tempfile.TemporaryDirectory(prefix="deskbridge-package-") as temporary:
    stage = Path(temporary) / "Knot"; stage.mkdir()
    app = stage / "Knot.app"
    installer = stage / "Install Knot.app"
    shutil.copytree(ROOT / "dist/Knot.app", app, symlinks=True)
    shutil.copytree(ROOT / "dist/Install Knot.app", installer, symlinks=True)
    if tree_snapshot(installer) != completed["installerManifest"]:
        raise SystemExit("Local installer changed while staging; rebuild before packaging")
    # Recheck the copied payload before signing to bind this package to the successful build.
    if tree_snapshot(app) != completed["appManifest"]:
        raise SystemExit("App changed while staging; rebuild before packaging")
    if host_supervisor_snapshot(app) != completed["hostSupervisor"]:
        raise SystemExit("Host supervisor changed while staging; rebuild before packaging")
    supervisor = app / "Contents/Helpers/KnotHostSupervisor"
    if args.mode == "release":
        sign_sparkle(app / "Contents/Frameworks/Sparkle.framework", run, args.identity, release=True)
        run("sign-host-supervisor-release", ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity, str(supervisor)])
        run("sign-app-release", ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity,
            "--entitlements", str(ROOT / "packaging/macos/DeskBridge.entitlements"), str(app)])
        notarize_zip = Path(temporary) / "notarize.zip"
        run("notary-app-zip", ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(notarize_zip)])
        run("notarize-app", ["/usr/bin/xcrun", "notarytool", "submit", str(notarize_zip), "--keychain-profile", args.notary_profile, "--wait"])
        run("staple-app", ["/usr/bin/xcrun", "stapler", "staple", str(app)])
        run("validate-app-ticket", ["/usr/bin/xcrun", "stapler", "validate", str(app)])
        embedded_payload = installer / "Contents/Helpers/Knot.app"
        shutil.rmtree(embedded_payload)
        shutil.copytree(app, embedded_payload, symlinks=True)
        run("sign-local-installer-release", ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity, str(installer)])
        installer_zip = Path(temporary) / "notarize-installer.zip"
        run("notary-installer-zip", ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(installer), str(installer_zip)])
        run("notarize-local-installer", ["/usr/bin/xcrun", "notarytool", "submit", str(installer_zip), "--keychain-profile", args.notary_profile, "--wait"])
        run("staple-local-installer", ["/usr/bin/xcrun", "stapler", "staple", str(installer)])
        run("validate-local-installer-ticket", ["/usr/bin/xcrun", "stapler", "validate", str(installer)])
    run("verify-staged-local-installer", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installer)])
    if tree_snapshot(installer / "Contents/Helpers/Knot.app") != tree_snapshot(app):
        raise SystemExit("Packaged installer payload differs from the checked/re-signed app.")
    installer_entitlements = run("inspect-staged-local-installer-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(installer)])
    if installer_entitlements.strip() and plistlib.loads(installer_entitlements) != {}:
        raise SystemExit("The packaged local installer must have no entitlements.")
    parse_system_dependencies(run("inspect-staged-local-installer-dependencies", ["/usr/bin/otool", "-L", str(installer / "Contents/MacOS/KnotInstaller")]), installer / "Contents/MacOS/KnotInstaller")
    run("verify-staged-host-supervisor", ["/usr/bin/codesign", "--verify", "--strict", str(supervisor)])
    helper_entitlements = run("inspect-staged-host-supervisor-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(supervisor)])
    if helper_entitlements.strip() and plistlib.loads(helper_entitlements) != {}:
        raise SystemExit("The packaged host supervisor must have no entitlements.")
    try:
        dependencies = parse_system_dependencies(
            run("inspect-staged-host-supervisor-dependencies", ["/usr/bin/otool", "-L", str(supervisor)]), supervisor)
    except SystemDependencyError as error:
        raise SystemExit(str(error))
    try:
        packaged_supervisor = supervisor_package_record(completed["hostSupervisor"], host_supervisor_snapshot(app), args.mode == "release")
    except BuildSnapshotError as error:
        raise SystemExit("Discard the staged package and rebuild before packaging: " + str(error)) from None
    run("verify-staged-app", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    entitlements = run("inspect-staged-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
    if plistlib.loads(entitlements) != {"com.apple.security.device.camera": True}:
        raise SystemExit("The packaged app must contain exactly the camera permission entitlement.")
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
    try:
        installation = render_installation_links((ROOT / "INSTALLATION.md").read_text(encoding="utf-8"), head)
    except ValueError as error:
        raise SystemExit(str(error))
    (stage / "INSTALLATION.md").write_text(installation, encoding="utf-8")
    (stage / "INSTALL.txt").write_text("Install Knot.app을 열고 설치 및 다시 시작을 누르세요. 기존 Knot은 자동으로 정상 종료·교체·재실행됩니다.\nApple Silicon / macOS 26+\n" +
        "preview.22 이하에서 처음 업데이트할 때만 파일 전송·설정 작업을 먼저 마쳐 주세요. 이후 버전은 진행 중인 작업을 기다립니다.\n" +
        "설치 위치가 보호돼 있으면 종료 전에 중단합니다. 관리자가 기존 앱을 교체해야 합니다. 새 앱을 다른 위치에 중복 설치하지 마세요.\n" +
        "Application Support·설정·인증서는 보존하세요. macOS 권한을 다시 요청할 수 있습니다.\n" +
        ("Developer ID 서명 및 Apple 공증 패키지입니다.\n" if args.mode == "release" else "개발 프리뷰: 로컬 ad-hoc 서명이며 Apple 공증이 없습니다.\n") +
        "설정 안내는 이 패키지의 INSTALLATION.md를 확인하세요. 대응 소스는 같은 릴리스의 별도 파일 " + name + "-source.tar.gz 입니다.\n", encoding="utf-8")
    if args.mac_format in ["zip", "both"]:
        mac_zip = output / (name + "-macos-arm64" + suffix + ".zip")
        run("mac-zip", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(mac_zip)])
        generated.append(mac_zip)
    if args.mac_format in ["dmg", "both"]:
        image = output / (name + "-macos-arm64" + suffix + ".dmg")
        run("create-dmg", ["/usr/bin/hdiutil", "create", "-volname", "Knot", "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(image)])
        run("verify-dmg", ["/usr/bin/hdiutil", "verify", str(image)])
        generated.append(image)
        if args.mode == "release":
            run("sign-dmg", ["/usr/bin/codesign", "--force", "--timestamp", "--sign", args.identity, str(image)])
            run("notarize-dmg", ["/usr/bin/xcrun", "notarytool", "submit", str(image), "--keychain-profile", args.notary_profile, "--wait"])
            run("staple-dmg", ["/usr/bin/xcrun", "stapler", "staple", str(image)])
            run("validate-dmg-ticket", ["/usr/bin/xcrun", "stapler", "validate", str(image)])
    portable = output / (name + "-windows-x64-portable-preview.zip")
    with zipfile.ZipFile(portable, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted((ROOT / "host/windows").iterdir()):
            if file.is_file(): archive.write(file, "Knot-Windows-Setup/" + file.name)
        archive.write(ROOT / "LICENSE", "Knot-Windows-Setup/LICENSE")
        archive.writestr("Knot-Windows-Setup/INSTALLATION.md", installation)
        archive.write(ROOT / "Vendor/QRCodegen/NOTICE", "Knot-Windows-Setup/QRCodegen-LICENSE")
        archive.write(ROOT / "Vendor/ZXingNet/LICENSE", "Knot-Windows-Setup/QRDecoder-LICENSE.txt")
        archive.write(ROOT / "Vendor/ZXingNet/NOTICE", "Knot-Windows-Setup/QRDecoder-NOTICE.txt")
        for relative in ("MoonlightDependency.json", "MoonlightFiles.json", "Moonlight-LICENSE.txt", "Moonlight-NOTICE.txt", "README.ko.md"):
            archive.write(ROOT / "client/windows" / relative, "Knot-Windows-Setup/ReverseClient/" + relative)
        archive.writestr("Knot-Windows-Setup/ReverseClient/START.txt", "Windows에서 Mac을 열려면 함께 제공한 quick-setup EXE를 실행하고 Mac 열기를 선택하세요. 이 고급 스크립트 ZIP은 기존 Windows 공유 설정용이며 Windows 클라이언트 실행 파일을 대신하지 않습니다.\n")
        if args.windows_launcher:
            qr_library = args.windows_launcher.with_name('DeskBridge-QR.dll')
            if hashlib.sha256(qr_library.read_bytes()).hexdigest() != launcher_record.get('qrLibrarySha256'):
                raise SystemExit('QR helper changed after launcher build')
            archive.write(qr_library, 'Knot-Windows-Setup/DeskBridge-QR.dll')
    generated.append(portable)
    if args.windows_launcher:
        launcher = output / (name + '-windows-x64-quick-setup-preview.exe')
        shutil.copy2(args.windows_launcher, launcher)
        if hashlib.sha256(launcher.read_bytes()).hexdigest() != launcher_record['sha256']:
            raise SystemExit('Windows helper changed during packaging')
        generated.append(launcher)
    if args.linux_package:
        linux_output = output / (name + '-ubuntu24.04-amd64-preview.deb')
        shutil.copy2(args.linux_package, linux_output)
        if hashlib.sha256(linux_output.read_bytes()).hexdigest() != linux_record['sha256']:
            raise SystemExit('Linux package changed during packaging')
        generated.append(linux_output)
        shutil.copy2(ROOT / 'host/linux/README.md', output / 'LINUX-INSTALLATION.md')
        generated.append(output / 'LINUX-INSTALLATION.md')
    source = run("corresponding-source", ["git", "archive", "--format=tar", "--prefix=Knot-source/", head])
    source_path = output / (name + "-source.tar.gz")
    with gzip.open(source_path, "wb") as handle: handle.write(source)
    generated.append(source_path)
    (output / "INSTALLATION.md").write_text(installation, encoding="utf-8")
    shutil.copy2(ROOT / "Vendor/WindowsRuntime/NOTICE", output / "WindowsRuntime-NOTICE.txt")
    shutil.copy2(ROOT / "client/windows/Moonlight-NOTICE.txt", output / "Moonlight-NOTICE.txt")
    shutil.copy2(ROOT / "client/windows/Moonlight-LICENSE.txt", output / "Moonlight-LICENSE.txt")
    shutil.copy2(ROOT / "Vendor/ZXingNet/NOTICE", output / "QRDecoder-NOTICE.txt")
    shutil.copy2(ROOT / "Vendor/ZXingNet/LICENSE", output / "QRDecoder-LICENSE.txt")
generated.append(output / "INSTALLATION.md")
generated.append(output / "WindowsRuntime-NOTICE.txt")
generated += [output / name for name in ("Moonlight-NOTICE.txt", "Moonlight-LICENSE.txt", "QRDecoder-NOTICE.txt", "QRDecoder-LICENSE.txt")]
if (source_snapshot(ROOT) != json.loads((build / "source-manifest.json").read_text()) or
        subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != head or
        subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)):
    raise SystemExit("Source changed during packaging; discard these outputs and rebuild")
try:
    validate_corresponding_source(ROOT, source_snapshot(ROOT), head)
except BuildSnapshotError as error:
    raise SystemExit("Source archive changed during packaging; discard these outputs and rebuild: " + str(error))
# Hash only this invocation's outputs, never stale files from a prior signing mode/version.
artifacts = sorted(generated)
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts}
(output / "SHA256SUMS").write_text("".join(digest + "  " + filename + "\n" for filename, digest in sorted(hashes.items())))
manifest = {"head": head, "version": version, "mode": args.mode, "output": str(output.relative_to(ROOT)), "configuration": completed["configuration"],
            "checks": checks, "sha256": hashes, "macHostSupervisor": packaged_supervisor,
            "macNotarized": args.mode == "release", "linuxHostBuiltHere": bool(args.linux_package), "linuxDesktopRuntimeTested": False, "windowsExeBuiltHere": bool(args.windows_launcher),
            "windowsInstallerBuiltHere": False, "windowsHelperRuntimeTested": False,
            "windowsCompiler": "Pinned Zig native bootstrap + explicit Roslyn / Framework 4.8 references" if args.windows_launcher else "GitHub Actions Windows job / pinned Inno Setup", "guiLaunched": False}
(evidence / "manifest.json").write_text(json.dumps(manifest, indent=2))
(ROOT / "evidence/latest-package.json").write_text(json.dumps({"directory": str(evidence.relative_to(ROOT)), **manifest}, indent=2))
print(json.dumps({"output": str(output), "head": head, "artifacts": list(hashes)}, indent=2))

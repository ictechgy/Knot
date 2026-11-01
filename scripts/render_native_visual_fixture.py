#!/usr/bin/env python3
"""Render the actual native preview UI from fresh, inert, offscreen state only."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    marker = output / ".native-visual-owned.json"
    ownership = {"owner": "KnotNativeVisualFixture", "schema": 1}
    if marker.exists():
        if json.loads(marker.read_text()) != ownership:
            raise SystemExit("Visual output ownership differs")
    elif any(output.iterdir()):
        raise SystemExit("Refusing a nonempty visual output without this fixture's ownership marker")
    else:
        marker.write_text(json.dumps(ownership) + "\n")
    report_path = output / "visual-checks.json"
    report_path.unlink(missing_ok=True)
    sources = sorted((ROOT / "native-engine/macos/Sources").rglob("*.swift"))
    fixture = ROOT / "native-engine/macos/VisualFixtures/NativeVisualFixture.swift"
    asset = ROOT / "Assets/Brand/AppIcon.icns"
    module = ROOT / "native-engine/macos/Sources/CKnotPairing"
    crypto = ROOT / "native-engine/pairing"
    crypto_inputs = [module / "module.modulemap", module / "shim.h", crypto / "include/knot_pairing.h",
                     crypto / "knot_pairing.cpp", crypto / "CMakeLists.txt", crypto / "PROVENANCE.json"]
    library_directory = Path(os.environ.get("KNOT_NATIVE_PAIRING_LIBDIR",
        str(ROOT / "build/native-engine/macos/pairing/lib"))).resolve()
    if not any(library_directory.is_relative_to(parent) for parent in [ROOT / "build", ROOT / ".omx"]):
        raise SystemExit("Pairing libraries must be in this checkout's owned build/evidence directories")
    libraries = [library_directory / name for name in ["libKnotNativePairing.a", "libcrypto.a"]]
    if any(not p.is_file() or p.is_symlink() for p in libraries):
        raise SystemExit("Build the owned native pairing static libraries before rendering")
    library_manifest = {p.name: digest(p) for p in libraries}
    inputs = [*sources, ROOT / "native-engine/macos/Package.swift", fixture, asset, *crypto_inputs, Path(__file__).resolve()]
    source_manifest = {p.relative_to(ROOT).as_posix(): digest(p) for p in inputs}
    records = []

    def run(label, argv, timeout=240):
        result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, timeout=timeout)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        records.append({"label": label, "argv": list(map(str, argv)), "cwd": str(ROOT),
                        "exitCode": result.returncode,
                        "stdoutSHA256": hashlib.sha256(result.stdout).hexdigest(),
                        "stderrSHA256": hashlib.sha256(result.stderr).hexdigest()})
        (output / "invocations.json").write_text(json.dumps(records, indent=2) + "\n")
        if result.returncode:
            raise SystemExit(result.stderr.decode(errors="replace"))
        print(label + ": passed", flush=True)
        return result.stdout

    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="knot-native-visual-") as temporary:
        fresh = Path(temporary)
        common = ["-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-sdk", sdk, "-I", module,
                  "-O", "-module-cache-path", fresh / "module-cache"]
        core = sorted((ROOT / "native-engine/macos/Sources/KnotNativeCore").glob("*.swift"))
        run("compile-visual-core", ["/usr/bin/swiftc", "-parse-as-library", "-emit-library", "-static", "-emit-module",
            "-module-name", "KnotNativeCore", *common, *core, "-emit-module-path", fresh / "KnotNativeCore.swiftmodule",
            "-o", fresh / "libKnotNativeCore.a"])
        bundle = fresh / "KnotNativeVisualFixture.app"
        executable = bundle / "Contents/MacOS/KnotNativeVisualFixture"
        executable.parent.mkdir(parents=True)
        resources = bundle / "Contents/Resources"
        resources.mkdir()
        shutil.copyfile(asset, resources / "AppIcon.icns")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": executable.name, "CFBundleIdentifier": "org.knot.native-visual-fixture." + uuid.uuid4().hex,
            "CFBundleName": "KnotNativeVisualFixture", "CFBundlePackageType": "APPL", "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "26.0", "LSUIElement": True, "NSHighResolutionCapable": True}))
        ui = [p for p in sorted((ROOT / "native-engine/macos/Sources/KnotNativePreview").glob("*.swift")) if p.name != "App.swift"]
        run("compile-visual-ui", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "KnotNativeVisualFixture",
            *common, "-I", fresh, fresh / "libKnotNativeCore.a", *libraries, "-lc++", *ui, fixture, "-o", executable])
        run("render-offscreen-ui", [executable, output], timeout=120)

    rendered = json.loads((output / "render-result.json").read_text())
    effects = ["productionEntryInvoked", "networkInvoked", "clipboardInvoked", "certificateCreationInvoked",
               "captureInvoked", "actualInputInvoked", "screenCaptureInvoked", "syntheticWindowsShown", "existingUserUIRead"]
    if rendered.get("freshSyntheticOnly") is not True or any(rendered.get(key) is not False for key in effects):
        raise SystemExit("Visual fixture effect contract failed")
    for row in rendered["images"]:
        path = output / row["name"]
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (row["width"], row["height"]) or len(data) < 10_000:
            raise SystemExit("Missing/blank or invalid visual image: " + row["name"])
        row.update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
    if any(digest(p) != source_manifest[p.relative_to(ROOT).as_posix()] for p in inputs):
        raise SystemExit("Visual source changed during rendering")
    if any(digest(p) != library_manifest[p.name] for p in libraries):
        raise SystemExit("Pairing libraries changed during rendering")
    rendered.update(status="passed", visualAcceptance="manual-review-required", sourceManifest=source_manifest,
                    pairingLibraries=library_manifest,
                    invocationManifestSHA256=digest(output / "invocations.json"))
    report_path.write_text(json.dumps(rendered, ensure_ascii=False, indent=2) + "\n")
    print("Fresh offscreen native UI renders: " + str(output), flush=True)


if __name__ == "__main__":
    main()

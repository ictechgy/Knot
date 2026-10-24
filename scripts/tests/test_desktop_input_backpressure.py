#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run actual desktop input/core sources against a fresh inert backend; no session or sockets."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"
SDK = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="deskbridge-desktop-release-synthetic-") as fixture:
    temporary = Path(fixture)
    executable = temporary / "checks"
    response = temporary / "engine.sources"
    response.write_text("".join(json.dumps(str(path)) + "\n" for path in sorted(ENGINE.rglob("*.swift"))))
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library",
                    "-target", "arm64-apple-macosx26.0", "-sdk", SDK,
                    "-D", "SWIFT_PACKAGE", "-D", "DESKBRIDGE_DESKTOP_INPUT_BACKPRESSURE_CHECKS",
                    "-module-cache-path", str(temporary / "module-cache"), "@" + str(response),
                    str(ROOT / "Sources/DeskBridgeChecks/DesktopInputBackpressureChecks.swift"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)

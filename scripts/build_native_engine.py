#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the independent engine and fresh synthetic UI fixtures; never run production GUI/capture."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import unicodedata
import zlib
from datetime import datetime, timezone

sys.dont_write_bytecode = True
from build_snapshot import source_snapshot, validate_corresponding_source

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.0-native.10"
VERSION_BASE, PREVIEW_BUILD = VERSION.split("-native.", 1)
NUMERIC_VERSION = VERSION_BASE + "." + PREVIEW_BUILD


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_native_file_vectors(path):
    """Bind Windows-produced wire fixtures to their exact bounded file bytes."""
    path = Path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise ValueError("Native file vectors must be a bounded ordinary fresh artifact")
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if (type(value.get("schema")) is not int or value["schema"] != 1 or value.get("status") != "passed" or
            value.get("freshSyntheticOnly") is not True or
            value.get("actualCapture") is not False or value.get("actualInput") is not False):
        raise ValueError("Native file vectors must identify fresh synthetic-only file checks")

    def binary(text):
        if not isinstance(text, str):
            raise ValueError("Native file vector encoding missing")
        try:
            result = base64.b64decode(text, validate=True)
        except (ValueError, TypeError) as error:
            raise ValueError("Native file vector encoding invalid") from error
        if base64.b64encode(result).decode("ascii") != text:
            raise ValueError("Native file vector encoding noncanonical")
        return result

    def packets(data):
        result, offset = [], 0
        while offset < len(data):
            if len(data) - offset < 5:
                raise ValueError("Native file vector header truncated")
            kind, size = data[offset], struct.unpack_from(">I", data, offset + 1)[0]
            valid = (size == 0 if kind == 0x42 else 9 <= size <= 65544 if kind == 0x48 else
                     size == 40 if kind == 0x49 else 1 <= size <= 128 if kind == 0x7f else
                     1 <= size <= 4096 if kind in range(0x40, 0x50) else False)
            offset += 5
            if not valid or size > len(data) - offset:
                raise ValueError("Native file vector packet bounds invalid")
            result.append((kind, data[offset:offset + size])); offset += size
        return result

    vectors = value.get("vectors")
    if not isinstance(vectors, list) or not 17 <= len(vectors) <= 32:
        raise ValueError("Native file packet vector coverage missing")
    kinds, names = set(), set()
    for row in vectors:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str) or row["name"] in names:
            raise ValueError("Native file vector name missing or duplicate")
        names.add(row["name"])
        payload, encoded = binary(row.get("payloadBase64")), binary(row.get("encodedBase64"))
        if type(row.get("kind")) is not int or packets(encoded) != [(row["kind"], payload)]:
            raise ValueError("Native file encoded packet differs from its declaration")
        kinds.add(row["kind"])
        if row["kind"] in [0x40, 0x41] and json.loads(payload).get("v") != 2:
            raise ValueError("Native file protocol version differs")
    if kinds != set(range(0x40, 0x50)) | {0x7f}:
        raise ValueError("Native file packet kinds are incomplete")

    files, transfers = value.get("files"), value.get("transfers")
    if not isinstance(files, list) or len(files) != 3 or not isinstance(transfers, list) or len(transfers) != 3:
        raise ValueError("Native file transfer boundary fixtures missing")
    cases = {}
    for row in files:
        if not isinstance(row, dict):
            raise ValueError("Native file fixture is not an object")
        body = binary(row.get("bytesBase64"))
        if (not isinstance(row.get("name"), str) or row["name"] in cases or
                type(row.get("size")) is not int or row["size"] != len(body) or
                row.get("sha256") != hashlib.sha256(body).hexdigest()):
            raise ValueError("Native file fixture content/size/hash differs")
        cases[row["name"]] = body
    if 0 not in map(len, cases.values()) or 65541 not in map(len, cases.values()):
        raise ValueError("Native file empty/chunk-boundary coverage missing")
    seen, seen_cases = set(), set()
    for row in transfers:
        if not isinstance(row, dict):
            raise ValueError("Native file transfer fixture is not an object")
        name, filename = row.get("name"), row.get("fileName")
        body = binary(row.get("bytesBase64"))
        stream = packets(binary(row.get("encodedBase64")))
        if (name not in {"empty", "unicode", "boundary"} or name in seen_cases or filename not in cases or
                filename in seen or body != cases[filename] or
                type(row.get("size")) is not int or row["size"] != len(body) or row.get("sha256") != hashlib.sha256(body).hexdigest() or
                len(stream) < 2 or stream[0][0] != 0x47 or stream[-1][0] != 0x49):
            raise ValueError("Native file transfer sequence/content differs")
        seen.add(filename); seen_cases.add(name)
        if ((name == "empty" and len(body) != 0) or (name == "boundary" and len(body) != 65541) or
                (name == "unicode" and (not body or not any(ord(char) > 127 for char in filename)))):
            raise ValueError("Native file named boundary coverage differs")
        accepted = json.loads(stream[0][1])
        if accepted != {"name": row.get("fileName"), "size": len(body), "kind": "file", "count": 0}:
            raise ValueError("Native file Accepted metadata differs")
        received = bytearray()
        for kind, payload in stream[1:-1]:
            if kind != 0x48 or struct.unpack_from(">Q", payload)[0] != len(received):
                raise ValueError("Native file Chunk sequence/offset differs")
            received.extend(payload[8:])
        finish = stream[-1][1]
        if (received != body or struct.unpack_from(">Q", finish)[0] != len(body) or
                finish[8:] != hashlib.sha256(body).digest()):
            raise ValueError("Native file Finish content/size/hash differs")
    if seen != set(cases) or seen_cases != {"empty", "unicode", "boundary"}:
        raise ValueError("Native file transfer cases differ")
    rejected = ["Rejected." + ext for ext in ["app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "rtfd", "photoslibrary", "playground", "pkg"]] + ["HELPER.XPC", ".app"]
    if value.get("rejectedFolderNames") != rejected:
        raise ValueError("Native tree portable package rejection coverage missing")
    validate_native_tree_vectors(value.get("trees"), binary, packets)
    return value


def validate_native_tree_vectors(trees, binary, packets):
    """Check actual Windows tree streams against their declared synthetic bytes."""
    if not isinstance(trees, list) or len(trees) != 3:
        raise ValueError("Native tree boundary fixtures missing")
    seen = set()
    package_suffixes = tuple("." + ext for ext in ["app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "rtfd", "photoslibrary", "playground", "pkg"])
    def basename(name):
        if (not isinstance(name, str) or not name or name in [".", ".."] or len(name.encode()) > 255 or
                name.endswith((".", " ")) or name.lower().startswith(".knot-") or
                any(c in '/\\:<>"|?*' or unicodedata.category(c) in ["Cc", "Cf", "Zl", "Zp", "Cs"] for c in name)):
            raise ValueError("Native tree basename differs")
        stem = name.split(".")[0].rstrip(" ").upper()
        if stem in {"CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"} or (
                len(stem) == 4 and stem[:3] in ["COM", "LPT"] and stem[3] in "0123456789¹²³"):
            raise ValueError("Native tree reserved basename")
    for tree in trees:
        if not isinstance(tree, dict) or tree.get("name") not in {"empty", "nested", "boundary"} or tree["name"] in seen:
            raise ValueError("Native tree named coverage differs")
        seen.add(tree["name"]); basename(tree.get("folderName"))
        if tree["folderName"].lower().endswith(package_suffixes):
            raise ValueError("Native tree package root rejected")
        nodes, count, total = tree.get("nodes"), tree.get("count"), tree.get("size")
        if (not isinstance(nodes, list) or type(count) is not int or not 0 <= count <= 4096 or count != len(nodes) or
                type(total) is not int or not 0 <= total <= 8589934592):
            raise ValueError("Native tree declared limits differ")
        stream = packets(binary(tree.get("encodedBase64")))
        if len(stream) < 2 or stream[0][0] != 0x47 or json.loads(stream[0][1]) != dict(
                name=tree["folderName"], size=total, kind="folder", count=count):
            raise ValueError("Native tree Accepted differs")
        position, raw_count, received_total = 1, 0, 0
        parents, siblings, digest = {0: ("folder", 0)}, set(), hashlib.sha256()
        empty_folder, unicode_name, boundary = False, False, False
        for index, declared in enumerate(nodes, 1):
            if not isinstance(declared, dict):
                raise ValueError("Native tree node fixture is not an object")
            raw, body = binary(declared.get("jsonBase64")), binary(declared.get("bytesBase64"))
            raw_count += len(raw)
            if raw_count > 1048576 or position >= len(stream) or stream[position] != (0x4c, raw):
                raise ValueError("Native tree node sequence/metadata differs")
            position += 1; node = json.loads(raw)
            if (not isinstance(node, dict) or set(node) != {"id", "parent", "name", "kind", "size"} or
                    type(node["id"]) is not int or node["id"] != index or type(node["parent"]) is not int or
                    node["parent"] not in parents or parents[node["parent"]][0] != "folder" or
                    node["kind"] not in ["file", "folder"] or type(node["size"]) is not int or
                    not 0 <= node["size"] <= 8589934592):
                raise ValueError("Native tree parent/id/kind differs")
            basename(node["name"])
            if node["kind"] == "folder" and node["name"].lower().endswith(package_suffixes):
                raise ValueError("Native tree package node rejected")
            key = (node["parent"], unicodedata.normalize("NFC", node["name"]).casefold())
            depth = parents[node["parent"]][1] + 1
            if key in siblings or depth > 16:
                raise ValueError("Native tree sibling/depth differs")
            siblings.add(key); parents[index] = (node["kind"], depth)
            digest.update(struct.pack(">I", len(raw))); digest.update(raw)
            unicode_name |= any(ord(c) > 127 for c in node["name"])
            if node["kind"] == "folder":
                if node["size"] != 0 or body:
                    raise ValueError("Native tree folder bytes differ")
                empty_folder = True
                continue
            if node["size"] != len(body) or received_total > total - len(body):
                raise ValueError("Native tree file size/total differs")
            received = bytearray()
            while len(received) < len(body):
                if position >= len(stream) or stream[position][0] != 0x48:
                    raise ValueError("Native tree Chunk missing")
                payload = stream[position][1]; position += 1
                if struct.unpack_from(">Q", payload)[0] != len(received) or len(payload) - 8 > len(body) - len(received):
                    raise ValueError("Native tree Chunk offset/size differs")
                received.extend(payload[8:])
            if (received != body or position >= len(stream) or stream[position] != (0x49,
                    struct.pack(">Q", len(body)) + hashlib.sha256(body).digest())):
                raise ValueError("Native tree file Finish/hash differs")
            position += 1; received_total += len(body); digest.update(body); boundary |= len(body) == 65541
        if (received_total != total or position != len(stream) - 1 or stream[position][0] != 0x4d or
                tree.get("sha256") != digest.hexdigest() or json.loads(stream[position][1]) != dict(
                    count=count, size=total, sha256=digest.hexdigest())):
            raise ValueError("Native tree terminal transcript/hash differs")
        if ((tree["name"] == "empty" and (count != 0 or total != 0)) or
                (tree["name"] == "nested" and (not empty_folder or not unicode_name)) or
                (tree["name"] == "boundary" and not boundary)):
            raise ValueError("Native tree empty/Unicode/boundary coverage differs")
    if seen != {"empty", "nested", "boundary"}:
        raise ValueError("Native tree coverage differs")


def output_stat(path):
    """Inspect the entry, including broken links, without resolving its target."""
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def linked_output(info):
    # Junctions and other Windows reparse points need not be POSIX symlinks.
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def ordinary_output(info):
    return not linked_output(info) and stat.S_ISREG(info.st_mode) and info.st_nlink == 1


def remove_output_entry(path):
    """Remove owned scratch entries without descending through any kind of link."""
    info = output_stat(path)
    if info is None:
        return
    if linked_output(info):
        if stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x10:
            path.rmdir()  # Windows directory reparse point; remove the entry only.
        else:
            path.unlink()
    elif stat.S_ISDIR(info.st_mode):
        for child in path.iterdir():
            remove_output_entry(child)
        path.rmdir()
    else:
        path.unlink()


def validate_output_tree(path):
    info = output_stat(path)
    if info is None:
        return
    if linked_output(info):
        raise ValueError("Linked or reparse native output is unsupported: " + str(path))
    if stat.S_ISDIR(info.st_mode):
        for child in path.iterdir():
            validate_output_tree(child)
    elif not ordinary_output(info):
        raise ValueError("Non-regular or shared native output is unsupported: " + str(path))


def validate_wait_measurement(record):
    if (record.get("schema") != 1 or record.get("status") != "PASS" or
            record.get("freshSyntheticOnly") is not True or
            any(record.get(key) is not False for key in ["captureInvoked", "inputInvoked", "codecInvoked"]) or
            record.get("clock") != "QueryPerformanceCounter" or record.get("iterations") != 64 or
            record.get("requestedMicros") != 1000 or
            any(record.get(key) is not True for key in ["unstartedRejected", "expiredBudgetSkipped",
                "idempotentStartSingleHandle", "handlesRestored"])):
        raise ValueError("Wait evidence must identify fresh bounded timer measurement without device acceptance")
    for method in ["baselineSleep1", "ownedHighResolutionTimer"]:
        row = record.get(method)
        keys = ["p50Micros", "p95Micros", "maximumMicros", "totalMicros", "over16667Micros"]
        if (not isinstance(row, dict) or any(type(row.get(key)) is not int or row[key] < 0 for key in keys) or
                not row["p50Micros"] <= row["p95Micros"] <= row["maximumMicros"] <= row["totalMicros"] or
                row["totalMicros"] > 64 * row["maximumMicros"] or row["over16667Micros"] > 64):
            raise ValueError("Wait evidence must contain consistent measured timer distributions")


def validate_four_k_fixture(record, fixture, fps, frames):
    if (record.get("v") != 1 or record.get("synthetic") is not True or
            record.get("captureInvoked") is not False or record.get("hardwareEncoder") is not False or
            record.get("codec") != "h264-annexb" or
            any(record.get(key) != value for key, value in
                {"width": 3840, "height": 2160, "fps": fps, "bitrate": 40000000, "frames": frames}.items()) or
            record.get("parserChecks") is not True or record.get("encoderCapacity") != 2 or
            type(record.get("peakOutputScratchBytes")) is not int or
            not 0 <= record["peakOutputScratchBytes"] <= 24883200 or
            type(record.get("peakEncoderInFlight")) is not int or
            not 1 <= record["peakEncoderInFlight"] <= 2 or
            type(record.get("keyframes")) is not int or not 1 <= record["keyframes"] <= frames or
            not fixture.is_file() or fixture.is_symlink() or not fixture.stat().st_size):
        raise ValueError("4K codec evidence must prove its exact fresh software-only synthetic profile")


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
        # This is a single-writer, owned build workspace. Check pre-existing
        # entries before any compiler/copy writes; this is not a defense against
        # concurrent hostile filesystem replacement during a build.
        self.output = Path(os.path.abspath(output))
        if self.output == ROOT or not self.output.is_relative_to(ROOT / "build"):
            raise ValueError("Native outputs must be in this checkout's build directory")
        directory = ROOT
        for part in self.output.relative_to(ROOT).parts:
            directory = directory / part
            info = output_stat(directory)
            if info is not None and (linked_output(info) or not stat.S_ISDIR(info.st_mode)):
                raise ValueError("Linked, reparse or non-directory native build output is unsupported")
        marker = self.output / ".native-build-owned.json"
        marker_info = output_stat(marker)
        if marker_info is not None and not ordinary_output(marker_info):
            raise ValueError("Native build ownership marker must be an ordinary unshared file")
        if self.output.exists() and any(self.output.iterdir()) and marker_info is None:
            raise ValueError("Refusing an existing output directory without our ownership marker")
        self.output.mkdir(parents=True, exist_ok=True)
        if marker_info is not None:
            if json.loads(marker.read_text()) != {"owner": "KnotNativeBuild", "schema": 1}:
                raise ValueError("Native build ownership marker differs")
        else:
            marker.write_text(json.dumps({"owner": "KnotNativeBuild", "schema": 1}) + "\n")
        # Start a fresh evidence epoch, including substep reports. A failed
        # rebuild must not pair new inputs with a previous run's passed JSON.
        unsafe_seals = []
        for name in ["NATIVE-BUILD.json", "SHA256SUMS", "NATIVE-INPUTS.json", "native-ui-visual-checks.json",
                     "native-cpp-checks.json", "native-host-checks.json", "native-installer-metadata.json",
                     "native-pairing-crypto-checks.json", "native-pairing-managed-checks.json",
                     "synthetic-codec.json", "synthetic-codec-4k.json", "synthetic-4k60.json",
                     "native-wait-checks.json"]:
            path = self.output / name
            info = output_stat(path)
            if info is not None and stat.S_ISDIR(info.st_mode) and not linked_output(info):
                unsafe_seals.append(path)
            else:
                remove_output_entry(path)
        if unsafe_seals:
            raise ValueError("Non-file native completion record is unsupported: " + str(unsafe_seals[0]))
        # These directories contain owned per-step success records too. Refuse
        # links/files rather than following them or deleting an external target.
        owned_directories = [self.output / name for name in ["evidence", "visuals"]]
        for directory in owned_directories:
            info = output_stat(directory)
            if info is not None and (linked_output(info) or not stat.S_ISDIR(info.st_mode)):
                raise ValueError("Linked or non-directory native evidence output is unsupported")
        for directory in owned_directories:
            remove_output_entry(directory)
        # SwiftPM and DMG staging legitimately create internal and Applications
        # links. Discard these owned scratch trees without following any links;
        # all retained destinations must be ordinary entries before reuse.
        for name in ["swift", "dmg-input"]:
            directory = self.output / name
            info = output_stat(directory)
            if info is not None and (linked_output(info) or not stat.S_ISDIR(info.st_mode)):
                raise ValueError("Linked or non-directory native scratch output is unsupported")
            remove_output_entry(directory)
        validate_output_tree(self.output)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir()
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
                (self.platform == "macos" and report.get("syntheticWindowsShown") is not False) or
                report.get("visualAcceptance") != "manual-review-required" or
                not isinstance(report.get("renderMethod"), str) or not report["renderMethod"].strip()):
            raise ValueError("UI checks must identify fresh synthetic rendering without production effects")
        if self.platform == "windows":
            monitor = report.get("monitorIllustrationChecks")
            measurements = {"boundsCases": 6, "rasterCases": 36, "minimumDpi": 96, "maximumDpi": 288}
            if (not isinstance(monitor, dict) or monitor.get("status") != "PASS" or
                    any(type(monitor.get(key)) is not int or monitor[key] != value
                        for key, value in measurements.items()) or
                    any(monitor.get(key) is not True for key in
                        ["centered", "paneAspectPreserved", "panesContained",
                         "sameBoundsDpiPixelIdentity", "degenerateBoundsSkipped"]) or
                    not isinstance(monitor.get("scope"), str) or not monitor["scope"].strip()):
                raise ValueError("Windows monitor illustration needs fresh measured geometry and DPI raster checks")
        rows = report.get("images")
        if self.platform == "macos" and (type(report.get("fileAdaptersInvoked")) is not int or report["fileAdaptersInvoked"] != 0):
            raise ValueError("Mac UI checks must measure zero file adapter invocations")
        if not isinstance(rows, list) or not 7 <= len(rows) <= 40:
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
                     ["idle", "reviewed", "approval", "streaming", "input-paused", "failed", "help", "compact", "dark", "fullscreen-text-rejected",
                      "searching", "empty", "nearby", "number", "number-working", "number-error",
                      "nearby-compact", "number-compact", "number-dark", "help-compact",
                      "files", "files-compact", "files-fullscreen", "files-working", "files-error", "files-empty"]}
                    if self.platform == "macos" else
                    {"windows-" + name + ".png" for name in
                     ["idle", "invitation", "request", "preparing", "sharing", "failure", "help",
                      "short-idle", "short-code", "short-code-compact", "short-help-compact",
                      "short-idle-scale150", "short-idle-scale200", "files-sharing", "files-sharing-compact", "files-unavailable"]})
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
                "NSLocalNetworkUsageDescription": "Find and connect to the Windows PC you choose on your private network."}
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
        self.input(media / "media_wait.h")
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
        wait_checks = self.output / "KnotNativeWaitChecks.exe"
        self.msvc("compile-native-wait-checks", [*common, self.input(media / "media_wait_test.cpp"),
                  "/Fe:" + str(wait_checks)])
        wait_record = self.output / "native-wait-checks.json"
        self.run("native-wait-checks", [wait_checks, "--json", wait_record], timeout=60)
        validate_wait_measurement(json.loads(wait_record.read_text()))
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
        validate_four_k_fixture(native_record_4k, fixture_4k, 30, 6)
        fixture_4k60 = self.output / "synthetic-4k60.h264"
        fixture_record_4k60 = self.output / "synthetic-4k60.json"
        self.run("native-media-synthetic-4k60", [self.output / "KnotNativeMediaSynthetic.exe", "--software-4k60",
                                               fixture_4k60, fixture_record_4k60], timeout=180)
        validate_four_k_fixture(json.loads(fixture_record_4k60.read_text()), fixture_4k60, 60, 12)
        if self.media_only:
            return [self.output / "KnotNativeMedia.dll", fixture, fixture_record, fixture_4k, fixture_record_4k,
                    fixture_4k60, fixture_record_4k60, wait_record, cpp_record]
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
        file_vectors = self.output / "native-file-vectors.json"
        file_vectors.unlink(missing_ok=True)
        result = self.run("native-host-checks", [checks, "--export-certificate", public_certificate],
                          timeout=300).decode("utf-8-sig").strip()
        parsed = json.loads(result)
        if (parsed.get("status") != "passed" or parsed.get("freshSyntheticOnly") is not True or
                parsed.get("actualCapture") is not False or parsed.get("actualSendInput") is not False):
            raise ValueError("Native host checks must prove their fresh/inert capture and input scope")
        for key, minimum in [("actualFreshExplorerInputFixtures", 1), ("actualFreshExplorerOleFixtures", 1),
                             ("actualFreshTreeFixtures", 9), ("actualFreshTreeTlsFixtures", 28)]:
            if type(parsed.get(key)) is not int or parsed[key] < minimum:
                raise ValueError("Native host folder/Explorer checks incomplete: " + key)
        (self.output / "native-host-checks.json").write_text(json.dumps(parsed, indent=2) + "\n")
        if public_pin.read_text().strip() != digest(public_certificate):
            raise ValueError("Fresh Windows certificate pin differs from exported public DER")
        validate_native_file_vectors(file_vectors)
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
                fixture_4k60, fixture_record_4k60, wait_record,
                self.output / "native-host-checks.json", public_certificate, public_pin, file_vectors, cpp_record, installer_metadata,
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

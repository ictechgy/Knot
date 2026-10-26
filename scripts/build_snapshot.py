# SPDX-License-Identifier: GPL-3.0-only
"""Shared build/package provenance checks. Only reads this source tree and its build artifacts."""
from pathlib import Path
import hashlib, io, json, os, stat, struct, subprocess, tarfile


class BuildSnapshotError(ValueError):
    pass

REQUIRED_CHECK_STAGES = {"synthetic-checks", "synthetic-model-checks", "termination-admission-checks", "build-contract-checks", "system-dependency-policy-checks",
                         "input-batching-checks", "control-hardening-checks", "desktop-input-backpressure-checks",
                         "video-frame-lifecycle-checks", "video-color-checks", "video-prepare-checks", "stream-launch-lifecycle-checks", "media-receive-lifecycle-checks", "audio-notice-power-checks",
                         "rtsp-replay-checks", "inspect-app-entitlements", "inspect-dependencies",
                         "compile-host-supervisor", "sign-host-supervisor", "verify-host-supervisor",
                         "inspect-host-supervisor-entitlements", "inspect-host-supervisor-dependencies",
                         "mac-host-lifetime-checks", "private-storage-checks", "update-policy-checks", "enrollment-protocol-checks",
                         "mac-installer-checks", "compile-mac-installer", "sign-mac-installer", "verify-mac-installer",
                         "inspect-mac-installer-entitlements", "inspect-mac-installer-dependencies"}


def unchanged_supervisor_digest(supervisor, expected):
    if hashlib.sha256(Path(supervisor).read_bytes()).hexdigest() != expected:
        raise BuildSnapshotError("Supervisor changed during lifetime checks")
    return expected


def supervisor_package_record(tested, packaged, release_resigned):
    tested_contract = {key: value for key, value in tested.items() if key != "sha256"}
    packaged_contract = {key: value for key, value in packaged.items() if key != "sha256"}
    if type(release_resigned) is not bool or packaged_contract != tested_contract:
        raise BuildSnapshotError("Packaged supervisor contract differs from its tested build")
    if not release_resigned and tested["sha256"] != packaged["sha256"]:
        raise BuildSnapshotError("Preview supervisor differs from its tested build")
    return {"testedSHA256": tested["sha256"], "packagedSHA256": packaged["sha256"],
            "releaseResigned": release_resigned,
            "transformation": "Developer ID codesign before package signature validation" if release_resigned else "none",
            "lifetimeProofScope": "tested build before release re-signing"}


def host_supervisor_snapshot(app):
    app = Path(app)
    relative = "Contents/Helpers/KnotHostSupervisor"
    path = app / relative
    digest = _ordinary_file(app, path)
    mode = stat.S_IMODE(path.stat().st_mode)
    data = path.read_bytes()
    # Thin arm64 MH_EXECUTE, not a script, library, universal fallback, or link.
    if (len(data) < 32 or struct.unpack_from("<III", data) != (0xFEEDFACF, 0x0100000C, 0) or
            struct.unpack_from("<I", data, 12)[0] != 2 or not mode & 0o111 or mode & 0o022):
        raise BuildSnapshotError("Invalid native arm64 host supervisor")
    return {"path": relative, "sha256": digest, "mode": mode, "architecture": "arm64", "type": "MH_EXECUTE"}


def _ordinary_file(root, path):
    relative = path.relative_to(root)
    if any((root / Path(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts) + 1)):
        raise BuildSnapshotError("Symlink is not a build input: " + relative.as_posix())
    if not path.is_file():
        raise BuildSnapshotError("Missing build input: " + relative.as_posix())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_snapshot(root):
    root = Path(root)
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    paths = {root / name for name in tracked if name}
    # These inputs are consumed outside the recursively scanned roots as well.
    paths.update(root / name for name in ["LICENSE", "INSTALLATION.md", "VERSION"])
    # Include new, not-yet-indexed compiler/resource inputs as well.
    for name in ["Sources", "Assets", "Vendor/Glimmer", "Vendor/QRCodegen", "Vendor/ZXingNet", "Vendor/WindowsRuntime", "Vendor/UpdateRuntime", "host/windows", "host/macos", "host/linux", "client", "scripts", "packaging", ".github"]:
        for path in (root / name).rglob("*"):
            # Only tooling bytecode is generated bookkeeping. A cache-named directory
            # under compiler/resource roots may still contain actual shipped inputs.
            if name == "scripts" and path.parent.name == "__pycache__" and path.suffix == ".pyc":
                continue
            if path.is_symlink() or path.is_file():
                paths.add(path)
    return {p.relative_to(root).as_posix(): _ordinary_file(root, p) for p in sorted(paths)}


def tree_snapshot(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise BuildSnapshotError("Missing or linked app bundle")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            # Sparkle's versioned framework requires these exact, pinned links.
            # No other application symlink is admitted or followed.
            from update_runtime import sparkle_links
            links = sparkle_links(Path(__file__).resolve().parent.parent)
            prefixes = ("Contents/Frameworks/", "Contents/Helpers/Knot.app/Contents/Frameworks/")
            expected = {prefix + name: target for prefix in prefixes for name, target in links.items()}
            relative = path.relative_to(root).as_posix()
            target = os.readlink(path)
            prefix = prefixes[1] if relative.startswith(prefixes[1]) else prefixes[0]
            framework = (root / (prefix + "Sparkle.framework")).resolve()
            if expected.get(relative) != target or not path.resolve().is_relative_to(framework):
                raise BuildSnapshotError("Unexpected app bundle symlink")
            result[relative] = {"sha256": hashlib.sha256(target.encode()).hexdigest(), "mode": 0o777, "symlink": target}
            continue
        if path.is_file():
            result[path.relative_to(root).as_posix()] = {
                "sha256": _ordinary_file(root, path),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
    if not result:
        raise BuildSnapshotError("Empty app bundle")
    return result


def validate_corresponding_source(root, expected, revision="HEAD"):
    # Compare the actual archive, including export-ignore/export-subst behavior.
    # No archive paths are extracted to the filesystem.
    try:
        data = subprocess.check_output(["git", "archive", "--format=tar", revision], cwd=root, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        diagnostic = error.stderr.decode("utf-8", errors="replace").strip()[:1000]
        raise BuildSnapshotError("Could not read the committed source archive; inspect the revision and rebuild: " + diagnostic) from error
    archived = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive:
                if member.isdir():
                    continue
                if not member.isfile():
                    raise BuildSnapshotError("Unsupported corresponding-source entry: " + member.name)
                archived[member.name] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    except tarfile.TarError as error:
        raise BuildSnapshotError("Invalid committed source archive; inspect the revision and rebuild") from error
    if expected != archived:
        missing = sorted(expected.keys() - archived.keys())
        extra = sorted(archived.keys() - expected.keys())
        changed = sorted(k for k in expected.keys() & archived.keys() if expected[k] != archived[k])
        raise BuildSnapshotError("Build inputs do not match corresponding source; commit inputs and rebuild. " +
                                 "Missing from archive: " + repr(missing) + "; extra: " + repr(extra) +
                                 "; changed: " + repr(changed))


def validate_completed_build(root, build, require_release=False):
    root, build = Path(root), Path(build)
    try:
        relative = build.relative_to(root / "evidence")
        if ".." in relative.parts or any((root / "evidence" / Path(*relative.parts[:i])).is_symlink()
                                         for i in range(len(relative.parts) + 1)):
            raise BuildSnapshotError("Build evidence must remain inside this source tree")
        completed = json.loads((build / "completed-build.json").read_text())
        invocations = json.loads((build / "build-invocations.json").read_text())
        checks = json.loads((build / "synthetic-checks.stdout").read_text())
        model_checks = json.loads((build / "synthetic-model-checks.stdout").read_text())
        admission_checks = json.loads((build / "termination-admission-checks.stdout").read_text())
        lifetime_checks = json.loads((build / "mac-host-lifetime-checks.stdout").read_text())
        expected = json.loads((build / "source-manifest.json").read_text())
        current = source_snapshot(root)
        if expected != current:
            added = sorted(current.keys() - expected.keys())
            removed = sorted(expected.keys() - current.keys())
            changed = sorted(k for k in current.keys() & expected.keys() if current[k] != expected[k])
            raise BuildSnapshotError("Source changed after build; rebuild. Added: " + repr(added) +
                                     "; removed: " + repr(removed) + "; changed: " + repr(changed))
        validate_corresponding_source(root, expected)
        labels = {r["label"] for r in invocations if r["exitCode"] == 0}
        if (completed.get("schema") != 1 or not completed.get("checksPassed") or
                completed.get("configuration") not in ["release", "debug"] or
                any(r["exitCode"] != 0 for r in invocations) or
                not REQUIRED_CHECK_STAGES <= labels or
                checks.get("status") != "passed" or model_checks.get("status") != "passed"):
            raise BuildSnapshotError("A completed build with both check suites is required")
        if (admission_checks.get("status") != "passed" or any(
                type(admission_checks.get(key)) is not int or admission_checks[key] < minimum
                for key, minimum in (("terminationAdmissionChecks", 21), ("setupExchangeGateChecks", 39), ("desktopGuidanceChecks", 123)))):
            raise BuildSnapshotError("Actual synthetic Quit/admission proof is required")
        if (lifetime_checks.get("status") != "passed" or type(lifetime_checks.get("checks")) is not int or
                lifetime_checks["checks"] < 41 or
                any(lifetime_checks.get(key) is not True for key in (
                    "actualMacHostChild", "nativeSupervisor", "freshSyntheticOnly", "appAbruptDeath",
                    "gracefulStop", "boundedStop", "restartDescendantCleanup", "writerNotInherited", "supervisorCrashCleanup",
                    "pinnedRestartForkDenied", "forkVforkSpawnDenied", "normalThreadsAndFiles",
                    "unrestrictedChildModeRefused", "wrapperAndProfileUnavailableRefused")) or
                lifetime_checks.get("productionHostLaunched") is not False):
            raise BuildSnapshotError("Checked synthetic native host lifetime proof is required")
        if require_release and completed["configuration"] != "release":
            raise BuildSnapshotError("Signed releases require an optimized release build")
        if completed.get("appManifest") != tree_snapshot(root / "dist/Knot.app"):
            raise BuildSnapshotError("App bundle changed after the successful build; rebuild")
        if completed.get("installerManifest") != tree_snapshot(root / "dist/Install Knot.app"):
            raise BuildSnapshotError("Local installer changed after the successful build; rebuild")
        if completed.get("hostSupervisor") != host_supervisor_snapshot(root / "dist/Knot.app"):
            raise BuildSnapshotError("Host supervisor differs from its checked build; rebuild")
        if lifetime_checks.get("testedSupervisorSHA256") != completed["hostSupervisor"]["sha256"]:
            raise BuildSnapshotError("Host supervisor lifetime proof belongs to a different helper; rebuild")
        if tree_snapshot(root / "dist/Install Knot.app/Contents/Helpers/Knot.app") != completed["appManifest"]:
            raise BuildSnapshotError("Local installer payload differs from the tested app; rebuild")
        return completed, checks
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise BuildSnapshotError("Incomplete or invalid build evidence; rebuild") from error

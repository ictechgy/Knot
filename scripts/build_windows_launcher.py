#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline cross-build of a native Windows bootstrap and embedded managed helper.

Inputs are an explicit C# compiler and Framework reference directory. This script
does not download/install tools, run the EXE, or change any Windows configuration.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile
from build_snapshot import source_snapshot
from windows_resources import resource_file, validate_bootstrap
from reverse_client import client_sources, generate_engine_pin, generate_qr_loader
from reverse_qr import compile_decoder
from update_windows import prepare_windows_updates

ROOT = Path(__file__).resolve().parent.parent
PAYLOAD_NAMES = (
    "Setup-DeskBridge.ps1", "Invoke-DeskBridgeSetup.ps1", "SetupContract.psm1", "SetupDownload.psm1", "SetupStatus.psm1", "SetupReadiness.psm1",
    "Enable-DeskBridgeSFTP.ps1", "Resume-DeskBridgeSFTP.ps1", "Disable-DeskBridgeSFTP.ps1",
    "SunshineDependency.json", "README.md", "EnrollmentClient.cs", "Enrollment.psm1",
    "ConnectionInvitation.psm1", "Show-ConnectionQR.ps1",
    "HeadlessSetup.psm1", "HeadlessStatus.psm1", "HeadlessNative.cs", "Invoke-DeskBridgeHeadless.ps1", "Show-HeadlessSetup.ps1",
    "VirtualDisplayDependency.json", "VirtualDisplayFiles.json", "VirtualDisplayDeployments.json", "Knot-vdd_settings.xml", "VirtualDisplay-NOTICE.txt",
)


def payload_files(root, qr_library):
    return [(name, root / "host/windows" / name) for name in PAYLOAD_NAMES] + [
        ("LICENSE", root / "LICENSE"), ("INSTALLATION.md", root / "INSTALLATION.md"),
        ("AppIcon.ico", root / "Assets/Brand/AppIcon.ico"),
        ("DeskBridge-QR.dll", qr_library), ("QRCodegen-LICENSE", root / "Vendor/QRCodegen/NOTICE"),
        ("WindowsRuntime-NOTICE", root / "Vendor/WindowsRuntime/NOTICE"),
        ("MoonlightDependency.json", root / "client/windows/MoonlightDependency.json"),
        ("MoonlightFiles.json", root / "client/windows/MoonlightFiles.json"),
        ("Moonlight-LICENSE.txt", root / "client/windows/Moonlight-LICENSE.txt"),
        ("Moonlight-NOTICE.txt", root / "client/windows/Moonlight-NOTICE.txt"),
        ("Mac-client-README.md", root / "client/windows/README.ko.md"),
        ("QRDecoder-LICENSE.txt", root / "Vendor/ZXingNet/LICENSE"),
        ("QRDecoder-NOTICE.txt", root / "Vendor/ZXingNet/NOTICE")]


def verify_runtime_notices(root):
    vendor = Path(root) / 'Vendor/WindowsRuntime'
    provenance = json.loads((vendor / 'UPSTREAM.json').read_text())
    if set(provenance['files']) != {'Zig-LICENSE', 'Mingw-COPYING'}:
        raise ValueError('Unexpected native runtime notice inventory')
    notice = (vendor / 'NOTICE').read_bytes()
    for name, digest in provenance['files'].items():
        content = (vendor / name).read_bytes()
        if hashlib.sha256(content).hexdigest() != digest or content.rstrip(b'\r\n') not in notice:
            raise ValueError('Native runtime notice differs from pinned source: ' + name)
    return {**provenance['files'], 'NOTICE': hashlib.sha256(notice).hexdigest()}


def verify_virtual_display_inputs(root):
    folder = Path(root) / 'host/windows'
    pin = json.loads((folder / 'VirtualDisplayDependency.json').read_text())
    files = json.loads((folder / 'VirtualDisplayFiles.json').read_text())
    # This candidate has not cleared the upstream IPC review. Changing JSON alone
    # must not silently enable a release; broker and policy need a reviewed change.
    if (pin.get('installEnabled') is not False or
            pin.get('driverSafetyReviewStatus') != 'blocked' or
            pin.get('installBlockedReason') != 'upstream-ipc-review'):
        raise ValueError('Virtual display candidate must remain blocked pending driver safety review')
    if (pin.get('schema') != 1 or pin.get('bytes') != 132118 or
            pin.get('sha256') != 'e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a' or
            pin.get('url') != 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip' or
            pin.get('architecture') != 'amd64' or files.get('schema') != 1):
        raise ValueError('Unexpected virtual display package pin')
    expected = {'VirtualDisplayDriver/mttvdd.cat', 'VirtualDisplayDriver/MttVDD.dll',
                'VirtualDisplayDriver/MttVDD.inf', 'VirtualDisplayDriver/vdd_settings.xml'}
    inventory = files.get('files', [])
    if (len(inventory) != 4 or {item['path'] for item in inventory} != expected or
            any(type(item['bytes']) is not int or not 0 < item['bytes'] <= 300000 or
                not re.fullmatch('[0-9a-f]{64}', item['sha256']) for item in inventory)):
        raise ValueError('Invalid virtual display inventory')
    if hashlib.sha256((folder / 'Knot-vdd_settings.xml').read_bytes()).hexdigest() != pin.get('settingsSha256'):
        raise ValueError('Virtual display settings differ from the pinned template')
    deployments = json.loads((folder / 'VirtualDisplayDeployments.json').read_text())
    profiles = deployments.get('profiles', [])
    required_files = {'mttvdd.cat', 'MttVDD.dll', 'MttVDD.inf', 'vdd_settings.xml'}
    ids = [profile.get('manifestId') for profile in profiles]
    if (deployments.get('schema') != 1 or not profiles or len(profiles) > 32 or
            any(not isinstance(value, str) or not re.fullmatch('[a-z0-9][a-z0-9.-]{0,79}', value) for value in ids) or
            len(set(ids)) != len(ids) or deployments.get('currentManifestId') not in ids or
            not isinstance(deployments.get('legacySchema2ManifestIds'), list) or
            not set(deployments['legacySchema2ManifestIds']) <= set(ids)):
        raise ValueError('Invalid trusted virtual display deployment profiles')
    for profile in profiles:
        deployed = profile.get('files', [])
        if (set(profile) != {'manifestId', 'archiveSha256', 'driverVersion', 'catalogSignerCertificateSha256', 'files'} or
                not re.fullmatch('[0-9a-f]{64}', profile.get('archiveSha256', '')) or
                not re.fullmatch('[0-9a-f]{64}', profile.get('catalogSignerCertificateSha256', '')) or
                not re.fullmatch(r'[0-9]+(?:\.[0-9]+){3}', profile.get('driverVersion', '')) or
                len(deployed) != 4 or {entry.get('name') for entry in deployed} != required_files or
                any(set(entry) != {'name', 'bytes', 'sha256'} or
                    type(entry.get('bytes')) is not int or not 0 < entry['bytes'] <= 300000 or
                    not re.fullmatch('[0-9a-f]{64}', entry.get('sha256', '')) for entry in deployed)):
            raise ValueError('Invalid trusted virtual display deployment inventory')
    current = profiles[ids.index(deployments['currentManifestId'])]
    expected_deployed = {Path(item['path']).name: (item['bytes'], item['sha256']) for item in inventory}
    settings = (folder / 'Knot-vdd_settings.xml').read_bytes()
    expected_deployed['vdd_settings.xml'] = (len(settings), pin['settingsSha256'])
    actual_deployed = {item['name']: (item['bytes'], item['sha256']) for item in current['files']}
    if (current['archiveSha256'] != pin['sha256'] or current['driverVersion'] != pin['driverVersion'] or
            current['catalogSignerCertificateSha256'] != pin['catalogSignerCertificateSha256'] or
            actual_deployed != expected_deployed):
        raise ValueError('Current virtual display profile differs from installation pins')
    native = (folder / 'HeadlessNative.cs').read_text()
    if ('internal const string DriverVersion = "' + pin['driverVersion'] + '";') not in native:
        raise ValueError('Native virtual display verification version differs from installation pins')
    backend = (folder / 'HeadlessSetup.psm1').read_text(encoding='utf-8-sig')
    ui = (folder / 'Show-HeadlessSetup.ps1').read_text(encoding='utf-8-sig')
    # Literal-drift lint only: this text search does not establish executable
    # PowerShell semantics. The backend's actual manifest reader and archive
    # verifier enforce pins; inert PowerShell contract tests exercise rejection.
    for source, variable, fields in ((backend, 'dependency', ('bytes', 'sha256', 'driverVersion', 'catalogSignerCertificateSha256')),
                                     (ui, 'dep', ('url', 'bytes'))):
        for field in fields:
            values = re.findall(r'\$' + variable + r'\.' + field + r"\s+-c?ne\s+(?:'([^']*)'|([0-9]+))(?=\s|[)])", source)
            if [text or number for text, number in values] != [str(pin[field])]:
                raise ValueError('PowerShell virtual display verification pin differs: ' + variable + '.' + field)
    notice = (folder / 'VirtualDisplay-NOTICE.txt').read_text()
    if 'Copyright (c) 2024 Virtual Display' not in notice or 'Permission is hereby granted' not in notice:
        raise ValueError('Missing virtual display license notice')
    return {'dependencySha256': hashlib.sha256((folder / 'VirtualDisplayDependency.json').read_bytes()).hexdigest(),
            'inventorySha256': hashlib.sha256((folder / 'VirtualDisplayFiles.json').read_bytes()).hexdigest(),
            'settingsSha256': pin['settingsSha256'],
            'deploymentProfilesSha256': hashlib.sha256((folder / 'VirtualDisplayDeployments.json').read_bytes()).hexdigest(),
            'nativeSourceSha256': hashlib.sha256((folder / 'HeadlessNative.cs').read_bytes()).hexdigest(),
            'deviceRuntimeTested': False}


def build(compiler, references, output, dotnet=None, native_compiler=None):
    if not native_compiler:
        raise ValueError('Supply the pinned Zig compiler via --native-compiler')
    runtime_notice_hashes = verify_runtime_notices(ROOT)
    virtual_display = verify_virtual_display_inputs(ROOT)
    native_compiler_sha = hashlib.sha256(Path(native_compiler).read_bytes()).hexdigest()
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?", version):
        raise ValueError("Invalid VERSION")
    snapshot = source_snapshot(ROOT)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Never leave old success evidence for a failed build.
    manifest = output.with_suffix(".build.json")
    output.unlink(missing_ok=True)
    manifest.unlink(missing_ok=True)
    managed = output.with_name('DeskBridge-Managed.exe')
    managed.unlink(missing_ok=True)
    refs = [Path(references) / (name + ".dll") for name in ("mscorlib", "System", "System.Core", "System.Windows.Forms", "System.Drawing", "System.IO.Compression", "System.IO.Compression.FileSystem")]
    if any(not p.is_file() for p in refs):
        raise ValueError("Supply the .NET Framework 4.8 reference assemblies directory")
    compiler = Path(shutil.which(str(compiler)) or compiler).resolve(strict=True)
    managed_compiler_sha = hashlib.sha256(compiler.read_bytes()).hexdigest()
    reference_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in refs}
    compiler_prefix = [str(dotnet), str(compiler)] if dotnet else [str(compiler)]
    vendor = ROOT / 'Vendor/QRCodegen'
    provenance = json.loads((vendor / 'UPSTREAM.json').read_text())
    if {p.name for p in vendor.glob('*.cs')} != {name for name in provenance['files'] if name.endswith('.cs')}:
        raise ValueError('Unexpected or missing QR generator source')
    for name, digest in provenance['files'].items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != digest:
            raise ValueError('QR generator differs from its pinned source: ' + name)
    qr_library = output.with_name('DeskBridge-QR.dll')
    qr_library.unlink(missing_ok=True)
    qr_argv = compiler_prefix + ['-nologo', '-target:library', '-platform:anycpu', '-langversion:7.3', '-optimize+', '-deterministic+',
                                '-nostdlib+', '-out:' + str(qr_library), *['-r:' + str(p) for p in refs[:3]],
                                *map(str, sorted(vendor.glob('*.cs')))]
    qr_result = subprocess.run(qr_argv, cwd=ROOT, capture_output=True)
    if qr_result.returncode:
        qr_library.unlink(missing_ok=True)
        raise RuntimeError(qr_result.stdout.decode(errors='replace') + qr_result.stderr.decode(errors='replace'))
    decoder = output.with_name('DeskBridge.QrDecoder.dll')
    decoder_record = compile_decoder(ROOT, compiler_prefix, references, decoder)
    with tempfile.TemporaryDirectory(prefix="deskbridge-launcher-build-") as temporary:
        update = prepare_windows_updates(ROOT, compiler_prefix, references, Path(temporary) / "updates")
        entries = payload_files(ROOT, qr_library) + update['payload']
        hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in entries}
        engine_pin = Path(temporary) / "EnginePin.cs"
        engine_record = generate_engine_pin(ROOT, engine_pin)
        qr_loader = Path(temporary) / "ReverseQrLibrary.cs"
        generate_qr_loader(decoder_record['sha256'], qr_loader)
        generated = Path(temporary) / "Payload.cs"
        generated.write_text(
            'using System.Reflection;\n[assembly: AssemblyTitle("Knot Windows")]\n' +
            '[assembly: AssemblyVersion("' + version.split("-")[0] + '.0")]\n' +
            '[assembly: AssemblyInformationalVersion("' + version + '")]\n' +
            'internal static class Payload { internal static readonly PayloadEntry[] Entries = {\n' +
            "".join('new PayloadEntry(' + json.dumps(name) + ',' + json.dumps("DeskBridge.Payload." + name) + ',' + json.dumps(hashes[name]) + '),\n' for name, _ in entries) +
            '}; }\n', encoding="utf-8")
        argv = compiler_prefix + [
            # IL-only AnyCPU without Prefer32Bit runs in the 64-bit Windows CLR.
            # Main explicitly rejects other OS architectures before extraction.
            "-nologo", "-target:winexe", "-platform:anycpu", "-optimize+", "-deterministic+",
            "-langversion:5", "-nostdlib+", "-main:Launcher", "-out:" + str(managed),
            "-win32manifest:" + str(ROOT / "packaging/windows/Launcher.manifest"),
            "-win32icon:" + str(ROOT / "Assets/Brand/AppIcon.ico"),
            *["-r:" + str(p) for p in refs],
            "-r:" + str(decoder),
            "-resource:" + str(decoder) + "," + decoder_record['resourceName'],
            *["-resource:" + str(path) + ",DeskBridge.Payload." + name for name, path in entries],
            str(ROOT / "packaging/windows/Launcher.cs"), str(ROOT / "packaging/windows/RoleChooser.cs"),
            str(ROOT / "host/windows/SunshineQuickSetup.cs"), str(generated),
            str(engine_pin), str(qr_loader), str(update['configurationSource']),
            str(ROOT / 'packaging/windows/KnotUpdateHandoff.cs'), *map(str, client_sources(ROOT)),
        ]
        result = subprocess.run(argv, cwd=temporary, capture_output=True)
        if result.returncode:
            managed.unlink(missing_ok=True)
            raise RuntimeError(result.stdout.decode(errors="replace") + result.stderr.decode(errors="replace"))
        managed_bytes = managed.read_bytes()
        managed_sha = hashlib.sha256(managed_bytes).hexdigest()
        (Path(temporary) / 'NativePayload.h').write_text(
            '#define DB_MANAGED_RESOURCE_ID 101\n#define DB_MANAGED_SHA256 "' + managed_sha + '"\n')
        resources = Path(temporary) / 'NativePayload.res'
        resources.write_bytes(resource_file(managed_bytes,
            (ROOT / 'packaging/windows/Launcher.manifest').read_bytes(),
            (ROOT / 'Assets/Brand/AppIcon.ico').read_bytes(), version))
        native_argv = [str(native_compiler), 'cc', '-target', 'x86_64-windows-gnu',
                       '-std=c11', '-municode', '-O2', '-Wl,--subsystem,windows',
                       '-I', temporary, str(ROOT / 'packaging/windows/NativeBootstrap.c'),
                       str(resources), '-o', str(output), '-ladvapi32', '-lshell32', '-lole32', '-luser32', '-luuid']
        native_env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(output.parent / 'zig-global-cache'),
                          ZIG_LOCAL_CACHE_DIR=str(output.parent / 'zig-local-cache'))
        native_version = subprocess.run([str(native_compiler), 'version'], capture_output=True, check=True).stdout.decode().strip()
        pinned = json.loads((ROOT / 'packaging/windows/ZigDependency.json').read_text())['version']
        if native_version != pinned:
            raise ValueError('Native compiler version must match ZigDependency.json')
        native_result = subprocess.run(native_argv, cwd=temporary, env=native_env, capture_output=True)
        if native_result.returncode:
            output.unlink(missing_ok=True)
            raise RuntimeError(native_result.stdout.decode(errors='replace') + native_result.stderr.decode(errors='replace'))
        native_imports = validate_bootstrap(output.read_bytes(), managed_bytes, version)
    if source_snapshot(ROOT) != snapshot:
        output.unlink(missing_ok=True)
        raise RuntimeError("Source changed during launcher build; rebuild")
    if (hashlib.sha256(compiler.read_bytes()).hexdigest() != managed_compiler_sha or
            {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in refs} != reference_hashes):
        output.unlink(missing_ok=True)
        raise RuntimeError("Managed compiler or reference assemblies changed during launcher build; rebuild")
    if output.read_bytes()[:2] != b"MZ":
        output.unlink(missing_ok=True)
        raise RuntimeError("Compiler did not produce a Windows executable")
    record = {"schema": 1, "version": version, "sourceManifest": snapshot,
              "compiler": str(compiler), "references": str(references), "argv": argv,
              "managedCompilerSha256": managed_compiler_sha, "referenceAssemblySha256": reference_hashes,
              "compilerExitCode": result.returncode, "stdout": result.stdout.decode(errors="replace"),
              "stderr": result.stderr.decode(errors="replace"), "payloadSha256": hashes,
              "managedSha256": managed_sha, "nativeCompiler": str(native_compiler),
              "nativeCompilerVersion": native_version, "nativeCompilerSha256": native_compiler_sha,
              "nativeCompilerDigestVerifiedAgainstPin": False, "runtimeNoticeSha256": runtime_notice_hashes,
              "nativeCompilerArgv": native_argv,
              "nativeCompilerExitCode": native_result.returncode,
              "nativeCompilerStdout": native_result.stdout.decode(errors='replace'),
              "nativeCompilerStderr": native_result.stderr.decode(errors='replace'),
              "nativeImports": native_imports, "nativeCLRHeaderAbsent": True,
              "qrLibrarySha256": hashes['DeskBridge-QR.dll'], "qrCompilerArgv": qr_argv,
              "qrCompilerExitCode": qr_result.returncode, "qrCompilerStdout": qr_result.stdout.decode(errors='replace'),
              "qrCompilerStderr": qr_result.stderr.decode(errors='replace'),
              "reverseQrDecoder": decoder_record, "reverseEngine": engine_record,
              "extraResources": {decoder_record['resourceName']: decoder_record['sha256']},
              "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
              "virtualDisplay": virtual_display, "updates": update['record'],
              "windowsRuntimeTested": False, "authenticodeSigned": False}
    manifest.write_text(json.dumps(record, indent=2))
    return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, help="csc.exe, or SDK Roslyn csc.dll with --dotnet")
    parser.add_argument("--references", required=True, help=".NET Framework 4.8 reference assemblies directory")
    parser.add_argument("--dotnet", help="Explicit dotnet runtime to run csc.dll on macOS/Linux")
    parser.add_argument("--native-compiler", required=True, help="Pinned Zig compiler for the native pre-CLR bootstrap")
    parser.add_argument("--output", help="EXE path; defaults to build/windows/Knot-Windows.exe")
    args = parser.parse_args()
    record = build(args.compiler, args.references, args.output or ROOT / "build/windows/Knot-Windows.exe", args.dotnet, args.native_compiler)
    print(json.dumps({key: record[key] for key in ("version", "sha256", "windowsRuntimeTested", "authenticodeSigned")}, indent=2))

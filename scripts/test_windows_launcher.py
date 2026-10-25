#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline compiled-assembly checks in a new temp project, without Windows Main."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, shutil, subprocess, tempfile
from windows_resources import NativePE, validate_bootstrap
from build_snapshot import source_snapshot
from test_reverse_client import run as run_reverse_client
from test_windows_updates import check as run_update_checks
from windows_check_record import HEADLESS_SOURCE_PATHS, MAC_INTEROP_SOURCE_PATHS, MINIMUM_WINDOWS_CHECKS, REQUIRED_WINDOWS_SUITES, validate_windows_check_record

ROOT = Path(__file__).resolve().parent.parent


def fixture_module(name):
    # An unrelated installed package named "tests" must not substitute a checker.
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/tests' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_headless_checks(powershell, invoke, snapshot, bootstrap_policy_runner=None):
    """Compile actual native source and exercise production setup with inert fixtures."""
    if not powershell:
        if os.name != 'nt':
            raise ValueError('Supply --powershell for mandatory synthetic headless native/setup checks')
        powershell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    results = {'sourceSha256': {path: snapshot[path] for path in HEADLESS_SOURCE_PATHS}}
    for label, script in [('headless-native', 'Test-HeadlessNative.ps1'), ('headless-setup', 'Test-HeadlessSetup.ps1'), ('headless-status', 'Test-HeadlessStatus.ps1')]:
        argv = [powershell, '-NoProfile', '-NonInteractive', '-File', ROOT / 'host/windows/tests' / script]
        if label == 'headless-status':
            if not bootstrap_policy_runner:
                raise ValueError('Supply the compiled native bootstrap policy for mandatory composed result checks')
            argv += ['-BootstrapPolicyRunner', bootstrap_policy_runner]
        entry = invoke(label + '-synthetic-checks', argv)
        lines = entry['stdout'].strip().splitlines()
        if not lines:
            raise ValueError(label + ' checker returned no terminal result')
        result = json.loads(lines[-1])
        if (result.get('status') != 'passed' or type(result.get('checks')) is not int or
                result['checks'] < MINIMUM_WINDOWS_CHECKS[label] or result.get('freshSyntheticOnly') is not True or
                result.get('nativeApisInvoked') is not False):
            raise ValueError(label + ' checker returned incomplete or unsafe results')
        if label == 'headless-native' and type(result.get('frameworkCompiler')) is not bool:
            raise ValueError('Headless native fixture did not identify its compiler path')
        if label == 'headless-native' and os.name == 'nt' and result['frameworkCompiler'] is not True:
            raise ValueError('Windows headless checks require the protected Framework compiler boundary')
        if label == 'headless-status' and result.get('bootstrapPolicyComposed') is not True:
            raise ValueError('Actual wrapper results were not composed with the compiled native bootstrap policy')
        results[label] = result
    return results

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', required=True)
    parser.add_argument('--executable', type=Path, default=ROOT / 'build/windows/Knot-Windows.exe')
    parser.add_argument('--mac-checker', type=Path, help='Run actual Mac QR reader against a new C#-generated bitmap fixture')
    parser.add_argument('--native-compiler', help='Pinned Zig compiler to build pure C checks on Windows')
    parser.add_argument('--compiler', help='C# compiler; defaults to the executable build record')
    parser.add_argument('--references', help='.NET Framework 4.8 references; defaults to the executable build record')
    parser.add_argument('--powershell', help='Explicit PowerShell executable for mandatory inert headless suites; Windows defaults to system Windows PowerShell')
    args = parser.parse_args()
    check_record = args.executable.resolve().with_suffix('.checks.json')
    check_record.unlink(missing_ok=True)
    snapshot = source_snapshot(ROOT)
    mac_checker_sha = hashlib.sha256(args.mac_checker.read_bytes()).hexdigest() if args.mac_checker else None
    invocations = []
    with tempfile.TemporaryDirectory(prefix='deskbridge-launcher-checks-') as directory:
        root = Path(directory)
        native = args.executable.resolve()
        record = json.loads(native.with_suffix('.build.json').read_text())
        if record.get('sourceManifest') != snapshot:
            raise ValueError('Windows helper was built from another source snapshot')
        native_bytes = native.read_bytes()
        if hashlib.sha256(native_bytes).hexdigest() != record['sha256']:
            raise ValueError('Native bootstrap differs from build manifest')
        close_helper = native.with_name('KnotCloseForUpdate.exe')
        close_record = record.get('closeForUpdate', {})
        if (close_record.get('compilerExitCode') != 0 or close_record.get('nativeCompilerExitCode') != 0 or
                close_record.get('hardenedNativeBootstrap') is not True or
                hashlib.sha256(close_helper.read_bytes()).hexdigest() != close_record.get('sha256')):
            raise ValueError('Graceful-close helper differs from the exact build')
        close_payload = NativePE(close_helper.read_bytes()).resource(10, 101)
        validate_bootstrap(close_helper.read_bytes(), close_payload, record['version'])
        if hashlib.sha256(close_payload).hexdigest() != close_record.get('managedSHA256'):
            raise ValueError('Graceful-close embedded policy differs from its exact build')

        managed_bytes = NativePE(native_bytes).resource(10, 101)
        validate_bootstrap(native_bytes, managed_bytes, record['version'])
        if hashlib.sha256(managed_bytes).hexdigest() != record['managedSha256']:
            raise ValueError('Embedded managed helper differs from build manifest')
        managed = root / 'DeskBridge-Managed.exe'
        managed.write_bytes(managed_bytes)
        managed.with_suffix('.build.json').write_text(json.dumps(record))
        (root / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable></PropertyGroup></Project>')
        (root / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
        shutil.copy2(ROOT / 'scripts/tests/WindowsLauncherChecks.cs', root / 'Checks.cs')
        env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
                   DOTNET_CLI_HOME=str(root / 'cli-home'), NUGET_PACKAGES=str(root / 'packages'))

        def invoke(label, argv, invocation_env=env, timeout=180):
            result = subprocess.run(list(map(str, argv)), cwd=root, env=invocation_env, capture_output=True, timeout=timeout)
            entry = {'label': label, 'argv': list(map(str, argv)), 'exitCode': result.returncode,
                     'stdout': result.stdout.decode(errors='replace'), 'stderr': result.stderr.decode(errors='replace')}
            invocations.append(entry)
            if result.returncode:
                raise RuntimeError(label + ' failed:\n' + entry['stdout'] + entry['stderr'])
            return entry

        if os.name == 'nt':
            # Real Windows GetFileVersionInfo catches a writer/parser pair that
            # agrees on bytes which Explorer cannot actually read. No EXE runs.
            version_check = root / 'Check-NativeVersion.ps1'
            version_check.write_text('''$ErrorActionPreference='Stop'
$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($args[0])
if ($v.ProductName -cne 'Knot' -or $v.FileDescription -cne 'Knot Windows' -or
    $v.OriginalFilename -cne 'Knot-Windows.exe' -or $v.FileVersion -cne $args[1] -or $v.ProductVersion -cne $args[1]) {
 throw 'Native Windows shell product metadata differs from Knot release metadata.'
}
@{status='passed';product=$v.ProductName;version=$v.ProductVersion} | ConvertTo-Json -Compress
''')
            system_powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
            invoke('native-windows-shell-product-version', [system_powershell, '-NoProfile', '-NonInteractive',
                   '-File', version_check, native, record['version']], timeout=30)

        invoke('compile-managed-payload-checker', [args.dotnet, 'build', root / 'Checks.csproj', '--configuration', 'Release', '--nologo', '--verbosity', 'quiet'])
        bmp = root / 'windows-connection-qr.bmp'
        payload_argv = [args.dotnet, root / 'bin/Release/net8.0/Checks.dll', managed, bmp]
        mac_fixture = root / 'mac-connection-qr.json'
        if args.mac_checker:
            invoke('export-actual-mac-qr-fixture', [args.mac_checker.resolve(), '--synthetic-mac-qr', mac_fixture], timeout=60)
            payload_argv.append(mac_fixture)
        payload_result = json.loads(invoke('execute-managed-payload-checker', payload_argv, timeout=60)['stdout'])
        if payload_result.get('status') != 'passed' or type(payload_result.get('checks')) is not int or payload_result['checks'] < MINIMUM_WINDOWS_CHECKS['managed-payload']:
            raise ValueError('Managed payload checker returned incomplete results')
        if (payload_result.get('embeddedDecoderBindingTested') is not True or
                payload_result.get('decoderResolverIdentityTested') is not True or
                payload_result.get('decoderInitializationIdempotent') is not True or
                payload_result.get('embeddedDecoderSha256') != record['reverseQrDecoder']['sha256']):
            raise ValueError('Packaged adapter did not execute the exact embedded QR decoder binding')
        if payload_result.get('macToWindowsQRInterop') is not bool(args.mac_checker):
            raise ValueError('Mac-to-Windows QR interop was not actually executed as requested')
        if args.mac_checker and payload_result.get('macToWindowsQRFixtureSha256') != hashlib.sha256(mac_fixture.read_bytes()).hexdigest():
            raise ValueError('Mac-to-Windows QR interop fixture digest mismatch')
        if os.name == 'nt' and not args.native_compiler:
            raise ValueError('Supply --native-compiler to run pure native argument checks on Windows')
        prefix = [args.native_compiler, 'cc'] if args.native_compiler else ['/usr/bin/cc']
        native_checks = root / ('native-checks.exe' if os.name == 'nt' else 'native-checks')
        native_env = dict(env, ZIG_GLOBAL_CACHE_DIR=str(root / 'zig-global'), ZIG_LOCAL_CACHE_DIR=str(root / 'zig-local'))
        invoke('compile-native-argument-checks', prefix + ['-std=c11', '-Wall', '-Wextra', '-Werror', str(ROOT / 'scripts/tests/NativeBootstrapChecks.c'), '-o', str(native_checks)], native_env)
        native_result = json.loads(invoke('execute-native-argument-checks', [native_checks], timeout=60)['stdout'])
        if native_result.get('status') != 'passed' or type(native_result.get('checks')) is not int or native_result['checks'] < MINIMUM_WINDOWS_CHECKS['native-arguments']:
            raise ValueError('Native argument checker returned incomplete results')
        if args.mac_checker:
            invoke('windows-to-mac-qr-interop', [args.mac_checker.resolve(), '--synthetic-qr-bmp', bmp], timeout=60)
        compiler = args.compiler or record.get('compiler')
        references = args.references or record.get('references')
        if not compiler or not references:
            raise ValueError('Supply --compiler and --references for source-bound reverse checks')
        reverse = run_reverse_client(args.dotnet, compiler, references)
        updates = run_update_checks(compiler, references, args.dotnet if str(compiler).lower().endswith('.dll') else None)
        reverse_qr = fixture_module('test_reverse_qr').run(args.dotnet)
        if (reverse_qr.get('status') != 'PASS' or type(reverse_qr.get('checks')) is not int or reverse_qr['checks'] < 65 or
                reverse_qr.get('actualDecoder') is not True or reverse_qr.get('freshSyntheticOnly') is not True):
            raise ValueError('Portable reverse QR checker returned incomplete results')
        reverse_qr_windows = fixture_module('test_reverse_qr_windows').run(compiler, references,
            args.dotnet if str(compiler).lower().endswith('.dll') else None, compile_only=os.name != 'nt')
        if (reverse_qr_windows.get('compilerExitCode') != 0 or
                reverse_qr_windows.get('status') != ('PASS' if os.name == 'nt' else 'COMPILED_ONLY') or
                reverse_qr_windows.get('windowsImageCodecTested') is not (os.name == 'nt')):
            raise ValueError('Native Windows QR fixture result is incomplete or mislabeled')
        headless = run_headless_checks(args.powershell, invoke, snapshot, native_checks)
    if source_snapshot(ROOT) != snapshot or hashlib.sha256(native.read_bytes()).hexdigest() != record['sha256']:
        raise ValueError('Inputs changed during Windows checks; rerun')
    if args.mac_checker and hashlib.sha256(args.mac_checker.read_bytes()).hexdigest() != mac_checker_sha:
        raise ValueError('Mac checker changed during QR interop checks; rerun')
    checked = {'schema': 1, 'status': 'passed',
        'suites': REQUIRED_WINDOWS_SUITES,
        'counts': {'native-pe': 1, 'managed-payload': payload_result['checks'], 'native-arguments': native_result['checks'],
                   **reverse['counts'], 'reverse-qr': reverse_qr['checks'],
                   'headless-native': headless['headless-native']['checks'], 'headless-setup': headless['headless-setup']['checks'],
                   'headless-status': headless['headless-status']['checks']},
        **{key: record[key] for key in ('sha256', 'managedSha256', 'sourceManifest')},
        'updates': updates, 'reverseClient': reverse, 'reverseQR': reverse_qr, 'reverseQRWindows': reverse_qr_windows, 'headless': headless,
        'embeddedDecoderBindingTested': payload_result['embeddedDecoderBindingTested'],
        'embeddedDecoderSha256': payload_result['embeddedDecoderSha256'],
        'decoderResolverIdentityTested': payload_result['decoderResolverIdentityTested'],
        'decoderInitializationIdempotent': payload_result['decoderInitializationIdempotent'],
        'macToWindowsQRInterop': payload_result['macToWindowsQRInterop'],
        'macToWindowsQRFixtureSha256': payload_result['macToWindowsQRFixtureSha256'],
        'macCheckerSha256': mac_checker_sha,
        'macInteropSourceSha256': {path: snapshot[path] for path in MAC_INTEROP_SOURCE_PATHS} if args.mac_checker else {},
        'invocations': invocations, 'windowsImageCodecRuntimeTested': os.name == 'nt',
        'windowsToMacQRInterop': bool(args.mac_checker), 'windowsRuntimeTested': False}
    validate_windows_check_record(checked, record)
    check_record.write_text(json.dumps(checked, indent=2))
    print(json.dumps({'status': 'passed', 'suites': checked['suites'], 'counts': checked['counts'],
        'windowsImageCodecRuntimeTested': checked['windowsImageCodecRuntimeTested'],
        'macToWindowsQRInterop': checked['macToWindowsQRInterop'],
        'windowsToMacQRInterop': checked['windowsToMacQRInterop'], 'windowsRuntimeTested': False}, indent=2))

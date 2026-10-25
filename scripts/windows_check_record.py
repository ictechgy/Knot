# SPDX-License-Identifier: GPL-3.0-only
"""Bind offline Windows checks to the exact executable, decoder and source."""
import re

REQUIRED_WINDOWS_SUITES = ['native-pe', 'managed-payload', 'native-arguments',
                          'reverse-client', 'reverse-discovery', 'reverse-qr', 'headless-native', 'headless-setup', 'headless-status']
MINIMUM_WINDOWS_CHECKS = {'native-pe': 1, 'managed-payload': 242, 'native-arguments': 1278,
                        'reverse-client': 124, 'reverse-discovery': 195, 'reverse-qr': 65,
                        'headless-native': 370, 'headless-setup': 291, 'headless-status': 82}
HEADLESS_SOURCE_PATHS = ['host/windows/HeadlessNative.cs', 'host/windows/HeadlessSetup.psm1',
                         'host/windows/Invoke-DeskBridgeHeadless.ps1', 'host/windows/tests/Test-HeadlessNative.ps1',
                         'host/windows/tests/Test-HeadlessSetup.ps1', 'scripts/tests/HeadlessNativeChecks.cs',
                         'host/windows/VirtualDisplayDependency.json', 'host/windows/VirtualDisplayFiles.json',
                         'host/windows/Knot-vdd_settings.xml', 'host/windows/VirtualDisplayDeployments.json',
                         'host/windows/Show-HeadlessSetup.ps1', 'host/windows/HeadlessStatus.psm1',
                         'host/windows/tests/Test-HeadlessStatus.ps1', 'packaging/windows/NativeBootstrap.c',
                         'packaging/windows/NativeArguments.h', 'scripts/tests/NativeBootstrapChecks.c']
MAC_INTEROP_SOURCE_PATHS = ['Sources/DeskBridgeAppChecks/main.swift', 'Sources/DeskBridgeApp/MacHostPage.swift',
                            'Sources/DeskBridgeCore/ConnectionInvitation.swift']


def _digest(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def validate_windows_check_record(checks, build):
    message = 'Windows payload/reverse checks are missing, failed or stale; rerun test_windows_launcher.py'
    if (checks.get('schema') != 1 or checks.get('status') != 'passed' or
            checks.get('suites') != REQUIRED_WINDOWS_SUITES or
            any(checks.get(key) != build.get(key) or not build.get(key)
                for key in ('sha256', 'managedSha256', 'sourceManifest'))):
        raise ValueError(message)
    counts = checks.get('counts', {})
    if (not isinstance(counts, dict) or set(counts) != set(REQUIRED_WINDOWS_SUITES) or
            any(type(counts.get(label)) is not int or counts[label] < minimum
                for label, minimum in MINIMUM_WINDOWS_CHECKS.items())):
        raise ValueError(message)
    source = build['sourceManifest']
    update_paths = {'client/windows/KnotUpdates.cs', 'packaging/windows/KnotUpdateHandoff.cs', 'scripts/tests/WindowsUpdateChecks.cs'}
    if update_paths & source.keys():
        updates = checks.get('updates', {})
        update_build = build.get('updates', {})
        if (not update_paths <= source.keys() or not isinstance(updates, dict) or not isinstance(update_build, dict) or
                updates.get('status') != 'PASS' or updates.get('compilerExitCode') != 0 or updates.get('runExitCode') != 0 or
                type(updates.get('checks')) is not int or updates['checks'] < (72 if updates.get('nativeWindowsFileSharingTested') else 65) or updates.get('freshSyntheticOnly') is not True or
                any(updates.get(field) is not False for field in ('nativeUpdaterExecuted', 'installerExecuted', 'registryRead', 'networkUsed')) or
                updates.get('sourceSHA256') != {path: source[path] for path in update_paths} or
                not _digest(update_build.get('runtimeSHA256')) or not _digest(update_build.get('handoffSHA256')) or
                updates.get('handoffBuild', {}).get('runtimeSHA256') != update_build['runtimeSHA256'] or
                type(updates.get('nativeWindowsFileSharingTested')) is not bool or
                (checks.get('windowsImageCodecRuntimeTested') is True and updates['nativeWindowsFileSharingTested'] is not True)):
            raise ValueError('Windows signed updater policy checks are missing, failed or stale')
    headless = checks.get('headless', {})
    if not isinstance(headless, dict):
        raise ValueError(message)
    headless_sources = headless.get('sourceSha256', {})
    if (not isinstance(headless_sources, dict) or set(headless_sources) != set(HEADLESS_SOURCE_PATHS) or
            any(not _digest(digest) or source.get(path) != digest for path, digest in headless_sources.items())):
        raise ValueError(message)
    for label in ('headless-native', 'headless-setup', 'headless-status'):
        result = headless.get(label, {})
        if (not isinstance(result, dict) or result.get('status') != 'passed' or result.get('checks') != counts[label] or
                type(result.get('checks')) is not int or result.get('freshSyntheticOnly') is not True or
                result.get('nativeApisInvoked') is not False):
            raise ValueError(message)
        invocations = [entry for entry in checks.get('invocations', []) if isinstance(entry, dict) and entry.get('label') == label + '-synthetic-checks']
        if len(invocations) != 1 or invocations[0].get('exitCode') != 0:
            raise ValueError(message)
    if headless['headless-status'].get('bootstrapPolicyComposed') is not True:
        raise ValueError(message)
    if type(headless['headless-native'].get('frameworkCompiler')) is not bool:
        raise ValueError(message)
    if type(checks.get('macToWindowsQRInterop')) is not bool:
        raise ValueError(message)
    if checks['macToWindowsQRInterop']:
        mac_sources = checks.get('macInteropSourceSha256', {})
        if (not _digest(checks.get('macToWindowsQRFixtureSha256')) or not _digest(checks.get('macCheckerSha256')) or
                not isinstance(mac_sources, dict) or set(mac_sources) != set(MAC_INTEROP_SOURCE_PATHS) or
                any(not _digest(value) or source.get(path) != value for path, value in mac_sources.items()) or
                not any(entry.get('label') == 'export-actual-mac-qr-fixture' and entry.get('exitCode') == 0
                        for entry in checks.get('invocations', []) if isinstance(entry, dict))):
            raise ValueError(message)
    elif (checks.get('macToWindowsQRFixtureSha256') is not None or checks.get('macCheckerSha256') is not None or
          checks.get('macInteropSourceSha256') != {}):
        raise ValueError(message)
    reverse = checks.get('reverseClient', {})
    if (not isinstance(reverse, dict) or reverse.get('schema') != 1 or reverse.get('status') != 'passed' or
            reverse.get('suites') != ['reverse-client', 'reverse-discovery'] or
            reverse.get('sourceManifest') != source or reverse.get('freshSyntheticOnly') is not True or
            reverse.get('windowsRuntimeTested') is not False or reverse.get('windowsImageCodecRuntimeTested') is not False or
            reverse.get('counts') != {key: counts[key] for key in ('reverse-client', 'reverse-discovery')} or
            not _digest(reverse.get('compiledAssemblySha256')) or not _digest(reverse.get('runnerSha256'))):
        raise ValueError(message)
    source_hashes = reverse.get('sourceSha256', {})
    expected_sources = {path for path in source if path.startswith('client/windows/') and path.endswith('.cs')} | {
        'scripts/tests/ReverseDiscoveryChecks.cs', 'host/windows/KnotUpdateForm.cs'}
    if (not isinstance(source_hashes, dict) or not source_hashes or
            any(not _digest(digest) or source.get(path) != digest for path, digest in source_hashes.items()) or
            set(source_hashes) != expected_sources or 'client/windows/Tests.cs' not in source_hashes):
        raise ValueError(message)
    invocations = reverse.get('invocations', [])
    if (not isinstance(invocations, list) or len(invocations) < 4 or
            any(not isinstance(entry, dict) or entry.get('exitCode') != 0 for entry in invocations) or
            not {'compile-actual-reverse-client', 'restore-offline-runner', 'compile-offline-runner',
                 'execute-pure-reverse-checks'} <= {entry.get('label') for entry in invocations}):
        raise ValueError(message)
    decoder = reverse.get('qrDecoder', {})
    embedded_decoder = build.get('reverseQrDecoder', {})
    if (not isinstance(decoder, dict) or not isinstance(embedded_decoder, dict) or
            not _digest(decoder.get('sha256')) or decoder.get('compilerExitCode') != 0 or
            decoder.get('sha256') != embedded_decoder.get('sha256') or
            decoder.get('upstreamCommit') != embedded_decoder.get('upstreamCommit') or
            build.get('extraResources', {}).get('DeskBridge.Reverse.QrDecoder') != decoder.get('sha256')):
        raise ValueError(message)
    if (checks.get('embeddedDecoderBindingTested') is not True or
            checks.get('embeddedDecoderSha256') != decoder['sha256'] or
            checks.get('decoderResolverIdentityTested') is not True or
            checks.get('decoderInitializationIdempotent') is not True):
        raise ValueError(message)
    qr = checks.get('reverseQR', {})
    native_qr = checks.get('reverseQRWindows', {})
    image_runtime = checks.get('windowsImageCodecRuntimeTested')
    if (not isinstance(qr, dict) or qr.get('status') != 'PASS' or qr.get('checks') != counts['reverse-qr'] or
            qr.get('actualDecoder') is not True or qr.get('freshSyntheticOnly') is not True or
            qr.get('windowsImageCodecTested') is not False or
            qr.get('upstreamCommit') != decoder.get('upstreamCommit') or
            qr.get('productionAdapterSha256') != source.get('client/windows/QrImageReader.cs') or
            qr.get('fixtureSha256') != source.get('scripts/tests/test_reverse_qr.cs') or
            qr.get('windowsNativeFileAndImagePathTested') is not False or
            not isinstance(native_qr, dict) or native_qr.get('compilerExitCode') != 0 or
            type(image_runtime) is not bool or native_qr.get('windowsImageCodecTested') is not image_runtime or
            native_qr.get('status') != ('PASS' if image_runtime else 'COMPILED_ONLY') or
            native_qr.get('upstreamCommit') != decoder.get('upstreamCommit') or
            native_qr.get('fixtureSha256') != source.get('scripts/tests/test_reverse_qr_windows.cs') or
            native_qr.get('separatelyCompiledEmbeddedDecoder') is not True or native_qr.get('noAdjacentDecoder') is not True or
            native_qr.get('embeddedDecoderSha256') != decoder['sha256'] or
            native_qr.get('embeddedDecoderBindingTested') is not image_runtime or
            checks.get('windowsRuntimeTested') is not False):
        raise ValueError(message)
    if image_runtime and (native_qr.get('freshSyntheticOnly') is not True or
                          type(native_qr.get('checks')) is not int or native_qr['checks'] < 20):
        raise ValueError(message)
    if image_runtime and headless['headless-native']['frameworkCompiler'] is not True:
        raise ValueError(message)

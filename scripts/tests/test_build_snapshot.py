# SPDX-License-Identifier: GPL-3.0-only
"""Offline regression cases: source additions/removals and binary replacement must invalidate packaging."""
from pathlib import Path
import copy, json, os, shlex, shutil, struct, subprocess, sys, tempfile, unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_snapshot import BuildSnapshotError, REQUIRED_CHECK_STAGES, host_supervisor_snapshot, source_snapshot, supervisor_package_record, tree_snapshot, unchanged_supervisor_digest, validate_completed_build, validate_corresponding_source
from windows_check_record import HEADLESS_SOURCE_PATHS, MAC_INTEROP_SOURCE_PATHS, MINIMUM_WINDOWS_CHECKS, REQUIRED_WINDOWS_SUITES, validate_windows_check_record
from test_windows_launcher import run_headless_checks


class SupervisorDigestTests(unittest.TestCase):
    def test_package_records_tested_and_resigned_hashes_separately(self):
        tested = {"path": "Contents/Helpers/KnotHostSupervisor", "architecture": "arm64", "type": "MH_EXECUTE", "mode": 0o755, "sha256": "a" * 64}
        preview = supervisor_package_record(tested, dict(tested), False)
        self.assertEqual((preview["testedSHA256"], preview["packagedSHA256"], preview["releaseResigned"], preview["transformation"]),
                         ("a" * 64, "a" * 64, False, "none"))
        signed = {**tested, "sha256": "b" * 64}
        release = supervisor_package_record(tested, signed, True)
        self.assertEqual((release["testedSHA256"], release["packagedSHA256"], release["releaseResigned"]),
                         ("a" * 64, "b" * 64, True))
        self.assertIn("codesign", release["transformation"])
        self.assertIn("before release re-signing", release["lifetimeProofScope"])
        with self.assertRaises(BuildSnapshotError):
            supervisor_package_record(tested, signed, False)
        with self.assertRaises(BuildSnapshotError):
            supervisor_package_record(tested, {**signed, "mode": 0o777}, True)

    def test_lifetime_digest_refuses_changed_bytes(self):
        with tempfile.TemporaryDirectory(prefix="knot-supervisor-digest-") as temporary:
            path = Path(temporary) / "synthetic-helper"
            path.write_bytes(b"synthetic initial bytes")
            import hashlib
            initial = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(unchanged_supervisor_digest(path, initial), initial)
            path.write_bytes(b"synthetic changed bytes")
            with self.assertRaisesRegex(BuildSnapshotError, "changed during"):
                unchanged_supervisor_digest(path, initial)


class WindowsPayloadCheckRecordTests(unittest.TestCase):
    def setUp(self):
        source = {path: 'c' * 64 for path in (
            'packaging/windows/Launcher.cs', 'client/windows/Tests.cs', 'client/windows/EngineStore.cs',
            'scripts/tests/ReverseDiscoveryChecks.cs', 'client/windows/QrImageReader.cs',
            'scripts/tests/test_reverse_qr.cs', 'scripts/tests/test_reverse_qr_windows.cs', 'host/windows/KnotUpdateForm.cs')}
        source.update({path: '8' * 64 for path in HEADLESS_SOURCE_PATHS})
        decoder = {'sha256': 'e' * 64, 'upstreamCommit': 'f' * 40, 'compilerExitCode': 0}
        self.build = {'sha256': 'a' * 64, 'managedSha256': 'b' * 64,
                      'sourceManifest': source, 'reverseQrDecoder': decoder,
                      'extraResources': {'DeskBridge.Reverse.QrDecoder': decoder['sha256']}}
        self.checks = {**self.build, 'schema': 1, 'status': 'passed',
                       'suites': REQUIRED_WINDOWS_SUITES, 'counts': dict(MINIMUM_WINDOWS_CHECKS),
                       'windowsRuntimeTested': False, 'windowsImageCodecRuntimeTested': False,
                       'embeddedDecoderBindingTested': True, 'embeddedDecoderSha256': decoder['sha256'],
                       'decoderResolverIdentityTested': True, 'decoderInitializationIdempotent': True,
                       'macToWindowsQRInterop': False, 'macToWindowsQRFixtureSha256': None,
                       'macCheckerSha256': None, 'macInteropSourceSha256': {},
                       'headless': {'sourceSha256': {path: source[path] for path in HEADLESS_SOURCE_PATHS},
                           'headless-native': {'status': 'passed', 'checks': MINIMUM_WINDOWS_CHECKS['headless-native'],
                               'freshSyntheticOnly': True, 'nativeApisInvoked': False, 'frameworkCompiler': False},
                           'headless-setup': {'status': 'passed', 'checks': MINIMUM_WINDOWS_CHECKS['headless-setup'],
                               'freshSyntheticOnly': True, 'nativeApisInvoked': False},
                           'headless-status': {'status': 'passed', 'checks': MINIMUM_WINDOWS_CHECKS['headless-status'],
                               'bootstrapPolicyComposed': True, 'freshSyntheticOnly': True, 'nativeApisInvoked': False}},
                       'invocations': [{'label': label + '-synthetic-checks', 'exitCode': 0} for label in ('headless-native', 'headless-setup', 'headless-status')],
                       'reverseClient': {
                           'schema': 1, 'status': 'passed', 'suites': ['reverse-client', 'reverse-discovery'],
                           'sourceManifest': source, 'freshSyntheticOnly': True, 'windowsRuntimeTested': False,
                           'windowsImageCodecRuntimeTested': False, 'compiledAssemblySha256': '1' * 64,
                           'runnerSha256': '2' * 64, 'qrDecoder': decoder,
                           'counts': {key: MINIMUM_WINDOWS_CHECKS[key] for key in ('reverse-client', 'reverse-discovery')},
                           'sourceSha256': {path: digest for path, digest in source.items() if path.startswith('client/windows/') or path in ('scripts/tests/ReverseDiscoveryChecks.cs', 'host/windows/KnotUpdateForm.cs')},
                           'invocations': [{'label': label, 'exitCode': 0} for label in (
                               'compile-actual-reverse-client', 'restore-offline-runner', 'compile-offline-runner', 'execute-pure-reverse-checks')]},
                       'reverseQR': {'status': 'PASS', 'checks': 65, 'actualDecoder': True, 'freshSyntheticOnly': True,
                           'windowsImageCodecTested': False, 'upstreamCommit': decoder['upstreamCommit'],
                           'productionAdapterSha256': source['client/windows/QrImageReader.cs'],
                           'fixtureSha256': source['scripts/tests/test_reverse_qr.cs'], 'windowsNativeFileAndImagePathTested': False},
                       'reverseQRWindows': {'status': 'COMPILED_ONLY', 'compilerExitCode': 0,
                           'windowsImageCodecTested': False, 'upstreamCommit': decoder['upstreamCommit'],
                           'separatelyCompiledEmbeddedDecoder': True, 'noAdjacentDecoder': True,
                           'embeddedDecoderBindingTested': False, 'embeddedDecoderSha256': decoder['sha256'],
                           'fixtureSha256': source['scripts/tests/test_reverse_qr_windows.cs']}}

    def test_updater_record_required_when_compiled_source_is_present(self):
        paths = {'client/windows/KnotUpdates.cs', 'packaging/windows/KnotUpdateHandoff.cs', 'scripts/tests/WindowsUpdateChecks.cs'}
        self.build['sourceManifest'].update({path:'9'*64 for path in paths})
        self.checks['reverseClient']['sourceSha256']['client/windows/KnotUpdates.cs'] = '9'*64
        self.build['updates'] = {'runtimeSHA256':'a'*64, 'handoffSHA256':'b'*64}
        proof = {'status':'PASS', 'compilerExitCode':0, 'runExitCode':0, 'checks':65, 'freshSyntheticOnly':True,
                 'nativeUpdaterExecuted':False, 'installerExecuted':False, 'registryRead':False, 'networkUsed':False,
                 'nativeWindowsFileSharingTested':False, 'sourceSHA256':{path:'9'*64 for path in paths},
                 'handoffBuild':{'runtimeSHA256':'a'*64}}
        with self.assertRaises(ValueError): validate_windows_check_record(self.checks,self.build)
        self.checks['updates']=proof
        validate_windows_check_record(self.checks,self.build)
        for field,value in [('status','failed'),('checks',64),('compilerExitCode',1),('runExitCode',1),('networkUsed',True),('sourceSHA256',{})]:
            invalid=copy.deepcopy(self.checks); invalid['updates'][field]=value
            with self.subTest(field=field), self.assertRaises(ValueError): validate_windows_check_record(invalid,self.build)
        invalid=copy.deepcopy(self.checks); invalid['updates']['nativeWindowsFileSharingTested']=True
        with self.assertRaises(ValueError): validate_windows_check_record(invalid,self.build)

    def test_matching_checked_executable_is_accepted(self):
        validate_windows_check_record(self.checks, self.build)

    def test_unchecked_executable_is_rejected(self):
        with self.assertRaises(ValueError): validate_windows_check_record({}, self.build)

    def test_replaced_outer_executable_is_rejected(self):
        with self.assertRaises(ValueError): validate_windows_check_record(self.checks, {**self.build, 'sha256': 'd' * 64})

    def test_replaced_managed_payload_is_rejected(self):
        with self.assertRaises(ValueError): validate_windows_check_record(self.checks, {**self.build, 'managedSha256': 'd' * 64})

    def test_changed_source_or_checker_is_rejected(self):
        with self.assertRaises(ValueError): validate_windows_check_record(self.checks, {**self.build, 'sourceManifest': {'scripts/test_windows_launcher.py': 'd' * 64}})

    def test_failed_or_omitted_suite_is_rejected(self):
        for changed in ({'status': 'failed'}, {'suites': ['native-pe', 'managed-payload']}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                validate_windows_check_record({**self.checks, **changed}, self.build)

    def test_missing_or_incomplete_reverse_counts_are_rejected(self):
        for label in ('reverse-client', 'reverse-discovery', 'reverse-qr', 'headless-native', 'headless-setup', 'headless-status'):
            for invalid in (None, True, 0, MINIMUM_WINDOWS_CHECKS[label] - 1):
                changed = copy.deepcopy(self.checks)
                changed['counts'][label] = invalid
                with self.subTest(label=label, invalid=invalid), self.assertRaises(ValueError):
                    validate_windows_check_record(changed, self.build)

    def test_headless_synthetic_execution_cannot_be_omitted_or_replaced_by_native_calls(self):
        for label in ('headless-native', 'headless-setup', 'headless-status'):
            for key, value in (('status', 'failed'), ('freshSyntheticOnly', False), ('nativeApisInvoked', True), ('checks', True)):
                changed = copy.deepcopy(self.checks)
                changed['headless'][label][key] = value
                with self.subTest(label=label, key=key), self.assertRaises(ValueError):
                    validate_windows_check_record(changed, self.build)
            changed = copy.deepcopy(self.checks)
            del changed['headless'][label]
            with self.subTest(label=label, missing=True), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)
        changed = copy.deepcopy(self.checks)
        del changed['headless']
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_headless_source_and_runner_digests_are_required(self):
        for path in HEADLESS_SOURCE_PATHS:
            for mode in ('missing', 'changed'):
                changed = copy.deepcopy(self.checks)
                if mode == 'missing': del changed['headless']['sourceSha256'][path]
                else: changed['headless']['sourceSha256'][path] = '9' * 64
                with self.subTest(path=path, mode=mode), self.assertRaises(ValueError):
                    validate_windows_check_record(changed, self.build)

    def test_headless_success_requires_one_successful_invocation_per_suite(self):
        for label in ('headless-native', 'headless-setup', 'headless-status'):
            for mode in ('missing', 'failed', 'duplicate'):
                changed = copy.deepcopy(self.checks)
                selected = next(item for item in changed['invocations'] if item['label'] == label + '-synthetic-checks')
                if mode == 'missing': changed['invocations'].remove(selected)
                elif mode == 'failed': selected['exitCode'] = 1
                else: changed['invocations'].append(dict(selected))
                with self.subTest(label=label, mode=mode), self.assertRaises(ValueError):
                    validate_windows_check_record(changed, self.build)

    def test_headless_compiler_path_must_be_explicit(self):
        for value in (None, 'true', 1):
            changed = copy.deepcopy(self.checks)
            changed['headless']['headless-native']['frameworkCompiler'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)

    def test_source_changed_after_reverse_checks_is_rejected(self):
        changed = copy.deepcopy(self.checks)
        changed['reverseClient']['sourceManifest']['client/windows/EngineStore.cs'] = 'd' * 64
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_omitted_production_client_source_is_rejected(self):
        changed = copy.deepcopy(self.checks)
        del changed['reverseClient']['sourceSha256']['client/windows/EngineStore.cs']
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_shared_update_form_must_be_bound_to_reverse_checks(self):
        for value in (None, 'd' * 64):
            changed = copy.deepcopy(self.checks)
            if value is None: del changed['reverseClient']['sourceSha256']['host/windows/KnotUpdateForm.cs']
            else: changed['reverseClient']['sourceSha256']['host/windows/KnotUpdateForm.cs'] = value
            with self.subTest(value=value), self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_replaced_decoder_or_qr_fixture_is_rejected(self):
        for section, key in (('reverseClient', 'qrDecoder'), ('reverseQR', 'fixtureSha256'), ('reverseQRWindows', 'fixtureSha256')):
            changed = copy.deepcopy(self.checks)
            if key == 'qrDecoder': changed[section][key]['sha256'] = '9' * 64
            else: changed[section][key] = '9' * 64
            with self.subTest(section=section), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)

    def test_failed_or_missing_reverse_invocation_is_rejected(self):
        for mode in ('missing', 'failed'):
            changed = copy.deepcopy(self.checks)
            if mode == 'missing': changed['reverseClient']['invocations'].pop()
            else: changed['reverseClient']['invocations'][-1]['exitCode'] = 1
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)

    def test_compile_only_cannot_claim_windows_image_codec_execution(self):
        changed = copy.deepcopy(self.checks)
        changed['windowsImageCodecRuntimeTested'] = True
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_actual_windows_qr_fixture_result_is_accepted_without_claiming_full_app_test(self):
        changed = copy.deepcopy(self.checks)
        changed['windowsImageCodecRuntimeTested'] = True
        changed['reverseQRWindows'].update(status='PASS', windowsImageCodecTested=True, freshSyntheticOnly=True,
                                           embeddedDecoderBindingTested=True, checks=23)
        changed['headless']['headless-native']['frameworkCompiler'] = True
        validate_windows_check_record(changed, self.build)

    def test_windows_record_cannot_replace_framework_proof_with_portable_check(self):
        changed = copy.deepcopy(self.checks)
        changed['windowsImageCodecRuntimeTested'] = True
        changed['reverseQRWindows'].update(status='PASS', windowsImageCodecTested=True, freshSyntheticOnly=True,
                                           embeddedDecoderBindingTested=True, checks=23)
        with self.assertRaises(ValueError):
            validate_windows_check_record(changed, self.build)

    def test_runner_requires_framework_only_on_windows(self):
        fixtures = copy.deepcopy(self.checks['headless'])
        def invoke(label, argv):
            return {'stdout': json.dumps(fixtures[label.removesuffix('-synthetic-checks')])}
        for host, framework, accepted in (('posix', False, True), ('nt', False, False), ('nt', True, True)):
            fixtures['headless-native']['frameworkCompiler'] = framework
            with self.subTest(host=host, framework=framework), patch('test_windows_launcher.os') as platform:
                platform.name = host
                if accepted:
                    result = run_headless_checks('synthetic-powershell', invoke, self.build['sourceManifest'], 'synthetic-native-policy')
                    self.assertIs(result['headless-native']['frameworkCompiler'], framework)
                else:
                    with self.assertRaisesRegex(ValueError, 'Framework compiler boundary'):
                        run_headless_checks('synthetic-powershell', invoke, self.build['sourceManifest'], 'synthetic-native-policy')

    def test_native_bootstrap_composition_proof_is_required(self):
        for value in (False, None, 'true', 1):
            changed = copy.deepcopy(self.checks)
            changed['headless']['headless-status']['bootstrapPolicyComposed'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)
        def invoke(label, argv):
            return {'stdout': json.dumps(self.checks['headless'][label.removesuffix('-synthetic-checks')])}
        with self.assertRaisesRegex(ValueError, 'compiled native bootstrap policy'):
            run_headless_checks('synthetic-powershell', invoke, self.build['sourceManifest'])

    def test_embedded_binding_and_identity_proofs_are_required(self):
        for key in ('embeddedDecoderBindingTested', 'decoderResolverIdentityTested', 'decoderInitializationIdempotent'):
            for mode in ('missing', 'false'):
                changed = copy.deepcopy(self.checks)
                if mode == 'missing': del changed[key]
                else: changed[key] = False
                with self.subTest(key=key, mode=mode), self.assertRaises(ValueError):
                    validate_windows_check_record(changed, self.build)

    def test_binding_proof_for_another_decoder_is_rejected(self):
        for section in ('packaged', 'native-fixture'):
            changed = copy.deepcopy(self.checks)
            target = changed if section == 'packaged' else changed['reverseQRWindows']
            target['embeddedDecoderSha256'] = '9' * 64
            with self.subTest(section=section), self.assertRaises(ValueError):
                validate_windows_check_record(changed, self.build)

    def test_compiled_decoder_sources_cannot_substitute_for_embedded_reference_fixture(self):
        changed = copy.deepcopy(self.checks)
        changed['reverseQRWindows']['separatelyCompiledEmbeddedDecoder'] = False
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_mac_to_windows_interop_cannot_be_claimed_without_fixture_and_source_proof(self):
        changed = copy.deepcopy(self.checks)
        changed['macToWindowsQRInterop'] = True
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)
        del changed['macToWindowsQRInterop']
        with self.assertRaises(ValueError): validate_windows_check_record(changed, self.build)

    def test_source_bound_mac_to_windows_fixture_result_is_accepted(self):
        build = copy.deepcopy(self.build)
        build['sourceManifest'].update({path: '4' * 64 for path in MAC_INTEROP_SOURCE_PATHS})
        changed = copy.deepcopy(self.checks)
        changed['sourceManifest'] = build['sourceManifest']
        changed['reverseClient']['sourceManifest'] = build['sourceManifest']
        changed.update(macToWindowsQRInterop=True, macToWindowsQRFixtureSha256='5' * 64,
                       macCheckerSha256='6' * 64, macInteropSourceSha256={path: '4' * 64 for path in MAC_INTEROP_SOURCE_PATHS},
                       invocations=changed['invocations'] + [{'label': 'export-actual-mac-qr-fixture', 'exitCode': 0}])
        validate_windows_check_record(changed, build)
        changed['macInteropSourceSha256'][MAC_INTEROP_SOURCE_PATHS[0]] = '7' * 64
        with self.assertRaises(ValueError): validate_windows_check_record(changed, build)


class BuildSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="deskbridge-build-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Fixture-only isolation: never redirect git to a developer checkout or load
        # their global Git configuration. Project/tool privacy hooks are unchanged.
        self.git_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.git_env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_ATTR_NOSYSTEM="1",
                            GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="core.excludesFile", GIT_CONFIG_VALUE_0=os.devnull,
                            GIT_CONFIG_KEY_1="core.attributesFile", GIT_CONFIG_VALUE_1=os.devnull)
        self.git("init", "-q")
        self.source = self.root / "Sources/Example.swift"
        self.source.parent.mkdir(); self.source.write_text("struct Example {}\n")
        (self.root / ".gitignore").write_text("build/\ndist/\nevidence/\n__pycache__/\n")
        for name in ["LICENSE", "INSTALLATION.md", "VERSION"]:
            (self.root / name).write_text("Synthetic fixture " + name + "\n")
        self.commit()
        self.app = self.root / "dist/Knot.app/Contents/MacOS/DeskBridge"
        self.app.parent.mkdir(parents=True); self.app.write_bytes(b"synthetic executable")
        self.app.chmod(0o755)
        self.supervisor = self.app.parent.parent / "Helpers/KnotHostSupervisor"
        self.supervisor.parent.mkdir()
        self.supervisor.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0) + b"SYNTHETIC ONLY")
        self.supervisor.chmod(0o755)
        installer = self.root / "dist/Install Knot.app/Contents/MacOS/KnotInstaller"
        installer.parent.mkdir(parents=True); installer.write_bytes(b"SYNTHETIC LOCAL INSTALLER")
        installer.chmod(0o755)
        shutil.copytree(self.root / "dist/Knot.app", self.root / "dist/Install Knot.app/Contents/Helpers/Knot.app")
        self.build = self.root / "evidence/synthetic-build"
        self.build.mkdir(parents=True)
        self.snapshot_now()
        (self.build / "build-invocations.json").write_text(json.dumps([
            {"label": label, "exitCode": 0}
            for label in sorted(REQUIRED_CHECK_STAGES)
        ]))
        (self.build / "synthetic-checks.stdout").write_text('{"status":"passed"}')
        (self.build / "synthetic-model-checks.stdout").write_text('{"status":"passed"}')
        (self.build / "mac-host-lifetime-checks.stdout").write_text(json.dumps({
            "status": "passed", "checks": 41, "productionHostLaunched": False,
            "testedSupervisorSHA256": host_supervisor_snapshot(self.root / "dist/Knot.app")["sha256"],
            **{key: True for key in ("actualMacHostChild", "nativeSupervisor", "freshSyntheticOnly", "appAbruptDeath",
                "gracefulStop", "boundedStop", "restartDescendantCleanup", "writerNotInherited", "supervisorCrashCleanup",
                "pinnedRestartForkDenied", "forkVforkSpawnDenied", "normalThreadsAndFiles",
                "unrestrictedChildModeRefused", "wrapperAndProfileUnavailableRefused")}}))
        self.record = {"schema": 1, "configuration": "release", "checksPassed": True,
                       "appManifest": tree_snapshot(self.root / "dist/Knot.app"),
                       "hostSupervisor": host_supervisor_snapshot(self.root / "dist/Knot.app"),
                       "installerManifest": tree_snapshot(self.root / "dist/Install Knot.app")}
        self.write_record()

    def write_record(self):
        (self.build / "completed-build.json").write_text(json.dumps(self.record))

    def commit(self):
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        # Plumbing creates synthetic snapshots without a porcelain commit lifecycle.
        commit = self.git("-c", "user.name=Synthetic Check", "-c", "user.email=check@example.invalid",
                          "-c", "commit.gpgsign=false", "commit-tree", tree, "-m", "Synthetic fixture").decode().strip()
        self.git("update-ref", "HEAD", commit)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.git_env)

    def isolated(self):
        return patch.dict(os.environ, self.git_env, clear=True)

    def snapshot_now(self):
        with self.isolated():
            (self.build / "source-manifest.json").write_text(json.dumps(source_snapshot(self.root)))

    def validate(self, release=False):
        with self.isolated():
            return validate_completed_build(self.root, self.build, require_release=release)

    def test_unchanged_build_is_accepted(self):
        self.assertEqual(self.validate(True)[0]["configuration"], "release")

    def test_each_required_suite_cannot_be_omitted(self):
        path = self.build / "build-invocations.json"
        records = json.loads(path.read_text())
        for label in REQUIRED_CHECK_STAGES:
            with self.subTest(stage=label):
                path.write_text(json.dumps([r for r in records if r["label"] != label]))
                with self.assertRaises(BuildSnapshotError): self.validate()

    def test_failed_model_result_cannot_be_labeled_successful(self):
        (self.build / "synthetic-model-checks.stdout").write_text('{"status":"failed"}')
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_missing_model_result_cannot_be_labeled_successful(self):
        (self.build / "synthetic-model-checks.stdout").unlink()
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_new_source_without_index_is_rejected(self):
        (self.source.parent / "New.swift").write_text("struct New {}\n")
        with self.assertRaisesRegex(BuildSnapshotError, "Added"): self.validate()

    def test_new_brand_asset_without_index_is_rejected(self):
        asset = self.root / "Assets/Brand/new.png"
        asset.parent.mkdir(parents=True)
        asset.write_bytes(b"synthetic asset")
        with self.assertRaisesRegex(BuildSnapshotError, "Added"): self.validate()

    def test_new_indexed_source_is_rejected(self):
        (self.source.parent / "New.swift").write_text("struct New {}\n")
        self.git("add", "Sources")
        with self.assertRaisesRegex(BuildSnapshotError, "New.swift"): self.validate()

    def test_deleted_source_is_rejected(self):
        self.source.unlink()
        self.git("add", "-u")
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_changed_source_is_rejected(self):
        self.source.write_text("struct Changed {}\n")
        with self.assertRaisesRegex(BuildSnapshotError, "changed"): self.validate()

    def test_replaced_binary_is_rejected(self):
        self.app.write_bytes(b"another executable")
        with self.assertRaisesRegex(BuildSnapshotError, "App bundle changed"): self.validate()

    def test_local_installer_is_required_and_immutable(self):
        installer = self.root / "dist/Install Knot.app/Contents/MacOS/KnotInstaller"
        installer.write_bytes(b"REPLACED SYNTHETIC INSTALLER")
        with self.assertRaisesRegex(BuildSnapshotError, "Local installer changed"): self.validate()
        installer.unlink()
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_local_installer_proof_cannot_be_omitted(self):
        del self.record["installerManifest"]; self.write_record()
        with self.assertRaisesRegex(BuildSnapshotError, "Local installer changed"): self.validate()

    def test_embedded_payload_cannot_reuse_updated_outer_inventory(self):
        payload = self.root / "dist/Install Knot.app/Contents/Helpers/Knot.app/Contents/MacOS/DeskBridge"
        payload.write_bytes(b"UNTESTED SYNTHETIC PAYLOAD")
        self.record["installerManifest"] = tree_snapshot(self.root / "dist/Install Knot.app"); self.write_record()
        with self.assertRaisesRegex(BuildSnapshotError, "payload differs"): self.validate()

    def test_extra_bundle_file_is_rejected(self):
        (self.app.parent / "Unexpected").write_bytes(b"extra payload")
        with self.assertRaisesRegex(BuildSnapshotError, "App bundle changed"): self.validate()

    def test_changed_executable_mode_is_rejected(self):
        self.app.chmod(0o644)
        with self.assertRaisesRegex(BuildSnapshotError, "App bundle changed"): self.validate()

    def test_missing_completion_record_is_rejected(self):
        (self.build / "completed-build.json").unlink()
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_helper_record_is_required(self):
        del self.record["hostSupervisor"]; self.write_record()
        with self.assertRaisesRegex(BuildSnapshotError, "Host supervisor"): self.validate()

    def test_lifetime_proof_is_required(self):
        path = self.build / "mac-host-lifetime-checks.stdout"
        valid = json.loads(path.read_text())
        for key, value in (("checks", 40), ("checks", True), ("status", "failed"), ("appAbruptDeath", False),
                           ("writerNotInherited", False), ("supervisorCrashCleanup", False), ("productionHostLaunched", True),
                           ("pinnedRestartForkDenied", False), ("forkVforkSpawnDenied", False), ("normalThreadsAndFiles", False),
                           ("unrestrictedChildModeRefused", False), ("wrapperAndProfileUnavailableRefused", False)):
            path.write_text(json.dumps({**valid, key: value}))
            with self.subTest(key=key, value=value), self.assertRaisesRegex(BuildSnapshotError, "lifetime proof"):
                self.validate()

    def test_lifetime_proof_digest_must_match_completed_helper(self):
        path = self.build / "mac-host-lifetime-checks.stdout"
        valid = json.loads(path.read_text())
        for value in (None, "0" * 64, "not-a-digest"):
            path.write_text(json.dumps({**valid, "testedSupervisorSHA256": value}))
            with self.subTest(digest=value), self.assertRaisesRegex(BuildSnapshotError, "proof belongs to a different helper"):
                self.validate()

    def test_new_bundle_inventory_and_helper_digest_do_not_reuse_old_lifetime_proof(self):
        self.supervisor.write_bytes(self.supervisor.read_bytes() + b"CHANGED SYNTHETIC")
        self.record["appManifest"] = tree_snapshot(self.root / "dist/Knot.app")
        self.record["hostSupervisor"] = host_supervisor_snapshot(self.root / "dist/Knot.app")
        self.write_record()
        with self.assertRaisesRegex(BuildSnapshotError, "proof belongs to a different helper"):
            self.validate()

    def test_replaced_helper_with_updated_bundle_inventory_is_rejected(self):
        self.supervisor.write_bytes(self.supervisor.read_bytes() + b"CHANGED SYNTHETIC")
        self.record["appManifest"] = tree_snapshot(self.root / "dist/Knot.app"); self.write_record()
        with self.assertRaisesRegex(BuildSnapshotError, "Host supervisor"): self.validate()

    def test_non_native_or_wrong_architecture_helper_is_rejected(self):
        for data in (b"#!/bin/sh\nexit 0\n", struct.pack("<8I", 0xFEEDFACF, 0x01000007, 3, 2, 0, 0, 0, 0)):
            self.supervisor.write_bytes(data)
            self.record["appManifest"] = tree_snapshot(self.root / "dist/Knot.app"); self.write_record()
            with self.assertRaisesRegex(BuildSnapshotError, "native arm64"): self.validate()

    def test_failed_checks_are_rejected(self):
        (self.build / "synthetic-checks.stdout").write_text('{"status":"failed"}')
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_skipped_checks_are_rejected(self):
        self.record["checksPassed"] = False; self.write_record()
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_debug_build_cannot_be_signed_release(self):
        self.record["configuration"] = "debug"; self.write_record()
        self.assertEqual(self.validate()[0]["configuration"], "debug")
        with self.assertRaisesRegex(BuildSnapshotError, "optimized release"): self.validate(True)

    def test_source_symlink_cannot_escape_snapshot(self):
        other = self.root / "synthetic-outside-input"; other.write_text("fixture")
        self.source.unlink(); self.source.symlink_to(other)
        with self.assertRaisesRegex(BuildSnapshotError, "Symlink"): self.validate()

    def test_bundle_symlink_is_rejected(self):
        self.app.unlink(); self.app.symlink_to("nowhere")
        with self.assertRaises(BuildSnapshotError): self.validate()

    def test_outside_build_evidence_is_rejected(self):
        with self.assertRaises(ValueError):
            validate_completed_build(self.root, self.root / "../unrelated", require_release=True)

    def test_ignored_source_present_before_build_is_rejected(self):
        hidden = self.source.parent / "build/Hidden.swift"
        hidden.parent.mkdir(); hidden.write_text("struct Hidden {}\n")
        self.snapshot_now()
        self.assertEqual(self.git("status", "--porcelain"), b"")
        self.assertIn(hidden, sorted(self.source.parent.rglob("*.swift")))
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*Hidden.swift"): self.validate()

    def test_untracked_input_present_before_build_is_rejected(self):
        (self.source.parent / "Untracked.swift").write_text("struct Untracked {}\n")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*Untracked.swift"): self.validate()

    def test_untracked_windows_runtime_notice_is_rejected(self):
        notice = self.root / "Vendor/WindowsRuntime/NOTICE"
        notice.parent.mkdir(parents=True); notice.write_text("Synthetic native runtime notice\n")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*WindowsRuntime/NOTICE"): self.validate()

    def test_ignored_windows_runtime_notice_is_rejected(self):
        notice = self.root / "Vendor/WindowsRuntime/NOTICE"
        notice.parent.mkdir(parents=True); notice.write_text("Synthetic native runtime notice\n")
        self.commit()
        with (self.root / ".gitignore").open("a") as handle: handle.write("\nVendor/WindowsRuntime/NOTICE\n")
        self.git("rm", "--cached", "Vendor/WindowsRuntime/NOTICE")
        self.commit(); self.snapshot_now()
        self.assertEqual(self.git("status", "--porcelain"), b"")
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*WindowsRuntime/NOTICE"): self.validate()

    def test_ignored_sourceless_tooling_file_is_rejected(self):
        folder = self.root / "scripts"; folder.mkdir()
        (folder / ".gitignore").write_text("*.pyc\n")
        self.commit()
        (folder / "unexpected.pyc").write_bytes(b"synthetic bytecode input")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*unexpected.pyc"): self.validate()

    def test_only_direct_tooling_cache_is_exempt(self):
        cache = self.root / "scripts/__pycache__"; cache.mkdir(parents=True)
        (cache / "build_snapshot.cpython-314.pyc").write_bytes(b"synthetic generated cache")
        self.snapshot_now()
        self.assertEqual(self.validate(True)[0]["configuration"], "release")
        nested = cache / "nested"; nested.mkdir()
        (nested / "unexpected.pyc").write_bytes(b"synthetic nested input")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*unexpected.pyc"): self.validate()

    def test_checkout_cache_named_ancestor_does_not_exempt_inputs(self):
        container = tempfile.TemporaryDirectory(prefix="deskbridge-cache-ancestor-fixture-")
        self.addCleanup(container.cleanup)
        original = self.root
        target = Path(container.name) / "__pycache__/checkout"
        target.parent.mkdir()
        original.rename(target)
        self.root = target
        self.source = target / self.source.relative_to(original)
        self.build = target / self.build.relative_to(original)
        self.app = target / self.app.relative_to(original)
        folder = target / "scripts"; folder.mkdir()
        (folder / ".gitignore").write_text("*.pyc\n")
        self.commit()
        (folder / "unexpected.pyc").write_bytes(b"synthetic sourceless input")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*unexpected.pyc"): self.validate()

    def test_ignored_swift_inside_cache_named_folder_is_rejected(self):
        hidden = self.source.parent / "__pycache__/Hidden.swift"
        hidden.parent.mkdir(); hidden.write_text("struct Hidden {}\n")
        self.snapshot_now()
        self.assertEqual(self.git("status", "--porcelain"), b"")
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*Hidden.swift"): self.validate()

    def test_index_only_input_present_before_build_is_rejected(self):
        (self.source.parent / "Staged.swift").write_text("struct Staged {}\n")
        self.git("add", "Sources")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*Staged.swift"): self.validate()

    def test_modified_input_present_before_build_is_rejected(self):
        self.source.write_text("struct ChangedBeforeBuild {}\n")
        self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "changed.*Example.swift"): self.validate()

    def test_export_ignored_source_is_rejected(self):
        (self.root / ".gitattributes").write_text("Sources/Example.swift export-ignore\n")
        self.commit(); self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive.*Example.swift"): self.validate()

    def test_export_substituted_source_is_rejected(self):
        self.source.write_text('// $Format:%H$\nstruct Example {}\n')
        (self.root / ".gitattributes").write_text("Sources/Example.swift export-subst\n")
        self.commit(); self.snapshot_now()
        with self.assertRaisesRegex(BuildSnapshotError, "changed.*Example.swift"): self.validate()

    def test_new_committed_input_is_accepted(self):
        (self.source.parent / "Committed.swift").write_text("struct Committed {}\n")
        self.commit(); self.snapshot_now()
        self.assertEqual(self.validate(True)[0]["configuration"], "release")

    def test_ignored_root_copied_inputs_are_rejected(self):
        names = ["LICENSE", "INSTALLATION.md", "VERSION"]
        with (self.root / ".gitignore").open("a") as handle:
            handle.write("\n" + "\n".join(names) + "\n")
        self.git("rm", "--cached", *names)
        self.commit(); self.snapshot_now()
        self.assertEqual(self.git("status", "--porcelain"), b"")
        with self.assertRaisesRegex(BuildSnapshotError, "Missing from archive") as rejected:
            self.validate()
        for name in names:
            self.assertIn(name, str(rejected.exception))

    def test_fixture_git_ignores_parent_routing_and_configuration(self):
        with tempfile.TemporaryDirectory(prefix="deskbridge-foreign-git-fixture-") as directory:
            foreign = Path(directory)
            subprocess.run(["git", "init", "-q", str(foreign)], env=self.git_env, check=True)
            hooks = foreign / "hooks"; hooks.mkdir()
            sentinel = foreign / "hook-ran"
            hook = hooks / "reference-transaction"
            hook.write_text("#!/bin/sh\nprintf called >> " + shlex.quote(str(sentinel)) + "\nexit 99\n")
            hook.chmod(0o755)
            config = foreign / "global-config"
            subprocess.run(["git", "config", "--file", str(config), "core.hooksPath", str(hooks)], env=self.git_env, check=True)
            xdg_git = foreign / "git"; xdg_git.mkdir()
            (xdg_git / "ignore").write_text("Sources/\n")
            (xdg_git / "attributes").write_text("*.swift export-ignore\n")
            poisoned = {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                        "GIT_INDEX_FILE": str(foreign / "foreign-index"), "GIT_CONFIG_GLOBAL": str(config),
                        "XDG_CONFIG_HOME": str(foreign)}
            nested = BuildSnapshotTests("test_unchanged_build_is_accepted")
            try:
                with patch.dict(os.environ, poisoned):
                    nested.setUp()
                    self.assertEqual(nested.validate(True)[0]["configuration"], "release")
                self.assertFalse((foreign / "foreign-index").exists())
                self.assertFalse((foreign / ".git/index").exists())
                self.assertFalse(sentinel.exists())
                # Positive control: this reachable hook fires when deliberately enabled,
                # only in the newly created foreign fixture, without changing config files.
                tree = subprocess.check_output(["git", "-C", str(foreign), "mktree"], input=b"", env=self.git_env).decode().strip()
                commit = subprocess.check_output(["git", "-C", str(foreign), "-c", "user.name=Synthetic Check",
                    "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false",
                    "commit-tree", tree, "-m", "Synthetic hook control"], env=self.git_env).decode().strip()
                control = subprocess.run(["git", "-C", str(foreign), "-c", "core.hooksPath=" + str(hooks),
                    "update-ref", "refs/heads/synthetic-probe", commit], env=self.git_env, capture_output=True)
                self.assertNotEqual(control.returncode, 0)
                self.assertIn("called", sentinel.read_text())
            finally:
                nested.doCleanups()

    def test_archive_failure_retains_git_diagnostic(self):
        with self.isolated():
            with self.assertRaises(BuildSnapshotError) as rejected:
                validate_corresponding_source(self.root, source_snapshot(self.root), "nonexistent-synthetic-revision")
        self.assertIn("nonexistent-synthetic-revision", str(rejected.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)

# SPDX-License-Identifier: GPL-3.0-only
"""Fresh fixtures exercise real update policy and Ed25519 verification, never install."""
from pathlib import Path
import base64, hashlib, json, os, plistlib, subprocess, sys, tempfile, unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from update_runtime import publisher_config, sparkle_info, stage_sparkle, verify_runtime
from update_version import build_number
ROOT = Path(__file__).resolve().parents[2]

class UpdateVersionChecks(unittest.TestCase):
    def test_order(self):
        versions = ['0.2.0-preview.16','0.2.0-preview.17','0.2.0-beta.0','0.2.0-rc.0','0.2.0','0.2.1-preview.0','0.3.0-preview.0','1.0.0-preview.0']
        actual = [int(build_number(v)) for v in versions]
        self.assertEqual(sorted(set(actual)), actual)
    def test_malformed_version(self):
        for value in ['0.2.0-preview.01','0.2.0-nightly.2','01.2.0','0.2.0-preview.100000','1000.0.0','0.2.0;open']:
            with self.subTest(value=value), self.assertRaises(ValueError): build_number(value)

class PublisherChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='knot-update-policy-')
        self.root = Path(self.temp.name); (self.root/'packaging/updates').mkdir(parents=True)
        self.config = {'schema':1, 'macFeedURL':'https://updates.example.org/mac.xml', 'windowsFeedURL':'https://updates.example.org/windows.xml',
                       'publicEDKey':base64.b64encode(bytes(range(32))).decode(), 'windowsPublisherCertificateSHA256':'a'*64}
    def tearDown(self): self.temp.cleanup()
    def check(self, config):
        (self.root/'packaging/updates/publisher.json').write_text(json.dumps(config)); return publisher_config(self.root)
    def test_missing_key_fails_closed(self):
        self.assertIsNone(self.check({name:None if name!='schema' else 1 for name in self.config}))
        for name in self.config:
            if name=='schema': continue
            config=dict(self.config); config[name]=None
            with self.subTest(name=name), self.assertRaises(ValueError): self.check(config)
    def test_https_public_and_key(self):
        self.assertEqual(self.check(self.config), self.config)
        for bad in ['http://updates.example.org/a','https://user:pw@updates.example.org/a','https://localhost/a','https://updates.example.org:42/a','https://updates.example.org/a#b','https://updates.example.org/a\n']:
            config=dict(self.config); config['macFeedURL']=bad
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.check(config)
        for bad in ['not base64',base64.b64encode(bytes(32)).decode(),base64.b64encode(bytes(31)).decode()]:
            config=dict(self.config); config['publicEDKey']=bad
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.check(config)
    def test_preview_has_no_network_configuration(self):
        (self.root/'VERSION').write_text('0.2.0-preview.16')
        self.check({name:None if name!='schema' else 1 for name in self.config})
        result=sparkle_info(self.root)
        self.assertFalse(result['KnotUpdatesConfigured']); self.assertNotIn('SUFeedURL',result); self.assertNotEqual(result['CFBundleVersion'],'17')
    def test_configured_requires_signed_feed_and_archive(self):
        (self.root/'VERSION').write_text('0.2.0-preview.17'); self.check(self.config)
        result=sparkle_info(self.root)
        self.assertTrue(result['SURequireSignedFeed']); self.assertTrue(result['SUVerifyUpdateBeforeExtraction']); self.assertFalse(result['SUAutomaticallyUpdate']); self.assertFalse(result['SUAllowsAutomaticUpdates'])

class OfficialRuntimeChecks(unittest.TestCase):
    def test_only_pinned_in_bundle_links_and_linkage_are_admitted(self):
        from build_snapshot import tree_snapshot, BuildSnapshotError
        from system_dependencies import parse_system_dependencies, SystemDependencyError
        with tempfile.TemporaryDirectory(prefix='knot-update-links-') as temporary:
            root=Path(temporary); framework=root/'Contents/Frameworks/Sparkle.framework'
            (framework/'Versions/B').mkdir(parents=True)
            (framework/'Versions/B/Sparkle').write_bytes(b'FRESH SYNTHETIC DYLIB')
            (framework/'Versions/Current').symlink_to('B')
            (framework/'Sparkle').symlink_to('Versions/Current/Sparkle')
            manifest=tree_snapshot(root)
            self.assertEqual(manifest['Contents/Frameworks/Sparkle.framework/Sparkle']['symlink'],'Versions/Current/Sparkle')
            (framework/'Sparkle').unlink(); (framework/'Sparkle').symlink_to('/tmp/untrusted')
            with self.assertRaises(BuildSnapshotError): tree_snapshot(root)
        image='/synthetic/Contents/MacOS/DeskBridge'
        metadata=' (compatibility version 1.0.0, current version 1.0.0)'
        for install_name, permitted in [('@rpath/Sparkle.framework/Versions/B/Sparkle',True),('@rpath/Evil.framework/Evil',False),('@rpath/Sparkle.framework/Versions/B/../../Evil',False)]:
            data=(image+':\n\t'+install_name+metadata+'\n').encode()
            if permitted:
                self.assertEqual(parse_system_dependencies(data,image,allowed_frameworks=('@rpath/Sparkle.framework/Versions/B/Sparkle',)),(install_name,))
                with self.assertRaises(SystemDependencyError): parse_system_dependencies(data,image)
            else:
                with self.assertRaises(SystemDependencyError): parse_system_dependencies(data,image,allowed_frameworks=('@rpath/Sparkle.framework/Versions/B/Sparkle',))
    def test_full_release_inventories(self):
        self.assertEqual(len(verify_runtime(ROOT,'Sparkle')[1]['inventory']),253)
        self.assertEqual(len(verify_runtime(ROOT,'WinSparkle')[1]['inventory']),47)

class SignedFixtureChecks(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin','Upstream macOS signer required')
    def test_real_upstream_signature_and_tamper_rejection(self):
        import tarfile
        from sign_update_feed import make_feed
        with tempfile.TemporaryDirectory(prefix='knot-update-signed-fixture-') as temporary:
            p=Path(temporary)
            (p/'gen.swift').write_text('import Foundation\nimport CryptoKit\nlet k=Curve25519.Signing.PrivateKey()\ntry Data(k.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath:CommandLine.arguments[1]))\n')
            subprocess.run(['/usr/bin/swiftc',str(p/'gen.swift'),'-o',str(p/'gen')],check=True,capture_output=True)
            subprocess.run([str(p/'gen'),str(p/'synthetic-key')],check=True,capture_output=True)
            (p/'synthetic-key').chmod(0o600)
            with tarfile.open(verify_runtime(ROOT,'Sparkle')[0]) as archive:
                (p/'sign_update').write_bytes(archive.extractfile('./bin/sign_update').read())
            (p/'sign_update').chmod(0o700)
            def invoke(*arguments):
                return subprocess.run([str(p/'sign_update'),'--ed-key-file',str(p/'synthetic-key'),*arguments],capture_output=True,timeout=20)
            artifact=p/'fixture.bin'; artifact.write_bytes(b'NEW SYNTHETIC NONEXECUTABLE UPDATE')
            signed=invoke('-p',str(artifact)); self.assertEqual(signed.returncode,0)
            signature=signed.stdout.decode().strip()
            self.assertEqual(invoke('--verify',str(artifact),signature).returncode,0)
            artifact.write_bytes(b'TAMPERED NONEXECUTABLE UPDATE')
            self.assertNotEqual(invoke('--verify',str(artifact),signature).returncode,0)
            feed=p/'appcast.xml'; feed.write_bytes(make_feed('0.2.0-preview.17','macos-arm64','https://updates.example.org/Knot-0.2.0-preview.17-macos-arm64.dmg',32,signature))
            self.assertEqual(invoke('-p',str(feed)).returncode,0)
            self.assertEqual(invoke('--verify',str(feed)).returncode,0)
            feed.write_bytes(feed.read_bytes().replace(b'preview.17',b'preview.99'))
            self.assertNotEqual(invoke('--verify',str(feed)).returncode,0)
            for platform,url in [('macos-arm64','https://updates.example.org/x.exe'),('windows-x64','https://updates.example.org/x.dmg')]:
                with self.subTest(platform=platform), self.assertRaises(ValueError): make_feed('0.2.0-preview.17',platform,url,32,signature)


class SwiftPolicyChecks(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin','Swift/AppKit and pinned Sparkle SDK required')
    def test_actual_signed_adapter_implements_pinned_delegate_selectors(self):
        # Optional Objective-C delegate methods can compile under the wrong
        # Swift spelling without implementing Sparkle's selector. Check both
        # the configured build branch and its actual runtime protocol surface.
        with tempfile.TemporaryDirectory(prefix='knot-update-signed-adapter-') as temporary:
            p=Path(temporary); frameworks=p/'Frameworks'
            stage_sparkle(ROOT,frameworks)
            def run(argv, timeout=30):
                result=subprocess.run(list(map(str,argv)),capture_output=True,text=True,timeout=timeout)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                return result.stdout
            core=sorted((ROOT/'Sources/DeskBridgeCore/Updates').glob('*.swift'))
            common=['/usr/bin/swiftc','-swift-version','6','-module-cache-path',p/'ModuleCache','-parse-as-library']
            run([*common,'-emit-library','-static','-emit-module','-module-name','DeskBridgeCore',*core,
                 '-emit-module-path',p/'DeskBridgeCore.swiftmodule','-o',p/'libDeskBridgeCore.a'])
            (p/'main.swift').write_text('''import Foundation
import ObjectiveC
import Sparkle
@main struct Check {
 @MainActor static func main() {
  let updater = KnotUpdates()
  let selectors: [(Selector, String)] = [
   (#selector(SPUUpdaterDelegate.updater(_:mayPerform:)), "updater:mayPerformUpdateCheck:error:"),
   (#selector(SPUUpdaterDelegate.updater(_:shouldProceedWithUpdate:updateCheck:)), "updater:shouldProceedWithUpdate:updateCheck:error:"),
   (#selector(SPUUpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)), "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:"),
   (#selector(SPUUpdaterDelegate.updater(_:didAbortWithError:)), "updater:didAbortWithError:"),
   (#selector(SPUUpdaterDelegate.updater(_:shouldDownloadReleaseNotesForUpdate:)), "updater:shouldDownloadReleaseNotesForUpdate:")
  ]
  for (selector, expected) in selectors {
   precondition(NSStringFromSelector(selector) == expected)
   precondition(protocol_getMethodDescription(SPUUpdaterDelegate.self, selector, false, true).name == selector)
   precondition(updater.responds(to: selector))
  }
  precondition(!updater.isConfigured && !updater.installationPending)
  // No start/check call: loading the pinned framework and an NSObject adapter
  // must not construct a controller, open UI, contact a feed, or install.
  print("{\\"status\\":\\"passed\\",\\"delegateSelectors\\":\\(selectors.count),\\"updaterStarted\\":false}")
 }
}
''')
            run([*common,'-D','KNOT_SIGNED_UPDATES','-F',frameworks,'-framework','Sparkle',
                 '-Xlinker','-rpath','-Xlinker',frameworks,'-I',p,p/'libDeskBridgeCore.a',
                 ROOT/'Sources/DeskBridgeApp/KnotUpdates.swift',p/'main.swift','-o',p/'check'])
            self.assertEqual(json.loads(run([p/'check'],timeout=10)),
                             {'status':'passed','delegateSelectors':5,'updaterStarted':False})

    @unittest.skipUnless(sys.platform=='darwin','Swift/AppKit SDK required')
    def test_actual_adapter_defers_once_until_idle(self):
        with tempfile.TemporaryDirectory(prefix='knot-update-adapter-') as temporary:
            p=Path(temporary)
            core=list(map(str,sorted((ROOT/'Sources/DeskBridgeCore/Updates').glob('*.swift'))))
            subprocess.run(['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-emit-library','-static','-emit-module','-module-name','DeskBridgeCore',*core,'-emit-module-path',str(p/'DeskBridgeCore.swiftmodule'),'-o',str(p/'libDeskBridgeCore.a')],check=True,capture_output=True)
            (p/'main.swift').write_text('''import Foundation
@main struct Check {
 @MainActor static func main() {
  let updater = KnotUpdates()
  var idle = false, installed = 0, prepared = 0
  updater.isIdle = { idle }
  updater.prepareForRelaunch = { prepared += 1 }
  precondition(updater.postponeRelaunch { installed += 1 })
  precondition(updater.installationPending && installed == 0 && prepared == 0)
  updater.stateDidChange(); precondition(installed == 0)
  idle = true; updater.stateDidChange()
  precondition(installed == 1 && prepared == 1)
  updater.stateDidChange(); precondition(installed == 1 && prepared == 1)
  let ready = KnotUpdates(); ready.isIdle = { true }
  ready.prepareForRelaunch = { prepared += 1 }
  precondition(!ready.postponeRelaunch { installed += 1 })
  precondition(ready.installationPending && installed == 1 && prepared == 2)
  let privateMarker = "SYNTHETIC_PRIVATE_ERROR_DO_NOT_DISPLAY"
  let privatePath = "/synthetic/private/update-artifact"
  for (domain, code, busy) in [("Knot.Update", 1, true), ("Knot.Update", 2, true),
                              ("Other.Update", 1, false), ("Other.Update", 2, false),
                              ("Knot.Update", 3, false)] {
   let aborted = KnotUpdates()
   var abortIdle = false, canceledInstall = 0, canceledPrepare = 0
   aborted.isIdle = { abortIdle }
   aborted.prepareForRelaunch = { canceledPrepare += 1 }
   precondition(aborted.postponeRelaunch { canceledInstall += 1 })
   precondition(aborted.installationPending)
   aborted.abortUpdate(NSError(domain: domain, code: code,
                              userInfo: [NSLocalizedDescriptionKey: privateMarker,
                                         NSFilePathErrorKey: privatePath]))
   let expected = busy ? "진행 중인 연결과 작업을 마친 뒤 업데이트를 다시 확인하세요." :
                         "서명된 업데이트를 완료하지 못했습니다. 현재 버전과 연결 설정은 유지됩니다."
   precondition(!aborted.installationPending && aborted.status == expected)
   precondition(!aborted.status.contains(privateMarker) && !aborted.status.contains(privatePath))
   abortIdle = true; aborted.stateDidChange(); aborted.stateDidChange()
   precondition(canceledInstall == 0 && canceledPrepare == 0)
  }
 }
}
''')
            subprocess.run(['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-I',str(p),str(p/'libDeskBridgeCore.a'),str(ROOT/'Sources/DeskBridgeApp/KnotUpdates.swift'),str(p/'main.swift'),'-o',str(p/'check')],check=True,capture_output=True)
            subprocess.run([str(p/'check')],check=True,capture_output=True,timeout=10)

    @unittest.skipUnless(sys.platform=='darwin','Swift/macOS SDK required')
    def test_real_core(self):
        with tempfile.TemporaryDirectory(prefix='knot-update-swift-') as temporary:
            p=Path(temporary)
            (p/'main.swift').write_text('''import Foundation
let now = Date(timeIntervalSince1970: 1000)
let cert = String(repeating: "a", count: 64)
let intent = UpdateReconnectIntent(endpoint: "192.168.1.2", hostUniqueID: "host-1", certificateSHA256: cert, now: now)!
var gate = UpdateReconnectGate(intent)
precondition(gate.consume(endpoint: intent.endpoint, hostUniqueID: "host-1", certificateSHA256: cert, now: now) == intent)
precondition(gate.consume(endpoint: intent.endpoint, hostUniqueID: "host-1", certificateSHA256: cert, now: now) == nil)
for (endpoint, id, digest, when) in [("192.168.1.3", "host-1", cert, now), (intent.endpoint, "host-2", cert, now), (intent.endpoint, "host-1", String(repeating: "b", count: 64), now), (intent.endpoint, "host-1", cert, now.addingTimeInterval(600)), (intent.endpoint, "host-1", cert, now.addingTimeInterval(-1))] {
 gate.arm(intent); precondition(gate.consume(endpoint: endpoint, hostUniqueID: id, certificateSHA256: digest, now: when) == nil)
 precondition(gate.consume(endpoint: intent.endpoint, hostUniqueID: "host-1", certificateSHA256: cert, now: now) == nil)
}
precondition(UpdateInstallAdmission.evaluate(configured: true, desktopActive: false, transferActive: false, hostActive: false, setupActive: false) == .ready)
for index in 0..<4 { precondition(UpdateInstallAdmission.evaluate(configured: true, desktopActive: index == 0, transferActive: index == 1, hostActive: index == 2, setupActive: index == 3) == .busy) }
precondition(UpdateInstallAdmission.evaluate(configured: false, desktopActive: false, transferActive: false, hostActive: false, setupActive: false) == .publisherUnconfigured)
print("Update continuity/admission: 19 checks passed")
''')
            subprocess.run(['/usr/bin/swiftc','-swift-version','6',*map(str,sorted((ROOT/'Sources/DeskBridgeCore/Updates').glob('*.swift'))),str(p/'main.swift'),'-o',str(p/'check')],check=True,capture_output=True)
            subprocess.run([str(p/'check')],check=True,capture_output=True,timeout=10)

if __name__=='__main__': unittest.main()

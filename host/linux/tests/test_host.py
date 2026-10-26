# SPDX-License-Identifier: GPL-3.0-only
"""Fresh synthetic fixtures only. Never starts Sunshine or opens a desktop/port."""
import io
import errno
import json
import os
from pathlib import Path
import signal
import shlex
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from policy import Failure, address, allowed_download_url, arguments, child_environment, invitation, select_addresses, validate_session, web_credentials, validate_web_credentials
from runtime import OwnedHost, Store, StrictRedirect, TransferControl, cleanup_owned, digest_file, download, publish_new, resolve_pinned_binary, save_package, trusted_program
import hashlib


class HostChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='deskbridge-linux-synthetic-')
        self.base = Path(self.temp.name).resolve()
        self.store = Store(self.base / 'private')
    def tearDown(self):
        self.store.close(); self.temp.cleanup()
    def rejects(self, operation):
        with self.assertRaises((Failure, OSError, ValueError)): operation()

    def test_scope(self):
        env = {'DISPLAY': ':1', 'XDG_SESSION_TYPE': 'x11'}
        validate_session({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, env)
        for release, arch, uid, change in [({'ID': 'debian', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '26.04'}, 'x86_64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'aarch64', 1000, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 0, {}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'XDG_SESSION_TYPE': 'wayland'}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'WAYLAND_DISPLAY': 'wayland-0'}),
            ({'ID': 'ubuntu', 'VERSION_ID': '24.04'}, 'x86_64', 1000, {'DISPLAY': ''})]:
            with self.subTest(change=change, arch=arch): self.rejects(lambda: validate_session(release, arch, uid, dict(env, **change)))

    def test_invitation(self):
        text = invitation('개발 Linux & +', ['192.168.50.20', '100.80.10.20'])
        self.assertIn('v=2', text); self.assertIn('platform=linux', text); self.assertIn('%26', text)
        for values in ([], ['8.8.8.8'], ['192.168.01.20'], ['192.168.1.20'] * 2, ['192.168.1.' + str(i) for i in range(1, 10)]):
            self.rejects(lambda: invitation('Linux', values))
        for name in ('', 'bad\nname', 'bad\u202ename', 'x' * 65): self.rejects(lambda: invitation(name, ['10.0.0.1']))

    def test_metadata(self):
        rows = [{'flags': ['UP'], 'addr_info': [{'family': 'inet', 'local': a} for a in ['10.0.0.1', '100.80.10.20', '169.254.1.1', '8.8.8.8']]},
                {'flags': [], 'addr_info': [{'family': 'inet', 'local': '192.168.1.2'}]}]
        self.assertEqual(select_addresses(json.dumps(rows)), ['10.0.0.1', '100.80.10.20'])
        self.rejects(lambda: select_addresses(' ' * 262145))
        self.rejects(lambda: select_addresses(json.dumps([{}] * 129)))

    def test_address_candidates_exclude_containers_not_real_bridges_or_vpn(self):
        def row(name, value, flags=['UP']):
            return dict(ifname=name, flags=flags, addr_info=[dict(family='inet', local=value)])
        rows = [row('docker0', '172.17.0.1'), row('br-abcdef', '172.18.0.1'), row('virbr0', '192.168.122.1'),
                row('veth123', '10.2.0.1'), row('eno1', '192.168.1.8'), row('tailscale0', '100.80.1.8'),
                row('br0', '10.20.0.8'), row('eno2', '172.20.0.8', ['UP', 'NO-CARRIER'])]
        self.assertEqual(select_addresses(json.dumps(rows)), ['10.20.0.8', '192.168.1.8', '100.80.1.8'])

    def test_empty_address_and_overlong_name_have_specific_guidance(self):
        rows = [dict(ifname='docker0', flags=['UP'], addr_info=[dict(family='inet', local='172.17.0.1')]),
                dict(ifname='eno1', flags=['UP'], addr_info=[dict(family='inet', local='169.254.1.1')])]
        with self.assertRaises(Failure) as caught: invitation('Linux', select_addresses(json.dumps(rows)))
        self.assertEqual(caught.exception.key, 'no_address')
        self.assertIn('Tailscale IPv4', str(caught.exception))
        for build in (lambda name: invitation(name, ['10.0.0.1']), lambda name: arguments('/synthetic', name)):
            with self.assertRaises(Failure) as caught: build('가' * 43)
            self.assertEqual(caught.exception.key, 'name_length')
            build('가' * 42)
            with self.assertRaises(Failure) as caught: build('bad\nname')
            self.assertEqual(caught.exception.key, 'configuration')

    def test_mandatory_cli(self):
        args = arguments(self.store.root, 'Linux Desktop')
        for value in ('capture=x11', 'lan_encryption_mode=2', 'wan_encryption_mode=2', 'upnp=disabled',
                      'origin_web_ui_allowed=pc', 'controller=disabled', 'log_path=/dev/null'): self.assertIn(value, args)
        for name in ('x#x', 'x\ny', 'x=y', 'x[y'): self.rejects(lambda: arguments(self.store.root, name))
        self.rejects(lambda: arguments('/tmp/bad\npath', 'Linux'))
        self.store.prepare()
        self.assertEqual(json.loads((self.store.root / 'apps.json').read_text())['apps'], [{'name': 'Desktop', 'cmd': ''}])

    def test_environment(self):
        env = child_environment({'HOME': '/synthetic', 'DISPLAY': ':1', 'LD_PRELOAD': 'bad', 'PYTHONPATH': 'bad',
            'CONFIGURATION_DIRECTORY': '/bad', 'SUNSHINE_MIGRATE_CONFIG': '1', 'XDG_CONFIG_HOME': '/bad', 'PATH': '/bad', 'WAYLAND_DISPLAY': 'bad'}, self.store.root)
        self.assertEqual(env['HOME'], '/synthetic'); self.assertEqual(env['PATH'], '/usr/bin:/bin')
        self.assertEqual(env['XDG_CONFIG_HOME'], str(self.store.root) + '/xdg')
        for key in ('LD_PRELOAD', 'PYTHONPATH', 'CONFIGURATION_DIRECTORY', 'SUNSHINE_MIGRATE_CONFIG', 'WAYLAND_DISPLAY'): self.assertNotIn(key, env)

    def test_restart_preserves_configured_applications(self):
        self.store.prepare()
        apps = self.store.root / 'apps.json'
        edited = b'{"env":{},"apps":[{"name":"Desktop","cmd":""},{"name":"Work","cmd":"synthetic-only"}]}\n'
        apps.write_bytes(edited)
        self.store.prepare()
        self.assertEqual(apps.read_bytes(), edited)
        apps.unlink()
        self.store.prepare()
        self.assertEqual(json.loads(apps.read_bytes())['apps'], [{'name': 'Desktop', 'cmd': ''}])

    def nonfile_apps_fixture(self, store, kind):
        apps, sentinel = store.root / 'apps.json', None
        if kind == 'directory':
            apps.mkdir(mode=0o700)
            sentinel = apps / 'preserved'
            Store.write_new(sentinel, b'synthetic preserved contents')
        elif kind == 'link':
            sentinel = self.base / (store.root.name + '-target')
            Store.write_new(sentinel, b'synthetic preserved contents')
            apps.symlink_to(sentinel)
        else:
            os.mkfifo(apps, 0o600)
        return apps, sentinel

    def test_prepare_rejects_nonfile_apps_without_replacing_contents(self):
        for kind in ('directory', 'link', 'fifo'):
            with self.subTest(kind=kind):
                store = Store(self.base / ('prepare-' + kind))
                try:
                    apps, sentinel = self.nonfile_apps_fixture(store, kind)
                    before = apps.lstat()
                    with self.assertRaises((Failure, OSError)) as caught:
                        store.prepare()
                    if isinstance(caught.exception, Failure):
                        self.assertEqual(caught.exception.key, 'storage')
                    after = apps.lstat()
                    self.assertEqual((after.st_ino, after.st_mode), (before.st_ino, before.st_mode))
                    if sentinel is not None:
                        self.assertEqual(sentinel.read_bytes(), b'synthetic preserved contents')
                finally:
                    store.close()

    def test_start_rejects_nonfile_apps_before_credentials_or_spawn(self):
        for kind in ('directory', 'link', 'fifo'):
            with self.subTest(kind=kind):
                store = Store(self.base / ('start-' + kind))
                try:
                    apps, sentinel = self.nonfile_apps_fixture(store, kind)
                    before = apps.lstat()
                    host = OwnedHost()
                    with patch('runtime.preflight', return_value=({'DISPLAY': ':1'}, '/synthetic/sunshine')), \
                         patch.object(host, '_spawn') as spawn, \
                         patch.object(store, 'prepare_web_credentials', wraps=store.prepare_web_credentials) as credentials:
                        with self.assertRaises((Failure, OSError)) as caught:
                            host.start({}, store, 'Linux', 'synthetic', 'Synthetic-password-42!')
                        if isinstance(caught.exception, Failure):
                            self.assertEqual(caught.exception.key, 'storage')
                        credentials.assert_not_called(); spawn.assert_not_called()
                    self.assertFalse(os.path.lexists(store.root / 'web-credentials.json'))
                    self.assertIsNone(host.child)
                    after = apps.lstat()
                    self.assertEqual((after.st_ino, after.st_mode), (before.st_ino, before.st_mode))
                    if sentinel is not None:
                        self.assertEqual(sentinel.read_bytes(), b'synthetic preserved contents')
                finally:
                    store.close()

    def test_storage_no_adoption_or_overlap(self):
        other = self.base / 'unowned'; other.mkdir(mode=0o700)
        self.rejects(lambda: Store(other))
        try: Store(other)
        except Failure as error: self.assertEqual(error.key, 'storage')
        self.assertFalse((other / '.owner').exists())
        self.rejects(lambda: Store(self.store.root))
        self.store.close(); self.store = Store(self.base / 'private')
        self.store.prepare(); self.store.validate()

    def test_storage_link_and_permissions(self):
        secret = self.base / 'new-synthetic-secret'; secret.write_bytes(b'synthetic')
        link = self.store.root / 'linked'; link.symlink_to(secret)
        self.rejects(self.store.validate); link.unlink()
        os.link(secret, link); self.rejects(self.store.validate); link.unlink()
        Store.write_new(link, b'synthetic'); link.chmod(0o644)
        self.rejects(self.store.validate); link.chmod(0o600)
        self.store.validate()
        self.rejects(lambda: Store.write_new(link, b'replace'))
        self.assertEqual(link.read_bytes(), b'synthetic')

    def test_credentials_exist_before_launch_without_plaintext_or_reset(self):
        password, salt = 'Synthetic-password-42!', '0123456789ABCDEF'
        value = json.loads(web_credentials('deskbridge', password, salt))
        self.assertEqual(value['password'], 'F55578F96AAE2127B01A4BB740A88BE284A34515B359E6960C1003F05B189FA9')
        validate_web_credentials(json.dumps(value))
        path = self.store.root / 'web-credentials.json'
        self.rejects(lambda: self.store.prepare_web_credentials('deskbridge', 'short'))
        self.assertFalse(path.exists())
        self.store.prepare_web_credentials('deskbridge', password)
        original = path.read_bytes(); self.assertNotIn(password.encode(), original)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600); self.assertEqual(path.stat().st_nlink, 1)
        self.store.prepare_web_credentials('other', 'Different-password-42!'); self.assertEqual(path.read_bytes(), original)
        path.write_bytes(b'{}')
        self.rejects(lambda: self.store.prepare_web_credentials('deskbridge', password))
        self.assertEqual(path.read_bytes(), b'{}')
        value['username'] = ''; self.rejects(lambda: validate_web_credentials(json.dumps(value)))

    def test_only_upstream_public_certificate_permissions_are_tightened(self):
        certificate = self.store.root / 'credentials/cacert.pem'
        certificate.write_bytes(b'SYNTHETIC PUBLIC CERTIFICATE'); certificate.chmod(0o644)
        self.store.validate(); self.assertEqual(certificate.stat().st_mode & 0o777, 0o600)
        certificate.chmod(0o666); self.rejects(self.store.validate)
        self.assertEqual(certificate.stat().st_mode & 0o777, 0o666)
        certificate.unlink(); certificate.symlink_to(self.base / 'not-read')
        self.rejects(self.store.validate)

    def test_redirects(self):
        self.assertTrue(allowed_download_url('https://release-assets.githubusercontent.com/a'))
        for url in ('http://github.com/a', 'https://github.com.evil/a', 'https://user@github.com/a', 'https://github.com:80/a', 'file:///etc/passwd', 'https://github.com/a#fragment'):
            self.assertFalse(allowed_download_url(url))
            self.rejects(lambda: StrictRedirect().redirect_request(None, None, 302, '', {}, url))

    def fixture_download(self, data, declared=None, url='https://github.com/fixture'):
        pin = dict(url='https://github.com/fixture', version='synthetic', bytes=8, sha256=hashlib.sha256(b'fixture!').hexdigest())
        class Response(io.BytesIO):
            status = 200
            def __init__(self):
                super().__init__(data); self.url = url; self.headers = {} if declared is None else {'Content-Length': str(declared)}
        class Opener:
            def open(self, *_args, **_kwargs): return Response()
        return pin, Opener()

    def test_download_integrity_publish_and_collision(self):
        pin, opener = self.fixture_download(b'fixture!', 8)
        path = download(pin, self.store, threading.Event(), opener=opener)
        self.assertEqual(path.read_bytes(), b'fixture!'); self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(download(pin, self.store, threading.Event(), opener=opener), path)
        path.write_bytes(b'tampered'); self.rejects(lambda: download(pin, self.store, threading.Event(), opener=opener))
        self.assertEqual(path.read_bytes(), b'tampered')
        with self.assertRaises(Failure) as caught: download(pin, self.store, threading.Event(), opener=opener)
        self.assertEqual(caught.exception.key, 'download_collision')
        path.unlink()
        self.assertEqual(download(pin, self.store, threading.Event(), opener=opener).read_bytes(), b'fixture!')

    def test_atomic_publish_and_verified_export_never_replace_or_make_links(self):
        source, target = self.base / 'new-source', self.base / 'new-target'
        source.write_bytes(b'new'); target.write_bytes(b'existing')
        self.rejects(lambda: publish_new(source, target))
        self.assertEqual(source.read_bytes(), b'new'); self.assertEqual(target.read_bytes(), b'existing')
        target.unlink(); publish_new(source, target)
        self.assertFalse(source.exists()); self.assertEqual(target.stat().st_nlink, 1)
        pin, opener = self.fixture_download(b'fixture!', 8)
        package = download(pin, self.store, threading.Event(), opener=opener)
        exported = save_package(pin, package, self.base / 'visible package.deb')
        self.assertEqual(exported.read_bytes(), b'fixture!'); self.assertEqual(exported.stat().st_nlink, 1)
        with self.assertRaises(Failure) as caught: save_package(pin, package, exported)
        self.assertEqual(caught.exception.key, 'collision')
        self.store.validate()
        self.store.close(); self.store = Store(self.base / 'private'); self.store.validate()

    def test_missing_system_program_is_install_error(self):
        with self.assertRaises(Failure) as caught: trusted_program(self.base / 'missing-program')
        self.assertEqual(caught.exception.key, 'install')

    def test_pinned_executable_resolves_every_trusted_symlink_hop(self):
        target = self.base / 'sunshine-version'; target.write_bytes(b'synthetic executable'); target.chmod(0o755)
        intermediate = self.base / 'sunshine-current'; intermediate.symlink_to(target.name)
        link = self.base / 'sunshine'; link.symlink_to(intermediate.name)
        pin = dict(binary=str(link), binarySHA256=hashlib.sha256(target.read_bytes()).hexdigest())
        real_lstat, real_fstat = Path.lstat, os.fstat
        def projected(s, uid=0):
            values = list(s); values[0] &= ~0o022; values[4] = uid
            return os.stat_result(values)
        for untrusted in (None, link, intermediate, target):
            with self.subTest(untrusted=untrusted):
                def lstat(path): return projected(real_lstat(path), 1000 if path == untrusted else 0)
                with patch.object(Path, 'lstat', new=lstat), patch('runtime.os.fstat', side_effect=lambda fd: projected(real_fstat(fd))):
                    if untrusted is None:
                        self.assertEqual(resolve_pinned_binary(pin), str(target))
                        with self.assertRaises(Failure) as caught: resolve_pinned_binary(dict(pin, binarySHA256='0' * 64))
                    else:
                        with self.assertRaises(Failure) as caught: resolve_pinned_binary(pin)
                    self.assertEqual(caught.exception.key, 'install')

    def test_owned_host_executes_the_exact_verified_canonical_path(self):
        host, storage = OwnedHost(), Mock(root=self.store.root)
        program = '/synthetic/root-controlled/sunshine-version'
        with patch('runtime.preflight', return_value=({'DISPLAY': ':1'}, program)), patch.object(host, '_spawn') as spawn:
            host.start(dict(binary='/synthetic/symlink'), storage, 'Linux', 'synthetic', 'Synthetic-password-42!')
        self.assertEqual(spawn.call_args.args[0][0], program)

    def test_spawn_requires_enforced_exec_confirmation_and_cleans_refusal(self):
        for ready in (b'R', b'F', b'', None):
            with self.subTest(ready=ready):
                host, child = OwnedHost(), Mock(pid=12345)
                def finish(): host.child = None
                with patch('runtime.os.pipe2', side_effect=[(101, 102), (103, 104)], create=True), \
                     patch('runtime.os.close') as close, patch('runtime.subprocess.Popen', return_value=child) as spawn, \
                     patch('runtime.select.select', return_value=([103] if ready is not None else [], [], [])), \
                     patch('runtime.os.read', return_value=ready), patch.object(host, '_finish', side_effect=finish) as cleanup:
                    if ready == b'R':
                        host._spawn(['/synthetic/inert-host'], {})
                        self.assertIs(host.child, child); self.assertEqual(host.lifetime_writer, 102)
                        cleanup.assert_not_called()
                    else:
                        with self.assertRaises(Failure): host._spawn(['/synthetic/inert-host'], {})
                        cleanup.assert_called_once()
                        self.assertIsNone(host.child); self.assertIsNone(host.lifetime_writer)
                        self.assertIn(unittest.mock.call(102), close.call_args_list)
                    self.assertEqual(spawn.call_args.kwargs['pass_fds'], (101, 104))
                    self.assertTrue(spawn.call_args.kwargs['start_new_session'])
                    for descriptor in (101, 103, 104):
                        self.assertEqual(close.call_args_list.count(unittest.mock.call(descriptor)), 1)

    def test_invalid_host_name_never_prepares_or_commits_credentials(self):
        host, storage = OwnedHost(), Mock(root=self.store.root)
        with patch('runtime.preflight') as preflight, patch.object(host, '_spawn') as spawn, self.assertRaises(Failure) as caught:
            host.start({}, storage, '\ud55c' * 43, 'synthetic', 'Synthetic-password-42!')
        self.assertEqual(caught.exception.key, 'name_length')
        storage.prepare.assert_not_called(); storage.prepare_web_credentials.assert_not_called()
        preflight.assert_not_called(); spawn.assert_not_called()

    def test_preflight_recognizes_versioned_canonical_basename_without_live_proc(self):
        from runtime import preflight
        process = self.base / '1234'; process.mkdir(); (process / 'comm').write_bytes(b'sunshine-versio\n')
        with patch('runtime.platform.freedesktop_os_release', return_value={}, create=True), patch('runtime.validate_session'), \
             patch('runtime.resolve_pinned_binary', return_value='/synthetic/sunshine-version'), \
             patch('runtime.metadata_command', return_value=b'fixture'), patch('runtime.os.access', return_value=True), \
             patch('runtime.trusted_program'), patch('runtime.Path.iterdir', return_value=iter([process])), \
             patch('runtime.socket.socket') as sockets, self.assertRaises(Failure) as caught:
            preflight(dict(packageVersion='fixture'), env={})
        self.assertEqual(caught.exception.key, 'existing'); sockets.assert_not_called()

    def test_public_export_accepts_destination_modes_but_keeps_private_source_policy(self):
        pin, opener = self.fixture_download(b'fixture!', 8)
        package = download(pin, self.store, threading.Event(), opener=opener)
        real_fstat, real_mkstemp, exported_inode = os.fstat, tempfile.mkstemp, []
        def mkstemp(*args, **kwargs):
            fd, path = real_mkstemp(*args, **kwargs)
            exported_inode.append(real_fstat(fd).st_ino)
            return fd, path
        def fstat(fd):
            s = real_fstat(fd)
            if s.st_ino in exported_inode:
                values = list(s); values[0] = stat.S_IFREG | 0o644
                return os.stat_result(values)
            return s
        with patch('runtime.tempfile.mkstemp', side_effect=mkstemp), patch('runtime.os.fstat', side_effect=fstat):
            exported = save_package(pin, package, self.base / 'public-copy.deb')
        self.assertEqual(exported.read_bytes(), b'fixture!')
        for error in (PermissionError('synthetic denied'), OSError(errno.EOPNOTSUPP, 'synthetic unsupported rename')):
            with patch('runtime.publish_new', side_effect=error), self.assertRaises(Failure) as caught:
                save_package(pin, package, self.base / 'never-published.deb')
            self.assertEqual(caught.exception.key, 'export_destination')
        self.assertEqual(list(self.base.glob('.deskbridge-package-*')), [])
        package.chmod(0o644)
        with self.assertRaises(Failure) as caught: save_package(pin, package, self.base / 'private-source-refused.deb')
        self.assertEqual(caught.exception.key, 'storage')
        package.chmod(0o600)

    def test_export_preserves_source_error_and_cleanup_failure_evidence(self):
        import runtime
        pin, opener = self.fixture_download(b'fixture!', 8)
        package = download(pin, self.store, threading.Event(), opener=opener)
        ordinary = runtime.ordinary_read; calls = [0]
        def source_error(*args, **kwargs):
            calls[0] += 1
            if calls[0] == 2: raise OSError(errno.EIO, 'synthetic source failure')
            return ordinary(*args, **kwargs)
        with patch('runtime.ordinary_read', side_effect=source_error), self.assertRaises(Failure) as caught:
            save_package(pin, package, self.base / 'source-failed.deb')
        self.assertEqual(caught.exception.key, 'download')
        with patch('runtime.publish_new', side_effect=PermissionError('synthetic destination')), \
             patch('runtime.os.unlink', side_effect=OSError(errno.EIO, 'synthetic cleanup')), self.assertRaises(Failure) as caught:
            save_package(pin, package, self.base / 'destination-failed.deb')
        self.assertEqual(caught.exception.key, 'export_destination')
        self.assertTrue(caught.exception.cleanup_failed)
        self.assertNotIn('synthetic cleanup', str(caught.exception))

    def test_export_success_preserves_recreated_temporary_name(self):
        import runtime
        pin, opener = self.fixture_download(b'fixture!', 8)
        package = download(pin, self.store, threading.Event(), opener=opener)
        publish, residue = runtime.publish_new, []
        destination = self.base / 'published-copy.deb'
        def publish_with_fresh_residue(source, target):
            publish(source, target)
            Path(source).write_bytes(b'synthetic residue after publication')
            residue.append(Path(source))
        with patch('runtime.publish_new', side_effect=publish_with_fresh_residue), \
             patch('runtime.os.unlink') as cleanup:
            self.assertEqual(save_package(pin, package, destination), destination)
            cleanup.assert_not_called()
        self.assertEqual(destination.read_bytes(), b'fixture!')
        self.assertEqual(len(residue), 1); self.assertTrue(residue[0].exists())
        residue[0].unlink()

    def test_nonreaping_child_retains_ownership_and_failed_cleanup(self):
        events = []; host = OwnedHost()
        class Child:
            pid = 12345
            def wait(self, timeout):
                if timeout > 1: raise AssertionError('unbounded reap')
                raise subprocess.TimeoutExpired('synthetic', timeout)
        host.child = Child()
        with patch.object(host, '_exited', return_value=True), patch('runtime.os.killpg') as kill:
            cleanup_owned(host, None, lambda: events.append('quit'), lambda: events.append('failed'))
            self.assertEqual(kill.call_count, 2)  # TERM then KILL; no post-reap/retry signal.
        self.assertEqual(events, ['failed']); self.assertIsNotNone(host.child)
        host.child = None

    def test_download_failures_cleanup(self):
        for data, declared, url in ((b'short', None, 'https://github.com/a'), (b'fixture!extra', None, 'https://github.com/a'),
                                    (b'bad!!!!!', None, 'https://github.com/a'), (b'fixture!', 7, 'https://github.com/a'),
                                    (b'fixture!', 8, 'http://github.com/a')):
            pin, opener = self.fixture_download(data, declared, url)
            self.rejects(lambda: download(pin, self.store, threading.Event(), opener=opener))
            self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])
        pin, opener = self.fixture_download(b'fixture!', 8)
        cancel = threading.Event(); cancel.set()
        self.rejects(lambda: download(pin, self.store, cancel, opener=opener))
        self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])

    def blocked_transfer(self, cancel, control):
        # An inert socket substitute lets the watchdog interrupt a blocked receive.
        gate = threading.Event()
        class Socket:
            def shutdown(self, how): gate.set()
        class Response(io.BytesIO):
            status, url, headers = 200, 'https://github.com/fixture', {}
            def read1(self, size):
                if not gate.wait(2): raise AssertionError('watchdog failed to interrupt active I/O')
                raise OSError('synthetic receive interrupted')
        class Opener:
            def open(self, *_args, **_kwargs):
                control.attach(Socket()); return Response()
        pin, unused = self.fixture_download(b'fixture!', 8)
        began = time.monotonic()
        with self.assertRaises(Failure) as caught:
            download(pin, self.store, cancel, opener=Opener(), control=control)
        self.assertLess(time.monotonic() - began, 1)
        self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])
        return caught.exception.key

    def test_cancel_interrupts_active_receive(self):
        cancel = threading.Event(); control = TransferControl(cancel)
        timer = threading.Timer(0.05, cancel.set); timer.start()
        try: self.assertEqual(self.blocked_transfer(cancel, control), 'cancel')
        finally: timer.join(); control.close()

    def test_deadline_interrupts_active_receive(self):
        cancel = threading.Event(); control = TransferControl(cancel, seconds=0.05)
        try: self.assertEqual(self.blocked_transfer(cancel, control), 'download')
        finally: control.close()

    def blocked_establishment(self, stage, deadline):
        # Exercise the real urllib connection path, replacing every network
        # operation. DNS is a fresh sleeping child, not a resolver thread.
        cancel = threading.Event(); control = TransferControl(cancel)
        phase, timers, children = [], [], []
        interrupted = threading.Event()
        def entered():
            phase.append(stage)
            if deadline:
                control.deadline = time.monotonic() + 0.05
            else:
                timer = threading.Timer(0.05, cancel.set); timers.append(timer); timer.start()
        class Socket:
            closed = False
            def shutdown(self, _how): interrupted.set()
            def close(self): self.closed = True
            def setblocking(self, value): self.blocking = value
            def setsockopt(self, *_args): pass
            def connect_ex(self, address):
                self.address = address
                if stage == 'tcp': entered(); return errno.EINPROGRESS
                return 0
            def do_handshake(self):
                entered()
                raise ssl.SSLWantReadError(ssl.SSL_ERROR_WANT_READ, 'synthetic pending handshake')
        raw, tls = Socket(), Socket()
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443])]
        def select_ready(readers, writers, exceptional, timeout):
            self.assertEqual(readers, [tls] if stage == 'tls' else [])
            self.assertEqual(writers, [raw] if stage == 'tcp' else [])
            self.assertEqual(exceptional, [])
            self.assertLessEqual(timeout, 0.05)
            interrupted.wait(timeout)
            return [], [], []
        def wrap(context, sock, *, server_hostname, do_handshake_on_connect):
            self.assertIs(sock, raw); self.assertFalse(raw.blocking)
            self.assertEqual(server_hostname, 'github.com')
            self.assertFalse(do_handshake_on_connect)
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
            return tls
        popen = subprocess.Popen
        marker = self.base / ('resolver-entered-' + str(deadline))
        def spawn(argv, **kwargs):
            self.assertEqual(argv[:5], ['/usr/bin/python3', '-I', '-S', '-B', '-c'])
            self.assertEqual(argv[5:], [control.RESOLVER, 'github.com', '443'])
            self.assertEqual(kwargs['env'], {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
            self.assertTrue(kwargs['close_fds'])
            code = 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text("ready"); time.sleep(30)'
            child = popen([sys.executable, '-I', '-S', '-B', '-c', code, str(marker)], **kwargs)
            children.append(child)
            for _ in range(100):
                if marker.exists(): break
                time.sleep(0.01)
            self.assertTrue(marker.exists(), 'inert resolver did not enter its blocking operation')
            entered()
            return child
        pin, _ = self.fixture_download(b'fixture!', 8)
        began = time.monotonic()
        try:
            with patch('runtime.subprocess.Popen', side_effect=spawn) as resolver, \
                 patch('runtime.socket.socket', return_value=raw) as create_socket, \
                 patch('runtime.select.select', side_effect=select_ready), \
                 patch('runtime.ssl.SSLContext.wrap_socket', new=wrap):
                if stage == 'dns':
                    with self.assertRaises(Failure) as caught:
                        download(pin, self.store, cancel, control=control)
                    resolver.assert_called_once(); create_socket.assert_not_called()
                else:
                    with patch.object(control, '_resolve', return_value=addresses), self.assertRaises(Failure) as caught:
                        download(pin, self.store, cancel, control=control)
                    resolver.assert_not_called(); self.assertTrue(raw.closed if stage == 'tcp' else tls.closed)
            self.assertLess(time.monotonic() - began, 1)
            self.assertEqual(phase, [stage])
            self.assertEqual(caught.exception.key, 'download' if deadline else 'cancel')
            self.assertFalse(control.worker.is_alive())
            self.assertEqual(list((self.store.root / 'downloads').iterdir()), [])
            for child in children:
                self.assertEqual(child.returncode, -signal.SIGKILL)
                self.assertTrue(child.stdout.closed)
        finally:
            for timer in timers: timer.join()
            for child in children:
                if child.poll() is None: child.kill(); child.wait(timeout=1)
                child.stdout.close()
            control.close()

    def test_cancel_interrupts_dns_tcp_and_tls_setup(self):
        for stage in ('dns', 'tcp', 'tls'):
            with self.subTest(stage=stage): self.blocked_establishment(stage, deadline=False)

    def test_deadline_interrupts_dns_tcp_and_tls_setup(self):
        for stage in ('dns', 'tcp', 'tls'):
            with self.subTest(stage=stage): self.blocked_establishment(stage, deadline=True)

    def test_resolver_bounds_and_numeric_addresses_without_network(self):
        valid = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', ('192.0.2.1', 443)),
                 (socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', ('2001:db8::1', 443, 0, 0))]
        popen = subprocess.Popen
        for rows, accepted in ((valid, True), ([], False), (valid * 33, False),
                ([(2, 1, 6, '', ('x' * 17000, 443))], False),
                ([(2, 1, 6, '', ('must-never-resolve.invalid', 443))], False),
                ([(2, 1, 6, '', ('192.0.2.1', 80))], False)):
            with self.subTest(addresses=len(rows), accepted=accepted):
                control = TransferControl(threading.Event()); children = []
                def spawn(argv, **kwargs):
                    # Run the production resolver code with inert getaddrinfo;
                    # only this test uses the development Python executable.
                    code = 'import socket,json\nsocket.getaddrinfo=lambda *args,**kwargs: json.loads(' + repr(json.dumps(rows)) + ')\n' + argv[5]
                    child = popen([sys.executable, '-I', '-S', '-B', '-c', code, *argv[6:]], **kwargs)
                    children.append(child); return child
                try:
                    with patch('runtime.subprocess.Popen', side_effect=spawn):
                        if accepted:
                            result = control._resolve('github.com', 443, time.monotonic() + 2)
                            self.assertEqual([row[3][0] for row in result], ['192.0.2.1', '2001:db8::1'])
                        else:
                            self.rejects(lambda: control._resolve('github.com', 443, time.monotonic() + 2))
                    for child in children:
                        self.assertIsNotNone(child.returncode); self.assertTrue(child.stdout.closed)
                finally:
                    control.close()

    def test_tcp_fallback_and_tls_read_write_handshake_preserve_hostname(self):
        control = TransferControl(threading.Event())
        failed = Mock(connect_ex=Mock(return_value=errno.ECONNREFUSED))
        raw = Mock(connect_ex=Mock(return_value=0))
        tls = Mock(do_handshake=Mock(side_effect=[ssl.SSLWantWriteError(), ssl.SSLWantReadError(), None]))
        context = ssl.create_default_context()
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443]),
                     (socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::1', 443, 0, 0])]
        try:
            with patch.object(control, '_resolve', return_value=addresses), \
                 patch('runtime.socket.socket', side_effect=[failed, raw]), \
                 patch.object(context, 'wrap_socket', return_value=tls) as wrap, \
                 patch('runtime.select.select', side_effect=lambda r, w, x, t: (r, w, [])) as ready:
                self.assertIs(control.connect('github.com', 443, context, 20), tls)
            failed.close.assert_called_once(); raw.setblocking.assert_called_once_with(False)
            raw.connect_ex.assert_called_once_with(('2001:db8::1', 443, 0, 0))
            wrap.assert_called_once_with(raw, server_hostname='github.com', do_handshake_on_connect=False)
            self.assertEqual(ready.call_args_list[0].args[:3], ([], [tls], []))
            self.assertEqual(ready.call_args_list[1].args[:3], ([tls], [], []))
            tls.settimeout.assert_called_once_with(20)
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED); self.assertTrue(context.check_hostname)
        finally:
            tls.close(); control.close()

    def test_blackholed_ipv6_falls_back_to_ipv4_without_extending_setup_budget(self):
        control = TransferControl(threading.Event()); clock = [time.monotonic()]
        pending = Mock(connect_ex=Mock(return_value=errno.EINPROGRESS))
        raw = Mock(connect_ex=Mock(return_value=0))
        tls = Mock(do_handshake=Mock(return_value=None)); context = Mock(wrap_socket=Mock(return_value=tls))
        rows = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::1', 443, 0, 0]),
                (socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::2', 443, 0, 0]),
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443])]
        began = clock[0]
        def not_ready(readers, writers, exceptional, timeout):
            self.assertEqual((readers, writers, exceptional), ([], [pending], []))
            clock[0] += timeout
            return [], [], []
        try:
            with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                 patch('runtime.socket.socket', side_effect=[pending, raw]) as create, patch('runtime.select.select', side_effect=not_ready):
                self.assertIs(control.connect('github.com', 443, context, 20), tls)
            self.assertAlmostEqual(clock[0] - began, control.CONNECT_ATTEMPT_SECONDS)
            self.assertEqual([call.args[0] for call in create.call_args_list], [socket.AF_INET6, socket.AF_INET])
            pending.close.assert_called_once(); raw.connect_ex.assert_called_once_with(('192.0.2.1', 443))
            context.wrap_socket.assert_called_once_with(raw, server_hostname='github.com', do_handshake_on_connect=False)
            tls.settimeout.assert_called_once_with(20)
        finally: control.close()

    def test_candidate_timeouts_keep_shared_deadline_and_cancellation_authoritative(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                control = TransferControl(threading.Event()); clock = [time.monotonic()]; began = clock[0]
                rows = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::' + str(i), 443, 0, 0]) for i in range(1, 13)]
                context = Mock(); created = []
                def socket_fixture(*_):
                    sock = Mock(connect_ex=Mock(return_value=errno.EINPROGRESS)); created.append(sock); return sock
                def not_ready(_readers, _writers, _exceptional, timeout):
                    clock[0] += timeout
                    if cancel: control.cancel.set()
                    return [], [], []
                try:
                    with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                         patch('runtime.socket.socket', side_effect=socket_fixture), patch('runtime.select.select', side_effect=not_ready), self.assertRaises(Failure) as caught:
                        control.connect('github.com', 443, context, 20)
                    self.assertEqual(caught.exception.key, 'cancel' if cancel else 'download')
                    self.assertLessEqual(clock[0] - began, 20.000001)
                    self.assertEqual(len(created), 1 if cancel else 2 * len(rows))
                    for sock in created: sock.close.assert_called_once()
                    context.wrap_socket.assert_not_called()
                finally: control.close()

    def test_only_candidate_retains_remaining_shared_deadline(self):
        control = TransferControl(threading.Event()); clock = [time.monotonic()]; began = clock[0]
        rows = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443])]
        sock = Mock(connect_ex=Mock(return_value=errno.EINPROGRESS), getsockopt=Mock(return_value=0))
        def ready(_readers, writers, _exceptional, timeout):
            clock[0] += timeout
            return ([], writers, []) if clock[0] - began >= 18 else ([], [], [])
        try:
            with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                 patch('runtime.socket.socket', return_value=sock) as create, patch('runtime.select.select', side_effect=ready):
                self.assertIs(control._connect_tcp('fixture.invalid', 443, began + 20, None), sock)
            self.assertGreaterEqual(clock[0] - began, 18); self.assertLess(clock[0] - began, 20)
            create.assert_called_once(); sock.close.assert_not_called()
        finally: control.close()

    def test_locally_capped_candidate_retries_after_later_route_rejects(self):
        control = TransferControl(threading.Event()); clock = [time.monotonic()]; began = clock[0]
        rows = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::1', 443, 0, 0]),
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443])]
        first = Mock(connect_ex=Mock(return_value=errno.EINPROGRESS), getsockopt=Mock(return_value=0))
        rejected = Mock(connect_ex=Mock(return_value=errno.ENETUNREACH))
        retried = Mock(connect_ex=Mock(return_value=errno.EINPROGRESS), getsockopt=Mock(return_value=0))
        elapsed = {id(first): 0.0, id(retried): 0.0}
        def ready(_readers, writers, _exceptional, timeout):
            clock[0] += timeout; elapsed[id(writers[0])] += timeout
            return ([], writers, []) if elapsed[id(writers[0])] >= 3 else ([], [], [])
        try:
            with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                 patch('runtime.socket.socket', side_effect=[first, rejected, retried]) as create, patch('runtime.select.select', side_effect=ready):
                self.assertIs(control._connect_tcp('fixture.invalid', 443, began + 20, None), retried)
            self.assertEqual([call.args[0] for call in create.call_args_list], [socket.AF_INET6, socket.AF_INET, socket.AF_INET6])
            first.close.assert_called_once(); rejected.close.assert_called_once(); retried.close.assert_not_called()
            retried.connect_ex.assert_called_once_with(('2001:db8::1', 443, 0, 0))
            self.assertAlmostEqual(elapsed[id(first)], control.CONNECT_ATTEMPT_SECONDS)
            self.assertGreaterEqual(elapsed[id(retried)], 3); self.assertLess(clock[0] - began, 6)
        finally: control.close()

    def test_final_first_pass_blackhole_leaves_retry_budget_without_http_replay(self):
        cancel = threading.Event(); control = TransferControl(cancel)
        clock = [time.monotonic()]; began = clock[0]
        rows = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::1', 443, 0, 0]),
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443]),
                (socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::2', 443, 0, 0])]
        first, blackhole, retried = [Mock(connect_ex=Mock(return_value=errno.EINPROGRESS), getsockopt=Mock(return_value=0)) for _ in range(3)]
        rejected = Mock(connect_ex=Mock(return_value=errno.ECONNREFUSED))
        tls = Mock(do_handshake=Mock(return_value=None)); context = Mock(wrap_socket=Mock(return_value=tls))
        elapsed = {id(sock): 0.0 for sock in (first, blackhole, retried)}
        def ready(_readers, writers, _exceptional, timeout):
            clock[0] += timeout; elapsed[id(writers[0])] += timeout
            return ([], writers, []) if writers != [blackhole] and elapsed[id(writers[0])] >= 3 else ([], [], [])
        pin, response = self.fixture_download(b'fixture!', 8)
        def open_response(*_args, **_kwargs):
            control.connect('github.com', 443, context, 20)
            return response.open()
        opener = Mock(open=Mock(side_effect=open_response))
        try:
            with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                 patch('runtime.socket.socket', side_effect=[first, rejected, blackhole, retried]) as create, \
                 patch('runtime.select.select', side_effect=ready):
                package = download(pin, self.store, cancel, opener=opener, control=control)
            self.assertEqual(package.read_bytes(), b'fixture!'); self.assertEqual(create.call_count, 4)
            self.assertAlmostEqual(elapsed[id(first)], control.CONNECT_ATTEMPT_SECONDS)
            self.assertAlmostEqual(elapsed[id(blackhole)], control.CONNECT_ATTEMPT_SECONDS)
            self.assertGreaterEqual(elapsed[id(retried)], 3); self.assertLess(clock[0] - began, 9)
            for sock in (first, rejected, blackhole): sock.close.assert_called_once()
            retried.close.assert_not_called(); opener.open.assert_called_once()
            context.wrap_socket.assert_called_once_with(retried, server_hostname='github.com', do_handshake_on_connect=False)
            tls.do_handshake.assert_called_once(); tls.settimeout.assert_called_once_with(20)
        finally: control.close()

    def test_permanently_rejected_candidates_are_not_retried(self):
        control = TransferControl(threading.Event())
        rows = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.' + str(i), 443]) for i in (1, 2)]
        sockets = [Mock(connect_ex=Mock(return_value=status)) for status in (errno.ECONNREFUSED, errno.ENETUNREACH)]
        try:
            with patch.object(control, '_resolve', return_value=rows), patch('runtime.socket.socket', side_effect=sockets) as create, \
                 self.assertRaises(Failure) as caught:
                control._connect_tcp('fixture.invalid', 443, time.monotonic() + 20, None)
            self.assertEqual(caught.exception.key, 'download'); self.assertEqual(create.call_count, 2)
            for sock in sockets: sock.close.assert_called_once()
        finally: control.close()

    def test_capped_candidate_retry_keeps_shared_deadline_and_cancellation(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                control = TransferControl(threading.Event()); clock = [time.monotonic()]; began = clock[0]
                rows = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['2001:db8::1', 443, 0, 0]),
                        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, ['192.0.2.1', 443])]
                first, retried = [Mock(connect_ex=Mock(return_value=errno.EINPROGRESS)) for _ in range(2)]
                rejected = Mock(connect_ex=Mock(return_value=errno.ENETUNREACH))
                def not_ready(_readers, writers, _exceptional, timeout):
                    clock[0] += timeout
                    if cancel and writers == [retried]: control.cancel.set()
                    return [], [], []
                try:
                    with patch('runtime.time.monotonic', side_effect=lambda: clock[0]), patch.object(control, '_resolve', return_value=rows), \
                         patch('runtime.socket.socket', side_effect=[first, rejected, retried]) as create, \
                         patch('runtime.select.select', side_effect=not_ready), self.assertRaises(Failure) as caught:
                        control._connect_tcp('fixture.invalid', 443, began + 4, None)
                    self.assertEqual(caught.exception.key, 'cancel' if cancel else 'download')
                    self.assertEqual(create.call_count, 3); self.assertLessEqual(clock[0] - began, 4.000001)
                    for sock in (first, rejected, retried): sock.close.assert_called_once()
                finally: control.close()

    def test_shutdown_finalizes_after_lost_ownership(self):
        events = []
        class Host:
            child = None
            def stop(self): events.append('stop'); raise Failure('exit')
        class Storage:
            def close(self): events.append('close')
        cleanup_owned(Host(), Storage(), lambda: events.append('quit'), lambda: events.append('failed'))
        self.assertEqual(events, ['stop', 'close', 'quit'])

    def test_shutdown_keeps_owned_host_visible_on_unexpected_stop_failure(self):
        events = []
        host = OwnedHost()
        class Child:
            pid = 12345  # Never signalled: killpg is an injected inert failure below.
        class Storage:
            def close(self): events.append('close')
        host.child = Child()
        with patch.object(host, '_exited', return_value=False), patch('runtime.os.killpg', side_effect=PermissionError('synthetic stop denied')):
            cleanup_owned(host, Storage(), lambda: events.append('quit'), lambda: events.append('failed'))
        self.assertEqual(events, ['failed'])
        self.assertIsNotNone(host.child)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux WNOWAIT process ownership')
    def test_only_owned_inert_process_is_stopped(self):
        host = OwnedHost()
        foreign = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        host.child = child
        try:
            self.assertTrue(host.alive()); host.stop()
            self.assertIsNone(host.child); self.assertIsNotNone(child.returncode)
            self.assertIsNone(foreign.poll()); host.stop()
        finally:
            foreign.terminate(); foreign.wait()
            if host.child is not None: host.stop()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux WNOWAIT process ownership')
    def test_lost_child_ownership_never_signals_pid(self):
        host = OwnedHost()
        child = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        child.wait(); host.child = child  # Simulate an unexpected external reaper.
        with patch('runtime.os.killpg') as kill:
            self.rejects(host.stop)
            kill.assert_not_called(); self.assertIsNone(host.child)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux owner lifetime pipe')
    def test_creator_worker_return_does_not_end_share_but_owner_death_does(self):
        import select
        marker = self.base / 'fresh-engine-pid'
        owner_code = '''import sys,threading,time
sys.path.insert(0,sys.argv[1])
from runtime import OwnedHost
host=OwnedHost()
engine="import os,time; from pathlib import Path; Path("+repr(sys.argv[2])+").write_text(str(os.getpid())); time.sleep(30)"
thread=threading.Thread(target=lambda:host._spawn([sys.executable,'-c',engine],{'PATH':'/usr/bin:/bin'}))
thread.start();thread.join()
print(host.child.pid,flush=True)
sys.stdin.read()
'''
        owner = subprocess.Popen([sys.executable, '-c', owner_code, str(Path(__file__).resolve().parents[1]), str(marker)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        pidfds = []
        try:
            self.assertTrue(select.select([owner.stdout], [], [], 5)[0])
            supervisor_pid = int(owner.stdout.readline())
            for _ in range(100):
                if marker.exists(): break
                time.sleep(0.02)
            self.assertTrue(marker.exists(), 'short creator worker killed the share')
            engine_pid = int(marker.read_text())
            pidfds = [os.pidfd_open(pid) for pid in (supervisor_pid, engine_pid)]
            self.assertFalse(select.select(pidfds, [], [], 0.1)[0], 'share died while owner alive')
            owner.kill(); owner.wait(timeout=2)
            for fd in pidfds: self.assertTrue(select.select([fd], [], [], 3)[0], 'share survived owner death')
        finally:
            if owner.poll() is None: owner.kill(); owner.wait(timeout=2)
            for fd in pidfds: os.close(fd)
            owner.stdin.close(); owner.stdout.close()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux supervisor group stop')
    def test_supervised_inert_engine_normal_and_stubborn_stop(self):
        for stubborn in (False, True):
            host = OwnedHost(); marker = self.base / ('engine-' + str(stubborn))
            code = 'import signal,time; from pathlib import Path; ' + ('signal.signal(signal.SIGTERM,signal.SIG_IGN); ' if stubborn else '') + 'Path(' + repr(str(marker)) + ').write_text("ready"); time.sleep(30)'
            try:
                host._spawn([sys.executable, '-c', code], {'PATH': '/usr/bin:/bin'})
                for _ in range(100):
                    if marker.exists(): break
                    time.sleep(0.02)
                self.assertTrue(marker.exists()); began = time.monotonic()
                host.stop(); self.assertLess(time.monotonic() - began, 4.5)
                self.assertIsNone(host.child); self.assertIsNone(host.lifetime_writer)
            finally:
                if host.child is not None: host.stop()


    def test_ui_monitor_and_shutdown_retry_with_inert_adapters(self):
        # Execute actual method bodies with no GTK import, Window, screen or event loop.
        import ast
        from types import SimpleNamespace
        source = Path(__file__).resolve().parents[1] / 'ui.py'
        tree = ast.parse(source.read_text())
        window = next(item for item in tree.body if isinstance(item, ast.ClassDef) and item.name == 'Window')
        methods = [item for item in window.body if isinstance(item, ast.FunctionDef) and item.name in ('monitor', 'shutdown_failed', 'controls', 'exported_package')]
        class Thread:
            def __init__(self, target, **_): self.target = target
            def start(self): self.target()
        namespace = dict(GLib=SimpleNamespace(idle_add=lambda callback, *args: callback(*args)),
                         threading=SimpleNamespace(Thread=Thread), Failure=Failure, shlex=shlex)
        exec(compile(ast.Module(body=methods, type_ignores=[]), str(source), 'exec'), namespace)
        for retained in (False, True):
            def alive(): raise Failure('exit') if not retained else OSError('synthetic')
            state = SimpleNamespace(generation=1, host=SimpleNamespace(alive=alive, child=object() if retained else None),
                                    status=SimpleNamespace(set_text=lambda text: None), controls=lambda: None)
            namespace['monitor'](state, 1)
            self.assertEqual(state.running, retained)
        calls = []
        state = SimpleNamespace(generation=2, host=SimpleNamespace(child=object()), status=SimpleNamespace(set_text=lambda text: None),
                                controls=lambda: None, monitor=lambda epoch: calls.append(epoch))
        namespace['shutdown_failed'](state)
        self.assertTrue(state.running); self.assertEqual(calls, [2])
        class Button:
            def set_sensitive(self, value): self.enabled = value
        state = SimpleNamespace(busy=True, running=False, closing=False, package=None, qr_bytes=None, operation_kind='download')
        for name in ('download_button','start_button','refresh_button','install_button','export_button','stop_button','web_button','save_button','name','admin_name','admin_password','cancel_button'):
            setattr(state, name, Button())
        namespace['controls'](state); self.assertTrue(state.cancel_button.enabled)
        state.operation_kind = None
        namespace['controls'](state); self.assertFalse(state.cancel_button.enabled)
        values = []
        state = SimpleNamespace(package='synthetic-private-download', install_command=SimpleNamespace(set_text=values.append),
                                status=SimpleNamespace(set_text=values.append))
        namespace['exported_package'](state, Path('/synthetic/public package.deb'))
        self.assertEqual(state.package, 'synthetic-private-download')
        self.assertEqual(len(values), 1, 'public export must not replace the private install command')
        self.assertIn('사본을 저장', values[0])

    def test_ui_reports_cleanup_failure_without_masking_primary_or_raw_os_text(self):
        import ast
        from types import SimpleNamespace
        source = Path(__file__).resolve().parents[1] / 'ui.py'
        tree = ast.parse(source.read_text())
        window = next(item for item in tree.body if isinstance(item, ast.ClassDef) and item.name == 'Window')
        method = next(item for item in window.body if isinstance(item, ast.FunctionDef) and item.name == 'run')
        class Thread:
            def __init__(self, target, **_): self.target = target
            def start(self): self.target()
        namespace = dict(GLib=SimpleNamespace(idle_add=lambda callback, *args: callback(*args)),
                         threading=SimpleNamespace(Thread=Thread), Failure=Failure)
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(source), 'exec'), namespace)
        for error in (Failure('export_destination'), Failure('collision'), OSError('synthetic private path and raw OS text')):
            with self.subTest(error=type(error).__name__, key=getattr(error, 'key', None)):
                error.cleanup_failed = True
                values = []; completed = Mock()
                state = SimpleNamespace(busy=False, closing=False, cancel=threading.Event(), controls=lambda: None,
                                        status=SimpleNamespace(set_text=values.append))
                def work(): raise error
                namespace['run'](state, work, completed)
                primary = str(error) if isinstance(error, Failure) else str(Failure('operation'))
                self.assertEqual(len(values), 1); self.assertTrue(values[0].startswith(primary))
                self.assertIn('임시 패키지 사본', values[0]); self.assertNotIn('synthetic', values[0])
                self.assertIn('.deskbridge-package-', values[0]); self.assertIn('숨김', values[0])
                completed.assert_not_called(); self.assertFalse(state.busy); self.assertIsNone(state.operation_kind)


if __name__ == '__main__': unittest.main()

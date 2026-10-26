# SPDX-License-Identifier: GPL-3.0-only
"""Actual Linux-kernel lifetime checks using only a freshly compiled inert host."""
import ctypes
import errno
import os
from pathlib import Path
import platform
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST))
import containment
from policy import Failure
from runtime import OwnedHost
import lifetime


class FilterChecks(unittest.TestCase):
    @staticmethod
    def verdict(number, flags=0, arch=0xc000003e):
        # Evaluate the exact classic BPF instruction stream on synthetic syscall
        # records, including ABI/64-bit argument cases unsafe to execute on Mac.
        data = {0: number, 4: arch, 16: flags & 0xffffffff, 20: flags >> 32}
        program, position, accumulator = containment.instructions(), 0, 0
        while True:
            code, yes, no, value = program[position]
            position += 1
            if code == 0x20: accumulator = data[value]
            elif code == 0x15: position += yes if accumulator == value else no
            elif code == 0x45: position += yes if accumulator & value else no
            elif code == 0x06: return value
            else: raise AssertionError('Unexpected filter opcode')

    def test_only_normal_pthread_clones_are_allowed(self):
        for flags in (0x003d0f00, 0x013d0f00):
            self.assertEqual(self.verdict(56, flags), 0x7fff0000)
        for flags in (signal.SIGCHLD, 0x100 | signal.SIGCHLD, 0x003d0f00 | 0x8000,
                      0x003d0f00 | 0x10000000, 0x1003d0f00, 0xffffffffffffffff):
            self.assertEqual(self.verdict(56, flags), 0x00050000 | errno.EPERM)

    def test_abi_and_escape_syscalls_are_refused(self):
        self.assertEqual(self.verdict(56, 0x003d0f00, 0x40000003), 0x80000000)
        self.assertEqual(self.verdict(0x40000000 | 56, 0x003d0f00), 0x80000000)
        for number in (57, 58, 109, 112, 272, 308):
            self.assertEqual(self.verdict(number), 0x00050000 | errno.EPERM)
        self.assertEqual(self.verdict(435), 0x00050000 | errno.ENOSYS)
        self.assertEqual(self.verdict(59), 0x7fff0000)  # exec inherits enforcement.

    def test_unsupported_architecture_refuses_before_kernel_call(self):
        with patch('containment.platform.machine', return_value='aarch64'), \
             patch('containment.ctypes.CDLL') as library, self.assertRaises(containment.ContainmentUnavailable):
            containment.install_containment()
        library.assert_not_called()

    def test_filter_install_failure_is_not_an_unrestricted_fallback(self):
        library = unittest.mock.Mock()
        library.prctl.side_effect = [0, -1]
        with patch('containment.sys.platform', 'linux'), patch('containment.platform.machine', return_value='x86_64'), \
             patch('containment.ctypes.CDLL', return_value=library), self.assertRaises(containment.ContainmentUnavailable):
            containment.install_containment()
        self.assertEqual(library.prctl.call_count, 2)

    def test_only_typed_preexec_refusal_reports_containment(self):
        for failure in (containment.ContainmentUnavailable('synthetic refusal'), RuntimeError('synthetic unexpected error')):
            with self.subTest(failure=type(failure).__name__):
                # Exercise the actual preexec callback and Popen's error
                # translation without forking or installing a filter on Mac.
                def spawn(*_args, **kwargs):
                    try: kwargs['preexec_fn']()
                    except Exception: raise subprocess.SubprocessError('Exception occurred in preexec_fn.') from None
                    raise AssertionError('Fixture must refuse before exec')
                with patch('lifetime.os.pipe2', return_value=(101, 102), create=True), \
                     patch('lifetime.os.close'), patch('lifetime.os.write') as write, \
                     patch('lifetime.os.read', return_value=b'C' if isinstance(failure, containment.ContainmentUnavailable) else b''), \
                     patch('lifetime.install_containment', side_effect=failure), \
                     patch('lifetime.subprocess.Popen', side_effect=spawn):
                    expected = containment.ContainmentUnavailable if isinstance(failure, containment.ContainmentUnavailable) else subprocess.SubprocessError
                    with self.assertRaises(expected): lifetime.spawn_restricted(['/synthetic/inert-host'])
                    if expected is containment.ContainmentUnavailable:
                        write.assert_called_once_with(102, b'C')
                    else:
                        write.assert_not_called()

    def test_exec_error_does_not_report_containment_refusal(self):
        with patch('lifetime.os.pipe2', return_value=(101, 102), create=True), \
             patch('lifetime.os.close'), patch('lifetime.os.write') as write, \
             patch('lifetime.os.read') as read, \
             patch('lifetime.subprocess.Popen', side_effect=FileNotFoundError('synthetic missing executable')):
            with self.assertRaises(FileNotFoundError): lifetime.spawn_restricted(['/synthetic/missing-host'])
        write.assert_not_called(); read.assert_not_called()

    def test_containment_guidance_is_fixed_and_actionable(self):
        guidance = str(Failure('containment'))
        self.assertEqual(guidance, Failure.messages['containment'])
        for term in ('Ubuntu 24.04 LTS amd64', 'seccomp', '관리자', '보안 제한을 해제하지 마세요'):
            self.assertIn(term, guidance)
        self.assertNotEqual(guidance, str(Failure('operation')))


@unittest.skipUnless(sys.platform == 'linux' and platform.machine() == 'x86_64', 'Linux amd64 seccomp kernel fixtures')
class NativeLifetimeChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='deskbridge-native-lifetime-')
        cls.base = Path(cls.temporary.name)
        cls.fixture = cls.base / 'inert-host'
        compiler = shutil.which('cc')
        if compiler is None:
            raise AssertionError('Linux lifetime acceptance requires cc and pthread headers')
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
                        str(Path(__file__).with_name('lifetime_fixture.c')), '-o', str(cls.fixture)],
                       check=True, capture_output=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.host = OwnedHost()
        self.marker = self.base / self.id().rsplit('.', 1)[-1]

    def tearDown(self):
        if self.host.child is not None: self.host.stop()

    def report(self):
        try:
            return dict(line.split('=', 1) for line in self.marker.read_text().splitlines())
        except (FileNotFoundError, ValueError):
            return {}

    def wait_report(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            report = self.report()
            if 'pid' in report and ('beat' in report or 'clone3' in report): return report
            time.sleep(0.01)
        self.fail('Native inert fixture did not become ready')

    def start(self, mode):
        self.host._spawn([str(self.fixture), mode, str(self.marker)], {'PATH': '/usr/bin:/bin'})
        return self.wait_report()

    def test_real_kernel_restricts_fork_escape_and_allows_native_pthread(self):
        report = self.start('probe')
        for name in ('fork', 'vfork', 'clone_process', 'clone_vm_process', 'clone_parent',
                     'clone_namespace', 'clone_high_word', 'setpgid', 'setsid', 'unshare', 'setns'):
            self.assertEqual(report[name], str(errno.EPERM), name)
        self.assertEqual(report['clone3'], str(errno.ENOSYS))
        self.assertEqual(report['pthread'], '1')
        self.assertEqual(int(report['pgid']), self.host.child.pid)

    def test_pinned_restart_topology_cannot_create_session_child(self):
        report = self.start('restart')
        self.assertEqual(report['restart'], str(errno.EPERM))
        self.assertEqual(report['pthread'], '1')
        self.assertTrue(self.host.alive())
        self.host.stop()
        self.assertIsNone(self.host.child)
        self.assertIsNone(self.host.lifetime_writer)

    def test_stop_ends_normal_and_stubborn_native_hosts(self):
        for mode in ('hold', 'stubborn'):
            with self.subTest(mode=mode):
                self.marker.unlink(missing_ok=True)
                report = self.start(mode)
                descriptor = os.pidfd_open(int(report['pid']))
                try:
                    began = time.monotonic()
                    self.host.stop()
                    self.assertLess(time.monotonic() - began, 4.5)
                    self.assertTrue(select.select([descriptor], [], [], 1)[0])
                    beat = self.marker.read_bytes()
                    time.sleep(0.06)
                    self.assertEqual(self.marker.read_bytes(), beat)
                finally:
                    os.close(descriptor)

    def test_owner_eof_ends_native_host_after_creator_thread_returns(self):
        code = '''import sys,threading
sys.path.insert(0,sys.argv[1])
from runtime import OwnedHost
host=OwnedHost()
worker=threading.Thread(target=lambda:host._spawn(sys.argv[2:],{'PATH':'/usr/bin:/bin'}))
worker.start();worker.join()
print(host.child.pid,flush=True)
sys.stdin.read()
'''
        owner = subprocess.Popen([sys.executable, '-I', '-c', code, str(HOST), str(self.fixture), 'stubborn', str(self.marker)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        descriptors = []
        try:
            self.assertTrue(select.select([owner.stdout], [], [], 5)[0])
            supervisor = int(owner.stdout.readline())
            report = self.wait_report()
            descriptors = [os.pidfd_open(pid) for pid in (supervisor, int(report['pid']))]
            self.assertFalse(select.select(descriptors, [], [], 0.1)[0])
            owner.kill(); owner.wait(timeout=2)
            for descriptor in descriptors:
                self.assertTrue(select.select([descriptor], [], [], 3)[0], 'Native host survived owner EOF')
            beat = self.marker.read_bytes()
            time.sleep(0.06)
            self.assertEqual(self.marker.read_bytes(), beat)
        finally:
            if owner.poll() is None: owner.kill(); owner.wait(timeout=2)
            for descriptor in descriptors: os.close(descriptor)
            owner.stdin.close(); owner.stdout.close()

    def test_kernel_enforcement_refusal_never_executes_host(self):
        code = '''import sys
sys.path.insert(0,sys.argv[1])
from runtime import OwnedHost
from policy import Failure
host=OwnedHost()
try:
    host._spawn(sys.argv[2:],{'PATH':'/usr/bin:/bin'})
except Failure as error:
    assert host.child is None and host.lifetime_writer is None
    assert error.key == 'containment'
    assert str(error) == Failure.messages['containment'] and 'seccomp' in str(error)
else:
    host.stop()
    raise SystemExit('Unrestricted fallback executed')
'''
        subprocess.run([str(self.fixture), 'forbid-install-exec', sys.executable, '-I', '-c', code,
                        str(HOST), str(self.fixture), 'hold', str(self.marker)], check=True, capture_output=True, timeout=5)
        self.assertFalse(self.marker.exists())

    def test_native_exec_failure_remains_neutral_and_reaps_owner(self):
        with self.assertRaises(Failure) as caught:
            self.host._spawn([str(self.base / 'fresh-missing-executable')], {'PATH': '/usr/bin:/bin'})
        self.assertEqual(caught.exception.key, 'operation')
        self.assertEqual(str(caught.exception), Failure.messages['operation'])
        self.assertIsNone(self.host.child)
        self.assertIsNone(self.host.lifetime_writer)


if __name__ == '__main__': unittest.main()

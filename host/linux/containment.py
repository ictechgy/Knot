# SPDX-License-Identifier: GPL-3.0-only
"""Inherited process-creation restrictions for the supported Linux amd64 host.

This is a lifetime boundary for the pinned host, not a general same-user sandbox.
The isolated, single-threaded lifetime supervisor installs it in its child before
exec. Ordinary native pthreads remain available; restart helpers and configured
subprocesses fail rather than escaping the supervisor's owned process group.
"""
import ctypes
import errno
import platform
import sys


class ContainmentUnavailable(OSError):
    pass


class SockFilter(ctypes.Structure):
    _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte),
                ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint32)]


class SockFprog(ctypes.Structure):
    _fields_ = [('len', ctypes.c_ushort), ('filter', ctypes.POINTER(SockFilter))]


def instructions():
    # Linux amd64 UAPI: audit arch, syscall numbers and struct seccomp_data
    # offsets. Reject alternate ABIs before interpreting these syscall numbers.
    load, equal, bit_set, ret = 0x20, 0x15, 0x45, 0x06
    kill, allow = 0x80000000, 0x7fff0000
    deny = 0x00050000 | errno.EPERM
    program = [(load, 0, 0, 4), (equal, 1, 0, 0xc000003e), (ret, 0, 0, kill),
               (load, 0, 0, 0), (bit_set, 0, 1, 0x40000000), (ret, 0, 0, kill)]
    # fork, vfork, setpgid, setsid, unshare and setns. In particular, a failed
    # fork cannot fall back to moving a descendant into another group/session.
    for number in (57, 58, 109, 112, 272, 308):
        program.extend([(equal, 0, 1, number), (ret, 0, 0, deny)])
    # Classic BPF cannot inspect clone_args through a pointer. glibc on Ubuntu
    # 24.04 falls back to clone on ENOSYS; a real pthread fixture verifies this.
    program.extend([(equal, 0, 1, 435), (ret, 0, 0, 0x00050000 | errno.ENOSYS)])
    # Only normal pthread clone flags (and optional CLONE_CHILD_SETTID) pass.
    # Both 32-bit halves are checked: namespace/parent/vfork flags and an exit
    # signal are never accepted. CLONE_THREAD keeps every task in one TGID.
    program.extend([(equal, 0, 8, 56),
                    (load, 0, 0, 20), (equal, 1, 0, 0), (ret, 0, 0, deny),
                    (load, 0, 0, 16), (equal, 2, 0, 0x003d0f00),
                    (equal, 1, 0, 0x013d0f00), (ret, 0, 0, deny),
                    (ret, 0, 0, allow), (ret, 0, 0, allow)])
    return program


def install_containment():
    """Fail closed before exec if inherited kernel enforcement is unavailable."""
    if sys.platform != 'linux' or platform.machine() != 'x86_64' or ctypes.sizeof(ctypes.c_void_p) != 8:
        raise ContainmentUnavailable(errno.ENOTSUP, 'Linux amd64 containment required')
    library = ctypes.CDLL(None, use_errno=True)
    prctl = library.prctl
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    values = instructions()
    filters = (SockFilter * len(values))(*(SockFilter(*value) for value in values))
    program = SockFprog(len(values), filters)
    # no_new_privs also suppresses installed file capabilities. There is no
    # setpriv-only or unrestricted fallback when installing the filter fails.
    if prctl(38, 1, 0, 0, 0) != 0 or prctl(22, 2, ctypes.addressof(program), 0, 0) != 0:
        raise ContainmentUnavailable(ctypes.get_errno(), 'Kernel containment unavailable')

# SPDX-License-Identifier: GPL-3.0-only
"""Explicit host actions; tests inject fresh paths and inert children, never run Sunshine."""
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import http.client
import itertools
import json
import os
from pathlib import Path
import platform
import select
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from policy import Failure, allowed_download_url, arguments, child_environment, select_addresses, validate_session, web_credentials, validate_web_credentials


@contextlib.contextmanager
def ordinary_read(path, maximum, uid=None, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_size > maximum or (uid is not None and s.st_uid != uid):
            raise Failure('storage')
        if private and s.st_mode & 0o077:
            raise Failure('storage')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            yield stream
    finally:
        os.close(fd)


def digest_file(path, maximum, uid=None, private=False):
    with ordinary_read(path, maximum, uid, private) as f:
        h, count = hashlib.sha256(), 0
        while data := f.read(65536):
            count += len(data)
            if count > maximum:
                raise Failure('storage')
            h.update(data)
        return count, h.hexdigest()


def trusted_program(path):
    """System symlinks are accepted only when every link/target is root-controlled."""
    p = Path(path)
    if not p.is_absolute():
        raise Failure('install')
    resolved, pending, links = Path(p.anchor), list(p.parts[1:]), 0
    try:
        s = resolved.lstat()
        if s.st_uid != 0 or not stat.S_ISDIR(s.st_mode) or s.st_mode & 0o022:
            raise Failure('install')
        # Walk each hop before resolving it. Checking only the final realpath
        # could miss a user-controlled link in an otherwise trusted chain.
        while pending:
            part = pending.pop(0)
            if part == '..':
                resolved = resolved.parent
                continue
            item = resolved / part
            s = item.lstat()
            if s.st_uid != 0 or (not stat.S_ISLNK(s.st_mode) and s.st_mode & 0o022):
                raise Failure('install')
            if stat.S_ISLNK(s.st_mode):
                links += 1
                if links > 40: raise Failure('install')
                target = Path(os.readlink(item))
                if target.is_absolute():
                    resolved = Path(target.anchor)
                    pending = list(target.parts[1:]) + pending
                else:
                    pending = list(target.parts) + pending
            else:
                if pending and not stat.S_ISDIR(s.st_mode): raise Failure('install')
                resolved = item
    except OSError:
        raise Failure('install') from None
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise Failure('install')
    return str(resolved)


def resolve_pinned_binary(pin):
    program = trusted_program(pin['binary'])
    try:
        installed_digest = digest_file(program, 64 * 1024 * 1024, 0)[1]
    except (OSError, Failure):
        raise Failure('install') from None
    if installed_digest != pin['binarySHA256']:
        raise Failure('install')
    return program


class Store:
    MARKER = b'DeskBridge Linux host private storage v1\n'
    def __init__(self, root):
        self.root, self.lock = Path(root), None
        self.root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for p in (self.root.parent, *self.root.parent.parents):
            s = p.lstat()
            # System-owned ancestors and the user's home are allowed; writable shared paths are not.
            if stat.S_ISLNK(s.st_mode) or not stat.S_ISDIR(s.st_mode) or s.st_uid not in (0, os.getuid()) or (s.st_mode & 0o022 and not (s.st_uid == 0 and s.st_mode & stat.S_ISVTX)):
                raise Failure('storage')
        new = False
        try:
            self.root.mkdir(mode=0o700); new = True
        except FileExistsError:
            pass
        self._directory(self.root)
        if new:
            self.write_new(self.root / '.owner', self.MARKER)
        try:
            with ordinary_read(self.root / '.owner', 128, os.getuid(), True) as f:
                if f.read(129) != self.MARKER:
                    raise Failure('storage')
        except OSError:
            raise Failure('storage') from None
        fd = os.open(self.root / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
        try:
            s = os.fstat(fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_nlink != 1 or s.st_mode & 0o077:
                raise Failure('storage')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(fd); raise Failure('storage') from None
        self.lock = fd
        try:
            for name in ('credentials', 'xdg', 'downloads'):
                p = self.root / name
                p.mkdir(mode=0o700, exist_ok=True); self._directory(p)
            self.validate()
        except BaseException:
            self.close(); raise

    @staticmethod
    def _directory(p):
        s = p.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
            raise Failure('storage')

    def validate(self):
        count = 0
        for directory, dirs, files in os.walk(self.root, followlinks=False):
            self._directory(Path(directory))
            for name in dirs:
                self._directory(Path(directory) / name)
            for name in files:
                count += 1
                if count > 256:
                    raise Failure('storage')
                if Path(directory) / name == self.root / 'credentials/cacert.pem':
                    self._tighten_certificate(Path(directory) / name)
                with ordinary_read(Path(directory) / name, 16 * 1024 * 1024, os.getuid(), True):
                    pass

    @staticmethod
    def _tighten_certificate(path):
        # Pinned upstream chmods its public certificate to0644. Only this known
        # owned regular inode may be tightened, never arbitrary files/keys/links.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            value = os.fstat(fd)
            if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or value.st_nlink != 1 or stat.S_IMODE(value.st_mode) not in (0o600, 0o644):
                raise Failure('storage')
            os.fchmod(fd, 0o600)
        finally: os.close(fd)

    @staticmethod
    def write_new(path, data):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())

    def prepare(self):
        self.validate()
        config = self.root / 'sunshine.conf'
        if not config.exists():
            self.write_new(config, b'# DeskBridge private host configuration\n')
        apps = self.root / 'apps.json'
        # Sunshine's local web UI owns later app-list edits. Seed only a missing
        # file; restarting this wrapper must not discard the user's entries.
        if not os.path.lexists(apps):
            data = b'{"env":{},"apps":[{"name":"Desktop","cmd":""}]}\n'
            fd, temporary = tempfile.mkstemp(prefix='.apps-', dir=self.root)
            try:
                with os.fdopen(fd, 'wb') as f:
                    f.write(data); f.flush(); os.fsync(f.fileno())
                publish_new(temporary, apps)
            finally:
                if os.path.lexists(temporary): os.unlink(temporary)
        # A private directory is valid elsewhere in the tree, but Sunshine's
        # file_apps argument must name an owned ordinary file before launch.
        with ordinary_read(apps, 16 * 1024 * 1024, os.getuid(), True):
            pass
        self.validate()

    def close(self):
        if self.lock is not None:
            os.close(self.lock); self.lock = None

    def prepare_web_credentials(self, username, password):
        path = self.root / 'web-credentials.json'
        if os.path.lexists(path):
            with ordinary_read(path, 8192, os.getuid(), True) as source:
                validate_web_credentials(source.read(8193))
            return  # Never overwrite or silently reset an existing administrator.
        data = web_credentials(username, password)
        fd, temporary = tempfile.mkstemp(prefix='.web-credentials-', dir=self.root)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            publish_new(temporary, path)
        finally:
            if os.path.lexists(temporary): os.unlink(temporary)


class StrictRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_download_url(newurl):
            raise Failure('download')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def publish_new(source, destination):
    """Atomic no-replace rename; a crash never leaves a two-link private inode."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'linux':
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        args = (-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    elif sys.platform == 'darwin':  # Offline source fixtures on the development Mac.
        function = library.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        args = (os.fsencode(source), os.fsencode(destination), 4)
    else:
        raise Failure('storage')
    function.restype = ctypes.c_int
    if function(*args) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


class TransferControl:
    """Bound DNS/TCP/TLS setup and interrupt active I/O on cancel/deadline."""
    # getaddrinfo can block in libc/NSS beyond a socket timeout. Isolate it in a
    # single child which is always reaped before the transfer returns; never
    # abandon a resolver thread on cancellation. Only numeric addresses cross
    # this pipe, with fixed output/address bounds and an isolated interpreter.
    RESOLVER = '''import json,socket,sys
rows=socket.getaddrinfo(sys.argv[1],int(sys.argv[2]),type=socket.SOCK_STREAM)
if not 0 < len(rows) <= 64: raise SystemExit(1)
data=json.dumps([[family,kind,protocol,address] for family,kind,protocol,_,address in rows]).encode('ascii')
if len(data) > 16384: raise SystemExit(1)
sys.stdout.buffer.write(data)
'''
    CONNECT_ATTEMPT_SECONDS = 2.5

    def __init__(self, cancel, seconds=600):
        self.cancel, self.deadline = cancel, time.monotonic() + seconds
        self.done, self.lock, self.sockets = threading.Event(), threading.Lock(), []
        self.aborted = None
        self.worker = threading.Thread(target=self._watch, daemon=True)
        self.worker.start()

    def attach(self, sock):
        with self.lock:
            self.sockets.append(sock)
            aborted = self.aborted
        if aborted:
            self._shutdown(sock)
            raise Failure(aborted)

    @staticmethod
    def _shutdown(sock):
        with contextlib.suppress(OSError): sock.shutdown(socket.SHUT_RDWR)

    def _watch(self):
        while not self.done.wait(0.05):
            reason = 'cancel' if self.cancel.is_set() else 'download' if time.monotonic() >= self.deadline else None
            if reason:
                with self.lock:
                    self.aborted = reason
                    sockets = list(self.sockets)
                for sock in sockets: self._shutdown(sock)
                return

    def check(self):
        if self.cancel.is_set(): raise Failure('cancel')
        if self.aborted or time.monotonic() >= self.deadline: raise Failure(self.aborted or 'download')

    def close(self):
        self.done.set(); self.worker.join(timeout=1)

    def _remaining(self, expires):
        self.check()
        remaining = min(expires, self.deadline) - time.monotonic()
        if remaining <= 0: raise Failure('download')
        return remaining

    def _resolve(self, host, port, expires):
        self._remaining(expires)
        child = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-B', '-c', self.RESOLVER, host, str(port)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, close_fds=True)
        try:
            while True:
                try:
                    output, _ = child.communicate(timeout=min(0.05, self._remaining(expires)))
                    break
                except subprocess.TimeoutExpired:
                    pass
            self._remaining(expires)
            if child.returncode != 0 or len(output) > 16384: raise Failure('download')
            rows = json.loads(output)
            if not isinstance(rows, list) or not 0 < len(rows) <= 64: raise Failure('download')
            for family, kind, protocol, address in rows:
                if (family not in (socket.AF_INET, socket.AF_INET6) or kind != socket.SOCK_STREAM
                        or protocol not in (0, socket.IPPROTO_TCP) or len(address) != (2 if family == socket.AF_INET else 4)
                        or address[1] != port):
                    raise Failure('download')
                socket.inet_pton(family, address[0])  # Numeric only; connect must not trigger DNS again.
            return rows
        finally:
            if child.poll() is None:
                child.kill()
            try:
                child.wait(timeout=1)
            finally:
                child.stdout.close()

    def _ready(self, sock, expires, writing, attempt_expires=None):
        while True:
            wait = min(0.05, self._remaining(expires))
            if attempt_expires is not None:
                attempt_remaining = attempt_expires - time.monotonic()
                if attempt_remaining <= 0: raise TimeoutError('TCP candidate timed out')
                wait = min(wait, attempt_remaining)
            try:
                readable, writable, _ = select.select([] if writing else [sock], [sock] if writing else [], [], wait)
            except InterruptedError:
                continue
            self._remaining(expires)
            if readable or writable: return

    def _connect_tcp(self, host, port, expires, source_address):
        rows = self._resolve(host, port, expires)
        if not rows: raise Failure('download')
        # Preserve the resolver's first-family preference, then alternate
        # families so several unreachable IPv6 rows cannot starve IPv4.
        first = [row for row in rows if row[0] == rows[0][0]]
        other = [row for row in rows if row[0] != rows[0][0]]
        ordered = [row for pair in itertools.zip_longest(first, other) for row in pair if row is not None]
        deferred = []
        # Keep half of a multi-address setup budget for one retry pass, including
        # when the final first-pass route blackholes or the resolver has many rows.
        first_pass_seconds = min(self.CONNECT_ATTEMPT_SECONDS, self._remaining(expires) / (2 * len(ordered)))
        # Retries remain TCP setup only and share the original DNS/TCP/TLS deadline.
        for candidates, retrying in ((ordered, False), (deferred, True)):
            for index, (family, kind, protocol, address) in enumerate(candidates):
                self._remaining(expires)
                sock = None
                try:
                    sock = socket.socket(family, kind, protocol)
                    self.attach(sock)
                    sock.setblocking(False)
                    if source_address: sock.bind(source_address)
                    try:
                        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    except OSError as error:
                        if error.errno != errno.ENOPROTOOPT: raise
                    status = sock.connect_ex(tuple(address))
                    if status not in (0, errno.EISCONN):
                        if status not in (errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY, errno.EINTR):
                            raise OSError(status, os.strerror(status))
                        # A single route retains its full budget. Deferred routes
                        # share remaining time fairly; prompt rejects release their
                        # unused share to later routes, with no further retry pass.
                        attempt_expires = expires
                        if len(ordered) > 1:
                            seconds = self._remaining(expires) / (len(candidates) - index) if retrying else first_pass_seconds
                            attempt_expires = min(expires, time.monotonic() + seconds)
                        try:
                            self._ready(sock, expires, writing=True, attempt_expires=attempt_expires)
                        except TimeoutError:
                            if not retrying and attempt_expires < min(expires, self.deadline):
                                deferred.append((family, kind, protocol, address))
                            raise
                        status = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                        if status: raise OSError(status, os.strerror(status))
                    self._remaining(expires)
                    return sock
                except OSError:
                    if sock is not None: sock.close()
                    self._remaining(expires)
                except BaseException:
                    if sock is not None: sock.close()
                    raise
        raise Failure('download')

    def connect(self, host, port, context, timeout, source_address=None):
        if timeout is socket._GLOBAL_DEFAULT_TIMEOUT: timeout = socket.getdefaulttimeout()
        expires = self.deadline if timeout is None else min(self.deadline, time.monotonic() + timeout)
        raw = self._connect_tcp(host, port, expires, source_address)
        wrapped = None
        try:
            # Keep the logical hostname for SNI and certificate verification.
            # Handshake only after the SSL socket is registered and nonblocking.
            wrapped = context.wrap_socket(raw, server_hostname=host, do_handshake_on_connect=False)
            self.attach(wrapped)
            while True:
                self._remaining(expires)
                try:
                    wrapped.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    self._ready(wrapped, expires, writing=False)
                except ssl.SSLWantWriteError:
                    self._ready(wrapped, expires, writing=True)
            self._remaining(expires)
            wrapped.settimeout(timeout)
            return wrapped
        except BaseException:
            (wrapped if wrapped is not None else raw).close()
            raise

    def handler(self):
        control = self
        class Connection(http.client.HTTPSConnection):
            def connect(self):
                if self._tunnel_host: raise Failure('download')
                self.sock = control.connect(self.host, self.port, self._context, self.timeout, self.source_address)
        class Handler(urllib.request.HTTPSHandler):
            def https_open(self, request):
                return self.do_open(Connection, request, context=self._context)
        return Handler()


def download(pin, store, cancel, progress=lambda value: None, opener=None, control=None):
    if not allowed_download_url(pin['url']):
        raise Failure('download')
    store.validate()
    destination = store.root / 'downloads' / ('sunshine-' + pin['version'] + '-ubuntu24.04-amd64.deb')
    if os.path.lexists(destination):
        try:
            if digest_file(destination, pin['bytes'], os.getuid(), True) == (pin['bytes'], pin['sha256']):
                return destination
        except (OSError, Failure): pass
        raise Failure('download_collision')
    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=store.root / 'downloads')
    request = urllib.request.Request(pin['url'], headers={'User-Agent': 'Knot-Linux/1', 'Accept': 'application/octet-stream'})
    control = control or TransferControl(cancel)
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), StrictRedirect(), control.handler())
    received, h = 0, hashlib.sha256()
    try:
        with os.fdopen(fd, 'wb') as out, opener.open(request, timeout=20) as response:
            if response.status != 200 or not allowed_download_url(response.url):
                raise Failure('download')
            length = response.headers.get('Content-Length')
            if length is not None and int(length) != pin['bytes']:
                raise Failure('download')
            while True:
                control.check()
                data = response.read1(65536)
                if not data: break
                received += len(data)
                if received > pin['bytes']: raise Failure('download')
                out.write(data); h.update(data); progress(received / pin['bytes'])
            control.check()
            if received != pin['bytes'] or h.hexdigest() != pin['sha256']:
                raise Failure('download')
            out.flush(); os.fsync(out.fileno())
        publish_new(temporary, destination)
        return destination
    except Failure:
        raise
    except Exception:
        control.check()
        raise Failure('download') from None
    finally:
        control.close()
        if os.path.lexists(temporary): os.unlink(temporary)


def metadata_command(argv):
    trusted_program(argv[0])
    # Small metadata commands only. No service logs or existing Sunshine configuration.
    with tempfile.TemporaryFile() as output:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.DEVNULL,
                                 env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, close_fds=True)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            try: child.wait(timeout=1)
            except subprocess.TimeoutExpired: pass
            raise Failure('operation') from None
        if child.returncode != 0 or output.tell() > 262144:
            raise Failure('operation')
        output.seek(0); return output.read(262145)


def addresses():
    return select_addresses(metadata_command(['/usr/sbin/ip', '-json', '-4', 'address', 'show']))


def preflight(pin, env=None):
    env = dict(os.environ if env is None else env)
    validate_session(platform.freedesktop_os_release(), platform.machine(), os.getuid(), env)
    program = resolve_pinned_binary(pin)
    version = metadata_command(['/usr/bin/dpkg-query', '-W', '-f=${Version}', 'sunshine']).decode('ascii')
    if version != pin['packageVersion']:
        raise Failure('install')
    if not os.access('/dev/uinput', os.R_OK | os.W_OK):
        raise Failure('input')
    expected_commands = {b'sunshine', os.fsencode(Path(program).name)[:15]}
    # Detect any existing Sunshine without reading argv/environment/logs/configuration.
    for index, entry in enumerate(Path('/proc').iterdir()):
        if index > 32768: raise Failure('existing')
        if entry.name.isdecimal():
            try:
                with (entry / 'comm').open('rb') as f:
                    if f.read(128).strip() in expected_commands: raise Failure('existing')
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                pass
    ports = []
    try:
        for kind, values in ((socket.SOCK_STREAM, (47984, 47989, 47990, 48010)),
                             (socket.SOCK_DGRAM, (47998, 47999, 48000, 48002, 48010))):
            for port in values:
                s = socket.socket(socket.AF_INET, kind); ports.append(s)
                # Sunshine's TCP servers use reuse_address. Still reject every live
                # listener; UDP deliberately stays exclusive (reuse would hide it).
                if kind == socket.SOCK_STREAM: s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind(('0.0.0.0', port))
    except OSError:
        raise Failure('existing') from None
    finally:
        for s in ports: s.close()
    return env, program


class OwnedHost:
    """Hold the unreaped original PID while signaling its group; never signal after reap."""
    def __init__(self):
        self.child, self.lock = None, threading.RLock()
        self.lifetime_writer = None

    def start(self, pin, store, name, username='', password=''):
        with self.lock:
            if self.child is not None: raise Failure('existing')
            host_arguments = arguments(store.root, name)
            env, program = preflight(pin)
            store.prepare()
            store.prepare_web_credentials(username, password)
            argv = [program] + host_arguments
            self._spawn(argv, child_environment(env, store.root))

    def _spawn(self, argv, env):
        reader, writer = os.pipe2(os.O_CLOEXEC)
        ready_reader = ready_writer = None
        try:
            ready_reader, ready_writer = os.pipe2(os.O_CLOEXEC)
            supervisor = str(Path(__file__).with_name('lifetime.py'))
            self.child = subprocess.Popen(['/usr/bin/python3', '-I', supervisor, str(reader), str(ready_writer), *argv], env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True, pass_fds=(reader, ready_writer), umask=0o077)
            self.lifetime_writer = writer
            # A spawned supervisor is not a started host: require confirmation
            # of kernel containment and the direct child's successful exec.
            os.close(ready_writer); ready_writer = None
            status = os.read(ready_reader, 1) if select.select([ready_reader], [], [], 5)[0] else b''
            if status == b'C':
                raise Failure('containment')
            if status != b'R':
                raise Failure('operation')
        except BaseException:
            if self.child is not None:
                self._close_lifetime()
                self._finish()
            else:
                os.close(writer)
            raise
        finally:
            os.close(reader)
            if ready_reader is not None: os.close(ready_reader)
            if ready_writer is not None: os.close(ready_writer)

    def _close_lifetime(self):
        if self.lifetime_writer is not None:
            os.close(self.lifetime_writer); self.lifetime_writer = None

    def _exited(self):
        # WNOWAIT observes without reaping, retaining the PID's group identity.
        try:
            return os.waitid(os.P_PID, self.child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        except ChildProcessError:
            self.child = None
            self._close_lifetime()
            raise Failure('exit') from None

    def alive(self):
        with self.lock:
            if self.child is None: return False
            if not self._exited(): return True
            self._finish(); return False

    def _signal(self, sig):
        self._exited()  # Reaped elsewhere means ownership was lost: never signal a reused PID.
        try: os.killpg(self.child.pid, sig)
        except ProcessLookupError: pass

    def _finish(self):
        self._signal(signal.SIGKILL)
        self.child.wait(timeout=1)  # On timeout retain ownership and the window for retry.
        self.child = None
        self._close_lifetime()

    def stop(self):
        with self.lock:
            if self.child is None: return
            self._signal(signal.SIGTERM)
            deadline = time.monotonic() + 3
            while not self._exited() and time.monotonic() < deadline:
                time.sleep(0.05)
            self._finish()


def open_installer(pin, package):
    if digest_file(package, pin['bytes'], os.getuid(), True) != (pin['bytes'], pin['sha256']):
        raise Failure('download')
    trusted_program('/usr/bin/gio')
    # Explicit user action opens the standard desktop package handler. It owns authentication.
    subprocess.run(['/usr/bin/gio', 'open', str(package)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=10, check=True, close_fds=True)


def save_package(pin, package, destination):
    """Export a verified copy; never overwrite, follow a leaf link, or run a shell."""
    if digest_file(package, pin['bytes'], os.getuid(), True) != (pin['bytes'], pin['sha256']):
        raise Failure('download')
    destination = Path(destination)
    temporary = None
    primary = None
    try:
        try:
            with ordinary_read(package, pin['bytes'], os.getuid(), True) as source:
                try:
                    fd, temporary = tempfile.mkstemp(prefix='.deskbridge-package-', dir=destination.parent)
                    with os.fdopen(fd, 'wb') as out:
                        while True:
                            try: data = source.read(65536)
                            except OSError: raise Failure('download') from None
                            if not data: break
                            out.write(data)
                        out.flush(); os.fsync(out.fileno())
                    # The public copy is not the privileged installation source.
                    try: verified = digest_file(temporary, pin['bytes'], os.getuid())
                    except (OSError, Failure): raise Failure('export_destination') from None
                    if verified != (pin['bytes'], pin['sha256']): raise Failure('export_destination')
                    publish_new(temporary, destination)
                    temporary = None  # Rename consumed it; a recreated name belongs to someone else.
                    return destination
                except FileExistsError:
                    raise Failure('collision') from None
                except OSError:
                    raise Failure('export_destination') from None
        except OSError:
            raise Failure('download') from None
    except BaseException as error:
        primary = error
        raise
    finally:
        if temporary is not None and os.path.lexists(temporary):
            try: os.unlink(temporary)
            except OSError:
                if primary is None:
                    primary = Failure('export_destination')
                    primary.cleanup_failed = True
                    raise primary from None
                # Preserve the authored primary failure, recording cleanup failure
                # without embedding paths or raw OS text into user guidance.
                primary.cleanup_failed = True


def cleanup_owned(host, store, finished, failed):
    """Quit after confirmed stop/ownership loss; retain the window on other errors."""
    try:
        host.stop()
    except Failure as error:
        if error.key != 'exit' or host.child is not None:
            failed(); return
        # waitid confirmed a lost child and revoked ownership before raising.
    except Exception:
        failed(); return  # Keep the owned child/store/window available for explicit retry.
    try:
        if store: store.close()
    finally:
        finished()

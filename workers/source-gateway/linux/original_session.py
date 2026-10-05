"""Portable one-shot original-transfer session. Not a Linux/SQL authority.

Only the four captured child modules execute in the child. The caller owns the
spool producer and any partial bytes. A wait here identifies this Popen child,
not a cgroup, remote writer, source server or an admitted executor lifetime.
"""
from dataclasses import dataclass
import fcntl
import hashlib
import os
from pathlib import Path
import selectors
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile

from protocol import Refused, canonical, clock, clock_name, clock_ns, decode, digest, require
from original_transport import checked_result, validate_input
from identity import process_identity

FILES = ('protocol.py', 'transport.py', 'original_transport.py', 'original_child.py')
MAX_SOURCE = 131_072
MAX_SOURCES = 262_144
MAX_INPUT = 24_576
MAX_RESULT = 4_096
MAX_STDERR = 4_096
MAX_BINARY = 5_242_880
CHUNK = 65_536
STARTUP_SECONDS = 5
JOIN_SECONDS = .5

# This loader is an owned source string, included in the immutable recipe. -I
# and -S remove workspace/site imports; project modules resolve only these
# already-read bytes. No metadata parser, Deno or mutable workspace is loaded.
BOOTSTRAP = '''import hashlib,importlib.abc,importlib.util,json,os,pathlib,stat,sys,types
def load():
 root=pathlib.Path(sys.argv[1]); expected=sys.argv[2]
 def read(name,limit):
  fd=os.open(root/name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
  try:
   info=os.fstat(fd); assert stat.S_ISREG(info.st_mode) and info.st_size<=limit
   raw=b''
   while len(raw)<=limit:
    part=os.read(fd,min(65536,limit+1-len(raw)))
    if not part: break
    raw+=part
   assert len(raw)==info.st_size and len(raw)<=limit
   return raw
  finally: os.close(fd)
 manifest_raw=read('bundle.json',16384); assert hashlib.sha256(manifest_raw).hexdigest()==expected
 manifest=json.loads(manifest_raw)
 assert set(manifest['files'])=={'protocol.py','transport.py','original_transport.py','original_child.py'}
 raw={name:read(name,131072) for name in manifest['files']}
 assert all(len(data)==manifest['files'][name]['bytes'] and hashlib.sha256(data).hexdigest()==manifest['files'][name]['sha256'] for name,data in raw.items())
 context=types.ModuleType('frozen_context'); context.bundle_sha256=expected
 context.data_mode=sys.argv[3]; context.data_fd=int(sys.argv[4]); context.loaded={}
 sys.modules['frozen_context']=context
 class Loader(importlib.abc.MetaPathFinder,importlib.abc.Loader):
  def find_spec(self,name,path=None,target=None):
   return importlib.util.spec_from_loader(name,self) if name+'.py' in raw else None
  def create_module(self,spec): return None
  def exec_module(self,module):
   name=module.__name__+'.py'; data=raw[name]; module.__file__=str(root/name)
   context.loaded[name]=hashlib.sha256(data).hexdigest()
   exec(compile(data,str(root/name),'exec'),module.__dict__)
 sys.meta_path.insert(0,Loader())
 import original_child
 return original_child.main()
try: result=load()
except Exception: result=90
raise SystemExit(result)
'''


def _read(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, 'bundle_limit')
        raw = bytearray()
        while len(raw) <= maximum:
            part = os.read(fd, min(CHUNK, maximum + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(fd)
        require(len(raw) == before.st_size <= maximum
                and (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'bundle_changed')
        return bytes(raw)
    finally:
        os.close(fd)


def _runtime_hash(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 268_435_456, 'runtime_limit')
        hashed, count = hashlib.sha256(), 0
        while count <= info.st_size:
            part = os.read(fd, min(CHUNK, info.st_size + 1 - count))
            if not part:
                break
            count += len(part)
            hashed.update(part)
        after = os.fstat(fd)
        require(count == info.st_size
                and (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'runtime_changed')
        return hashed.hexdigest()
    finally:
        os.close(fd)


@dataclass(frozen=True)
class FrozenTransferBundle:
    root: Path
    manifest_bytes: bytes

    @property
    def sha256(self):
        return digest(self.manifest_bytes)

    @property
    def manifest(self):
        return decode(self.manifest_bytes)

    def command(self, mode, data_fd):
        require(mode in ('input', 'output') and type(data_fd) is int and data_fd > 2, 'invalid_descriptor')
        manifest = self.manifest
        require(_read(self.root / 'bundle.json', 16_384) == self.manifest_bytes, 'bundle_changed')
        bootstrap = _read(self.root / 'bootstrap.py', 16_384)
        require(digest(bootstrap) == manifest['bootstrap_sha256']
                and _runtime_hash(manifest['python_path']) == manifest['python_sha256'], 'runtime_changed')
        for name, entry in manifest['files'].items():
            raw = _read(self.root / name, MAX_SOURCE)
            require(len(raw) == entry['bytes'] and digest(raw) == entry['sha256'], 'bundle_changed')
        return [manifest['python_path'], '-I', '-S', '-B', '-c', bootstrap.decode('utf8'),
                str(self.root), self.sha256, mode, str(data_fd)]


def capture_bundle(parent):
    """Capture a new private bundle; caller retains it until all children join.

    The runtime digest identifies the Python executable, not all OS/stdlib/TLS
    dependencies. This portable fixture recipe is not host admission evidence.
    """
    here = Path(__file__).resolve().parent
    captured = {name: _read((here.parent if name in ('protocol.py', 'transport.py') else here) / name,
                            MAX_SOURCE) for name in FILES}
    require(sum(map(len, captured.values())) + len(BOOTSTRAP.encode()) <= MAX_SOURCES, 'bundle_limit')
    runtime = str(Path(sys.executable).resolve())
    manifest = {'format': 'original-transfer-bundle-v1', 'local_fixture_only': True,
                'files': {name: {'bytes': len(raw), 'sha256': digest(raw)} for name, raw in captured.items()},
                'bootstrap_sha256': digest(BOOTSTRAP.encode()), 'python_path': runtime,
                'python_sha256': _runtime_hash(runtime), 'python_version': sys.version,
                'tls_version': ssl.OPENSSL_VERSION, 'shared_clock': clock_name(),
                'source_bytes': sum(map(len, captured.values())) + len(BOOTSTRAP.encode())}
    manifest_raw = canonical(manifest)
    require(len(manifest_raw) <= 16_384, 'bundle_limit')
    root = Path(tempfile.mkdtemp(prefix='original-transfer-', dir=parent)).resolve()
    try:
        os.chmod(root, 0o700)
        for name, raw in {**captured, 'bootstrap.py': BOOTSTRAP.encode(), 'bundle.json': manifest_raw}.items():
            fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            try:
                offset = 0
                while offset < len(raw):
                    sent = os.write(fd, raw[offset:offset + CHUNK])
                    require(sent > 0, 'bundle_write_failed')
                    offset += sent
                os.fsync(fd)
            finally:
                os.close(fd)
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        os.chmod(root, 0o500)
        return FrozenTransferBundle(root, manifest_raw)
    except BaseException:
        os.chmod(root, 0o700)
        shutil.rmtree(root)
        raise


class SessionStartError(Refused):
    """Retains the exact Popen owner when setup/READY cannot safely complete."""
    def __init__(self, session, code):
        super().__init__(code)
        self.session = session


class OriginalSession:
    """Single-caller control lane; only a cancellation Event is shared.

    Construct/READY is not permission. go() consumes permission before its first
    write. finish() never seals/deletes the caller's producer, retries transport,
    or turns elapsed time/EOF into retirement. Keep this object if unresolved.
    Deadlines are checked around append; this is not an OS bound on arbitrary
    caller callbacks or filesystem latency.
    """
    def __init__(self, bundle, value, *, input_fd=None):
        self.bundle = bundle
        self._value = validate_input(value)
        self._input = canonical(self._value)
        require(len(self._input) + 1 <= MAX_INPUT, 'input_limit')
        self.input_sha256 = digest(self._input)
        self.child, self._binary = None, None
        self.identity = None
        self.sent_go, self._deadline_ns = False, None
        self._fatal, self._kill_sent, self._report = None, False, None
        self._ipc_uncertain = False
        self._output, self._stderr = bytearray(), bytearray()
        self._binary_count, self._binary_hash = 0, hashlib.sha256()
        self._binary_eof = self._value['request']['kind'] == 'original_upload'
        self._control_eof, self._error_eof = False, False
        self._ready = False
        child_fd = None
        try:
            if self._value['request']['kind'] == 'original_upload':
                require(type(input_fd) is int and input_fd > 2, 'invalid_descriptor')
                info = os.fstat(input_fd)
                require(stat.S_ISREG(info.st_mode) and fcntl.fcntl(input_fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
                        and info.st_size == self._value['request']['candidate_bytes'], 'invalid_descriptor')
                child_fd, mode = os.dup(input_fd), 'input'
            else:
                require(input_fd is None, 'invalid_descriptor')
                self._binary, child_fd = os.pipe()
                os.set_blocking(self._binary, False)
                os.set_blocking(child_fd, False)
                mode = 'output'
            argv = bundle.command(mode, child_fd)
            self.child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          close_fds=True, pass_fds=(child_fd,), start_new_session=True,
                                          cwd=bundle.root, env={'LC_ALL': 'C'}, bufsize=0)
            closing, child_fd = child_fd, None
            try:
                os.close(closing)
            except BaseException:
                self._ipc_uncertain = True
                raise
            for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
                os.set_blocking(pipe.fileno(), False)
            self._handshake()
        except BaseException:
            if child_fd is not None:
                closing, child_fd = child_fd, None
                try:
                    os.close(closing)
                except BaseException:
                    self._ipc_uncertain = True
            if self.child is not None:
                try:
                    self._fail('handshake_failed')
                    code = self._collect(None, JOIN_SECONDS)
                    if code is not None:
                        self._close_pipes()
                except BaseException:
                    pass  # Retain this exact owner; never fabricate a join.
                raise SessionStartError(self, 'original_session_start_failed') from None
            self._close_binary()
            raise

    @property
    def value(self):
        return decode(self._input)

    def _fail(self, reason):
        if self._fatal is None:
            self._fatal = reason
        if self.child is not None and not self._kill_sent and self.child.poll() is None:
            self._kill_sent = True
            try:
                self.child.kill()
            except ProcessLookupError:
                pass

    def _close_failed(self):
        # A close error may follow actual kernel release. Record uncertainty;
        # never retain/retry a detached raw integer that may now be reused.
        self._ipc_uncertain = True
        try:
            self._fail('ipc_cleanup_failed')
        except BaseException:
            pass  # Cleanup of the other independent descriptors still runs.

    def _close_binary(self):
        closing, self._binary = self._binary, None
        if closing is not None:
            try:
                os.close(closing)
            except BaseException:
                self._close_failed()

    def _close_stream(self, pipe):
        if pipe is not None and not pipe.closed:
            try:
                pipe.close()
            except BaseException:
                # FileIO detaches its raw FD before the syscall. If a trusted
                # wrapper instead fails before close, retain that still-open
                # object for a later cleanup attempt; do not save its integer.
                self._close_failed()

    def _write(self, raw, deadline, cancelled=None):
        offset = 0
        with selectors.DefaultSelector() as selector:
            selector.register(self.child.stdin, selectors.EVENT_WRITE)
            while offset < len(raw):
                require(cancelled is None or not cancelled.is_set(), 'cancelled')
                require(clock() < deadline, 'control_deadline')
                for _, _ in selector.select(min(.02, max(0, deadline - clock()))):
                    try:
                        sent = os.write(self.child.stdin.fileno(), raw[offset:offset + 4096])
                    except BlockingIOError:
                        continue
                    require(sent > 0, 'control_failed')
                    offset += sent

    def _handshake(self):
        deadline = clock() + STARTUP_SECONDS
        self._write(self._input + b'\n', deadline)
        ready = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(self.child.stdout, selectors.EVENT_READ, 'control')
            selector.register(self.child.stderr, selectors.EVENT_READ, 'error')
            if self._binary is not None:
                selector.register(self._binary, selectors.EVENT_READ, 'binary')
            while not ready.endswith(b'\n'):
                require(clock() < deadline and self.child.poll() is None, 'invalid_ready')
                for key, _ in selector.select(min(.02, max(0, deadline - clock()))):
                    part = os.read(key.fd, 1025 - len(ready) if key.data == 'control' else 1)
                    require(key.data == 'control' and part, 'invalid_ready')
                    ready.extend(part)
                    require(len(ready) <= 1024, 'invalid_ready')
        expected = {'format': 'original-transfer-ready-v1', 'attempt_id': self._value['attempt_id'],
                    'input_sha256': self.input_sha256, 'bundle_sha256': self.bundle.sha256, 'process_id': self.child.pid}
        require(bytes(ready) == canonical(expected) + b'\n', 'invalid_ready')
        self.identity = process_identity(self.child.pid)
        require(self.child.poll() is None, 'invalid_ready')
        self._ready = True

    def go(self, deadline_ns, *, cancelled=None):
        require(self._ready and not self.sent_go and self._report is None and self._fatal is None
                and self.child.poll() is None, 'session_consumed')
        require(process_identity(self.child.pid) == self.identity, 'child_identity_changed')
        now = clock_ns()
        require(type(deadline_ns) is int and now < deadline_ns <= now + self._value['useful_ms'] * 1_000_000, 'deadline')
        require(cancelled is None or not cancelled.is_set(), 'cancelled')
        self.sent_go, self._deadline_ns = True, deadline_ns
        raw = canonical({'format': 'original-transfer-go-v1', 'execution_id': self._value['attempt_id'],
                         'input_sha256': self.input_sha256, 'bundle_sha256': self.bundle.sha256,
                         'deadline_ns': str(deadline_ns)}) + b'\n'
        try:
            self._write(raw, min(deadline_ns / 1e9, clock() + 1), cancelled)
            self._close_stream(self.child.stdin)
            require(self._fatal is None, 'control_failed')
        except BaseException:
            self._fail('control_failed')
            raise

    def _collect(self, producer, duration=None, cancelled=None):
        limit = (clock() + duration if duration is not None else
                 self._deadline_ns / 1e9 + self._value['close_ms'] / 1000 if self._deadline_ns is not None else
                 clock() + JOIN_SECONDS)
        stop_limit = clock() + JOIN_SECONDS if self._fatal is not None else None
        with selectors.DefaultSelector() as selector:
            for pipe, label in ((self.child.stdout, 'control'), (self.child.stderr, 'error')):
                if not pipe.closed:
                    selector.register(pipe, selectors.EVENT_READ, label)
            if self._binary is not None:
                selector.register(self._binary, selectors.EVENT_READ, 'binary')
            while selector.get_map() or self.child.poll() is None:
                now = clock()
                if self._fatal is None and (cancelled is not None and cancelled.is_set() or now >= limit):
                    self._fail('cancelled' if cancelled is not None and cancelled.is_set() else 'deadline')
                if self._fatal is not None and stop_limit is None:
                    stop_limit = now + JOIN_SECONDS
                until = stop_limit if stop_limit is not None else limit
                if now >= until:
                    break
                for key, _ in selector.select(min(.02, max(0, until - now))):
                    try:
                        part = os.read(key.fd, CHUNK)
                    except BlockingIOError:
                        continue
                    except OSError:
                        self._fail('pipe_failed')
                        selector.unregister(key.fileobj)
                        continue
                    if not part:
                        selector.unregister(key.fileobj)
                        if key.data == 'binary':
                            self._close_binary()
                            self._binary_eof = True
                        else:
                            self._close_stream(key.fileobj)
                            if key.data == 'control':
                                self._control_eof = True
                            else:
                                self._error_eof = True
                        continue
                    if key.data == 'binary':
                        self._binary_count += len(part)
                        self._binary_hash.update(part)
                        if self._binary_count > min(MAX_BINARY, self._value['request']['byte_ceiling']):
                            self._fail('binary_limit')
                        elif self._fatal is None:
                            try:
                                require(producer is not None, 'producer_required')
                                producer.append(part)
                            except Exception:
                                self._fail('append_failed')
                    else:
                        target, maximum = (self._output, MAX_RESULT + 1) if key.data == 'control' else (self._stderr, MAX_STDERR)
                        if len(target) + len(part) > maximum:
                            self._fail('output_limit')
                        else:
                            target.extend(part)
                            if key.data == 'error':
                                self._fail('child_stderr')
        return self.child.poll()

    def _close_pipes(self):
        for pipe in (self.child.stdin, self.child.stdout, self.child.stderr):
            self._close_stream(pipe)
        self._close_binary()

    def _ipc_closed(self):
        return (not self._ipc_uncertain and self._binary is None
                and all(pipe is None or pipe.closed for pipe in (self.child.stdin, self.child.stdout, self.child.stderr)))

    def _report_value(self, code):
        result = None
        if (self._fatal is None and self.sent_go and code == 0 and self._binary_eof
                and self._control_eof and self._error_eof and not self._stderr):
            try:
                require(self._output.endswith(b'\n') and self._output.count(b'\n') == 1, 'invalid_output')
                result = checked_result(bytes(self._output[:-1]), self._value)
                require(result['binary_bytes'] == self._binary_count, 'binary_mismatch')
                if (result['kind'] == 'complete' and self._value['request']['kind'] != 'original_upload'
                        and result['status'] == 200):
                    require(result['framing_complete'] is True and result['body_bytes'] == self._binary_count
                            and result['body_sha256'] == self._binary_hash.hexdigest(), 'binary_mismatch')
            except (Refused, ValueError, TypeError, KeyError):
                self._fatal, result = 'invalid_output', None
        elif self._fatal is None:
            self._fatal = 'child_exit' if code is not None else 'unresolved'
        complete = bool(result is not None and result['kind'] == 'complete' and self._fatal is None and code == 0
                        and self._ipc_closed()
                        and (self._value['request']['kind'] == 'original_upload'
                             or result['status'] == 200 and result['body_bytes'] > 0))
        outcome = self._fatal or ('uncertain' if result is None or result['kind'] != 'complete'
                                  else 'empty_body' if result['status'] == 200 else 'http_status')
        return {'format': 'original-session-report-v1', 'local_fixture_only': True,
                'attempt_id': self._value['attempt_id'], 'input_sha256': self.input_sha256,
                'bundle_sha256': self.bundle.sha256, 'process_id': self.child.pid, 'identity': self.identity,
                'sent_go': self.sent_go, 'complete': complete,
                'outcome': 'complete' if complete else outcome,
                'returncode': code, 'child_retired': code is not None,
                'ipc_cleanup_complete': self._ipc_closed(),
                'retirement_witness': 'exact_child_wait' if code is not None else None,
                'binary_eof': self._binary_eof, 'binary_bytes': self._binary_count,
                'binary_sha256': self._binary_hash.hexdigest(), 'result': result}

    def finish(self, *, producer=None, cancelled=None):
        require(self.sent_go or self._fatal is not None, 'go_required')
        if self._report is not None and self._report['child_retired'] and self._report['ipc_cleanup_complete']:
            return decode(canonical(self._report))
        try:
            code = self._collect(producer, cancelled=cancelled)
        except BaseException:
            self._fail('collection_failed')
            code = self._collect(None, JOIN_SECONDS)
            if code is not None:
                self._close_pipes()
            raise
        # Cancellation/deadline may change inside the caller's append method
        # just before the final descriptors reach EOF. Recheck before success.
        if cancelled is not None and cancelled.is_set():
            self._fail('cancelled')
        elif self._deadline_ns is not None and clock_ns() > self._deadline_ns + self._value['close_ms'] * 1_000_000:
            self._fail('deadline')
        if code is not None:
            self._close_pipes()
        self._report = self._report_value(code)
        return decode(canonical(self._report))

    def stop(self):
        if self._report is not None and self._report['child_retired'] and self._report['ipc_cleanup_complete']:
            return decode(canonical(self._report))
        self._fail('stopped')
        code = self._collect(None, JOIN_SECONDS)
        if code is not None:
            self._close_pipes()
        self._report = self._report_value(code)
        return decode(canonical(self._report))

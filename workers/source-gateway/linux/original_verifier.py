"""Portable, paused receiver for the unchanged frozen PDF verifier.

The caller keeps the stored-readback spool lock and reader intent until the
exact child retires. This session owns one duplicate of the borrowed readonly
FD; it shares that FD's offset, which must start at zero and must not be used by
the caller concurrently. No SQL grant, host admission, receipt or spool cleanup
is implied by this local component.
"""
import fcntl
import math
import os
import re
import selectors
import signal
import stat
import sys
import threading

from original_spool import descriptor
from original_transport import REQUEST_KEYS
from protocol import Refused, canonical, clock, clock_ns, decode, digest, require, target
from wait4_child import Wait4Child, SpawnError

MAX_INPUT = 16_384
MAX_GO = 4096
MAX_RESULT = 4096
MAX_STDERR = 4096
MAX_BYTES = 5_242_880
MAX_USEFUL_MS = 5000
STARTUP_SECONDS = 5
JOIN_SECONDS = .5
LINUX_CHILD_UID = 62402
LINUX_CHILD_GID = 62402
REASONS = {'input_mismatch', 'input_changed', 'bundle_changed', 'receiver_failure', 'deadline'}
OUTCOMES = {'verified', 'malformed', 'encrypted', 'unsupported', 'parser_resource_limit',
            'resource_limit', 'internal_error', 'input_limit', 'page_limit', 'binding_mismatch'}


def _uuid(value):
    require(type(value) is str and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value), 'invalid_request')


def _sha(value):
    require(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), 'invalid_request')


def validate_input(value, bundle):
    require(type(value) is dict and set(value) == {'format', 'local_fixture_only', 'claim_id',
            'request', 'request_sha256', 'spool_descriptor'}, 'invalid_request')
    require(value['format'] == 'original-verifier-input-v1' and value['local_fixture_only'] is True, 'invalid_request')
    _uuid(value['claim_id'])
    _sha(value['request_sha256'])  # Opaque SQL jsonb hash, never recreated here.
    request = value['request']
    require(type(request) is dict and set(request) == REQUEST_KEYS
            and type(request['version']) is int and request['version'] == 1
            and request['kind'] == 'original_verify', 'invalid_request')
    for key in ('job_id', 'reservation_id', 'predecessor_operation_id', 'verification_profile_id'):
        _uuid(request[key])
    for key in ('predecessor_result_sha256', 'candidate_sha256', 'input_spool_sha256', 'stage_recipe_sha256',
                'build_sha256', 'parser_profile_sha256', 'verifier_host_policy_sha256',
                'storage_policy_sha256', 'spool_policy_sha256'):
        _sha(request[key])
    target({'source_id': request['source_id'], 'revision': request['source_revision'], 'stage': 'atom', 'byte_ceiling': 1})
    require(type(request['source_revision']) is int and request['source_revision'] > 0
            and request['bucket'] == 'paper-assets'
            and request['path'] == 'originals/' + request['reservation_id'] + '/original.pdf'
            and type(request['candidate_bytes']) is int and type(request['byte_ceiling']) is int
            and 1 <= request['candidate_bytes'] == request['byte_ceiling'] <= MAX_BYTES
            and len(canonical(request)) <= 2048, 'invalid_request')
    require(request['build_sha256'] == bundle.build_identity_sha256
            and request['parser_profile_sha256'] == bundle.profile_sha256, 'verifier_build_mismatch')
    require(type(value['spool_descriptor']) is str and 0 < len(value['spool_descriptor']) <= 4096,
            'invalid_descriptor')
    raw = value['spool_descriptor'].encode('utf8')
    spool = descriptor(raw)
    require(digest(raw) == request['input_spool_sha256']
            and spool['purpose'] == 'stored_readback'
            and spool['claim_id'] == request['predecessor_operation_id']
            and spool['claim_id'] != value['claim_id']
            and spool['reservation_id'] == request['reservation_id']
            and spool['sha256'] == request['candidate_sha256']
            and spool['bytes'] == request['candidate_bytes'], 'invalid_descriptor')
    encoded = canonical(value)
    require(len(encoded) + 1 <= MAX_INPUT, 'input_limit')
    return decode(encoded)


def checked_result(raw, value, bundle, go):
    require(type(raw) is bytes and 0 < len(raw) + 1 <= MAX_RESULT, 'invalid_output')
    result = decode(raw)
    # JSON float spellings differ between JS and Python (e.g. 0.00001/1e-05).
    # decode rejects duplicate/nonfinite literals; closed shape and numeric
    # validation below establish this DTO without a cross-language re-encode.
    require(type(result) is dict and set(result) == {
        'format', 'local_fixture_only', 'claim_id', 'execution_id', 'request_sha256', 'input_sha256',
        'bundle_sha256', 'go_sha256', 'kind', 'reason', 'parser_result'}, 'invalid_output')
    require(result['format'] == 'original-verifier-result-v1' and result['local_fixture_only'] is True
            and result['claim_id'] == value['claim_id'] and result['execution_id'] == go['execution_id']
            and result['request_sha256'] == value['request_sha256']
            and result['input_sha256'] == digest(canonical(value)) and result['bundle_sha256'] == bundle.sha256
            and result['go_sha256'] == digest(canonical(go)), 'invalid_output')
    if result['kind'] == 'refused':
        require(type(result['reason']) is str and result['reason'] in REASONS
                and result['parser_result'] is None, 'invalid_output')
    else:
        require(result['kind'] == 'parsed' and result['reason'] is None, 'invalid_output')
        measurement = result['parser_result']
        require(type(measurement) is dict and type(measurement.get('outcome')) is str
                and measurement['outcome'] in OUTCOMES, 'invalid_output')
        verified = measurement['outcome'] == 'verified'
        require(set(measurement) == {'outcome', 'sha256', 'bytes', 'profileID', 'profileSHA256',
                                    'wasmSHA256', 'elapsedMS'} | ({'pages'} if verified else set()), 'invalid_output')
        request = value['request']
        require(measurement['sha256'] == request['candidate_sha256']
                and type(measurement['bytes']) is int and measurement['bytes'] == request['candidate_bytes']
                and measurement['profileID'] == bundle.profile_id
                and measurement['profileSHA256'] == bundle.profile_sha256
                and measurement['wasmSHA256'] == bundle.manifest['files']['verifier.wasm']['sha256']
                and type(measurement['elapsedMS']) in (int, float)
                and 0 <= measurement['elapsedMS'] <= MAX_USEFUL_MS and math.isfinite(measurement['elapsedMS']),
                'invalid_output')
        if verified:
            require(type(measurement['pages']) is int and 1 <= measurement['pages'] <= 50, 'invalid_output')
    return result


def _file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


class VerifierStartError(Refused):
    def __init__(self, session):
        super().__init__('original_verifier_start_failed')
        self.session = session


class VerifierSession:
    """One caller, one GO, one exact child. No automatic parse retry.

    A cancellation Event may be shared. finish/stop return retained status;
    unresolved ownership must outlive the spool reader. Deno's permission flags
    are a capability restriction, not a substitute for Linux host isolation.
    """
    def __init__(self, bundle, value, *, input_fd):
        self._spawn(bundle, value, input_fd=input_fd)
        self.handshake()

    @classmethod
    def spawn_paused(cls, bundle, value, *, input_fd, child_uid=None, child_gid=None):
        """Prepare and spawn only; the caller drops privileges before handshake.

        Explicit child IDs select the fixed Linux Deno identity. The caller
        must be the single-threaded, captured supervisor bootstrap while the
        effective GID is temporarily selected for the inherited control pipe.
        No input/control bytes are sent here. Post-spawn failure retains the
        exact owner in VerifierStartError; no cross-UID signal is guaranteed.
        """
        session = cls.__new__(cls)
        session._spawn(bundle, value, input_fd=input_fd, child_uid=child_uid, child_gid=child_gid)
        return session

    def _spawn(self, bundle, value, *, input_fd, child_uid=None, child_gid=None):
        if child_uid is not None or child_gid is not None:
            require(sys.platform == 'linux' and type(child_uid) is int and type(child_gid) is int
                    and child_uid == LINUX_CHILD_UID and child_gid == LINUX_CHILD_GID,
                    'invalid_child_identity')
        self.bundle = bundle
        self._value = validate_input(value, bundle)
        self._input = canonical(self._value)
        self.input_sha256 = digest(self._input)
        self.child, self._control, self._input_fd = None, None, None
        self._control_metadata = None
        self._ready, self.sent_go = False, False
        self._handshake_started = False
        self._deadline_ns, self._go, self._spawn_ns, self._retired_ns = None, None, None, None
        self._fatal, self._report = None, None
        self._watchdog_done, self._watchdog = threading.Event(), None
        self._watchdog_started = False
        self._ipc_uncertain, self._kill_sent = False, False
        self._output, self._stderr = bytearray(), bytearray()
        self._output_eof, self._error_eof = False, False
        child_control = None
        try:
            require(type(input_fd) is int and input_fd > 2, 'invalid_descriptor')
            info = os.fstat(input_fd)
            sealed = descriptor(self._value['spool_descriptor'].encode())
            require(stat.S_ISREG(info.st_mode) and fcntl.fcntl(input_fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
                    and info.st_size == self._value['request']['candidate_bytes']
                    and {'device': str(info.st_dev), 'inode': str(info.st_ino)} == sealed['guardian']
                    and os.lseek(input_fd, 0, os.SEEK_CUR) == 0, 'invalid_descriptor')
            self._input_identity = _file_identity(info)
            self._input_fd = os.dup(input_fd)
            bundle.verify()
            child_control, writer = self._control_pipe(child_gid)
            # Own the raw writer even if fdopen setup itself fails.
            try:
                self._control = os.fdopen(writer, 'wb', buffering=0)
            except BaseException:
                try:
                    os.close(writer)
                except BaseException:
                    self._ipc_uncertain = True
                raise
            os.set_blocking(self._control.fileno(), False)
            alias = ('/dev/fd/' if sys.platform == 'darwin' else '/proc/self/fd/' if sys.platform == 'linux' else None)
            require(alias is not None, 'unsupported_platform')
            # The private eight-file code directory is also inspected for an
            # exact inventory. It is separate from, and grants no access to,
            # the caller's spool directory or surrounding workspace.
            allowed = [str(bundle.root), alias + str(child_control)]
            require(all(',' not in path for path in allowed), 'invalid_bundle_path')
            argv = [str(bundle.deno_path), 'run', '--no-config', '--no-lock', '--no-npm', '--no-remote',
                    '--no-prompt', '--cached-only', '--no-code-cache', '--deny-import', '--deny-net', '--deny-env',
                    '--deny-run', '--deny-ffi', '--deny-write', '--deny-sys', '--allow-read=' + ','.join(allowed),
                    str(bundle.receiver_entry), str(child_control), bundle.sha256]
            self._spawn_ns = clock_ns()
            try:
                identity = {} if child_uid is None else {'user': child_uid, 'group': child_gid}
                self.child = Wait4Child.spawn(argv, stdin=self._input_fd, pass_fds=(child_control,),
                                              cwd=str(bundle.root), env={'LC_ALL': 'C', 'DENO_DIR': str(bundle.root)},
                                              **identity)
            except SpawnError as error:
                self.child = error.owner
                raise
            closing, child_control = child_control, None
            try:
                os.close(closing)
            except BaseException:
                self._ipc_uncertain = True
                raise
        except BaseException:
            if child_control is not None:
                closing, child_control = child_control, None
                try:
                    os.close(closing)
                except BaseException:
                    self._ipc_uncertain = True
            if self.child is not None:
                self._failed_start()
                raise VerifierStartError(self) from None
            self._close_all()
            raise

    def _control_pipe(self, child_gid):
        reader, writer = None, None
        try:
            if child_gid is None:
                reader, writer = os.pipe()
            else:
                previous = os.getegid()
                try:
                    os.setegid(child_gid)
                    require(os.getegid() == child_gid, 'control_group_failed')
                    reader, writer = os.pipe()
                finally:
                    # Restore even if the first setter raised after changing
                    # credentials. A failed restore forbids child creation.
                    try:
                        os.setegid(previous)
                        require(os.getegid() == previous, 'control_group_restore_failed')
                    except BaseException:
                        raise Refused('control_group_restore_failed') from None
                # /proc/self/fd reopening checks the pipe inode's ownership.
                # The original write-end capability remains with the parent;
                # only the read end is inherited by the fixed Deno identity.
                os.fchmod(reader, 0o440)
            info = os.fstat(reader)
            if child_gid is not None:
                require(stat.S_ISFIFO(info.st_mode) and info.st_gid == child_gid
                        and stat.S_IMODE(info.st_mode) == 0o440, 'control_group_failed')
            self._control_metadata = {'child_fd': reader, 'device': str(info.st_dev), 'inode': str(info.st_ino),
                                      'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)}
            return reader, writer
        except BaseException:
            for number in (reader, writer):
                if number is not None:
                    try:
                        os.close(number)
                    except BaseException:
                        self._ipc_uncertain = True  # Never retry a raw FD integer.
            raise

    def _failed_start(self):
        try:
            self._fail('handshake_failed')
            self._collect()
            if self._observe() is not None:
                self._close_all()
        except BaseException:
            pass  # Keep the exact owner; no fabricated retirement.

    def handshake(self):
        """Send captured input and consume exactly one READY handshake attempt.

        bundle.verify() and launch-path access already completed before spawn;
        this phase uses only captured bundle properties and existing FDs, so
        it can run after the supervisor's permanent privilege drop.
        """
        require(not self._handshake_started and not self.sent_go and self._fatal is None
                and self._report is None, 'session_consumed')
        self._handshake_started = True
        try:
            self._check_input(before_go=True)
            self._handshake()
        except BaseException:
            self._failed_start()
            raise VerifierStartError(self) from None

    @property
    def value(self):
        return decode(self._input)

    @property
    def control_metadata(self):
        """Captured pipe setup only; not an independent child-privilege proof."""
        return None if self._control_metadata is None else dict(self._control_metadata)

    def _observe(self):
        result = self.child.observe() if self.child is not None else None
        if result is not None and self._retired_ns is None:
            self._retired_ns = clock_ns()
            self._watchdog_done.set()
        return result

    def _fail(self, code):
        if self._fatal is None:
            self._fatal = code
        if self.child is not None and not self._kill_sent:
            self._kill_sent = True
            self.child.signal(signal.SIGKILL)

    def _close_failed(self):
        self._ipc_uncertain = True
        try:
            self._fail('ipc_cleanup_failed')
        except BaseException:
            pass

    def _close_stream(self, stream):
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException:
                # Retain a still-open stream object, not a raw number which
                # might have been released and reused before close raised.
                self._close_failed()

    def _close_all(self):
        self._close_stream(self._control)
        if self.child is not None:
            for stream in (self.child.stdout, self.child.stderr):
                self._close_stream(stream)
        closing, self._input_fd = self._input_fd, None
        if closing is not None:
            try:
                os.close(closing)
            except BaseException:
                self._close_failed()

    def _watch_deadline(self):
        # Independent of caller/pipe drain progress. This only owns the exact
        # child in this live parent; guardian-death recovery needs Linux scope
        # integration. A Deno timer cannot interrupt synchronous WASM.
        while not self._watchdog_done.is_set():
            remaining = (self._deadline_ns - clock_ns()) / 1e9
            if remaining <= 0:
                try:
                    self._fail('deadline')
                finally:
                    self._watchdog_done.set()
                return
            self._watchdog_done.wait(min(.05, remaining))

    def _ipc_closed(self):
        streams = [self._control] + ([] if self.child is None else [self.child.stdout, self.child.stderr])
        return not self._ipc_uncertain and self._input_fd is None and all(s is None or s.closed for s in streams)

    def _write(self, raw, deadline, cancelled=None):
        offset = 0
        with selectors.DefaultSelector() as selected:
            selected.register(self._control, selectors.EVENT_WRITE)
            while offset < len(raw):
                require(cancelled is None or not cancelled.is_set(), 'cancelled')
                require(clock() < deadline and self._observe() is None and not self.child.lost_authority, 'control_deadline')
                for _, _ in selected.select(min(.02, max(0, deadline - clock()))):
                    try:
                        written = os.write(self._control.fileno(), raw[offset:offset + 4096])
                    except BlockingIOError:
                        continue
                    require(written > 0, 'control_failed')
                    offset += written

    def _handshake(self):
        deadline = clock() + STARTUP_SECONDS
        self._write(self._input + b'\n', deadline)
        raw = bytearray()
        with selectors.DefaultSelector() as selected:
            selected.register(self.child.stdout, selectors.EVENT_READ, 'ready')
            selected.register(self.child.stderr, selectors.EVENT_READ, 'error')
            while not raw.endswith(b'\n'):
                require(clock() < deadline and self._observe() is None and not self.child.lost_authority, 'invalid_ready')
                for key, _ in selected.select(min(.02, max(0, deadline - clock()))):
                    try:
                        part = os.read(key.fd, 1025 - len(raw) if key.data == 'ready' else 1)
                    except BlockingIOError:
                        continue
                    require(key.data == 'ready' and part, 'invalid_ready')
                    raw.extend(part)
                    require(len(raw) <= 1024, 'invalid_ready')
        expected = {'format': 'original-verifier-ready-v1', 'claim_id': self._value['claim_id'],
                    'input_sha256': self.input_sha256, 'bundle_sha256': self.bundle.sha256, 'process_id': self.child.pid}
        require(bytes(raw) == canonical(expected) + b'\n' and self._observe() is None
                and not self.child.lost_authority, 'invalid_ready')
        self._check_input(before_go=True)
        self._ready = True

    def _check_input(self, *, before_go=False):
        require(self._input_fd is not None and _file_identity(os.fstat(self._input_fd)) == self._input_identity,
                'input_changed')
        if before_go:
            require(os.lseek(self._input_fd, 0, os.SEEK_CUR) == 0, 'input_changed')

    def go(self, execution_id, binding_sha256, deadline_ns, *, cancelled=None):
        require(self._ready and not self.sent_go and self._report is None and self._fatal is None
                and self._observe() is None and not self.child.lost_authority, 'session_consumed')
        _uuid(execution_id)
        _sha(binding_sha256)
        now = clock_ns()
        require(type(deadline_ns) is int and now < deadline_ns <= now + MAX_USEFUL_MS * 1_000_000, 'deadline')
        require(cancelled is None or not cancelled.is_set(), 'cancelled')
        self._check_input(before_go=True)
        go = {'format': 'original-verifier-go-v1', 'claim_id': self._value['claim_id'],
              'execution_id': execution_id, 'binding_sha256': binding_sha256, 'input_sha256': self.input_sha256,
              'bundle_sha256': self.bundle.sha256, 'deadline_ns': str(deadline_ns),
              'budget_ms': max(1, (deadline_ns - now) // 1_000_000)}
        raw = canonical(go) + b'\n'
        require(len(raw) <= MAX_GO, 'control_limit')
        self.sent_go, self._deadline_ns, self._go = True, deadline_ns, go
        try:
            self._watchdog = threading.Thread(target=self._watch_deadline, daemon=True,
                                              name='original-verifier-deadline')
            try:
                self._watchdog.start()
            finally:
                self._watchdog_started = self._watchdog.ident is not None
            self._write(raw, min(deadline_ns / 1e9, clock() + 1), cancelled)
            self._close_stream(self._control)
            require(self._fatal is None, 'control_failed')
        except BaseException:
            self._fail('control_failed')
            raise

    def _collect(self, cancelled=None):
        limit = self._deadline_ns / 1e9 if self._deadline_ns is not None else clock() + JOIN_SECONDS
        stop_limit = clock() + JOIN_SECONDS if self._fatal is not None else None
        with selectors.DefaultSelector() as selected:
            for stream, label in ((self.child.stdout, 'output'), (self.child.stderr, 'error')):
                if stream is not None and not stream.closed:
                    selected.register(stream, selectors.EVENT_READ, label)
            while True:
                retirement = self._observe()
                now = clock()
                if self._fatal is None:
                    if self.child.lost_authority:
                        self._fail('wait_authority_lost')
                    elif cancelled is not None and cancelled.is_set():
                        self._fail('cancelled')
                    elif now >= limit:
                        self._fail('deadline')
                if not selected.get_map() and (retirement is not None or self.child.lost_authority):
                    break
                if self._fatal is not None and stop_limit is None:
                    stop_limit = now + JOIN_SECONDS
                until = stop_limit if stop_limit is not None else limit
                if now >= until:
                    break
                for key, _ in selected.select(min(.02, max(0, until - now))):
                    try:
                        part = os.read(key.fd, 4096)
                    except BlockingIOError:
                        continue
                    except OSError:
                        self._fail('pipe_failed')
                        selected.unregister(key.fileobj)
                        continue
                    if not part:
                        selected.unregister(key.fileobj)
                        if key.data == 'output':
                            self._output_eof = True
                        else:
                            self._error_eof = True
                        self._close_stream(key.fileobj)
                    else:
                        buffer = self._output if key.data == 'output' else self._stderr
                        maximum = MAX_RESULT if key.data == 'output' else MAX_STDERR
                        if len(buffer) + len(part) > maximum:
                            self._fail('output_limit')
                        else:
                            buffer.extend(part)
                            if key.data == 'error':
                                self._fail('child_stderr')
        return self._observe()

    def finish(self, *, cancelled=None):
        if self._report is not None:
            return decode(canonical(self._report))
        require(self.sent_go or self._fatal is not None, 'go_required')
        retirement = self._collect(cancelled)
        if self._fatal is None and retirement is not None:
            if retirement['returncode'] != 0:
                self._fail('child_exit')
            elif retirement['metrics_error'] is not None:
                self._fail('rusage_missing')
        result = None
        if (self._fatal is None and retirement is not None and retirement['returncode'] == 0
                and retirement['metrics_error'] is None and self._output_eof and self._error_eof and not self._stderr):
            try:
                self._check_input()
                require(self._output.endswith(b'\n') and self._output.count(b'\n') == 1, 'invalid_output')
                result = checked_result(bytes(self._output[:-1]), self._value, self.bundle, self._go)
                if result['kind'] == 'parsed':
                    require(os.lseek(self._input_fd, 0, os.SEEK_CUR) == self._value['request']['candidate_bytes'], 'input_changed')
            except Exception:
                self._fail('invalid_result')
                result = None
        if retirement is not None:
            self._watchdog_done.set()
            try:
                if self._watchdog_started:
                    self._watchdog.join(JOIN_SECONDS)
                    require(not self._watchdog.is_alive(), 'watchdog_cleanup_failed')
            except BaseException:
                self._close_failed()
            finally:
                self._close_all()
        # Cancellation and the acceptance deadline still apply after exact
        # wait, while the bounded result and descriptor are being checked.
        if cancelled is not None and cancelled.is_set():
            self._fail('cancelled')
        if self._fatal is None and self._deadline_ns is not None and clock_ns() >= self._deadline_ns:
            self._fail('deadline')
        complete = self._fatal is None and result is not None and self._ipc_closed()
        if not complete:
            result = None
        report = {'format': 'original-verifier-session-v1', 'local_fixture_only': True, 'hosted_admitted': False,
                  'complete': complete, 'verified': complete and result['kind'] == 'parsed' and result['parser_result']['outcome'] == 'verified',
                  'result': result, 'reason': self._fatal, 'child_retired': retirement is not None,
                  'ipc_cleanup_complete': self._ipc_closed(), 'retirement': retirement,
                  'lost_wait_authority': self.child.lost_authority,
                  'spawn_to_wait_wall_ms': None if self._retired_ns is None else (self._retired_ns - self._spawn_ns) / 1_000_000}
        # Unknown ownership/cleanup may be reconciled by a later call; never
        # freeze unknown into a fabricated success or repeat the parse.
        if retirement is not None and self._ipc_closed():
            self._report = decode(canonical(report))
        return report

    def stop(self):
        if self._report is not None:
            return decode(canonical(self._report))
        self._fail('cancelled')
        return self.finish()

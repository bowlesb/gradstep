"""One retained POSIX child and one wait4 owner; no IPC or group cleanup.

The caller must not reap this child elsewhere or install a SIGCHLD reaper. No
Popen lifecycle method is used: even Popen.kill() polls and can discard rusage.
Unresolved owners are deliberately retained, within a finite admission limit,
so dropping a caller/exception cannot run Popen's reaping destructor. There is
no authority-recovery or PID-only cleanup API. These are exact child facts, not
whole-host, cgroup, descendant-retirement or SQL evidence.
Kernel wait4 accounting may include resources of waited descendants; the
caller must separately establish any intended no-descendant process profile.
"""
import copy
import math
import os
import signal as signals
import subprocess
import sys
import threading


MAX_RETAINED_CHILDREN = 32
MAX_SAFE_INTEGER = (1 << 53) - 1
_RETAINED = {}
_REGISTRY_LOCK = threading.Lock()
_COUNTERS = ('ru_maxrss', 'ru_ixrss', 'ru_idrss', 'ru_isrss', 'ru_minflt',
             'ru_majflt', 'ru_nswap', 'ru_inblock', 'ru_oublock', 'ru_msgsnd',
             'ru_msgrcv', 'ru_nsignals', 'ru_nvcsw', 'ru_nivcsw')


class Wait4Error(Exception):
    """Finite diagnostics only; never include argv, environment or OS text."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


class SpawnError(Wait4Error):
    def __init__(self, owner):
        self.owner = owner
        super().__init__('child_setup_failed')


def _require(condition, code):
    if not condition:
        raise Wait4Error(code)


def _launch_arguments(argv, stdin, stdout, stderr, pass_fds, env, cwd, user=None, group=None):
    _require(type(argv) in (list, tuple) and 1 <= len(argv) <= 64, 'invalid_spawn')
    arguments = tuple(argv)
    _require(1 <= len(arguments) <= 64 and all(type(x) is str and x and '\0' not in x for x in arguments),
             'invalid_spawn')
    _require(os.path.isabs(arguments[0]) and sum(len(x.encode('utf8')) for x in arguments) <= 65_536,
             'invalid_spawn')
    _require(type(env) is dict and len(env) <= 64, 'invalid_spawn')
    environment = dict(env)
    _require(len(environment) <= 64 and all(type(k) is str and k and '=' not in k
             and '\0' not in k and type(v) is str and '\0' not in v for k, v in environment.items()),
             'invalid_spawn')
    _require(sum(len(k.encode('utf8')) + len(v.encode('utf8')) for k, v in environment.items()) <= 32_768,
             'invalid_spawn')
    _require(type(pass_fds) in (tuple, list) and len(pass_fds) <= 16
             and all(type(fd) is int and fd > 2 for fd in pass_fds), 'invalid_spawn')
    descriptors = tuple(sorted(set(pass_fds)))
    for value, allowed in ((stdin, (subprocess.PIPE, subprocess.DEVNULL)),
                           (stdout, (subprocess.PIPE, subprocess.DEVNULL)),
                           (stderr, (subprocess.PIPE, subprocess.DEVNULL, subprocess.STDOUT))):
        _require(value is None or type(value) is int and (value >= 0 or value in allowed), 'invalid_spawn')
    if cwd is not None:
        cwd = os.fspath(cwd)
        _require(type(cwd) is str and '\0' not in cwd and os.path.isabs(cwd)
                 and len(cwd.encode('utf8')) <= 4096, 'invalid_spawn')
    launch = dict(args=arguments, stdin=stdin, stdout=stdout, stderr=stderr,
                  pass_fds=descriptors, env=environment, cwd=cwd, close_fds=True,
                  bufsize=0, text=False, shell=False)
    if user is not None or group is not None:
        # These are numeric IDs only: no name-service lookup, root target,
        # supplementary-group inheritance or caller-supplied group list. The
        # enclosing fixed Linux policy chooses the particular positive pair.
        _require(sys.platform == 'linux' and type(user) is int and type(group) is int
                 and 0 < user < (1 << 31) and 0 < group < (1 << 31), 'invalid_identity')
        launch.update(user=user, group=group, extra_groups=())
    return launch


def _usage(value, platform):
    """Copy a closed numeric record, then derive conservative whole-ms CPU."""
    raw = {}
    for name in ('ru_utime', 'ru_stime'):
        number = getattr(value, name)
        _require(type(number) in (int, float) and 0 <= number <= MAX_SAFE_INTEGER / 1000
                 and math.isfinite(number), 'invalid_rusage')
        raw[name] = number
    for name in _COUNTERS:
        number = getattr(value, name)
        _require(type(number) is int and 0 <= number <= MAX_SAFE_INTEGER, 'invalid_rusage')
        raw[name] = number
    # Darwin's getrusage(2) uses bytes; Linux uses KiB. Do not guess elsewhere.
    scale = 1 if platform == 'darwin' else 1024
    peak = raw['ru_maxrss'] * scale
    # Round each actual CPU component upward separately. No RUSAGE_CHILDREN
    # subtraction or sampled-RSS substitute is involved.
    cpu = math.ceil(raw['ru_utime'] * 1000) + math.ceil(raw['ru_stime'] * 1000)
    _require(0 < peak <= MAX_SAFE_INTEGER and 0 <= cpu <= MAX_SAFE_INTEGER, 'invalid_rusage')
    return raw, {'cpu_ms': cpu, 'peak_process_bytes': peak}


class Wait4Child:
    def __init__(self):
        self._lock = threading.RLock()
        self._popen = None
        self._pid = None
        self._platform = sys.platform
        self._retirement = None
        self._authority_error = None
        self._wait_error = None
        self._signal_error = None

    @classmethod
    def spawn(cls, argv, *, stdin=None, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
              pass_fds=(), env, cwd=None, user=None, group=None):
        _require(sys.platform in ('darwin', 'linux') and hasattr(os, 'wait4'), 'wait4_unavailable')
        _require(signals.getsignal(signals.SIGCHLD) == signals.SIG_DFL, 'sigchld_owner_required')
        try:
            launch = _launch_arguments(argv, stdin, stdout, stderr, pass_fds, env, cwd, user, group)
        except (ValueError, TypeError, UnicodeError, OverflowError):
            raise Wait4Error('invalid_spawn') from None
        owner = cls()
        with _REGISTRY_LOCK:
            _require(len(_RETAINED) < MAX_RETAINED_CHILDREN, 'owner_capacity')
            _RETAINED[id(owner)] = owner
        try:
            # Retain the ordinary instance BEFORE its unchanged initializer.
            # This is not a subclass, preexec_fn or private reaper override. It
            # also preserves access if initialization raises after spawning.
            child = subprocess.Popen.__new__(subprocess.Popen)
            owner._popen = child
            subprocess.Popen.__init__(child, **launch)
            _require(type(child.pid) is int and child.pid > 0 and child.returncode is None,
                     'invalid_child')
            owner._pid = child.pid
            for pipe in (child.stdin, child.stdout, child.stderr):
                if pipe is not None:
                    os.set_blocking(pipe.fileno(), False)
            return owner
        except BaseException:
            child = owner._popen
            pid = getattr(child, 'pid', None)
            if type(pid) is int and pid > 0:
                owner._pid = pid
                # CPython can reap a failed exec during its initializer. That
                # status is not this owner's wait4 evidence and has no rusage.
                if getattr(child, 'returncode', None) is not None:
                    owner._authority_error = 'constructor_reaped'
            else:
                owner._authority_error = 'not_started'
                owner._release()
            raise SpawnError(owner) from None

    def _release(self):
        with _REGISTRY_LOCK:
            _RETAINED.pop(id(self), None)

    @property
    def pid(self):
        return self._pid

    @property
    def stdin(self):
        return getattr(self._popen, 'stdin', None)

    @property
    def stdout(self):
        return getattr(self._popen, 'stdout', None)

    @property
    def stderr(self):
        return getattr(self._popen, 'stderr', None)

    @property
    def lost_authority(self):
        with self._lock:
            return self._authority_error is not None

    @property
    def retirement(self):
        with self._lock:
            return copy.deepcopy(self._retirement)

    @property
    def evidence(self):
        with self._lock:
            return {'format': 'wait4-child-evidence-v1', 'pid': self._pid,
                    'retirement': copy.deepcopy(self._retirement),
                    'lost_authority': self._authority_error is not None,
                    'authority_error': self._authority_error,
                    'wait_error': self._wait_error, 'signal_error': self._signal_error}

    def _observe_locked(self):
        if self._retirement is not None or self._authority_error is not None:
            return
        if self._pid is None:
            self._authority_error = 'not_started'
            return
        if self._popen.returncode is not None:
            self._authority_error = 'unexpected_reap'
            return
        try:
            pid, status, usage = os.wait4(self._pid, os.WNOHANG)
        except InterruptedError:
            return
        except ChildProcessError:
            self._authority_error = 'wait_authority_lost'
            return
        except OSError:
            self._authority_error = 'wait_failed'
            return
        if pid == 0:
            return
        if pid != self._pid or type(status) is not int:
            self._authority_error = 'invalid_wait_result'
            return
        if not (os.WIFEXITED(status) or os.WIFSIGNALED(status)):
            # A traced/stopped child is not retired. Keep the owner so a later
            # signal/wait can still terminate and reap that same direct child.
            self._wait_error = 'nonterminal_status'
            return
        code = os.waitstatus_to_exitcode(status)
        self._popen.returncode = code
        self._retirement = {'format': 'wait4-child-retirement-v1', 'pid': pid,
                            'wait_status': status, 'returncode': code,
                            'platform': self._platform,
                            'maxrss_unit': 'bytes' if self._platform == 'darwin' else 'KiB',
                            'rusage': None, 'metrics': None, 'metrics_error': 'invalid_rusage'}
        try:
            raw, metrics = _usage(usage, self._platform)
            self._retirement.update(rusage=raw, metrics=metrics, metrics_error=None)
        except Exception:
            # The actual terminal wait cannot be lost because resource fields
            # are unavailable/malformed. It is never performed a second time.
            pass
        finally:
            self._release()

    def observe(self):
        with self._lock:
            self._observe_locked()
            return copy.deepcopy(self._retirement)

    def signal(self, number):
        _require(isinstance(number, int) and not isinstance(number, bool)
                 and number in (signals.SIGTERM, signals.SIGKILL), 'invalid_signal')
        with self._lock:
            self._observe_locked()
            if self._retirement is not None or self._authority_error is not None:
                return False
            try:
                # The sole owner holds the same lock across wait4 and kill.
                # An exited but unreaped direct child still reserves its PID.
                os.kill(self._pid, number)
                return True
            except OSError:
                self._signal_error = 'signal_failed'
                return False

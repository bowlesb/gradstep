"""Fixed R -> S -> D Linux compatibility fixture, with two exact wait owners.

Only the outside guardian can retire the whole service/slice or its spool
reader. These bounded reports are not SQL receipts or host admission. In
particular, an exited supervisor with no Deno wait record is not completion.
The captured bootstrap imports this module before either privilege drop.
"""
import fcntl
import math
import os
from pathlib import Path
import re
import selectors
import stat
import sys
import time

from common import canonical, decode, require
from original_spool import descriptor
from original_verifier import (VerifierSession, VerifierStartError, validate_input,
                               OUTCOMES, REASONS as PARSER_REFUSALS)
from original_verifier_bundle import open_installed_verifier_bundle
from protocol import clock_ns, digest
import uid_policy
from wait4_child import Wait4Child, SpawnError

REAPER_UID, SUPERVISOR_UID, DENO_UID = 62403, 62401, 62402
MAX_CONFIG, MAX_READY, MAX_OUTPUT, MAX_GO, MAX_STDERR = 32768, 8192, 32768, 4096, 4096
MAX_NS, USEFUL_NS, JOIN_NS = 20_000_000_000, 5_000_000_000, 500_000_000
MODULES = ('verifier_probe_bootstrap.py', 'verifier_probe_runtime.py', 'uid_policy.py',
           'common.py', 'original_verifier.py', 'original_verifier_bundle.py',
           'original_spool.py', 'original_transport.py', 'transport.py',
           'protocol.py', 'wait4_child.py')
CONFIG_KEYS = {'format', 'local_fixture_only', 'bundle_path', 'bundle_sha256', 'input',
               'execution_id', 'binding_sha256', 'startup_deadline_ns',
               'go_deadline_ns', 'collection_deadline_ns'}
GO_KEYS = {'format', 'local_fixture_only', 'claim_id', 'execution_id', 'binding_sha256',
           'input_sha256', 'bundle_sha256', 'deadline_ns'}
REASONS = {'startup_failed', 'startup_deadline', 'go_deadline', 'collection_deadline',
           'invalid_control', 'invalid_supervisor', 'supervisor_stderr', 'output_limit',
           'supervisor_exit', 'wait_missing', 'rusage_missing', 'ipc_cleanup_failed',
           'receiver_failed', 'runtime_failed'}
SESSION_REASONS = {'handshake_failed', 'ipc_cleanup_failed', 'deadline', 'control_failed',
                   'wait_authority_lost', 'cancelled', 'pipe_failed', 'output_limit',
                   'child_stderr', 'child_exit', 'rusage_missing', 'invalid_result'}
SESSION_KEYS = {'format', 'local_fixture_only', 'hosted_admitted', 'complete', 'verified',
                'result', 'reason', 'child_retired', 'ipc_cleanup_complete', 'retirement',
                'lost_wait_authority', 'spawn_to_wait_wall_ms'}
USAGE_COUNTERS = ('ru_maxrss', 'ru_ixrss', 'ru_idrss', 'ru_isrss', 'ru_minflt', 'ru_majflt',
                  'ru_nswap', 'ru_inblock', 'ru_oublock', 'ru_msgsnd', 'ru_msgrcv',
                  'ru_nsignals', 'ru_nvcsw', 'ru_nivcsw')


def _uuid(value):
    require(type(value) is str and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value),
            'invalid_control')


def _sha(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'invalid_control')


def _decimal(value):
    require(type(value) is str and re.fullmatch('[1-9][0-9]{0,19}', value)
            and int(value) <= (1 << 64) - 1, 'invalid_control')
    return int(value)


def _path(value):
    require(type(value) is str and 0 < len(value) <= 4096
            and len(value.encode('utf8')) <= 4096 and value.startswith('/')
            and os.path.normpath(value) == value and not any(ord(c) < 32 or ord(c) == 127 for c in value),
            'invalid_control')
    return Path(value)


def _line(raw, maximum):
    require(type(raw) is bytes and 0 < len(raw) <= maximum and raw.endswith(b'\n')
            and raw.count(b'\n') == 1, 'invalid_control')
    value = decode(raw)
    require(canonical(value) + b'\n' == raw, 'invalid_control')
    return value


def checked_config(raw, bundle, *, now=None):
    value = _line(raw, MAX_CONFIG)
    require(type(value) is dict and set(value) == CONFIG_KEYS
            and value['format'] == 'linux-verifier-probe-config-v1'
            and value['local_fixture_only'] is True, 'invalid_control')
    _path(value['bundle_path'])
    _sha(value['bundle_sha256'])
    _sha(value['binding_sha256'])
    _uuid(value['execution_id'])
    require(value['bundle_sha256'] == bundle.sha256 and value['bundle_path'] == str(bundle.root), 'invalid_control')
    value['input'] = validate_input(value['input'], bundle)
    start, go, end = (_decimal(value[k]) for k in
                      ('startup_deadline_ns', 'go_deadline_ns', 'collection_deadline_ns'))
    now = clock_ns() if now is None else now
    require(now < start <= go < end <= now + MAX_NS and end - go >= JOIN_NS, 'invalid_control')
    return value


def checked_go(raw, config, *, now=None):
    value = _line(raw, MAX_GO)
    require(type(value) is dict and set(value) == GO_KEYS
            and value['format'] == 'linux-verifier-probe-go-v1'
            and value['local_fixture_only'] is True, 'invalid_control')
    require(value['claim_id'] == config['input']['claim_id']
            and value['execution_id'] == config['execution_id']
            and value['binding_sha256'] == config['binding_sha256']
            and value['bundle_sha256'] == config['bundle_sha256']
            and value['input_sha256'] == digest(canonical(config['input'])), 'invalid_control')
    deadline = _decimal(value['deadline_ns'])
    now = clock_ns() if now is None else now
    require(now < int(config['go_deadline_ns']) and now < deadline <= now + USEFUL_NS
            and deadline + JOIN_NS <= int(config['collection_deadline_ns']), 'invalid_control')
    return value


def _fd_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _trusted_directory(path, *, mode=None, gid=None):
    for part in reversed((path, *path.parents)):
        info = part.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'invalid_control')
    info = path.lstat()
    require((mode is None or stat.S_IMODE(info.st_mode) == mode)
            and (gid is None or info.st_gid == gid), 'invalid_control')


def _read_file_at(directory, name, maximum, mode, gid):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == gid
                and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == mode
                and 0 < info.st_size <= maximum, 'invalid_control')
        raw = bytearray()
        while len(raw) <= maximum:
            part = os.read(fd, min(4096, maximum + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        require(len(raw) == info.st_size and _fd_identity(os.fstat(fd)) == _fd_identity(info), 'invalid_control')
        return bytes(raw)
    finally:
        os.close(fd)  # This local raw reference is never reused/retried.


def load_config(path):
    require(sys.platform == 'linux' and os.geteuid() == 0, 'invalid_control')
    path = _path(path)
    require(path.name == 'config.json' and path.parent.name == 'control', 'invalid_control')
    _trusted_directory(path.parent, mode=0o750, gid=REAPER_UID)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        raw = _read_file_at(directory, path.name, MAX_CONFIG, 0o400, 0)
    finally:
        os.close(directory)
    preliminary = _line(raw, MAX_CONFIG)
    require(type(preliminary) is dict and set(preliminary) == CONFIG_KEYS, 'invalid_control')
    bundle = open_installed_verifier_bundle(_path(preliminary['bundle_path']), preliminary['bundle_sha256'])
    return checked_config(raw, bundle), bundle


def checked_pdf(fd, value):
    info = os.fstat(fd)
    sealed = descriptor(value['spool_descriptor'].encode('utf8'))
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
            and fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
            and os.lseek(fd, 0, os.SEEK_CUR) == 0 and info.st_size == sealed['bytes']
            and {'device': str(info.st_dev), 'inode': str(info.st_ino)} == sealed['guardian'], 'invalid_control')
    return {'device': str(info.st_dev), 'inode': str(info.st_ino), 'bytes': info.st_size,
            'offset': 0, 'access_mode': 'read-only'}


class DescriptorOwner:
    """Detach-before-close; never retry an ambiguous raw descriptor number."""
    def __init__(self, fd=None):
        self.fd, self.clean = fd, True

    def close(self):
        closing, self.fd = self.fd, None
        if closing is not None:
            try:
                os.close(closing)
            except BaseException:
                self.clean = False
        return self.clean


class ControlFiles:
    def __init__(self, config_path):
        parent = _path(config_path).parent
        _trusted_directory(parent, mode=0o750, gid=REAPER_UID)
        self.directory = DescriptorOwner(os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC))
        self.outputs, self.published = {}, set()
        try:
            for name in ('ready.json', 'report.json'):
                owned = DescriptorOwner(os.open(name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                               dir_fd=self.directory.fd))
                self.outputs[name] = owned
                info = os.fstat(owned.fd)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == REAPER_UID
                        and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o640 and info.st_size == 0,
                        'invalid_control')
        except BaseException:
            self.close()
            raise

    def launch_spent(self, config):
        raw = canonical({'format': 'linux-verifier-probe-launch-spent-v1',
                         'claim_id': config['input']['claim_id'], 'bundle_sha256': config['bundle_sha256'],
                         'input_sha256': digest(canonical(config['input'])), 'process_id': os.getpid()}) + b'\n'
        owned = DescriptorOwner(os.open('launch-spent.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                       | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self.directory.fd))
        try:
            os.fchmod(owned.fd, 0o600)
            _write_regular(owned.fd, raw)
            os.fsync(self.directory.fd)
        finally:
            require(owned.close(), 'ipc_cleanup_failed')

    def publish(self, name, value):
        require(name in self.outputs and name not in self.published, 'invalid_control')
        raw = canonical(value) + b'\n'
        require(len(raw) <= (MAX_READY if name == 'ready.json' else MAX_OUTPUT), 'output_limit')
        fd = self.outputs[name].fd
        info, named = os.fstat(fd), os.stat(name, dir_fd=self.directory.fd, follow_symlinks=False)
        require(_fd_identity(info) == _fd_identity(named) and info.st_nlink == 1 and info.st_size == 0,
                'invalid_control')
        # Mark consumed before the first write. A partial publication is never overwritten.
        self.published.add(name)
        _write_regular(fd, raw)
        os.fsync(self.directory.fd)

    def go(self):
        return _read_file_at(self.directory.fd, 'go.json', MAX_GO, 0o440, REAPER_UID)

    def close(self):
        clean = True
        for owned in [*self.outputs.values(), self.directory]:
            clean = owned.close() and clean
        return clean


def _write_regular(fd, raw):
    offset = 0
    while offset < len(raw):
        count = os.write(fd, raw[offset:])
        require(count > 0, 'ipc_cleanup_failed')
        offset += count
    os.fsync(fd)


def _read_proc(path, maximum):
    with open(path, 'rb') as stream:
        raw = stream.read(maximum + 1)
    require(0 < len(raw) <= maximum, 'invalid_supervisor')
    return raw.decode('ascii')


def process_record(pid):
    first = _read_proc('/proc/' + str(pid) + '/stat', 4096)
    require(first.startswith(str(pid) + ' ('), 'invalid_supervisor')
    fields = first[first.rfind(')') + 2:].split()
    require(len(fields) >= 20, 'invalid_supervisor')
    start = fields[19]
    _decimal(start)
    value = uid_policy.status(pid)
    group = _read_proc('/proc/' + str(pid) + '/cgroup', 4096)
    boot = _read_proc('/proc/sys/kernel/random/boot_id', 128).strip()
    _uuid(boot)
    again = _read_proc('/proc/' + str(pid) + '/stat', 4096)
    require(again[again.rfind(')') + 2:].split()[19] == start, 'invalid_supervisor')
    return {'process_id': pid, 'process_start_id': start, 'boot_id': boot, 'cgroup': group, 'status': value}


def _checked_process(value, uid, parent, *, threaded=False):
    require(type(value) is dict and set(value) == {'process_id', 'process_start_id', 'boot_id', 'cgroup', 'status'},
            'invalid_supervisor')
    _decimal(value['process_start_id'])
    _uuid(value['boot_id'])
    group, current = value['cgroup'], value['status']
    require(type(group) is str and group.startswith('0::/') and group.endswith('\n')
            and group.count('\n') == 1 and len(group) <= 4096, 'invalid_supervisor')
    require(type(current) is dict and set(current) == {'pid', 'parent_pid', 'uids', 'gids', 'groups',
            'caps', 'no_new_privs', 'threads', 'seccomp'}, 'invalid_supervisor')
    require(type(value['process_id']) is int and 1 < value['process_id'] < (1 << 31)
            and current['pid'] == value['process_id'] and current['parent_pid'] == parent
            and current['uids'] == [uid] * 4 and current['gids'] == [uid] * 4 and current['groups'] == []
            and current['caps'] == {key: 0 for key in uid_policy.CAP_FIELDS}
            and type(current['no_new_privs']) is int and current['no_new_privs'] == 1
            and type(current['seccomp']) is int and current['seccomp'] == 2
            and type(current['threads']) is int and 1 <= current['threads'] <= (64 if threaded else 1),
            'invalid_supervisor')
    return value


def _identity_fields(config):
    return {'claim_id': config['input']['claim_id'], 'execution_id': config['execution_id'],
            'bundle_sha256': config['bundle_sha256'], 'input_sha256': digest(canonical(config['input']))}


def _matches(value, config):
    require(all(value.get(k) == v for k, v in _identity_fields(config).items()), 'invalid_supervisor')


def checked_ready(raw, config, supervisor_pid, reaper_pid):
    value = _line(raw, MAX_READY)
    require(type(value) is dict and set(value) == {'format', 'local_fixture_only', *_identity_fields(config),
            'supervisor', 'deno', 'control', 'input'}
            and value['format'] == 'linux-verifier-probe-supervisor-ready-v1'
            and value['local_fixture_only'] is True, 'invalid_supervisor')
    _matches(value, config)
    supervisor = _checked_process(value['supervisor'], SUPERVISOR_UID, reaper_pid)
    deno = _checked_process(value['deno'], DENO_UID, supervisor_pid, threaded=True)
    require(supervisor['process_id'] == supervisor_pid and deno['process_id'] != supervisor_pid
            and supervisor['boot_id'] == deno['boot_id'] and supervisor['cgroup'] == deno['cgroup'], 'invalid_supervisor')
    control = value['control']
    require(type(control) is dict and set(control) == {'child_fd', 'device', 'inode', 'uid', 'gid', 'mode'}
            and type(control['child_fd']) is int and 2 < control['child_fd'] < 64
            and control['uid'] == 0 and control['gid'] == DENO_UID and control['mode'] == 0o440,
            'invalid_supervisor')
    require(type(control['device']) is str and re.fullmatch('0|[1-9][0-9]{0,19}', control['device']), 'invalid_supervisor')
    _decimal(control['inode'])
    sealed = descriptor(config['input']['spool_descriptor'].encode())
    require(value['input'] == dict(sealed['guardian'], bytes=sealed['bytes'], offset=0, access_mode='read-only'),
            'invalid_supervisor')
    return value


def _checked_wait(value, pid):
    require(type(value) is dict and set(value) == {'format', 'pid', 'wait_status', 'returncode', 'platform',
            'maxrss_unit', 'rusage', 'metrics', 'metrics_error'}
            and value['format'] == 'wait4-child-retirement-v1' and value['pid'] == pid
            and type(value['pid']) is int and 1 < value['pid'] < (1 << 31)
            and value['platform'] == 'linux' and value['maxrss_unit'] == 'KiB'
            and type(value['wait_status']) is int and 0 <= value['wait_status'] <= 65535
            and type(value['returncode']) is int and -64 <= value['returncode'] <= 255, 'invalid_supervisor')
    status = value['wait_status']
    expected = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status) if os.WIFSIGNALED(status) else None
    require(expected is not None and expected == value['returncode'], 'invalid_supervisor')
    if value['metrics_error'] is not None:
        require(value['metrics_error'] == 'invalid_rusage' and value['rusage'] is None and value['metrics'] is None,
                'invalid_supervisor')
        return value
    usage = value['rusage']
    require(type(usage) is dict and set(usage) == {'ru_utime', 'ru_stime', *USAGE_COUNTERS}, 'invalid_supervisor')
    for key in ('ru_utime', 'ru_stime'):
        number = usage[key]
        require(type(number) in (int, float) and 0 <= number <= ((1 << 53) - 1) / 1000
                and math.isfinite(number), 'invalid_supervisor')
    for key in USAGE_COUNTERS:
        require(type(usage[key]) is int and 0 <= usage[key] <= (1 << 53) - 1, 'invalid_supervisor')
    metrics = value['metrics']
    require(type(metrics) is dict and set(metrics) == {'cpu_ms', 'peak_process_bytes'}
            and all(type(number) is int for number in metrics.values())
            and 0 < usage['ru_maxrss'] * 1024 <= (1 << 53) - 1 and metrics == {
        'cpu_ms': math.ceil(usage['ru_utime'] * 1000) + math.ceil(usage['ru_stime'] * 1000),
        'peak_process_bytes': usage['ru_maxrss'] * 1024}, 'invalid_supervisor')
    return value


def _checked_parser_result(result, config, bundle):
    require(type(result) is dict and set(result) == {'format', 'local_fixture_only', 'claim_id',
            'execution_id', 'request_sha256', 'input_sha256', 'bundle_sha256', 'go_sha256',
            'kind', 'reason', 'parser_result'} and result['format'] == 'original-verifier-result-v1'
            and result['local_fixture_only'] is True, 'invalid_supervisor')
    _matches(result, config)
    _sha(result['go_sha256'])
    require(result['request_sha256'] == config['input']['request_sha256'], 'invalid_supervisor')
    if result['kind'] == 'refused':
        require(type(result['reason']) is str and result['reason'] in PARSER_REFUSALS
                and result['parser_result'] is None, 'invalid_supervisor')
        return False
    require(result['kind'] == 'parsed' and result['reason'] is None, 'invalid_supervisor')
    value, request = result['parser_result'], config['input']['request']
    require(type(value) is dict and type(value.get('outcome')) is str and value['outcome'] in OUTCOMES,
            'invalid_supervisor')
    verified = value['outcome'] == 'verified'
    require(set(value) == {'outcome', 'sha256', 'bytes', 'profileID', 'profileSHA256', 'wasmSHA256', 'elapsedMS'}
            | ({'pages'} if verified else set()) and value['sha256'] == request['candidate_sha256']
            and type(value['bytes']) is int and value['bytes'] == request['candidate_bytes']
            and value['profileID'] == bundle.profile_id and value['profileSHA256'] == bundle.profile_sha256
            and value['wasmSHA256'] == bundle.manifest['files']['verifier.wasm']['sha256']
            and type(value['elapsedMS']) in (int, float) and 0 <= value['elapsedMS'] <= 5000
            and math.isfinite(value['elapsedMS']), 'invalid_supervisor')
    if verified:
        require(type(value['pages']) is int and 1 <= value['pages'] <= 50, 'invalid_supervisor')
    return verified


def checked_supervisor_result(raw, config, ready, bundle):
    value = _line(raw, MAX_OUTPUT - MAX_READY)
    require(type(value) is dict and set(value) == {'format', 'local_fixture_only', *_identity_fields(config),
            'ready', 'go_received', 'reason', 'session', 'ipc_cleanup_complete'}
            and value['format'] == 'linux-verifier-probe-supervisor-result-v1'
            and value['local_fixture_only'] is True, 'invalid_supervisor')
    _matches(value, config)
    require(all(type(value[k]) is bool for k in ('ready', 'go_received', 'ipc_cleanup_complete'))
            and (value['reason'] is None or type(value['reason']) is str and value['reason'] in REASONS),
            'invalid_supervisor')
    if ready is None:
        require(not value['ready'] and not value['go_received'] and value['reason'] is not None,
                'invalid_supervisor')
    report = value['session']
    if report is None:
        require(value['reason'] is not None, 'invalid_supervisor')
        return value
    require(type(report) is dict and set(report) == SESSION_KEYS
            and report['format'] == 'original-verifier-session-v1'
            and report['local_fixture_only'] is True and report['hosted_admitted'] is False
            and all(type(report[k]) is bool for k in ('complete', 'verified', 'child_retired',
                                                     'ipc_cleanup_complete', 'lost_wait_authority'))
            and (report['reason'] is None or type(report['reason']) is str and report['reason'] in SESSION_REASONS),
            'invalid_supervisor')
    if ready is None:
        # Before READY, G did not independently observe D's identity. Preserve
        # a captured S's closed negative wait evidence without admitting it as
        # a successful handshake, parse or whole-scope retirement.
        require(not value['ready'] and not value['go_received'] and value['reason'] is not None
                and not report['complete'] and not report['verified'], 'invalid_supervisor')
    if report['retirement'] is not None:
        retirement = report['retirement']
        require(type(retirement) is dict, 'invalid_supervisor')
        _checked_wait(retirement, ready['deno']['process_id'] if ready is not None else retirement.get('pid'))
    require(report['child_retired'] == (report['retirement'] is not None), 'invalid_supervisor')
    wall = report['spawn_to_wait_wall_ms']
    require(wall is None and not report['child_retired'] or type(wall) in (int, float)
            and 0 <= wall <= 20000 and math.isfinite(wall) and report['child_retired'], 'invalid_supervisor')
    if report['complete']:
        require(ready is not None and value['ready'] and value['go_received'] and value['reason'] is None
                and value['ipc_cleanup_complete'] and report['ipc_cleanup_complete']
                and report['child_retired'] and not report['lost_wait_authority'] and report['reason'] is None
                and report['retirement']['returncode'] == 0 and report['retirement']['metrics_error'] is None
                and type(report['result']) is dict, 'invalid_supervisor')
        # The captured session checks its exact Deno GO hash; R additionally
        # rejects extra fields/content before retaining the closed result.
        verified = _checked_parser_result(report['result'], config, bundle)
        require(report['verified'] == verified, 'invalid_supervisor')
    else:
        require(report['result'] is None and report['verified'] is False, 'invalid_supervisor')
    return value


def _write_pipe(fd, raw, deadline):
    os.set_blocking(fd, False)
    with selectors.DefaultSelector() as selected:
        selected.register(fd, selectors.EVENT_WRITE)
        offset = 0
        while offset < len(raw):
            remaining = (deadline - clock_ns()) / 1e9
            require(remaining > 0, 'invalid_control')
            for _, _ in selected.select(min(.02, remaining)):
                try:
                    count = os.write(fd, raw[offset:offset + 4096])
                except BlockingIOError:
                    continue
                require(count > 0, 'invalid_control')
                offset += count


def _read_go_pipe(fd, config):
    info = os.fstat(fd)
    require(stat.S_ISFIFO(info.st_mode) and fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY,
            'invalid_control')
    os.set_blocking(fd, False)
    raw = bytearray()
    with selectors.DefaultSelector() as selected:
        selected.register(fd, selectors.EVENT_READ)
        while True:
            remaining = (int(config['go_deadline_ns']) - clock_ns()) / 1e9
            require(remaining > 0, 'go_deadline')
            for _, _ in selected.select(min(.02, remaining)):
                try:
                    part = os.read(fd, min(4096, MAX_GO + 1 - len(raw)))
                except BlockingIOError:
                    continue
                if not part:
                    return checked_go(bytes(raw), config)
                raw.extend(part)
                require(len(raw) <= MAX_GO, 'invalid_control')


def _finish_reaper_drop():
    uid_policy.begin_drop()
    os.setgroups([])
    os.setresgid(REAPER_UID, REAPER_UID, REAPER_UID)
    os.setresuid(REAPER_UID, REAPER_UID, REAPER_UID)
    uid_policy.prctl(4, 0)
    uid_policy.self_check(REAPER_UID)


def _finite_reason(error, fallback):
    code = getattr(error, 'code', None)
    if code is None and type(error) is ValueError and len(error.args) == 1:
        code = error.args[0]
    return code if type(code) is str and code in REASONS else fallback


def supervisor_main(path, control_fd):
    control, pdf = DescriptorOwner(control_fd), DescriptorOwner()
    session, config, ready, received, result, reason = None, None, False, False, None, None
    try:
        config, bundle = load_config(path)
        input_facts = checked_pdf(0, config['input'])
        pdf.fd = os.dup(0)
        uid_policy.begin_drop()
        session = VerifierSession.spawn_paused(bundle, config['input'], input_fd=pdf.fd,
                                               child_uid=DENO_UID, child_gid=DENO_UID)
        require(pdf.close(), 'ipc_cleanup_failed')
        uid_policy.finish_drop()
        session.handshake()
        require(clock_ns() < int(config['startup_deadline_ns']), 'startup_deadline')
        message = dict(_identity_fields(config), format='linux-verifier-probe-supervisor-ready-v1',
                       local_fixture_only=True, supervisor=process_record(os.getpid()),
                       deno=process_record(session.child.pid), control=session.control_metadata, input=input_facts)
        raw = canonical(message) + b'\n'
        checked_ready(raw, config, os.getpid(), os.getppid())
        _write_pipe(1, raw, int(config['startup_deadline_ns']))
        ready = True
        go = _read_go_pipe(control.fd, config)
        require(control.close(), 'ipc_cleanup_failed')
        received = True
        session.go(go['execution_id'], go['binding_sha256'], int(go['deadline_ns']))
        result = session.finish()
        if not result['complete']:
            reason = 'receiver_failed'
    except BaseException as error:
        if isinstance(error, VerifierStartError):
            session = error.session
        reason = _finite_reason(error, 'startup_failed' if not ready else 'receiver_failed')
    finally:
        if session is not None and result is None:
            try:
                result = session.stop()
            except BaseException:
                reason = reason or 'receiver_failed'
        clean = control.close()
        clean = pdf.close() and clean
        if not clean:
            reason = 'ipc_cleanup_failed'
        if config is not None:
            message = dict(_identity_fields(config), format='linux-verifier-probe-supervisor-result-v1',
                           local_fixture_only=True, ready=ready, go_received=received, reason=reason,
                           session=result, ipc_cleanup_complete=clean)
            try:
                raw = canonical(message) + b'\n'
                require(len(raw) <= MAX_OUTPUT - MAX_READY, 'output_limit')
                _write_pipe(1, raw, int(config['collection_deadline_ns']))
            except BaseException:
                reason = reason or 'ipc_cleanup_failed'
    return 0 if reason is None and result is not None and result['complete'] else 2


class SupervisorOutput:
    def __init__(self, child):
        self.child, self.output, self.stderr = child, bytearray(), bytearray()
        self.output_eof, self.stderr_eof, self.reason = False, False, None

    def poll(self, deadline):
        self.child.observe()  # Sole owner; EOF is never used as wait evidence.
        with selectors.DefaultSelector() as selected:
            for stream, label, ended in ((self.child.stdout, 'output', self.output_eof),
                                          (self.child.stderr, 'stderr', self.stderr_eof)):
                if stream is not None and not stream.closed and not ended:
                    selected.register(stream, selectors.EVENT_READ, label)
            remaining = max(0, (deadline - clock_ns()) / 1e9)
            if not selected.get_map():
                time.sleep(min(.02, remaining))
            for key, _ in selected.select(min(.02, remaining)) if selected.get_map() else ():
                try:
                    part = os.read(key.fd, 4096)
                except BlockingIOError:
                    continue
                except OSError:
                    self.reason = self.reason or 'ipc_cleanup_failed'
                    part = b''
                if not part:
                    if key.data == 'output':
                        self.output_eof = True
                    else:
                        self.stderr_eof = True
                else:
                    target = self.output if key.data == 'output' else self.stderr
                    cap = MAX_OUTPUT if key.data == 'output' else MAX_STDERR
                    if len(target) + len(part) <= cap:
                        target.extend(part)
                    else:
                        self.reason = self.reason or 'output_limit'
                    if key.data == 'stderr':
                        self.reason = self.reason or 'supervisor_stderr'
        self.child.observe()

    def close(self):
        clean = True
        for stream in (self.child.stdout, self.child.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except BaseException:
                    clean = False
        return clean


def _supervisor_argv(path, control_fd):
    import verifier_probe_context as context
    require(len(sys.argv) == 5 and sys.argv[3:] == ['reaper', path]
            and Path(sys.argv[0]) == context.module_root / 'verifier_probe_bootstrap.py'
            and sys.argv[1] == str(context.module_root) and sys.argv[2] == context.manifest_sha256
            and set(context.manifest['files']) == set(MODULES), 'invalid_control')
    return [sys.executable, '-I', '-S', '-B', *sys.argv[:3], 'supervisor', path, str(control_fd)]


def reaper_main(path):
    files, config, child, output = None, None, None, None
    reader, writer = DescriptorOwner(), DescriptorOwner()
    ready, forwarded, supervisor_result, reason, own = None, False, None, None, None
    try:
        config, bundle = load_config(path)
        checked_pdf(0, config['input'])
        files = ControlFiles(path)
        reader.fd, writer.fd = os.pipe()
        argv = _supervisor_argv(path, reader.fd)
        files.launch_spent(config)  # Durable one-launch fence precedes Popen.
        try:
            child = Wait4Child.spawn(argv, stdin=0, pass_fds=(reader.fd,), env={'LC_ALL': 'C'})
        except SpawnError as error:
            child = error.owner
            raise
        require(reader.close(), 'ipc_cleanup_failed')
        output = SupervisorOutput(child)
        _finish_reaper_drop()
        own = process_record(os.getpid())
        while b'\n' not in output.output:
            require(clock_ns() < int(config['startup_deadline_ns']), 'startup_deadline')
            output.poll(int(config['startup_deadline_ns']))
            require(output.reason is None and not output.output_eof and not child.lost_authority,
                    output.reason or 'invalid_supervisor')
        line = bytes(output.output).split(b'\n', 1)[0] + b'\n'
        first = _line(line, MAX_READY)
        if type(first) is dict and first.get('format') == 'linux-verifier-probe-supervisor-result-v1':
            supervisor_result = checked_supervisor_result(line, config, None, bundle)
            raise ValueError('startup_failed')
        ready = checked_ready(line, config, child.pid, os.getpid())
        require(child.retirement is None and not child.lost_authority, 'invalid_supervisor')
        require(own['boot_id'] == ready['supervisor']['boot_id']
                and own['cgroup'] == ready['supervisor']['cgroup'], 'invalid_supervisor')
        files.publish('ready.json', {'format': 'linux-verifier-probe-ready-v1', 'local_fixture_only': True,
                                    'hosted_admitted': False, 'reaper': own, 'supervisor_ready': ready})
        while True:
            require(clock_ns() < int(config['go_deadline_ns']), 'go_deadline')
            output.poll(int(config['go_deadline_ns']))
            require(output.reason is None and child.retirement is None and not child.lost_authority
                    and bytes(output.output) == line, output.reason or 'invalid_supervisor')
            try:
                raw = files.go()
            except FileNotFoundError:
                continue
            checked_go(raw, config)
            _write_pipe(writer.fd, raw, int(config['go_deadline_ns']))
            require(writer.close(), 'ipc_cleanup_failed')
            forwarded = True
            break
    except BaseException as error:
        reason = _finite_reason(error, 'startup_failed' if ready is None else 'invalid_control')
    finally:
        clean = reader.close()
        clean = writer.close() and clean
        if child is not None and config is not None:
            output = output or SupervisorOutput(child)
            try:
                while clock_ns() < int(config['collection_deadline_ns']):
                    output.poll(int(config['collection_deadline_ns']))
                    if (child.retirement is not None or child.lost_authority) and output.output_eof and output.stderr_eof:
                        break
                reason = reason or output.reason
                require(output.output_eof and output.stderr_eof, 'collection_deadline')
                require(child.retirement is not None and not child.lost_authority, 'wait_missing')
                _checked_wait(child.retirement, child.pid)
                lines = bytes(output.output).splitlines(keepends=True)
                if ready is None:
                    require(len(lines) == 1, 'invalid_supervisor')
                    supervisor_result = checked_supervisor_result(lines[0], config, None, bundle)
                else:
                    require(len(lines) == 2, 'invalid_supervisor')
                    supervisor_result = checked_supervisor_result(lines[1], config, ready, bundle)
                require(child.retirement['metrics_error'] is None, 'rusage_missing')
                require(child.retirement['returncode'] == 0, 'supervisor_exit')
            except BaseException as error:
                reason = reason or _finite_reason(error, 'invalid_supervisor')
            clean = output.close() and clean
        if not clean:
            reason = 'ipc_cleanup_failed'
        if files is not None and config is not None:
            report = None if supervisor_result is None else supervisor_result['session']
            complete = (reason is None and forwarded and report is not None and report['complete']
                        and supervisor_result['reason'] is None and supervisor_result['ipc_cleanup_complete'])
            final = dict(_identity_fields(config), format='linux-verifier-probe-report-v1', local_fixture_only=True,
                         hosted_admitted=False, ready_published='ready.json' in files.published,
                         go_forwarded=forwarded, complete=complete, verified=bool(complete and report['verified']),
                         reason=reason, supervisor_result=supervisor_result,
                         supervisor_wait=None if child is None else child.retirement,
                         supervisor_wait_authority_lost=False if child is None else child.lost_authority,
                         ipc_cleanup_complete=clean)
            try:
                files.publish('report.json', final)
            except BaseException:
                reason = reason or 'ipc_cleanup_failed'
            if not files.close():
                reason = reason or 'ipc_cleanup_failed'
    return 0 if reason is None and supervisor_result is not None and supervisor_result['session']['complete'] else 2


def main(argv=None):
    try:
        arguments = sys.argv[3:] if argv is None else argv
        require(type(arguments) in (list, tuple) and len(arguments) in (2, 3), 'invalid_control')
        role, path = arguments[:2]
        _path(path)
        if role == 'reaper':
            require(len(arguments) == 2, 'invalid_control')
            return reaper_main(path)
        require(role == 'supervisor' and len(arguments) == 3 and type(arguments[2]) is str
                and re.fullmatch('[1-9][0-9]?', arguments[2]) and 2 < int(arguments[2]) < 64, 'invalid_control')
        return supervisor_main(path, int(arguments[2]))
    except BaseException:
        # No raw exceptions, content, paths or stderr diagnostics cross roles.
        return 2

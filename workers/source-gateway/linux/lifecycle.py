"""Exact retained-slice observations for loopback fixtures, never SQL receipts."""
import hashlib
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

from common import canonical, decode, durable_read, publish, read, require

MARKER = {'schema_version': 1, 'mode': 'loopback_lifecycle_fixture',
          'source_network_enabled': False, 'hosted_admitted': False}
SERVICE_FIELDS = ('Id', 'LoadState', 'ActiveState', 'SubState', 'MainPID', 'InvocationID',
                  'ControlGroup', 'Slice', 'KillMode', 'Restart', 'Delegate', 'Job', 'FragmentPath')
SLICE_FIELDS = ('Id', 'LoadState', 'ActiveState', 'ControlGroup', 'StopWhenUnneeded', 'FragmentPath')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def names(attempt):
    normalized = str(uuid.UUID(attempt))
    require(attempt == normalized, 'invalid_attempt')
    prefix = 'tsfixture' + uuid.UUID(attempt).hex
    return prefix + '.service', prefix + '.slice', '/run/timestep-source-fixture/' + uuid.UUID(attempt).hex


def rendered_units(attempt):
    service, slice_name, root = names(attempt)
    result = {}
    for suffix, name in (('service', service), ('slice', slice_name)):
        raw = (Path(__file__).parent / ('attempt.' + suffix + '.in')).read_bytes()
        require(0 < len(raw) < 16_384, 'invalid_unit_template')
        text = raw.decode().replace('@ATTEMPT@', attempt).replace('@ROOT@', root).replace('@SLICE@', slice_name)
        require('@' not in text, 'unexpanded_unit_template')
        result[name] = text.encode()
    return result


def validate_ready(ready, attempt, mode=MARKER['mode']):
    require(type(ready) is dict and set(ready) == {'schema_version', 'mode', 'attempt_id', 'child_id',
            'identity', 'controller_pid', 'invocation_id', 'source_sha256', 'bundle_sha256',
            'source_network_enabled', 'hosted_admitted'} and type(ready['schema_version']) is int
            and ready['schema_version'] == 1 and ready['mode'] == mode and ready['attempt_id'] == attempt
            and ready['source_network_enabled'] is False and ready['hosted_admitted'] is False, 'invalid_ready')
    require(all(type(ready[key]) is str and re.fullmatch(r'[0-9a-f]{64}', ready[key])
                for key in ('source_sha256', 'bundle_sha256')) and type(ready['invocation_id']) is str
            and re.fullmatch(r'[0-9a-f]{32}', ready['invocation_id']), 'invalid_ready')
    require(type(ready['child_id']) is str and str(uuid.UUID(ready['child_id'])) == ready['child_id']
            and type(ready['controller_pid']) is int and 1 < ready['controller_pid'] < 2_147_483_647,
            'invalid_ready')
    identity = ready['identity']
    require(type(identity) is dict and set(identity) == {'boot_id', 'process_id', 'process_start_id'}
            and type(identity['boot_id']) is str and str(uuid.UUID(identity['boot_id'])) == identity['boot_id']
            and type(identity['process_id']) is int and 1 < identity['process_id'] < 2_147_483_647
            and type(identity['process_start_id']) is str and re.fullmatch(r'[0-9]{1,20}', identity['process_start_id']),
            'invalid_ready')


def run(argv, seconds=3):
    """Finite control command output; timeout is failure, never retirement."""
    require(argv[0] in ('/usr/bin/systemctl', '/usr/bin/systemd-analyze'), 'invalid_control_command')
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, close_fds=True, start_new_session=True,
                             env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
    output, error = bytearray(), bytearray()
    deadline = time.monotonic() + seconds
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, label in ((child.stdout, 'out'), (child.stderr, 'err')):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, label)
            while selector.get_map():
                require(time.monotonic() < deadline, 'control_timeout')
                for key, _ in selector.select(min(.02, max(0, deadline - time.monotonic()))):
                    value = os.read(key.fileobj.fileno(), 4096)
                    if not value:
                        selector.unregister(key.fileobj)
                        continue
                    target = output if key.data == 'out' else error
                    target.extend(value)
                    require(len(target) <= 16_384, 'control_output_limit')
        require(child.wait(timeout=max(.01, deadline - time.monotonic())) == 0, 'control_failed')
        return output.decode('utf8')
    finally:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                pass  # A control-command failure cannot establish a witness.
        child.stdout.close()
        child.stderr.close()


def show(unit, fields):
    require(re.fullmatch(r'tsfixture[0-9a-f]{32}\.(?:service|slice)', unit) is not None, 'invalid_unit')
    raw = run(['/usr/bin/systemctl', 'show', '--no-pager', '--property=' + ','.join(fields), unit])
    result = {}
    for line in raw.splitlines():
        key, separator, value = line.partition('=')
        require(separator and key in fields and key not in result, 'invalid_unit_state')
        result[key] = value
    require(set(result) == set(fields), 'incomplete_unit_state')
    return result


def boot_id():
    return str(uuid.UUID(read('/proc/sys/kernel/random/boot_id', 128).decode().strip()))


def preflight():
    require(sys.platform == 'linux' and os.geteuid() == 0, 'linux_fixture_root_required')
    marker = Path('/etc/timestep-source-lifecycle-fixture.json')
    status = marker.lstat()
    require(stat.S_ISREG(status.st_mode) and status.st_uid == 0 and not status.st_mode & 0o022
            and decode(read(marker)) == MARKER, 'unmarked_host')
    require(read('/proc/1/comm', 128).strip() == b'systemd', 'systemd_required')
    require(Path('/sys/fs/cgroup/cgroup.controllers').is_file() and hasattr(time, 'CLOCK_BOOTTIME'),
            'cgroup_v2_and_boottime_required')
    return {'schema_version': 1, 'mode': MARKER['mode'], 'boot_id': boot_id(),
            'kernel': os.uname().release, 'machine': os.uname().machine,
            'systemd': run(['/usr/bin/systemctl', '--version']).splitlines()[0],
            'python': sys.version, 'clock': 'CLOCK_BOOTTIME', 'source_network_enabled': False,
            'hosted_admitted': False}


def cgroup_snapshot(path, root=Path('/sys/fs/cgroup')):
    require(re.fullmatch(r'/tsfixture[0-9a-f]{32}\.slice', path) is not None, 'invalid_cgroup')
    parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directory = None
    try:
        directory = os.open(path[1:], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        status = os.fstat(directory)
        fd = os.open('cgroup.events', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as stream:
            data = stream.read(1025)
        require(len(data) <= 1024, 'invalid_cgroup_events')
        values = {}
        for line in data.decode('ascii').splitlines():
            pair = line.split()
            require(len(pair) == 2 and pair[0] not in values and re.fullmatch(r'[a-z_]+', pair[0])
                    and re.fullmatch(r'[0-9]+', pair[1]), 'invalid_cgroup_events')
            values[pair[0]] = int(pair[1])
        require(values.get('populated') in (0, 1), 'invalid_cgroup_events')
        return {'path': path, 'device': status.st_dev, 'inode': status.st_ino,
                'populated': values['populated']}
    finally:
        if directory is not None:
            os.close(directory)
        os.close(parent)


def process(pid):
    require(type(pid) is int and 1 < pid < 2_147_483_647, 'invalid_pid')
    raw = read('/proc/' + str(pid) + '/stat', 4096).decode()
    require(raw.startswith(str(pid) + ' ('), 'invalid_process')
    fields = raw[raw.rfind(')') + 2:].split()
    require(len(fields) >= 20 and fields[19].isdigit(), 'invalid_process')
    group = read('/proc/' + str(pid) + '/cgroup', 4096).decode().strip()
    require(group.startswith('0::/') and '\n' not in group, 'unexpected_process_cgroup')
    return {'process_id': pid, 'process_start_id': fields[19], 'parent_pid': int(fields[1]),
            'uid': Path('/proc/' + str(pid)).stat().st_uid, 'cgroup': group[3:]}


class Observer:
    def __init__(self, *, unit_show=show, current_boot=boot_id, snapshot=cgroup_snapshot,
                 current_process=process, unit_renderer=rendered_units, expected_uid=65534,
                 ready_mode=MARKER['mode']):
        self.show, self.boot, self.snapshot, self.process = unit_show, current_boot, snapshot, current_process
        self.render, self.expected_uid, self.ready_mode = unit_renderer, expected_uid, ready_mode

    def capture(self, attempt, ready):
        ready = decode(canonical(ready))
        service, slice_name, _ = names(attempt)
        validate_ready(ready, attempt, self.ready_mode)
        s = self.show(service, SERVICE_FIELDS)
        parent = self.show(slice_name, SLICE_FIELDS)
        require(s['Id'] == service and s['LoadState'] == 'loaded' and s['ActiveState'] == 'active'
                and s['InvocationID'] == ready['invocation_id']
                and re.fullmatch(r'[0-9a-f]{32}', s['InvocationID'])
                and s['MainPID'] == str(ready['controller_pid']) and s['Slice'] == slice_name
                and s['ControlGroup'] == '/' + slice_name + '/' + service
                and s['KillMode'] == 'control-group' and s['Restart'] == 'no' and s['Delegate'] == 'no'
                and s['FragmentPath'] == '/run/systemd/system/' + service, 'unit_identity_mismatch')
        require(parent['Id'] == slice_name and parent['LoadState'] == 'loaded'
                and parent['ActiveState'] == 'active' and parent['ControlGroup'] == '/' + slice_name
                and parent['StopWhenUnneeded'] == 'no'
                and parent['FragmentPath'] == '/run/systemd/system/' + slice_name, 'slice_identity_mismatch')
        identity = ready['identity']
        require(type(identity) is dict and set(identity) == {'boot_id', 'process_id', 'process_start_id'}
                and identity['boot_id'] == self.boot(), 'child_identity_mismatch')
        child = self.process(identity['process_id'])
        require(child['process_start_id'] == identity['process_start_id']
                and child['parent_pid'] == ready['controller_pid'] and child['uid'] == self.expected_uid
                and child['cgroup'] == '/' + slice_name + '/' + service,
                'child_identity_mismatch')
        group = self.snapshot('/' + slice_name)
        require(group['populated'] == 1, 'group_not_populated')
        units = self.render(attempt)
        require(read(s['FragmentPath'], 16_384) == units[service]
                and read(parent['FragmentPath'], 16_384) == units[slice_name], 'unit_source_changed')
        return {'schema_version': 1, 'kind': 'fixture_slice_capture_v1', 'attempt_id': attempt,
                'boot_id': identity['boot_id'], 'service': service, 'slice': slice_name,
                'invocation_id': s['InvocationID'], 'group': group, 'ready': ready,
                'unit_sha256': hashlib.sha256(units[service]).hexdigest(),
                'slice_sha256': hashlib.sha256(units[slice_name]).hexdigest(),
                'source_network_enabled': False, 'hosted_admitted': False}

    def observe(self, capture, fence):
        # Validate a restored checkpoint as strictly as a fresh one.
        require(type(capture) is dict and set(capture) == {'schema_version', 'kind', 'attempt_id', 'boot_id',
                'service', 'slice', 'invocation_id', 'group', 'ready', 'unit_sha256', 'slice_sha256',
                'source_network_enabled', 'hosted_admitted'}
                and type(capture['schema_version']) is int and capture['schema_version'] == 1
                and capture['kind'] == 'fixture_slice_capture_v1' and capture['source_network_enabled'] is False
                and capture['hosted_admitted'] is False, 'invalid_capture')
        service, slice_name, _ = names(capture['attempt_id'])
        validate_ready(capture['ready'], capture['attempt_id'], self.ready_mode)
        require(capture['service'] == service and capture['slice'] == slice_name
                and re.fullmatch(r'[0-9a-f]{32}', capture['invocation_id'])
                and capture['boot_id'] == self.boot() == capture['ready']['identity']['boot_id']
                and capture['invocation_id'] == capture['ready']['invocation_id'], 'capture_identity_changed')
        require(type(fence) is dict and type(fence.get('schema_version')) is int
                and fence == {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                          'capture_sha256': digest(capture), 'attempt_id': capture['attempt_id']}, 'invalid_stop_fence')
        old = capture['group']
        require(type(old) is dict and set(old) == {'path', 'device', 'inode', 'populated'}
                and old['path'] == '/' + slice_name and type(old['populated']) is int and old['populated'] == 1
                and all(type(old[k]) is int and old[k] >= 0 for k in ('device', 'inode')), 'invalid_group_capture')
        s = self.show(service, SERVICE_FIELDS)
        parent = self.show(slice_name, SLICE_FIELDS)
        # systemd255 clears the completed service's InvocationID. This alone is
        # no evidence: the durable root-owned stop marker must also inhibit all
        # future starts through the captured unit's ConditionPathExists rule.
        terminal = s['ActiveState'] in ('inactive', 'failed') and s['MainPID'] == '0' and s['Job'] == ''
        invocation_matches = s['InvocationID'] == capture['invocation_id'] or (s['InvocationID'] == '' and terminal)
        require(s['Id'] == service and s['LoadState'] == 'loaded'
                and invocation_matches and s['Restart'] == 'no'
                and s['KillMode'] == 'control-group' and s['Delegate'] == 'no'
                and s['Slice'] == slice_name and s['FragmentPath'] == '/run/systemd/system/' + service,
                'unit_identity_changed')
        require(parent['Id'] == slice_name and parent['ActiveState'] == 'active'
                and parent['ControlGroup'] == old['path'] and parent['StopWhenUnneeded'] == 'no'
                and parent['FragmentPath'] == '/run/systemd/system/' + slice_name, 'slice_identity_changed')
        units = self.render(capture['attempt_id'])
        require(read(s['FragmentPath'], 16_384) == units[service]
                and read(parent['FragmentPath'], 16_384) == units[slice_name]
                and hashlib.sha256(units[service]).hexdigest() == capture['unit_sha256']
                and hashlib.sha256(units[slice_name]).hexdigest() == capture['slice_sha256'],
                'unit_source_changed')
        now = self.snapshot(old['path'])
        require(all(now[key] == old[key] for key in ('path', 'device', 'inode')), 'group_identity_changed')
        complete = now['populated'] == 0 and terminal
        return {'schema_version': 1, 'kind': 'fixture_cgroup_empty_v1' if complete else 'fixture_unresolved_v1',
                'attempt_id': capture['attempt_id'], 'capture_sha256': digest(capture),
                'boot_id': capture['boot_id'], 'group': now, 'owned_group_empty': complete,
                'sql_receipt_authority': False, 'source_network_enabled': False, 'hosted_admitted': False}


def stop_and_observe(checkpoints, *, observer=None, seconds=3):
    """Only exact retained fixture units; no discovery, restart or SQL calls."""
    checkpoints = Path(checkpoints)
    capture = durable_read(checkpoints / 'capture.json')
    require(checkpoints == Path(names(capture['attempt_id'])[2]) / 'observer', 'invalid_checkpoint_path')
    fence_path = checkpoints / 'stop-fence.json'
    if not fence_path.exists():
        publish(checkpoints, 'stop-fence.json', {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                'capture_sha256': digest(capture), 'attempt_id': capture['attempt_id']})
    fence = durable_read(fence_path)
    observer = observer or Observer()
    # Validate the current identity before signalling; a changed boot/unit is not
    # permission to stop whatever happens to occupy the old name.
    observer.observe(capture, fence)
    run(['/usr/bin/systemctl', 'stop', '--no-block', capture['service']])
    deadline = time.monotonic() + min(3, max(.01, seconds))
    while True:
        result = observer.observe(capture, fence)
        if result['owned_group_empty'] or time.monotonic() >= deadline:
            return result
        time.sleep(.02)


def stop_before_cleanup(attempt, remove_artifacts, *, control=run, snapshot=cgroup_snapshot,
                        unit_renderer=rendered_units):
    """Keep unit files and journals intact after any uncertain stop/observation."""
    service, slice_name, _ = names(attempt)
    units = unit_renderer(attempt)
    require(all(read('/run/systemd/system/' + name, 16_384) == raw for name, raw in units.items()),
            'unit_source_changed')
    control(['/usr/bin/systemctl', 'stop', service])
    group = snapshot('/' + slice_name)
    require(type(group.get('populated')) is int and group['populated'] == 0, 'cleanup_group_unresolved')
    control(['/usr/bin/systemctl', 'stop', slice_name])
    # Only the successful two-stop + empty-group sequence reaches deletion.
    remove_artifacts()


def main():
    """Explicit fresh observer process; accepts no network or SQL parameters."""
    try:
        preflight()
        require(len(sys.argv) == 4, 'invalid_arguments')
        checkpoints = Path(sys.argv[3])
        require(re.fullmatch(r'/run/timestep-source-fixture/[0-9a-f]{32}/observer', str(checkpoints)),
                'invalid_checkpoint_path')
        result = stop_and_observe(checkpoints)
        print(canonical(result).decode())
        return 0 if result['owned_group_empty'] else 2
    except (ValueError, OSError, KeyError) as error:
        reasons = {'unit_identity_changed', 'slice_identity_changed', 'group_identity_changed',
                   'unit_source_changed', 'invalid_capture', 'capture_identity_changed',
                   'invalid_stop_fence', 'invalid_group_capture', 'control_failed',
                   'control_timeout', 'invalid_arguments', 'invalid_checkpoint_path'}
        reason = str(error) if str(error) in reasons else 'inconclusive'
        print(canonical({'schema_version': 1, 'kind': 'fixture_inconclusive_v1',
                         'reason': reason, 'sql_receipt_authority': False, 'hosted_admitted': False}).decode())
        return 2

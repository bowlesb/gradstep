#!/usr/bin/env python3
"""Finite root guardian for the marked, isolated Linux verifier compatibility VM.

This is an offline fixture, not a daemon, SQL adapter or admitted host policy.
Only explicitly named fresh fixture paths and units are created/removed. Failed
evidence is retained. No source, Storage, Mathpix or AI request is made.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import grp
import re
import shutil
import signal
import stat
import sys
import threading
import time
import uuid

SOURCE = Path(__file__).resolve().parent
sys.path[:0] = [str(SOURCE), str(SOURCE.parent)]
from common import canonical, decode, read, require
from lifecycle import preflight, run, process
import original_spool as spool
from original_verifier_bundle import BUILD_ID, install_verifier_bundle
from protocol import clock_ns, digest
import uid_policy
from verifier_probe_runtime import checked_ready, checked_supervisor_result, _checked_wait, _checked_process

MODULES = ('verifier_probe_bootstrap.py', 'verifier_probe_runtime.py', 'uid_policy.py',
           'common.py', 'original_verifier.py', 'original_verifier_bundle.py',
           'original_spool.py', 'original_transport.py', 'transport.py', 'protocol.py', 'wait4_child.py')
CASE_BASE = Path('/var/lib/timestep-verifier-probe')
FIELDS = ('Id', 'ActiveState', 'SubState', 'MainPID', 'InvocationID', 'ControlGroup',
          'Slice', 'KillMode', 'Restart', 'RemainAfterExit', 'FragmentPath', 'Result',
          'ExecMainCode', 'ExecMainStatus', 'LoadState', 'Job', 'SourcePath', 'DropInPaths', 'Delegate',
          'ExecMainStartTimestampMonotonic', 'ConditionResult')
SLICE_FIELDS = ('Id', 'ActiveState', 'ControlGroup', 'StopWhenUnneeded', 'FragmentPath',
                'LoadState', 'Job', 'SourcePath', 'DropInPaths')
TARGET_FIELDS = ('Id', 'ActiveState', 'StopWhenUnneeded', 'Wants', 'FragmentPath',
                 'LoadState', 'Job', 'SourcePath', 'DropInPaths')
SCHEDULES = ('valid', 'wrong_hash', 'deno_death', 'supervisor_death', 'reaper_death',
             'guardian_stop', 'no_go', 'recovery')


def sha_file(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for part in iter(lambda: stream.read(65_536), b''):
            value.update(part)
    return value.hexdigest()


def write_once(path, raw, *, mode=0o600, gid=0):
    require(type(raw) is bytes and len(raw) <= 131_072, 'fixture_write_limit')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    try:
        os.fchown(fd, 0, gid)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(raw):
            sent = os.write(fd, raw[offset:])
            require(sent > 0, 'fixture_write_failed')
            offset += sent
        os.fsync(fd)
    finally:
        os.close(fd)
    directory = os.open(Path(path).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def publish_go(path, value):
    # The receiver never sees a partial GO. An interrupted pending publication
    # is retained and not automatically retried.
    pending = path.with_name('go.pending')
    write_once(pending, canonical(value) + b'\n', mode=0o440, gid=62403)
    require(not os.path.lexists(path), 'go_already_published')
    # Only G can write this root-owned directory. A same-directory rename
    # exposes one complete, single-link inode to R in one operation.
    os.rename(pending, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def owned_directory(path, mode=0o755, gid=0, *, create=False):
    if create:
        path.mkdir(mode=mode)
        os.chown(path, 0, gid)
        path.chmod(mode)
    for parent in (path, *path.parents):
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'untrusted_fixture_path')
    info = path.stat()
    require(stat.S_IMODE(info.st_mode) == mode and info.st_gid == gid, 'fixture_directory_mode')


def capture_modules(parent):
    path = parent / 'modules'
    owned_directory(path, create=True)
    inventory = {}
    for name in MODULES:
        source = SOURCE / name if (SOURCE / name).is_file() else SOURCE.parent / name
        data = read(source, 131_072)
        write_once(path / name, data, mode=0o444)
        inventory[name] = digest(data)
    manifest = {'format': 'linux-verifier-probe-capture-v1', 'local_fixture_only': True,
                'hosted_admitted': False, 'files': inventory, 'python_sha256': sha_file('/usr/bin/python3')}
    raw = canonical(manifest)
    write_once(path / 'capture.json', raw, mode=0o444)
    path.chmod(0o555)
    return path, digest(raw), manifest


def show(unit, fields=FIELDS):
    require(re.fullmatch(r'tsverifier[0-9a-f]{32}\.(service|slice|target)', unit), 'invalid_fixture_unit')
    output = run(['/usr/bin/systemctl', 'show', '--no-pager', '--property=' + ','.join(fields), unit])
    result = {}
    for line in output.splitlines():
        key, separator, value = line.partition('=')
        require(separator and key in fields and key not in result, 'invalid_unit_state')
        result[key] = value
    require(set(result) == set(fields), 'incomplete_unit_state')
    return result


def counters(fd):
    result = {}
    for name in ('cgroup.events', 'cpu.stat', 'memory.current', 'memory.peak', 'memory.events',
                 'memory.max', 'memory.swap.max', 'pids.current', 'pids.events', 'pids.max'):
        member = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
        try:
            raw = os.read(member, 4097)
            require(len(raw) <= 4096, 'cgroup_counter_limit')
        finally:
            os.close(member)
        value = raw.decode('ascii').strip()
        if '\n' in value or ' ' in value:
            fields = {}
            for line in value.splitlines():
                key, number = line.split()
                require(key not in fields and number.isdecimal(), 'invalid_cgroup_counter')
                fields[key] = int(number)
            result[name] = fields
        else:
            require(value.isdecimal(), 'invalid_cgroup_counter')
            result[name] = int(value)
    info = os.fstat(fd)
    result['identity'] = {'device': str(info.st_dev), 'inode': str(info.st_ino)}
    return result


def record_if_complete(path):
    raw = read(path, 65_536)
    if not raw or not raw.endswith(b'\n'):
        return None
    require(raw.count(b'\n') == 1, 'invalid_probe_record')
    return decode(raw)


def fixture_input(bundle, descriptor_raw):
    sealed = spool.descriptor(descriptor_raw)
    request = {'version': 1, 'kind': 'original_verify', 'job_id': str(uuid.uuid4()),
               'reservation_id': sealed['reservation_id'], 'source_id': '1706.03762', 'source_revision': 1,
               'bucket': 'paper-assets', 'path': 'originals/' + sealed['reservation_id'] + '/original.pdf',
               'predecessor_operation_id': sealed['claim_id'], 'predecessor_result_sha256': '1' * 64,
               'candidate_sha256': sealed['sha256'], 'candidate_bytes': sealed['bytes'],
               'input_spool_sha256': digest(descriptor_raw), 'byte_ceiling': sealed['bytes'],
               'verification_profile_id': str(uuid.uuid4()), 'stage_recipe_sha256': '2' * 64,
               'build_sha256': bundle.build_identity_sha256, 'parser_profile_sha256': bundle.profile_sha256,
               'verifier_host_policy_sha256': '3' * 64, 'storage_policy_sha256': '4' * 64,
               'spool_policy_sha256': '5' * 64}
    return {'format': 'original-verifier-input-v1', 'local_fixture_only': True, 'claim_id': str(uuid.uuid4()),
            'request': request, 'request_sha256': '6' * 64, 'spool_descriptor': descriptor_raw.decode()}


def allow_fixture(*values):
    # Synthetic transfer/guardian authority only; never a SQL receipt.
    pass


def render(attempt, root, pdf, modules, capture, spools):
    stem = 'tsverifier' + uuid.UUID(attempt).hex
    require(all(re.fullmatch(r'/[A-Za-z0-9_./-]+', str(path)) for path in (root, pdf, modules, spools)),
            'invalid_unit_path')
    values = {'ATTEMPT': attempt, 'ROOT': str(root), 'PDF': str(pdf), 'MODULES': str(modules),
              'CAPTURE': capture, 'SPOOLS': str(spools), 'SLICE': stem + '.slice', 'SERVICE': stem + '.service'}
    result = {}
    for extension in ('slice', 'service', 'target'):
        raw = (SOURCE / ('verifier_probe.' + extension + '.in')).read_text()
        for key, value in values.items():
            raw = raw.replace('@' + key + '@', value)
        require('@' not in raw, 'unexpanded_unit_template')
        result[stem + '.' + extension] = raw.encode()
    return result


def checked_process(pid, uid, parent, cgroup):
    before = process(pid)
    state = uid_policy.status(pid)
    require(state['uids'] == [uid] * 4 and state['gids'] == [uid] * 4 and state['groups'] == []
            and all(value == 0 for value in state['caps'].values()) and state['no_new_privs'] == 1
            and state['seccomp'] == 2 and 1 <= state['threads'] <= 64
            and state['parent_pid'] == parent and before['cgroup'] == cgroup, 'wrong_runtime_boundary')
    tasks = sorted(int(path.name) for path in Path('/proc/' + str(pid) + '/task').iterdir())
    require(len(tasks) <= 64, 'task_limit')
    task_states = [uid_policy.status(task) for task in tasks]
    require(all(item['uids'] == [uid] * 4 and item['gids'] == [uid] * 4 and item['groups'] == []
                and all(cap == 0 for cap in item['caps'].values()) and item['no_new_privs'] == 1
                and item['seccomp'] == 2 for item in task_states), 'thread_privilege_mismatch')
    maps = read('/proc/' + str(pid) + '/maps', 131_072).decode().splitlines()
    mapped_files = sorted({line.split(maxsplit=5)[5] for line in maps if len(line.split(maxsplit=5)) == 6
                           and line.split(maxsplit=5)[5].startswith('/')})
    require(process(pid) == before, 'process_changed')
    return {'identity': before, 'status': state, 'tasks': tasks, 'task_statuses': task_states,
            'mapped_files': mapped_files, 'dumpable': None,
            'dumpable_note': 'Not exposed by this kernel status; exec reset is not suppressed or claimed.'}


def kill_exact(identity):
    require(process(identity['process_id']) == identity, 'process_changed_before_fault')
    fd = os.pidfd_open(identity['process_id'])
    try:
        require(process(identity['process_id']) == identity, 'process_changed_before_fault')
        signal.pidfd_send_signal(fd, signal.SIGKILL)
    finally:
        os.close(fd)


def stop_scope(service):
    run(['/usr/bin/systemctl', 'stop', service], seconds=4)


def join_guardian(watchdog, done):
    done.set()
    if watchdog is not None and watchdog.ident is not None:
        # The thread uses only held cgroup handles. It launches no control
        # subprocess and cannot issue a delayed systemctl stop after cleanup.
        watchdog.join(6)
        require(not watchdog.is_alive(), 'guardian_join_failed')


def kill_scope(fd, kill_fd, identity):
    info = os.fstat(fd)
    require({'device': str(info.st_dev), 'inode': str(info.st_ino)} == identity, 'scope_changed')
    require(os.write(kill_fd, b'1') == 1, 'scope_kill_failed')


def checked_units(units):
    for name, expected in units.items():
        path = Path('/run/systemd/system') / name
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o644 and read(path, 16_384) == expected,
                'unit_definition_changed')
        fields = FIELDS if name.endswith('.service') else SLICE_FIELDS if name.endswith('.slice') else TARGET_FIELDS
        current = show(name, fields)
        require(current['Id'] == name and current['FragmentPath'] == str(path)
                and current['LoadState'] == 'loaded' and current['SourcePath'] == ''
                and current['DropInPaths'] == '' and current['Job'] == '', 'unit_definition_changed')
        if name.endswith('.service'):
            require(current['Delegate'] == 'no', 'delegated_fixture_refused')
        elif name.endswith('.target'):
            require(current['Wants'] == name.removesuffix('.target') + '.service'
                    and current['StopWhenUnneeded'] == 'no', 'reference_target_changed')


def check_fences(control, config, reaper_pid, expected_fence):
    expected_launch = {'format': 'linux-verifier-probe-launch-spent-v1',
        'claim_id': config['input']['claim_id'], 'bundle_sha256': config['bundle_sha256'],
        'input_sha256': digest(canonical(config['input'])), 'process_id': reaper_pid}
    for name, value, mode in (('launch-spent.json', expected_launch, 0o600),
                              ('stop-fence.json', expected_fence, 0o400)):
        path = control / name
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and (info.st_uid, info.st_gid, info.st_nlink) == (0, 0, 1)
                and stat.S_IMODE(info.st_mode) == mode
                and read(path, 4096) == canonical(value) + b'\n', 'fence_changed')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    directory = os.open(control, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def unused_roles():
    roles = {62401, 62402, 62403}
    for identity in roles:
        for lookup in (pwd.getpwuid, grp.getgrgid):
            try:
                lookup(identity)
            except KeyError:
                continue
            raise ValueError('fixture_role_collision')
    processes, tasks = 0, 0
    with os.scandir('/proc') as entries:
        for entry in entries:
            if not entry.name.isdecimal():
                continue
            processes += 1
            require(processes <= 4096, 'process_inventory_limit')
            try:
                with os.scandir('/proc/' + entry.name + '/task') as threads:
                    for thread in threads:
                        require(thread.name.isdecimal(), 'invalid_task_name')
                        tasks += 1
                        require(tasks <= 16384, 'task_inventory_limit')
                        try:
                            raw = read('/proc/' + entry.name + '/task/' + thread.name + '/status', 16_384).decode()
                        except FileNotFoundError:
                            continue
                        values = dict(line.split(':', 1) for line in raw.splitlines())
                        require(not roles.intersection(map(int, values['Uid'].split()))
                                and not roles.intersection(map(int, values['Gid'].split())), 'fixture_live_role_collision')
            except FileNotFoundError:
                continue
    return {'processes_checked': processes, 'tasks_checked': tasks, 'numeric_roles_unused': sorted(roles)}


def single_case(work, bundle, modules, capture, body, schedule):
    attempt = str(uuid.uuid4())
    root = CASE_BASE / uuid.UUID(attempt).hex
    owned_directory(root, create=True)
    control = root / 'control'
    owned_directory(control, 0o750, 62403, create=True)
    for name in ('ready.json', 'report.json'):
        write_once(control / name, b'', mode=0o640, gid=62403)
    write_once(root / 'service.stderr', b'')
    evidence = {'format': 'linux-verifier-probe-evidence-v1', 'local_fixture_only': True,
                'hosted_admitted': False, 'attempt_id': attempt, 'schedule': schedule,
                'runtime_report': None, 'cleanup_complete': False, 'error': None}
    spools = root / 'spools'
    owned_directory(spools, 0o700, create=True)
    slot = {'reservation_id': str(uuid.uuid4()), 'claim_id': str(uuid.uuid4()), 'purpose': 'stored_readback'}
    binding = dict(slot, attempt_id=str(uuid.uuid4()), request_sha256='7' * 64,
                   binding_sha256='8' * 64, capture_sha256='9' * 64)
    service, slice_name = 'tsverifier' + uuid.UUID(attempt).hex + '.service', 'tsverifier' + uuid.UUID(attempt).hex + '.slice'
    reference = 'tsverifier' + uuid.UUID(attempt).hex + '.target'
    installed, scope_fd, kill_fd, watchdog, done, stopped, start_ns = [], None, None, None, threading.Event(), {}, None
    safe_empty, units, fence, config, ready = False, {}, None, None, None
    try:
        with spool.OriginalSpool(spools, slot, producer_uid=0, producer_gid=0) as owner:
            directory = owner.prepare(allow_fixture)
            try:
                with spool.Producer(directory, binding) as producer:
                    for offset in range(0, len(body), spool.CHUNK):
                        producer.append(body[offset:offset + spool.CHUNK])
                    completion = producer.finish({'status': 200, 'framing': 'content-length',
                        'framing_complete': True, 'bytes': len(body), 'sha256': digest(body)})
            finally:
                os.close(directory)
            descriptor_raw = owner.seal(binding, completion, allow_fixture)
            evidence['descriptor_sha256'] = digest(descriptor_raw)
            pdf = spools / owner.name / owner.leaf_name / 'guardian' / 'payload'
            value = fixture_input(bundle, descriptor_raw)
            if schedule == 'wrong_hash':
                # Author an explicitly synthetic request/descriptor disagreement
                # with the actual held bytes; every parent sees the same claim.
                altered = decode(descriptor_raw)
                altered['sha256'] = '0' * 64
                value['spool_descriptor'] = (canonical(altered) + b'\n').decode()
                value['request'].update(candidate_sha256='0' * 64,
                                        input_spool_sha256=digest(value['spool_descriptor'].encode()))
            with owner.open_sealed(descriptor_raw, allow_fixture) as held:
                units = render(attempt, root, pdf, modules, capture, spools)
                evidence['unit_sha256'] = {name: digest(raw) for name, raw in units.items()}
                for name, raw in units.items():
                    target = Path('/run/systemd/system') / name
                    write_once(target, raw, mode=0o644)
                    installed.append(target)
                run(['/usr/bin/systemd-analyze', 'verify', *map(str, installed)])
                run(['/usr/bin/systemctl', 'daemon-reload'])
                run(['/usr/bin/systemctl', 'start', slice_name])
                checked_units(units)
                initial_unit = show(slice_name, SLICE_FIELDS)
                require(initial_unit['ActiveState'] == 'active' and initial_unit['StopWhenUnneeded'] == 'no'
                        and initial_unit['ControlGroup'] == '/' + slice_name, 'invalid_retained_slice')
                scope_path = Path('/sys/fs/cgroup') / slice_name
                scope_fd = os.open(scope_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                domain_fd = os.open('cgroup.type', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=scope_fd)
                try:
                    require(os.read(domain_fd, 64) == b'domain\n', 'domain_scope_required')
                finally:
                    os.close(domain_fd)
                kill_fd = os.open('cgroup.kill', os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=scope_fd)
                initial = counters(scope_fd)
                require(initial['cgroup.events']['populated'] == 0 and initial['cpu.stat']['usage_usec'] == 0
                        and initial['pids.current'] == 0 and initial['memory.current'] == 0
                        and initial['memory.peak'] == 0 and initial['pids.max'] == 64
                        and initial['memory.max'] == 268_435_456 and initial['memory.swap.max'] == 0,
                        'nonfresh_counter_scope')
                evidence['initial'] = initial
                start_ns = clock_ns()
                config = {'format': 'linux-verifier-probe-config-v1', 'local_fixture_only': True,
                          'bundle_path': str(bundle.root), 'bundle_sha256': bundle.sha256, 'input': value,
                          'execution_id': str(uuid.uuid4()), 'binding_sha256': 'a' * 64,
                          'startup_deadline_ns': str(start_ns + 5_000_000_000),
                          'go_deadline_ns': str(start_ns + 10_000_000_000),
                          'collection_deadline_ns': str(start_ns + 19_000_000_000)}
                write_once(control / 'config.json', canonical(config) + b'\n', mode=0o400)
                guardian_deadline = [start_ns + 20_000_000_000]

                def guard():
                    try:
                        while not done.wait(.02):
                            now = counters(scope_fd)
                            require(now['identity'] == initial['identity'], 'scope_changed')
                            if clock_ns() >= guardian_deadline[0] or now['cpu.stat']['usage_usec'] > 2_000_000:
                                stopped['reason'] = 'guardian_wall_or_cpu_stop'
                                break
                    except Exception as error:
                        stopped['reason'] = type(error).__name__ + ':' + str(error)[:120]
                    if stopped:
                        try:
                            kill_scope(scope_fd, kill_fd, initial['identity'])
                        except Exception:
                            stopped['stop_uncertain'] = True

                watchdog = threading.Thread(target=guard, name='verifier-scope-guardian', daemon=True)
                watchdog.start()
                try:
                    run(['/usr/bin/systemctl', 'start', reference])
                    require(show(reference, TARGET_FIELDS)['ActiveState'] == 'active', 'reference_not_active')
                    ready = None
                    while clock_ns() < int(config['startup_deadline_ns']) and not stopped:
                        ready = record_if_complete(control / 'ready.json')
                        if ready is not None:
                            break
                        require(show(service)['ActiveState'] in ('active', 'activating'), 'service_ended_before_ready')
                        time.sleep(.02)
                    require(ready is not None, 'missing_ready')
                    evidence['ready'] = ready
                    unit = show(service)
                    evidence['service'] = unit
                    checked_units(units)
                    require(unit['KillMode'] == 'control-group' and unit['Restart'] == 'no'
                            and unit['RemainAfterExit'] == 'no' and unit['Slice'] == slice_name
                            and unit['ControlGroup'] == '/' + slice_name + '/' + service,
                            'service_policy_mismatch')
                    identities = observe_ready(ready, unit, held, config)
                    evidence['processes'] = identities
                    fence = {'format': 'linux-verifier-probe-stop-fence-v1', 'attempt_id': attempt,
                             'boot_id': preflight()['boot_id'], 'invocation_id': unit['InvocationID'],
                             'scope': initial['identity'], 'ready_sha256': digest(canonical(ready))}
                    write_once(control / 'stop-fence.json', canonical(fence) + b'\n', mode=0o400)
                    check_fences(control, config, int(unit['MainPID']), fence)
                    if schedule in ('deno_death', 'supervisor_death', 'reaper_death'):
                        role = schedule.removesuffix('_death')
                        kill_exact(identities[role]['identity'])
                    if schedule == 'guardian_stop':
                        # Exercise the independent guard's actual retained
                        # kernel stop handle while all three roles are paused.
                        guardian_deadline[0] = clock_ns()
                    if schedule not in ('supervisor_death', 'reaper_death', 'guardian_stop', 'no_go'):
                        useful_deadline = min(clock_ns() + 4_500_000_000,
                                              int(config['collection_deadline_ns']) - 500_000_000)
                        guardian_deadline[0] = min(guardian_deadline[0], useful_deadline + 500_000_000)
                        publish_go(control / 'go.json', {'format': 'linux-verifier-probe-go-v1',
                            'local_fixture_only': True, 'claim_id': value['claim_id'],
                            'execution_id': config['execution_id'], 'binding_sha256': config['binding_sha256'],
                            'input_sha256': digest(canonical(value)), 'bundle_sha256': bundle.sha256,
                            'deadline_ns': str(useful_deadline)})
                    while clock_ns() < int(config['collection_deadline_ns']) and not stopped:
                        report = record_if_complete(control / 'report.json')
                        if report is not None:
                            evidence['runtime_report'] = report
                        if counters(scope_fd)['cgroup.events']['populated'] == 0:
                            break
                        time.sleep(.02)
                finally:
                    join_guardian(watchdog, done)
                    checked_units(units)
                    if fence is not None:
                        check_fences(control, config, ready['reaper']['process_id'], fence)
                    stop_scope(service)
                    final = counters(scope_fd)
                    require(final['identity'] == initial['identity'] and final['cgroup.events']['populated'] == 0
                            and final['pids.current'] == 0 and scope_path.stat().st_ino == int(initial['identity']['inode']),
                            'scope_not_retired')
                    safe_empty = True
                    evidence['final'] = final
                    evidence['startup_to_empty_ms'] = (clock_ns() - start_ns) / 1e6
                    evidence['guardian_stop'] = stopped or None
                    evidence['service_exit'] = show(service)
                    report = record_if_complete(control / 'report.json')
                    if report is not None:
                        evidence['runtime_report'] = report
                    require(os.lseek(held, 0, os.SEEK_CUR) == 0, 'guardian_offset_changed')
                # Even reset-failed cannot remove the durable start fences.
                checked_units(units)
                check_fences(control, config, ready['reaper']['process_id'], fence)
                old_start = evidence['service_exit']['ExecMainStartTimestampMonotonic']
                require(old_start == evidence['service']['ExecMainStartTimestampMonotonic'] and int(old_start) > 0,
                        'service_start_changed')
                old_outputs = {name: sha_file(control / name) for name in ('ready.json', 'report.json')}
                run(['/usr/bin/systemctl', 'reset-failed', service])
                run(['/usr/bin/systemctl', 'start', service])
                denied = show(service)
                require(denied['MainPID'] == '0' and denied['ConditionResult'] == 'no'
                        and denied['ExecMainStartTimestampMonotonic'] == old_start
                        and counters(scope_fd)['cgroup.events']['populated'] == 0
                        and all(sha_file(control / name) == expected for name, expected in old_outputs.items()),
                        'restart_was_not_denied')
                check_fences(control, config, ready['reaper']['process_id'], fence)
                evidence['restart_attempt'] = denied
                evidence['restart_denied'] = True
            cleanup = owner.capture_cleanup(binding, lambda *args: require(safe_empty, 'scope_unknown'))
            evidence['spool_cleanup'] = decode(owner.retire_slots(cleanup, allow_fixture))
        validate_case(evidence, schedule, config, bundle)
    except BaseException as error:
        evidence['error'] = type(error).__name__ + ':' + str(error)[:240]
    finally:
        joined = False
        try:
            join_guardian(watchdog, done)
            joined = True
        except Exception:
            evidence['cleanup_error'] = 'guardian_join_failed; retain scope FD, units and slots'
        if installed and joined:
            try:
                checked_units(units)
                if fence is not None:
                    check_fences(control, config, ready['reaper']['process_id'], fence)
                stop_scope(service)
                if scope_fd is not None:
                    final = counters(scope_fd)
                    safe_empty = (final['cgroup.events']['populated'] == 0 and final['pids.current'] == 0
                                  and final['identity'] == evidence['initial']['identity'])
                    evidence['cleanup_final'] = final
                if safe_empty or scope_fd is None:
                    run(['/usr/bin/systemctl', 'stop', reference])
                    run(['/usr/bin/systemctl', 'stop', slice_name])
                    for path in installed:
                        path.unlink()
                    run(['/usr/bin/systemctl', 'daemon-reload'])
                    with contextlib.suppress(ValueError):
                        run(['/usr/bin/systemctl', 'reset-failed', service])
                    evidence['cleanup_complete'] = True
            except Exception as error:
                evidence['cleanup_error'] = type(error).__name__ + ':' + str(error)[:240]
        if scope_fd is not None and joined:
            os.close(scope_fd)
        if kill_fd is not None and joined:
            os.close(kill_fd)
        error_raw = read(root / 'service.stderr', 131_072)
        evidence['service_stderr'] = {'path': str(root / 'service.stderr'), 'bytes': len(error_raw),
            'sha256': digest(error_raw), 'preview': error_raw[:1024].decode(errors='replace')}
        write_once(work / (schedule + '-' + uuid.UUID(attempt).hex + '.json'), canonical(evidence) + b'\n')
    require(evidence['error'] is None and evidence['cleanup_complete'], 'probe_case_failed:' + schedule)
    return evidence


def observe_ready(ready, unit, held, config):
    require(type(ready) is dict and set(ready) == {'format', 'local_fixture_only', 'hosted_admitted',
            'reaper', 'supervisor_ready'} and ready['format'] == 'linux-verifier-probe-ready-v1'
            and ready['local_fixture_only'] is True and ready['hosted_admitted'] is False, 'invalid_ready')
    reaper = _checked_process(ready['reaper'], 62403, 1)
    require(str(reaper['process_id']) == unit['MainPID'], 'reaper_identity_mismatch')
    supervisor = ready['supervisor_ready']
    checked_ready(canonical(supervisor) + b'\n', config, supervisor['supervisor']['process_id'], reaper['process_id'])
    boot = read('/proc/sys/kernel/random/boot_id', 128).decode().strip()
    result = {}
    for role, record, uid, parent in (
            ('reaper', reaper, 62403, 1),
            ('supervisor', supervisor['supervisor'], 62401, reaper['process_id']),
            ('deno', supervisor['deno'], 62402, supervisor['supervisor']['process_id'])):
        current = checked_process(record['process_id'], uid, parent, unit['ControlGroup'])
        require(record['boot_id'] == boot and record['process_start_id'] == current['identity']['process_start_id']
                and record['cgroup'] == '0::' + unit['ControlGroup'] + '\n', 'process_identity_mismatch')
        result[role] = current
    members = sorted(map(int, read('/sys/fs/cgroup' + unit['ControlGroup'] + '/cgroup.procs', 4096).split()))
    require(members == sorted(item['identity']['process_id'] for item in result.values()), 'unexpected_ready_process')
    deno = supervisor['deno']['process_id']
    before = process(deno)
    fd_root = Path('/proc') / str(deno) / 'fd'
    pdf_info, original = (fd_root / '0').stat(), os.fstat(held)
    require(stat.S_ISREG(pdf_info.st_mode) and pdf_info.st_nlink == 1
            and (pdf_info.st_dev, pdf_info.st_ino, pdf_info.st_size) ==
                (original.st_dev, original.st_ino, original.st_size), 'inherited_pdf_changed')
    fdinfo = dict(line.split(':', 1) for line in read('/proc/' + str(deno) + '/fdinfo/0', 4096).decode().splitlines())
    require(int(fdinfo['pos']) == 0 and int(fdinfo['flags'], 8) & os.O_ACCMODE == os.O_RDONLY,
            'inherited_pdf_not_paused')
    pipe = supervisor['control']
    pipe_info = (fd_root / str(pipe['child_fd'])).stat()
    require(stat.S_ISFIFO(pipe_info.st_mode) and (pipe_info.st_uid, pipe_info.st_gid) == (0, 62402)
            and stat.S_IMODE(pipe_info.st_mode) == 0o440
            and (str(pipe_info.st_dev), str(pipe_info.st_ino)) == (pipe['device'], pipe['inode']),
            'control_pipe_changed')
    pipe_flags = dict(line.split(':', 1) for line in
                      read('/proc/' + str(deno) + '/fdinfo/' + str(pipe['child_fd']), 4096).decode().splitlines())
    require(int(pipe_flags['flags'], 8) & os.O_ACCMODE == os.O_RDONLY, 'control_pipe_writable')
    require(process(deno) == before, 'process_changed')
    result['deno']['pdf'] = {'device': str(pdf_info.st_dev), 'inode': str(pdf_info.st_ino),
                             'bytes': pdf_info.st_size, 'offset': 0, 'access_mode': 'read-only'}
    result['deno']['control'] = pipe
    return result


def validate_case(evidence, schedule, config, bundle):
    require(evidence['restart_denied'] and evidence['final']['cgroup.events']['populated'] == 0
            and evidence['final']['identity'] == evidence['initial']['identity'], 'retirement_incomplete')
    report = evidence['runtime_report']
    if schedule in ('reaper_death', 'guardian_stop'):
        require(report is None and evidence['service_exit']['Result'] == 'signal'
                and evidence['service_exit']['ExecMainCode'] == '2'
                and evidence['service_exit']['ExecMainStatus'] == str(int(signal.SIGKILL)), 'reaper_death_not_observed')
        if schedule == 'guardian_stop':
            require(evidence['guardian_stop'] == {'reason': 'guardian_wall_or_cpu_stop'}, 'guardian_stop_not_observed')
        return
    require(type(report) is dict and set(report) == {'format', 'local_fixture_only', 'hosted_admitted',
            'claim_id', 'execution_id', 'bundle_sha256', 'input_sha256', 'ready_published', 'go_forwarded',
            'complete', 'verified', 'reason', 'supervisor_result', 'supervisor_wait',
            'supervisor_wait_authority_lost', 'ipc_cleanup_complete'}
            and report['format'] == 'linux-verifier-probe-report-v1'
            and report['local_fixture_only'] is True and report['hosted_admitted'] is False,
            'invalid_runtime_report')
    for key, value in {'claim_id': config['input']['claim_id'], 'execution_id': config['execution_id'],
                       'bundle_sha256': config['bundle_sha256'],
                       'input_sha256': digest(canonical(config['input']))}.items():
        require(report[key] == value, 'runtime_report_binding')
    require(all(type(report[key]) is bool for key in ('ready_published', 'go_forwarded', 'complete', 'verified',
                'supervisor_wait_authority_lost', 'ipc_cleanup_complete')), 'invalid_runtime_report')
    ready = evidence['ready']['supervisor_ready']
    supervisor_wait = _checked_wait(report['supervisor_wait'], ready['supervisor']['process_id'])
    nested = report['supervisor_result']
    if nested is not None:
        checked_supervisor_result(canonical(nested) + b'\n', config, ready, bundle)
    if schedule in ('valid', 'recovery', 'wrong_hash'):
        require(report['complete'] and report['reason'] is None and report['ready_published']
                and report['go_forwarded'] and report['ipc_cleanup_complete']
                and not report['supervisor_wait_authority_lost'] and nested is not None
                and supervisor_wait['returncode'] == 0 and supervisor_wait['metrics_error'] is None
                and nested['session']['complete'] and evidence['guardian_stop'] is None
                and evidence['final']['cpu.stat']['usage_usec'] <= 2_000_000
                and evidence['service_exit']['ExecMainCode'] == '1'
                and evidence['service_exit']['ExecMainStatus'] == '0'
                and evidence['service_exit']['Result'] == 'success', 'measured_completion_missing')
        deno_wait = nested['session']['retirement']
        envelope = 1024 * (supervisor_wait['rusage']['ru_maxrss'] + deno_wait['rusage']['ru_maxrss'])
        require(envelope <= 268_435_456, 'rss_probe_limit')
        evidence['measurements'] = {'scope_cpu_usec': evidence['final']['cpu.stat']['usage_usec'],
            'conservative_overlapping_rss_bytes': envelope,
            'scope_charged_memory_peak_bytes': evidence['final']['memory.peak'],
            'cpu_records_summed': False, 'reaper_rss_in_envelope': False,
            'lifetime_task_peak': None, 'hosted_admitted': False}
        result = nested['session']['result']
        if schedule == 'wrong_hash':
            require(not report['verified'] and result['kind'] == 'refused'
                    and result['reason'] == 'input_mismatch', 'wrong_hash_was_not_refused')
        else:
            require(report['verified'] and result['kind'] == 'parsed'
                    and result['parser_result']['outcome'] == 'verified'
                    and result['parser_result']['pages'] == 1, 'pdf_not_verified')
    else:
        require(not report['complete'] and not report['verified'] and report['reason'] is not None,
                'negative_schedule_accepted')
        if schedule == 'supervisor_death':
            require(supervisor_wait['returncode'] == -signal.SIGKILL and nested is None, 'supervisor_death_not_observed')
        if schedule == 'deno_death':
            require(nested is not None and nested['session'] is not None
                    and nested['session']['retirement']['returncode'] == -signal.SIGKILL,
                    'deno_death_not_observed')
        if schedule == 'no_go':
            require(not report['go_forwarded'] and nested is not None and not nested['go_received']
                    and (nested['session'] is None or nested['session']['result'] is None), 'missing_go_not_observed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True)
    parser.add_argument('--deno', required=True)
    parser.add_argument('--schedules', nargs='+', choices=SCHEDULES, default=list(SCHEDULES))
    args = parser.parse_args()
    require(1 <= len(args.schedules) <= len(SCHEDULES) and len(set(args.schedules)) == len(args.schedules),
            'finite_unique_schedules_required')
    platform = preflight()
    work = Path(args.work)
    require(re.fullmatch(r'/opt/timestep-verifier-lab/[a-z0-9-]{1,64}/evidence', str(work)), 'invalid_work_path')
    owned_directory(work, create=True)
    roles = unused_roles()
    if not CASE_BASE.exists():
        owned_directory(CASE_BASE, create=True)
    else:
        owned_directory(CASE_BASE)
    modules, capture, capture_manifest = capture_modules(work)
    require(sha_file(args.deno) == 'd08d392418df53f4e6e88a08909c0e1bccbf9adcead7232df72b6ad6075ec416',
            'unreviewed_linux_runtime')
    bundle = install_verifier_bundle(work, BUILD_ID, args.deno)
    fixtures = SOURCE.parents[2] / '.artifacts/pdf-verifier/fixtures'
    body = read(fixtures / 'pages-1.pdf', spool.MAX_PAYLOAD)
    require(digest(body) == '50ad8729a600bc818abfc01f90ae7d97c35b4d6e7a388c3f54bb5160c53a1460', 'fixture_changed')
    summary = {'format': 'linux-verifier-probe-summary-v1', 'local_fixture_only': True, 'hosted_admitted': False,
               'platform': platform, 'role_preflight': roles, 'capture_sha256': capture, 'capture': capture_manifest,
               'bundle_sha256': bundle.sha256, 'bundle': bundle.manifest, 'cases': []}
    summary['guardian_sources'] = {name: sha_file(SOURCE / name) for name in
        ('verifier_probe.py', 'verifier_probe.service.in', 'verifier_probe.slice.in',
         'verifier_probe.target.in', 'lifecycle.py')}
    libraries = ['/lib/ld-linux-aarch64.so.1', *('/usr/lib/aarch64-linux-gnu/' + name for name in
                 ('libdl.so.2', 'libgcc_s.so.1', 'libpthread.so.0', 'libm.so.6', 'libc.so.6'))]
    summary['runtime_libraries'] = [{'path': path, 'resolved': str(Path(path).resolve()),
        'bytes': Path(path).stat().st_size, 'sha256': sha_file(path)} for path in libraries]
    for schedule in args.schedules:
        result = single_case(work, bundle, modules, capture, body, schedule)
        summary['cases'].append({'attempt_id': result['attempt_id'], 'schedule': schedule,
                                 'startup_to_empty_ms': result['startup_to_empty_ms']})
        print(json.dumps(summary['cases'][-1]), flush=True)
    bundle.verify()
    write_once(work / 'summary.json', canonical(summary) + b'\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

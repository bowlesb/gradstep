"""Opt-in, marked-Linux-only PG17 + captured metadata action + loopback TLS.

Run this file separately from test_prerequisite.py, as root, with the selected
Linux Python using -I -S -B. No setup runs on import or ordinary discovery.
Required TIMESTEP_METADATA_* variables: SOURCE_ROOT, DB_MANIFEST,
DB_MANIFEST_SHA256, DB_PORT, PARSER_DIR, RUNTIME_INVENTORY, PYTHON, DENO and
EVIDENCE_ROOT. Also set TIMESTEP_LINUX_METADATA_RUN=1. TIMESTEP_METADATA_SCENARIO
is exactly normal (default) or supervisor_death; one fresh instance runs one
workflow. The evidence path must be
new: /var/lib/timestep-metadata-fixture-runs/<12 lowercase hex characters>.

The supplied parser was built on this guest; this harness neither downloads nor
builds it. Owner SQL is fixture setup/audit only. The two source actions use the
unchanged captured guardian/controller and distinct actual restricted logins.
Any failed setup/action/check leaves its owned state for explicit review. Only
the selected, fully acknowledged schedule reaches the narrow cleanup below.
Only supervisor_death permits one exact reset-failed for its killed service,
after durable fault/result/receipt/empty-scope proof while its original unit and
permanent start fence are checked under the held lock. No restart is permitted.
The immutable bundle and bounded evidence remain for export after cleanup.
"""
from contextlib import contextmanager
import copy
import fcntl
import grp
import hashlib
import os
from pathlib import Path
import pwd
import re
import select
import signal
import socket
import stat
import sys
import threading
import time
import unittest
import uuid

# Explicit source imports for the test harness, never inherited PYTHONPATH.
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import fixture_database as database
import lifecycle
import metadata_bootstrap as bootstrap
from action_journal import RECORDS, _open_directory, _read as read_record
from execution_contract import source_dto, validate_execution
from metadata_host import HostAction, HOST, PROJECT, trusted_directory
from metadata_scope import MetadataScope, checked_go, policy_hashes
from metadata_settlement import check_ack, checked_observation
from protocol import clock_ns
from restricted_rpc import RestrictedRPC
from tls_fixture import Server
import uid_policy
import witness_slots

ENABLED = sys.platform == 'linux' and os.environ.get('TIMESTEP_LINUX_METADATA_RUN') == '1'
ACCOUNTS = ((62401, 'timestep-supervisor'), (62402, 'timestep-source'), (62403, 'timestep-executor'))
RUNS = Path('/var/lib/timestep-metadata-fixture-runs')
BUNDLES = Path('/var/lib/timestep-source/metadata-bundles')
SOURCE = '2403.81001'  # Same synthetic source/metadata as ../test_integration.py.
MAX_EVIDENCE = 524_288
FAULT = 'supervisor_death'


def selected_scenario():
    value = os.environ.get('TIMESTEP_METADATA_SCENARIO', 'normal')
    require(value in ('normal', FAULT), 'invalid_fixture_scenario')
    return value


def require(value, code):
    if not value:
        raise ValueError(code)


def atom():
    return ('<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/' + SOURCE +
            'v1</id><title>Local fixture paper</title><published>2024-03-01T00:00:00Z</published>'
            '<updated>2024-03-02T00:00:00Z</updated><author><name>Ada Example</name></author>'
            '<summary>Fixture only.</summary><category term="cs.LG"/></entry></feed>').encode()


def license_xml():
    # Deliberately source-only: the successful metadata journey must not claim a
    # verified original, eligible shared asset, conversion or paid worker result.
    return ('<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><GetRecord><record><header>'
            '<identifier>oai:arXiv.org:' + SOURCE + '</identifier></header><metadata>'
            '<arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/"><id>' + SOURCE + '</id>'
            '<version version="v1"><date>Sat, 02 Mar 2024 00:00:00 GMT</date></version>'
            '<license>http://arxiv.org/licenses/nonexclusive-distrib/1.0/</license>'
            '</arXivRaw></metadata></record></GetRecord></OAI-PMH>').encode()


class SingleRequestServer(Server):
    """Reuse the TLS fixture; also detect any attempted second connection."""
    def serve(self):
        deadline = time.monotonic() + 120
        super().serve()
        while self.error is None and not self.stop.is_set() and time.monotonic() < deadline:
            try:
                extra, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            extra.close()
            self.error = AssertionError('unexpected_second_fixture_connection')


def owned_directory(path, mode, *, create=False):
    require(path.is_absolute() and path.resolve() == path, 'redirected_fixture_directory')
    if create:
        database.directory(path, mode=mode)
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and value.st_uid == 0 and value.st_gid == 0
            and stat.S_IMODE(value.st_mode) == mode, 'fixture_directory_changed')


def account_command(arguments):
    require(arguments[0] in ('groupadd', 'useradd', 'userdel', 'groupdel'), 'invalid_account_operation')
    database.checked(['/usr/sbin/' + arguments[0], *arguments[1:]], timeout=5, maximum=4096)


def fixture_certificate(root):
    cert, key, config = root / 'fixture.pem', root / 'fixture.key', root / 'openssl.cnf'
    database.create_file(config, b'[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
        b'[dn]\nCN=export.arxiv.org\n[ext]\n'
        b'subjectAltName=DNS:export.arxiv.org,DNS:oaipmh.arxiv.org\n'
        b'basicConstraints=critical,CA:TRUE\n')
    # sources() already checked this absolute executable against the reviewed
    # database manifest; checked() supplies only the fixed minimal environment.
    database.checked([database.OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-keyout', str(key), '-out', str(cert), '-config', str(config)], timeout=15, maximum=1024)
    for path in (cert, key):
        database.read_file(path, 16_384, private=True)
    database.sync_dir(root)
    return cert, key


def explicit_path(name):
    value = os.environ.get('TIMESTEP_METADATA_' + name)
    require(type(value) is str and value and Path(value).is_absolute()
            and Path(value).resolve() == Path(value), 'explicit_fixture_path_required')
    return Path(value)


def fault_target(action, job):
    """Read immutable published inputs without taking the guardian's held lock."""
    def record(name):
        leaf, maximum = RECORDS[name]
        owner, group, mode = cleanup_identity(leaf)
        trusted_directory(action.layout[leaf].parent)
        fd = _open_directory(action.layout[leaf], owner, group, mode)
        try:
            require(os.stat(name, dir_fd=fd, follow_symlinks=False).st_nlink == 1, 'fault_record_alias')
            raw = read_record(fd, name, owner, group, 0o640 if leaf == 'control' else 0o600,
                              maximum, sync=True)
            os.fsync(fd)
        finally:
            os.close(fd)
        value = database.decode(raw)
        require(database.canonical(value) == raw, 'noncanonical_fault_record')
        return value
    capture, ready = record('capture.json'), record('ready.json')
    binding = copy.deepcopy(capture['binding_without_capture_sha256'])
    binding['scope']['capture_sha256'] = database.sha(database.canonical(capture))
    MetadataScope(action.manifest, action.render).checked_capture(capture, ready, binding)
    require(capture['job_id'] == job and capture['claim_id'] == action.claim
            and binding['boot_id'] == lifecycle.boot_id(), 'fault_capture_changed')
    fence = {'schema_version': 1, 'kind': 'linux_metadata_stop_fence_v1', 'scope_id': action.claim,
             'capture_sha256': binding['scope']['capture_sha256']}
    require(record('stop-fence.json') == fence, 'fault_fence_changed')
    go = record('go.json')
    require(go == record('go-intent.json'), 'fault_go_changed')
    execution_id, _ = checked_go(go, action.claim, ready)
    grant = record('grant.json')['response']
    execution = grant['execution']
    validate_execution(execution, binding, job, action.claim)
    require(grant['granted'] is True and grant['action'] == 'perform_stage'
            and execution['id'] == execution_id and execution['kind'] == 'atom'
            and source_dto(grant['job'], execution['kind'], execution['byte_ceiling']) == capture['source_request']
            and capture['source_request'] == {'source_id': SOURCE, 'revision': 1, 'stage': 'atom',
                                             'byte_ceiling': 1_048_576}, 'fault_grant_changed')
    for path, raw in action.units.items():
        info = path.lstat()
        require(info.st_gid == 0 and stat.S_IMODE(info.st_mode) == 0o644
                and database.read_file(path, 16_384) == raw, 'fault_unit_changed')
    require(capture['unit_sha256'] == database.sha(action.units[Path('/run/systemd/system') / action.service])
            and capture['slice_sha256'] == database.sha(action.units[Path('/run/systemd/system') / action.slice]),
            'fault_unit_changed')
    pid = capture['supervisor']['process_id']
    uid_policy.checked_status(pid, 62401)
    process = lifecycle.process(pid)
    unit = lifecycle.show(action.service, lifecycle.SERVICE_FIELDS + ('DropInPaths', 'SourcePath'), family='tsmetadata')
    require(process['process_start_id'] == capture['supervisor']['process_start_id']
            and process['cgroup'] == '/' + action.slice + '/' + action.service
            and unit['Id'] == action.service and unit['LoadState'] == 'loaded'
            and unit['ActiveState'] == 'active' and unit['SubState'] == 'running'
            and unit['MainPID'] == str(pid) and unit['InvocationID'] == ready['invocation_id']
            and unit['ControlGroup'] == process['cgroup'] and unit['Slice'] == action.slice
            and unit['KillMode'] == 'control-group' and unit['Restart'] == 'no' and unit['Delegate'] == 'no'
            and unit['Job'] == unit['DropInPaths'] == unit['SourcePath'] == ''
            and unit['FragmentPath'] == '/run/systemd/system/' + action.service, 'fault_supervisor_changed')
    uid_policy.checked_status(pid, 62401)
    require(lifecycle.process(pid) == process, 'fault_supervisor_changed')
    checked_go(go, action.claim, ready)
    return fault_intent(capture, ready, execution, go, fence, action.service)


def fault_intent(capture, ready, execution, go, fence, service):
    return {'schema_version': 1, 'kind': 'test_supervisor_death_intent_v1', 'job_id': capture['job_id'],
        'claim_id': capture['claim_id'], 'execution_id': execution['id'], 'generation': execution['generation'],
        'binding_sha256': execution['binding_sha256'], 'bundle_sha256': ready['bundle_sha256'],
        'capture_sha256': database.sha(database.canonical(capture)), 'go_sha256': database.sha(database.canonical(go)),
        'fence_sha256': database.sha(database.canonical(fence)), 'source_sha256': ready['source_sha256'],
        'boot_id': capture['binding_without_capture_sha256']['boot_id'], 'invocation_id': ready['invocation_id'],
        'supervisor': capture['supervisor'], 'service': service,
        'headers_sent': True, 'signal': 'SIGKILL', 'mechanism': 'pidfd',
        'new_retirement_receipt': False}


class SupervisorDeath:
    """One finite test injector. It never owns the guardian or a source receipt."""
    def __init__(self, fixture, action, job, record):
        require(callable(getattr(os, 'pidfd_open', None))
                and callable(getattr(signal, 'pidfd_send_signal', None)), 'pidfd_required')
        self.fixture, self.action, self.job, self.record = fixture, action, job, record
        self.cancel, self.lock = threading.Event(), threading.Lock()
        self.error = self.outcome = None
        self.thread = threading.Thread(target=self.inject, name='metadata-supervisor-death')

    def __enter__(self):
        self.thread.start()
        return self

    def inject(self):
        handle = None
        try:
            deadline = time.monotonic() + 12
            while not self.fixture.headers_sent.is_set():
                require(not self.cancel.wait(.02) and time.monotonic() < deadline, 'fault_headers_not_observed')
            require(self.fixture.slow and self.fixture.requested.is_set() and self.fixture.connections == 1,
                    'fault_source_not_held')
            target = fault_target(self.action, self.job)
            handle = os.pidfd_open(target['supervisor']['process_id'], 0)
            require(fault_target(self.action, self.job) == target, 'fault_target_changed_after_open')
            require(not select.select([handle], [], [], 0)[0], 'fault_target_exited')
            self.record('fault-intent.json', target)
            # Cancellation and the final decision serialize with the caller's
            # join. Recheck immutable inputs and live identity after publication.
            with self.lock:
                require(not self.cancel.is_set(), 'fault_cancelled')
                require(fault_target(self.action, self.job) == target, 'fault_target_changed_before_signal')
                require(not select.select([handle], [], [], 0)[0] and not self.cancel.is_set(), 'fault_target_exited')
                signal.pidfd_send_signal(handle, signal.SIGKILL, None, 0)
            require(bool(select.select([handle], [], [], 2)[0]), 'fault_supervisor_exit_unobserved')
            self.outcome = {'schema_version': 1, 'kind': 'test_supervisor_death_outcome_v1',
                'intent_sha256': database.sha(database.canonical(target)), 'claim_id': self.action.claim,
                'execution_id': target['execution_id'], 'signal_count': 1, 'pidfd_exit_observed': True,
                'new_retirement_receipt': False}
            self.record('fault-outcome.json', self.outcome)
        except BaseException as error:
            self.error = error
        finally:
            if handle is not None:
                os.close(handle)

    def __exit__(self, *_):
        with self.lock:
            self.cancel.set()
        # No action result can escape with a still-running injector or a hidden
        # error. Its three bounded systemctl reads precede the one signal.
        self.thread.join(20)
        require(not self.thread.is_alive(), 'fault_injector_not_joined')
        if self.error is not None:
            raise self.error
        require(self.outcome is not None, 'fault_not_injected')


def require_no_fixture_runtime():
    # This is a cleanup precondition, never a substitute for a retirement RPC.
    with os.scandir('/proc') as entries:
        for count, entry in enumerate(entries, 1):
            require(count <= 65_536, 'process_inventory_limit')
            if not entry.name.isdecimal():
                continue
            try:
                raw = lifecycle.read('/proc/' + entry.name + '/status', 16_384)
            except FileNotFoundError:
                continue
            match = re.search(rb'^Uid:\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)$', raw, re.M)
            require(match is not None and not any(int(x) in (62401, 62402, 62403) for x in match.groups()),
                    'source_runtime_still_present')


def removed_unit_state(unit, *, service):
    fields = ('Id', 'LoadState', 'ActiveState', 'SubState', 'FragmentPath', 'SourcePath',
              'DropInPaths', 'Job', 'ControlGroup') + (('MainPID',) if service else ())
    code, raw, _ = database.run(['/usr/bin/systemctl', 'show', unit, '--no-pager',
                                 '--property=' + ','.join(fields)], timeout=5, maximum=4096)
    require(code in (0, 4), 'unit_unload_unresolved')
    values = {}
    for line in raw.decode('utf8').splitlines():
        key, separator, value = line.partition('=')
        require(separator and key in fields and key not in values, 'invalid_unloaded_unit_state')
        values[key] = value
    require(set(values) == set(fields) and values['Id'] == unit
            and values['LoadState'] in (('not-found',) if service else ('loaded', 'not-found'))
            and values['ActiveState'] == 'inactive' and values['SubState'] == 'dead'
            and all(values[key] == '' for key in ('FragmentPath', 'SourcePath', 'DropInPaths', 'Job', 'ControlGroup'))
            and (not service or values['MainPID'] == '0'), 'unit_unload_unresolved')
    return values


def removed_runtime(action, observation):
    """Current absence after definition removal, distinct from the saved proof."""
    require(lifecycle.boot_id() == observation['boot_id'], 'changed_boot_requires_review')
    require(all(not os.path.lexists(path) for path in action.units), 'unit_definition_still_present')
    states = {action.service: removed_unit_state(action.service, service=True),
              action.slice: removed_unit_state(action.slice, service=False)}
    path = '/sys/fs/cgroup/' + action.slice
    try:
        group = lifecycle.cgroup_snapshot('/' + action.slice, family='tsmetadata')
    except FileNotFoundError:
        require(not os.path.lexists(path), 'scope_read_unresolved')
        group = None
    if group is not None:
        require(group['populated'] == 0 and str(group['device']) == observation['group']['device']
                and str(group['inode']) == observation['group']['inode'], 'scope_identity_changed')
    require_no_fixture_runtime()
    return {'kind': 'test_cleanup_current_absence_v1', 'boot_id': observation['boot_id'],
            'units': states, 'group': group, 'new_retirement_receipt': False}


def cleanup_spec(key):
    require(type(key) is str and key.count('/') == 1, 'invalid_cleanup_path')
    leaf, name = key.split('/')
    if leaf == 'witness':
        require(name in (witness_slots.FINAL, witness_slots.LOCK), 'invalid_cleanup_path')
        return leaf, name, 0 if name == witness_slots.LOCK else witness_slots.MAX_OUTPUT
    require(name in RECORDS and RECORDS[name][0] == leaf, 'invalid_cleanup_path')
    return leaf, name, RECORDS[name][1]


def checked_cleanup_checkpoint(value, claim, source_bytes):
    require(type(value) is dict and set(value) == {'claim_id', 'execution_id', 'pending_resources',
            'result_ack_sha256', 'observation', 'inventory', 'files'} and value['claim_id'] == claim
            and type(value['execution_id']) is str and str(uuid.UUID(value['execution_id'])) == value['execution_id']
            and value['pending_resources'] == [] and type(value['result_ack_sha256']) is str
            and re.fullmatch(r'[0-9a-f]{64}', value['result_ack_sha256']), 'invalid_cleanup_checkpoint')
    files = value['files']
    require(type(files) is dict and 1 <= len(files) <= 28, 'invalid_cleanup_file_manifest')
    required = {'records/' + name for name in ('capacity.json', 'capture.json', 'stop-fence.json',
        'result.json', 'result-ack.json', 'executor.json', 'executor-ack.json',
        'arxiv_connection.json', 'arxiv_connection-ack.json')}
    require(required | {'data/ready.json', 'data/privileges.json', 'witness/publication.lock'} <= set(files),
            'missing_cleanup_record')
    total = source_bytes
    for key, row in files.items():
        _, _, maximum = cleanup_spec(key)
        require(type(row) is dict and set(row) == {'bytes', 'sha256'} and type(row['bytes']) is int
                and (row['bytes'] == 0 if maximum == 0 else 0 < row['bytes'] <= maximum)
                and type(row['sha256']) is str and re.fullmatch(r'[0-9a-f]{64}', row['sha256']),
                'invalid_cleanup_file_manifest')
        total += row['bytes']
    require(value['inventory'] == {'names': len(files) + 2, 'bytes': total, 'ordinary_pending': []}
            and total <= witness_slots.MAX_BYTES and len(files) + 2 <= witness_slots.MAX_NAMES,
            'cleanup_inventory_mismatch')
    return value


def cleanup_identity(leaf):
    return (62401, 62401, 0o700) if leaf in ('data', 'ingress') else (0, 62401, 0o750) if leaf == 'control' else (0, 0, 0o700)


@contextmanager
def retained_cleanup_records(action, saved):
    """Test-only, definitions-absent reader. Never creates or repairs a file."""
    directories, lock = {}, None
    try:
        trusted_directory(action.root)
        for leaf, path in action.layout.items():
            trusted_directory(path.parent)
            directories[leaf] = _open_directory(path, *cleanup_identity(leaf))
        lock = os.open(witness_slots.LOCK, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                       dir_fd=directories['witness'])  # Existing exact lock; no O_CREAT.
        info = os.fstat(lock)
        require(stat.S_ISREG(info.st_mode) and (info.st_uid, info.st_gid) == cleanup_identity('witness')[:2]
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1 and info.st_size == 0,
                'invalid_cleanup_lock')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fsync(lock)

        def read(key):
            leaf, name, maximum = cleanup_spec(key)
            owner, group, _ = cleanup_identity(leaf)
            raw = read_record(directories[leaf], name, owner, group,
                              0o640 if leaf == 'control' else 0o600, maximum, sync=True)
            require(saved['files'][key] == {'bytes': len(raw), 'sha256': database.sha(raw)},
                    'cleanup_file_changed')
            os.fsync(directories[leaf])
            return raw

        found, remove = set(), []
        for leaf, fd in directories.items():
            with os.scandir(fd) as entries:
                for entry in entries:
                    key = leaf + '/' + entry.name
                    require(len(found) < 28 and key in saved['files'], 'unexpected_cleanup_file')
                    require(entry.stat(follow_symlinks=False).st_nlink == 1, 'unexplained_cleanup_alias')
                    read(key)
                    found.add(key)
                    remove.append(action.layout[leaf] / entry.name)
            os.fsync(fd)
        require(found == set(saved['files']), 'missing_cleanup_file')
        def record(name):
            require(name in RECORDS, 'unknown_cleanup_record')
            raw = read(RECORDS[name][0] + '/' + name)
            value = database.decode(raw)
            require(database.canonical(value) == raw, 'noncanonical_cleanup_record')
            return value
        yield record, remove
    finally:
        if lock is not None:
            os.close(lock)
        for fd in directories.values():
            os.close(fd)


def settled_cleanup_records(read, current, binding, job, claim, *, expected_failure=False):
    execution = current['execution']
    require(execution is not None and execution['pending_resources'] == []
            and current['step_result'] is not None, 'unsettled_action_retained')
    validate_execution(execution, binding, job, claim)
    result, ack = read('result.json'), read('result-ack.json')
    identity = {
                'p_job_id': job, 'p_claim_id': claim, 'p_attempt_id': execution['id'],
                'p_generation': execution['generation']}
    require(ack['id'] == job and ack['source_id'] == SOURCE and ack['requested_revision'] == 1,
            'missing_result_ack_retained')
    if expected_failure:
        require(result == {'name': 'worker_fail_metadata_stage_v2', 'parameters': dict(identity,
                    p_error_code='metadata_unavailable', p_retryable=True)}
                and current['step_result'] == {'attempt_id': execution['id'],
                    'error_code': 'metadata_unavailable', 'retryable': True}
                and type(result['parameters']['p_retryable']) is bool
                and type(current['step_result']['retryable']) is bool
                and ack == current['job'] and ack['generation'] == execution['generation']
                and ack['stage'] == execution['kind'] == 'atom' and ack['status'] == 'retry_wait'
                and ack['error_code'] == 'metadata_unavailable' and ack['retryable'] is True
                and ack['claim_id'] is None, 'unexpected_failure_retained')
    else:
        require(result['name'] == 'worker_finish_metadata_stage_v2'
                and all(result['parameters'][key] == value for key, value in identity.items())
                and current['step_result'].get('job_id') == job, 'missing_result_ack_retained')
    for resource in ('executor', 'arxiv_connection'):
        record = read(resource + '.json')
        require(record['name'] == 'worker_record_metadata_quiescence', 'invalid_receipt_checkpoint')
        check_ack(read(resource + '-ack.json'), execution, record['parameters'], binding, job, claim)
        if expected_failure:
            require(record['parameters']['p_evidence_kind'] == 'owned_scope_retired_v1'
                    and next(row for row in execution['receipts'] if row['resource'] == resource)['facts']
                        == record['parameters']['p_facts'], 'expected_scope_receipts_required')
    if expected_failure:
        facts = read('arxiv_connection.json')['parameters']['p_facts']
        require(all(facts[key] == value for key, value in {'framing': 'unknown', 'peer_eof': False,
            'actual_bytes': None, 'body_sha256': None, 'status_code': None, 'retry_after_seconds': 0}.items())
            and facts['peer_eof'] is False and type(facts['retry_after_seconds']) is int
            and read('executor-ack.json')['execution']['pending_resources'] == ['arxiv_connection']
            and read('arxiv_connection-ack.json')['execution']['pending_resources'] == [],
            'expected_unknown_body_required')
    return execution, ack


def remove_cleanup_layout(action):
    for path in action.layout.values():
        path.rmdir()
    action.root.rmdir()
    for parent in ({path.parent for path in action.layout.values()} - {action.root}) | {action.root.parent}:
        database.sync_dir(parent)


def fault_service_state(action, *, reset=False):
    fields = ('Id', 'LoadState', 'ActiveState', 'SubState', 'MainPID', 'InvocationID',
              'FragmentPath', 'SourcePath', 'DropInPaths', 'Job', 'ControlGroup',
              'Result', 'ExecMainCode', 'ExecMainStatus')
    value = lifecycle.show(action.service, fields, family='tsmetadata')
    require(value['Id'] == action.service and value['LoadState'] == 'loaded'
            and value['ActiveState'] == ('inactive' if reset else 'failed')
            and value['SubState'] == ('dead' if reset else 'failed') and value['MainPID'] == '0'
            and value['InvocationID'] in ('', action.ready['invocation_id'])
            and value['FragmentPath'] == '/run/systemd/system/' + action.service
            and value['SourcePath'] == value['DropInPaths'] == value['Job'] == ''
            and value['ControlGroup'] in ('', '/' + action.slice + '/' + action.service)
            and value['Result'] == ('success' if reset else 'signal')
            and (reset or (value['ExecMainCode'] == '2' and value['ExecMainStatus'] == '9')),
            'unexpected_fault_service_state')
    return value


@unittest.skipUnless(ENABLED, 'requires explicit opt-in inside the marked isolated Linux guest')
class MetadataIntegrationTests(unittest.TestCase):
    """One fixture instance and two finite metadata stages; no scheduler."""
    @classmethod
    def record(cls, name, value):
        require(re.fullmatch(r'[a-z0-9-]{1,60}\.json', name), 'invalid_evidence_name')
        raw = database.canonical(value)
        require(0 < len(raw) <= 65_536, 'evidence_record_limit')
        count = total = 0
        with os.scandir(cls.evidence) as entries:
            for entry in entries:
                count += 1
                info = entry.stat(follow_symlinks=False)
                require(count <= 31 and stat.S_ISREG(info.st_mode) and info.st_uid == 0
                        and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                        'unexpected_evidence_entry')
                total += info.st_size
        require(total + len(raw) <= MAX_EVIDENCE, 'evidence_capacity')
        database.create_file(cls.evidence / name, raw)

    @classmethod
    def setUpClass(cls):
        cls.scenario = selected_scenario()  # Refuse unknown selection before any mutation.
        cls.completed = False
        cls.claims = []
        cls.accounts = []
        cls.platform = lifecycle.preflight()
        require(os.getresuid() == (0, 0, 0) and os.getresgid() == (0, 0, 0)
                and os.getgroups() in ([], [0]), 'root_fixture_identity_required')
        cls.source = explicit_path('SOURCE_ROOT')
        require(HERE == cls.source / 'workers/source-gateway/linux', 'fixture_source_mismatch')
        cls.python, cls.deno = explicit_path('PYTHON'), explicit_path('DENO')
        require(cls.python == Path(sys.executable).resolve() and sys.flags.isolated
                and sys.flags.no_site and sys.dont_write_bytecode, 'isolated_selected_python_required')
        parser = explicit_path('PARSER_DIR')
        inventory = explicit_path('RUNTIME_INVENTORY')
        manifest_path = explicit_path('DB_MANIFEST')
        expected = os.environ.get('TIMESTEP_METADATA_DB_MANIFEST_SHA256', '')
        require(re.fullmatch(r'[0-9a-f]{64}', expected), 'reviewed_database_manifest_required')
        manifest_raw = database.read_file(manifest_path, private=True)
        require(database.sha(manifest_raw) == expected, 'database_manifest_changed')
        cls.database_manifest = database.decode(manifest_raw)
        # Verify all SQL/tool bytes before account or fixture mutation.
        database.sources(cls.source, cls.database_manifest)
        cls.port = int(os.environ.get('TIMESTEP_METADATA_DB_PORT', '0'))
        cls.evidence = explicit_path('EVIDENCE_ROOT')
        require(cls.evidence.parent == RUNS and re.fullmatch(r'[0-9a-f]{12}', cls.evidence.name)
                and not os.path.lexists(cls.evidence), 'new_exact_evidence_path_required')
        cls.instance = cls.evidence.name
        database.identity(cls.instance, cls.port)
        database.no_source_actions()
        # Avoid sharing the fixed identities with the prerequisite suite.
        for number, name in ACCOUNTS:
            for lookup, key in ((pwd.getpwuid, number), (pwd.getpwnam, name),
                                (grp.getgrgid, number), (grp.getgrnam, name)):
                try:
                    lookup(key)
                except KeyError:
                    continue
                raise ValueError('fixture_account_collision')
        require(not os.path.lexists(database.BASE / cls.instance), 'database_instance_collision')
        require(database.shutil.disk_usage('/var/lib').free >= 2 * 1024**3, 'fixture_disk_reserve')
        if not RUNS.exists():
            owned_directory(RUNS, 0o700, create=True)
        owned_directory(RUNS, 0o700)
        owned_directory(cls.evidence, 0o700, create=True)
        cls.addClassCleanup(cls.cleanup_owned)
        cls.record('inputs.json', {'schema_version': 1, 'mode': 'linux_metadata_integration_fixture',
            'instance': cls.instance, 'scenario': cls.scenario, 'platform': cls.platform, 'database_manifest_sha256': expected,
            'harness_sha256': database.sha(database.read_file(Path(__file__), 65_536)),
            'fixture_database_sha256': database.sha(database.read_file(HERE / 'fixture_database.py', 65_536)),
            'tls_fixture_sha256': database.sha(database.read_file(HERE / 'tls_fixture.py', 16_384)),
            'parser_manifest_sha256': database.sha(database.read_file(parser / 'manifest.json', 32_768)),
            'runtime_inventory_sha256': database.sha(database.read_file(inventory, 16_384)),
            'source_network_enabled': False, 'hosted_admitted': False})
        for number, name in ACCOUNTS:
            account_command(['groupadd', '--gid', str(number), name])
            account_command(['useradd', '--no-create-home', '--no-user-group', '--uid', str(number),
                             '--gid', str(number), '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin',
                             '--password', '!', '--comment', 'Timestep isolated metadata fixture', name])
            cls.accounts.append((number, name))
            cls.record('account-' + str(number) + '.json', {'uid': number, 'name': name, 'created': True})
        base = BUNDLES.parent
        if not base.exists():
            owned_directory(base, 0o755, create=True)
        owned_directory(base, 0o755)
        if not BUNDLES.exists():
            owned_directory(BUNDLES, 0o755, create=True)
        owned_directory(BUNDLES, 0o755)
        built = database.decode(database.checked([str(cls.python), '-I', '-S', '-B',
            str(HERE / 'package_metadata.py'), str(BUNDLES), str(parser), str(inventory),
            '--python', str(cls.python), '--deno', str(cls.deno), '--psql', str(database.PG / 'psql')],
            timeout=20, maximum=4096))
        require(type(built) is dict and re.fullmatch(r'[0-9a-f]{64}', built['bundle_sha256']), 'invalid_bundle_reply')
        cls.bundle = BUNDLES / built['bundle_sha256']
        cls.manifest, _ = bootstrap.load_bundle(cls.bundle)
        require(database.sha(database.canonical(cls.manifest)) == built['bundle_sha256'], 'bundle_reply_changed')
        cls.record('bundle.json', cls.manifest)
        setup = database.provision(cls.instance, cls.port, cls.source, cls.database_manifest)
        cls.descriptors = setup['descriptors']
        cls.record('database.json', setup)
        cls.record('permissions.json', database.verify_callers(cls.instance))
        cls.job, cls.account, cls.imported, cls.policy = (str(uuid.uuid4()) for _ in range(4))
        q = database.quote
        # Same seed schedule as ../test_integration.py: auth identity -> import
        # intent -> prepared lookup -> linked interest. No action owner session.
        cls.owner("begin;insert into auth.users values(" + q(cls.account) + ");"
            "select set_config('request.jwt.claim.sub'," + q(cls.account) + ",true);"
            "select public.v2_begin_import(" + q(cls.imported) + ',' + q(SOURCE) + ",0,1);"
            "set local role science_reader_metadata_executor;select public.worker_prepare_acquisition(" +
            q(cls.job) + ',' + q(SOURCE) + ",1);select public.worker_link_import_acquisition(" +
            q(cls.account) + ',' + q(cls.imported) + ',1,1,' + q(cls.job) + ");commit;")
        definition = {'version': 1, 'kind': 'metadata-linux-scope-v1',
            'connection_model': 'direct-owned-socket-v1', 'max_executors': 1,
            **policy_hashes(cls.manifest), 'max_useful_seconds': 30, 'max_report_seconds': 60}
        admitter = RestrictedRPC(cls.descriptors['admitter'])
        before = admitter.call('worker_metadata_authority_state', {})
        admitter.call('worker_install_metadata_executor_policy',
                      {'p_id': cls.policy, 'p_canonical_policy': database.canonical(definition).decode()})
        admission = admitter.call('worker_activate_metadata_executor_v2', {
            'p_expected_revision': before['revision'], 'p_project_ref': PROJECT, 'p_policy_id': cls.policy,
            'p_host_id': HOST, 'p_boot_id': cls.platform['boot_id'],
            'p_deployment_id': 'linux-fixture-' + cls.bundle.name[:32],
            'p_recovery_evidence_sha256': database.sha(database.canonical({
                'fixture_instance': cls.instance, 'no_prior_actions': True, 'bundle': cls.bundle.name}))})
        require(admission['enabled'] is True and admission['recovery_required'] is False,
                'fixture_activation_failed')
        del admitter
        cls.record('admission.json', admission)
        cls.record('admitter-retired.json', database.retire_admitter(cls.instance))
        # Keep generated private TLS inputs outside the bounded JSON evidence
        # leaf, under a separate exact run-owned directory.
        cls.tls = RUNS / (cls.instance + '-tls')
        owned_directory(cls.tls, 0o700, create=True)
        cls.cert, cls.key = fixture_certificate(cls.tls)

    @classmethod
    def owner(cls, sql):
        return database.owner_sql(cls.instance, sql).strip()

    @classmethod
    def state(cls, claim):
        return RestrictedRPC(cls.descriptors['observer']).call('worker_metadata_execution_state',
                   {'p_job_id': cls.job, 'p_claim_id': claim})

    @classmethod
    def counters(cls):
        return database.decode(cls.owner("select json_build_object('attempts',(select count(*) from app_private.execution_attempts),"
            "'steps',(select count(*) from app_private.acquisition_steps where kind='metadata_stage_v2'),"
            "'receipts',(select count(*) from app_private.execution_quiescence),"
            "'charged_bytes',(select coalesce(sum(charged),0) from app_private.acquisition_transfer_windows where kind='source_bytes'),"
            "'charged_requests',(select coalesce(sum(charged),0) from app_private.acquisition_transfer_windows where kind='source_requests'))"))

    @classmethod
    def action(cls, claim, fixture, mode):
        require(mode in ('run', 'recover'), 'invalid_fixture_mode')
        value = {'mode': mode, 'job_id': cls.job, 'claim_id': claim, 'fixture': fixture,
                 'observer': cls.descriptors['observer'], 'executor': cls.descriptors['executor']}
        raw = database.canonical(value)
        require(len(raw) <= 24_576, 'fixture_action_input_limit')
        # Only root guardian configuration crosses stdin. Its child receives
        # only the executor descriptor through the production bridge protocol.
        code, output, _ = database.run([str(cls.python), '-I', '-S', '-B', str(cls.bundle / 'bootstrap.py'),
            str(cls.bundle), 'metadata_guardian'], raw, timeout=110, maximum=65_536)
        require(code == 0, 'metadata_action_unresolved')
        result = database.decode(output)
        require(result == {'state': 'completed', 'job_id': cls.job, 'claim_id': claim,
            'execution_id': result.get('execution_id'), 'source_network_enabled': False, 'hosted_admitted': False}
            and str(uuid.UUID(result['execution_id'])) == result['execution_id'], 'metadata_action_not_completed')
        return result

    @classmethod
    def failure_audit(cls, claim):
        q = database.quote
        value = database.decode(cls.owner("select jsonb_build_object("
            "'gate',(select to_jsonb(g) from app_private.arxiv_network_gate g),"
            "'windows',(select jsonb_agg(to_jsonb(w) order by period,scope,kind) from app_private.acquisition_transfer_windows w),"
            "'attempt',(select to_jsonb(e) "
            "from app_private.execution_attempts e where job_id=" + q(cls.job) + " and operation_id=" + q(claim) + "),"
            "'step',(select to_jsonb(s) from app_private.acquisition_steps s where job_id=" + q(cls.job) +
            " and operation_id=" + q(claim) + "),'job',(select to_jsonb(j) from app_private.acquisition_jobs j where id=" +
            q(cls.job) + "),'import',(select to_jsonb(i) from app_private.import_requests i where id=" + q(cls.imported) + "))"))
        counts = cls.counters()
        require(counts == {'attempts': 1, 'steps': 1, 'receipts': 2,
                'charged_bytes': 1_048_576, 'charged_requests': 1}, 'fault_charge_changed')
        attempt, step = value['attempt'], value['step']
        windows = sorted(value['windows'], key=lambda row: row['kind'])
        require(len(windows) == 2 and windows[0] == {'period': attempt['charge_period'],
                    'scope': 'environment', 'kind': 'source_bytes', 'charged': 1_048_576}
                and windows[1] == {'period': windows[1]['period'], 'scope': 'environment',
                    'kind': 'source_requests', 'charged': 1}
                and re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', windows[1]['period'])
                and step['generation'] == attempt['generation'] and step['outcome'] == 'failed'
                and step['result'] == {'attempt_id': attempt['id'], 'error_code': 'metadata_unavailable', 'retryable': True},
                'fault_accounting_mismatch')
        return dict(value, counters=counts)

    @classmethod
    def fault_proof(cls, action, current, read):
        require(cls.scenario == FAULT and cls.claims == [action.claim], 'explicit_fault_cleanup_required')
        capture, ready, go = read('capture.json'), read('ready.json'), read('go.json')
        require(go == read('go-intent.json') and go['execution_id'] == current['execution']['id'], 'fault_go_changed')
        expected = fault_intent(capture, ready, current['execution'], go, read('stop-fence.json'), action.service)
        outcome = {'schema_version': 1, 'kind': 'test_supervisor_death_outcome_v1',
            'intent_sha256': database.sha(database.canonical(expected)), 'claim_id': action.claim,
            'execution_id': current['execution']['id'], 'signal_count': 1, 'pidfd_exit_observed': True,
            'new_retirement_receipt': False}
        owned_directory(cls.evidence, 0o700)
        fd = _open_directory(cls.evidence, *cleanup_identity('records'))
        try:
            for name, value in (('fault-intent.json', expected), ('fault-outcome.json', outcome)):
                require(os.stat(name, dir_fd=fd, follow_symlinks=False).st_nlink == 1, 'fault_proof_alias')
                require(read_record(fd, name, 0, 0, 0o600, 65_536, sync=True) == database.canonical(value),
                        'fault_proof_changed')
            os.fsync(fd)
        finally:
            os.close(fd)
        require(all(not os.path.lexists(action.layout['records'] / name)
                    for name in ('parser-input.json', 'parser-output.json', 'terminal-witness.json'))
                and set(p.name for p in action.layout['witness'].iterdir()) == {witness_slots.LOCK}
                and not list(action.layout['ingress'].iterdir()), 'fault_body_or_parser_retained')
        cls.failure_audit(action.claim)
        return outcome

    def test_selected_metadata_workflow(self):
        if self.scenario == 'normal':
            self.normal_workflow()
        else:
            self.supervisor_death_workflow()

    def supervisor_death_workflow(self):
        claim = str(uuid.uuid4())
        self.claims.append(claim)
        target = HostAction(self.bundle, self.manifest, claim)  # No open/lock or mutation.
        with SingleRequestServer(self.cert, self.key, slow=True, body=atom()) as server:
            with SupervisorDeath(server, target, self.job, self.record):
                result = self.action(claim, server.fixture, 'run')
            current = self.state(claim)
            target.open(fresh=False)
            try:
                target.restore()
                execution, _ = settled_cleanup_records(target.journal.read, current, target.binding,
                    self.job, claim, expected_failure=True)
                self.fault_proof(target, current, target.journal.read)
                self.assertFalse(target.journal.exists('parser-input.json'))
                self.assertFalse(target.journal.exists('parser-output.json'))
                self.assertEqual(set(p.name for p in target.layout['witness'].iterdir()), {witness_slots.LOCK})
                self.assertEqual(list(target.layout['ingress'].iterdir()), [])
            finally:
                target.close()
            before = self.failure_audit(claim)
            self.assertEqual(current['job']['stage'], 'atom')
            self.assertIsNone(current['job']['metadata_id'])
            self.assertEqual(before['job']['atom_attempts'], 1)
            self.assertEqual(before['job']['license_attempts'], 0)
            self.assertEqual(server.connections, 1)
            require_no_fixture_runtime()  # Original guardian has joined its own controller family.
            self.record('fault-run.json', {'result': result, 'state': current, 'audit': before,
                'accepted_loopback_connections': 1, 'no_body_or_parser_checkpoint': True})
            config = {'job_id': self.job, 'claim_id': claim, 'observer': self.descriptors['observer']}
            code, raw, _ = database.run([str(self.python), '-I', '-S', '-B', str(self.bundle / 'bootstrap.py'),
                str(self.bundle), 'metadata_observer'], database.canonical(config), timeout=35, maximum=4096)
            self.assertEqual(code, 0)
            recovered = database.decode(raw)
            self.assertEqual(recovered, {'schema_version': 1, 'kind': 'metadata_resource_closure_v1',
                'state': 'settled', 'job_id': self.job, 'claim_id': claim, 'execution_id': execution['id'],
                'source_network_enabled': False, 'hosted_admitted': False})
            self.assertEqual(self.state(claim), current)
            self.assertEqual(self.failure_audit(claim), before)
            self.assertEqual(server.connections, 1)
            self.assertTrue(server.thread.is_alive(), 'duplicate-connection observation expired')
            require_no_fixture_runtime()
            self.record('fault-observer-replay.json', {'result': recovered, 'audit': before,
                'accepted_loopback_connections': 1, 'unchanged_receipts_result_gate_and_backoff': True})
        type(self).completed = True

    def normal_workflow(self):
        for index, (stage, body) in enumerate((('atom', atom()), ('license', license_xml())), 1):
            if index == 2:
                delay = float(self.owner("select greatest(0,extract(epoch from next_allowed_at-clock_timestamp())) "
                                         "from app_private.arxiv_network_gate"))
                self.assertLessEqual(delay, 3.1)
                time.sleep(delay + .03)  # Honor the actual closed-connection cooldown.
            claim = str(uuid.uuid4())
            self.claims.append(claim)
            with SingleRequestServer(self.cert, self.key, body=body) as server:
                result = self.action(claim, server.fixture, 'run')
                self.assertTrue(server.requested.is_set())
                self.assertEqual(server.connections, 1)
                current = self.state(claim)
                self.assertEqual(current['execution']['pending_resources'], [])
                self.assertIsNotNone(current['step_result'])
                self.assertEqual(current['execution']['kind'], stage)
                source = next(row for row in current['execution']['receipts'] if row['resource'] == 'arxiv_connection')
                self.assertEqual(source['evidence_kind'], 'owned_child_joined')
                self.assertEqual(source['facts']['actual_bytes'], len(body))
                self.assertEqual(source['facts']['body_sha256'], database.sha(body))
                before = self.counters()
                self.assertEqual(before['attempts'], index)
                self.assertEqual(before['steps'], index)
                self.assertEqual(before['receipts'], 2 * index)
                self.record(stage + '-run.json', {'result': result, 'state': current, 'counters': before,
                                                  'accepted_loopback_connections': server.connections})
                recovered = self.action(claim, server.fixture, 'recover')
                self.assertEqual(recovered, result)
                self.assertEqual(self.counters(), before)
                self.assertEqual(server.connections, 1)
                self.assertTrue(server.thread.is_alive(), 'duplicate-connection observation expired')
                self.record(stage + '-recovery.json', {'result': recovered, 'counters': before,
                                                       'accepted_loopback_connections': server.connections})
            if stage == 'atom':
                self.assertEqual(current['job']['stage'], 'license')
                self.assertEqual(current['job']['metadata']['title'], 'Local fixture paper')
                self.assertEqual(current['job']['atom_updated_at'], '2024-03-02T00:00:00.000Z')
            else:
                self.assertEqual(current['job']['status'], 'complete')
                self.assertEqual(current['job']['eligibility'], 'source_only')
        marker = 'fixture_projection_' + uuid.uuid4().hex
        sql = ('begin;set local role science_reader_metadata_executor;select public.worker_project_import_acquisition('
               + database.quote(self.account) + ',' + database.quote(self.imported) + ',1);commit;select '
               + database.quote(marker) + ';')
        code, raw, _ = database.client_sql(self.instance, 'executor', sql)
        self.assertEqual(code, 0)
        lines = raw.split(b'\n')
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[1], marker.encode())
        self.assertEqual(lines[2], b'')
        projection = database.decode(lines[0])
        self.assertEqual(projection['entry']['phase'], 'source_only')
        self.assertIsNone(projection['entry']['document_id'])
        self.assertEqual(projection['entry']['metadata']['title'], 'Local fixture paper')
        self.assertGreater(projection['entry']['state_seq'], 1)
        final = self.counters()
        self.assertEqual(final, {'attempts': 2, 'steps': 2, 'receipts': 4,
                                'charged_bytes': len(atom()) + len(license_xml()), 'charged_requests': 2})
        no_original = self.owner("select not exists(select 1 from app_private.paper_asset_reservations) "
            "and not exists(select 1 from app_private.documents) and not exists(select 1 from app_private.render_artifacts) "
            "and (select not original_enabled and not verification_enabled from app_private.acquisition_policy) "
            "and (select not enabled from app_private.paper_read_policy)")
        self.assertEqual(no_original, b't')
        self.record('projection.json', {'projection': projection, 'counters': final,
                    'no_original_or_render_asset': True, 'source_network_enabled': False, 'hosted_admitted': False})
        type(self).completed = True

    @classmethod
    def cleanup_action(cls, claim):
        """Test-only deletion, after SQL settlement and exact durable scope proof."""
        action = HostAction(cls.bundle, cls.manifest, claim)
        remove = []
        try:
            action.open(fresh=False)
            action.restore()
            current = cls.state(claim)
            failure = getattr(cls, 'scenario', 'normal') == FAULT
            execution, ack = settled_cleanup_records(action.journal.read, current, action.binding,
                                                     cls.job, claim, expected_failure=failure)
            if failure:
                cls.fault_proof(action, current, action.journal.read)
            fence = action.journal.read('stop-fence.json')
            observation = action.scope.observe(action.capture, action.ready, action.binding,
                                              execution['binding_sha256'], fence)
            require(observation is not None, 'scope_not_empty_retained')
            counts = action.journal.inventory()
            require(counts['ordinary_pending'] == [] and not list(action.layout['ingress'].iterdir()),
                    'unfinished_publication_retained')
            files = {}
            for leaf, fd in action.journal.directories.items():
                with os.scandir(fd) as entries:
                    for entry in entries:
                        # Inventory already checked fixed names/modes/owners/aliases.
                        path = action.layout[leaf] / entry.name
                        info = entry.stat(follow_symlinks=False)
                        data = read_record(fd, entry.name, info.st_uid, info.st_gid,
                                           stat.S_IMODE(info.st_mode), 1_572_864, sync=True)
                        require(len(data) == info.st_size and len(data) <= 1_572_864,
                                'action_file_changed')
                        files[leaf + '/' + entry.name] = {'bytes': len(data), 'sha256': database.sha(data)}
                        remove.append(path)
            cls.record('cleanup-' + uuid.UUID(claim).hex + '.json', {
                'claim_id': claim, 'execution_id': execution['id'], 'pending_resources': [],
                'result_ack_sha256': database.sha(database.canonical(ack)),
                'observation': observation, 'inventory': counts, 'files': files})
            # Test-only exception: one exactly named killed service, after all
            # proofs are durable, while the original lock/unit/fence are held.
            if failure:
                cls.reset_fault_service(action, execution, observation)
            # The fence survives reset and definition removal/unloading.
            lifecycle.run(['/usr/bin/systemctl', 'stop', action.service])
            group = lifecycle.cgroup_snapshot('/' + action.slice, family='tsmetadata')
            require(group['populated'] == 0 and str(group['device']) == observation['group']['device']
                    and str(group['inode']) == observation['group']['inode'], 'scope_identity_changed')
            lifecycle.run(['/usr/bin/systemctl', 'stop', action.slice])
            for unit in (action.service, action.slice):
                state = lifecycle.show(unit, ('Id', 'LoadState', 'ActiveState', 'Job', 'FragmentPath'), family='tsmetadata')
                require(state['Id'] == unit and state['LoadState'] == 'loaded' and state['ActiveState'] == 'inactive'
                        and state['Job'] == '' and state['FragmentPath'] == '/run/systemd/system/' + unit,
                        'unit_stop_unresolved')
            action.journal.inventory()
            for path in action.units:
                path.unlink()
            database.sync_dir('/run/systemd/system')
            lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])
            removed_runtime(action, observation)
            # Exact names were inventoried while the same publication lock was
            # held. No producer/controller remains and no source unit can start.
            for path in sorted(remove, key=lambda p: (p.name == 'stop-fence.json', p.name == witness_slots.LOCK)):
                path.unlink()
            for path in action.layout.values():
                database.sync_dir(path)
        finally:
            action.close()
        remove_cleanup_layout(action)

    @classmethod
    def reset_fault_service(cls, action, execution, observation):
        require(action.journal is not None, 'held_action_required')
        def recheck():
            current = cls.state(action.claim)
            settled, _ = settled_cleanup_records(action.journal.read, current, action.binding,
                cls.job, action.claim, expected_failure=True)
            require(settled == execution, 'fault_settlement_changed')
            proof = cls.fault_proof(action, current, action.journal.read)
            action.journal.inventory()  # Checks exact original rendered definitions.
            require(action.journal.read('capture.json') == action.capture
                    and action.journal.read('stop-fence.json') == action.fence_value(), 'fault_fence_changed')
            fresh = action.scope.observe(action.capture, action.ready, action.binding,
                execution['binding_sha256'], action.journal.read('stop-fence.json'))
            require(fresh is not None and fresh['group'] == observation['group'], 'scope_not_empty_retained')
            checked_observation(fresh, action.capture, execution['binding_sha256'], action.fence_value())
            require_no_fixture_runtime()
            return proof, fault_service_state(action)
        proof, state = recheck()
        # A lost reset acknowledgement is retained for review, never retried by
        # this fixture. Reset clears systemd start counters too; the immutable
        # ConditionPathExists=!stop-fence remains the independent start fence.
        cls.record('fault-reset-intent.json', {'claim_id': action.claim, 'execution_id': execution['id'],
            'fault_outcome_sha256': database.sha(database.canonical(proof)), 'unit': state,
            'observation_sha256': database.sha(database.canonical(observation)),
            'unit_sha256': action.capture['unit_sha256'], 'fence_sha256': observation['fence_sha256']})
        require(recheck() == (proof, state), 'fault_reset_precondition_changed')
        lifecycle.run(['/usr/bin/systemctl', 'reset-failed', action.service])
        after = fault_service_state(action, reset=True)
        action.journal.inventory()
        require(action.journal.read('stop-fence.json') == action.fence_value(), 'fault_fence_changed')
        fresh = action.scope.observe(action.capture, action.ready, action.binding,
            execution['binding_sha256'], action.fence_value())
        require(fresh is not None and fresh['group'] == observation['group'], 'scope_not_empty_retained')
        cls.record('fault-reset-ack.json', {'claim_id': action.claim, 'execution_id': execution['id'],
                                         'unit': after, 'reset_count': 1, 'fence_retained': True})

    @classmethod
    def recover_cleanup_action(cls, claim, expected_cleanup_sha256):
        """Explicit test-only continuation after both unit definitions are gone.

        Caller supplies the independently retained cleanup-record digest. Every
        original file must still exist; partial deletion is deliberately refused.
        This issues only observer state reads, never grant/result/retirement RPCs.
        The class fixture identity/descriptors/bundle must be restored explicitly
        from its retained inputs, database.json and run evidence; setUpClass must
        not be called. No generic resume or recreation of the old group occurs.
        """
        require(claim in cls.claims and re.fullmatch(r'[0-9a-f]{64}', expected_cleanup_sha256),
                'explicit_cleanup_identity_required')
        require(getattr(cls, 'scenario', 'normal') == 'normal', 'fault_cleanup_uncertainty_requires_review')
        owned_directory(cls.evidence, 0o700)
        path = cls.evidence / ('cleanup-' + uuid.UUID(claim).hex + '.json')
        raw = database.read_file(path, 65_536, private=True)
        require(database.sha(raw) == expected_cleanup_sha256, 'cleanup_checkpoint_changed')
        evidence_fd = _open_directory(cls.evidence, *cleanup_identity('records'))
        try:
            owner, group, _ = cleanup_identity('records')
            require(read_record(evidence_fd, path.name, owner, group, 0o600, 65_536, sync=True) == raw,
                    'cleanup_checkpoint_changed')
            os.fsync(evidence_fd)
        finally:
            os.close(evidence_fd)
        saved = database.decode(raw)
        require(database.canonical(saved) == raw, 'noncanonical_cleanup_checkpoint')
        current_manifest, _ = bootstrap.load_bundle(cls.bundle)
        require(current_manifest == cls.manifest, 'cleanup_bundle_changed')
        action = HostAction(cls.bundle, cls.manifest, claim)
        checked_cleanup_checkpoint(saved, claim, action.source_bytes)
        require(all(not os.path.lexists(path) for path in action.units), 'unit_definition_still_present')
        with retained_cleanup_records(action, saved) as (read, remove):
            require(read('capacity.json') == action.capacity, 'cleanup_capacity_changed')
            capture, ready, fence = read('capture.json'), read('ready.json'), read('stop-fence.json')
            require(capture['claim_id'] == claim and capture['job_id'] == cls.job, 'cleanup_capture_changed')
            binding = copy.deepcopy(capture['binding_without_capture_sha256'])
            binding['scope']['capture_sha256'] = database.sha(database.canonical(capture))
            MetadataScope(cls.manifest, action.render).checked_capture(capture, ready, binding)
            require(capture['unit_sha256'] == database.sha(action.units[Path('/run/systemd/system') / action.service])
                    and capture['slice_sha256'] == database.sha(action.units[Path('/run/systemd/system') / action.slice]),
                    'cleanup_unit_source_changed')
            current = cls.state(claim)
            execution, ack = settled_cleanup_records(read, current, binding, cls.job, claim)
            require(execution['id'] == saved['execution_id']
                    and database.sha(database.canonical(ack)) == saved['result_ack_sha256'],
                    'cleanup_settlement_changed')
            checked_observation(saved['observation'], capture, execution['binding_sha256'], fence)
            absence = removed_runtime(action, saved['observation'])
            cls.record('cleanup-resumed-' + uuid.UUID(claim).hex + '.json', {
                'claim_id': claim, 'execution_id': execution['id'],
                'prior_cleanup_sha256': expected_cleanup_sha256, 'pending_resources': [],
                'current_absence': absence, 'uses_saved_scope_observation': True,
                'new_retirement_receipt': False})
            for path in sorted(remove, key=lambda p: (p.name == 'stop-fence.json', p.name == witness_slots.LOCK)):
                path.unlink()
            for path in action.layout.values():
                database.sync_dir(path)
        remove_cleanup_layout(action)

    @classmethod
    def cleanup_owned(cls):
        if not cls.completed:
            # Retain DB, source units, credentials and exact source/journals. No
            # failed unittest path silently invents settlement or deletes them.
            try:
                cls.record('retained.json', {'instance': cls.instance, 'claims': cls.claims,
                    'requires_review': True, 'source_network_enabled': False, 'hosted_admitted': False})
            except (OSError, ValueError):
                pass  # Failed evidence publication cannot authorize cleanup.
            raise ValueError('metadata_fixture_retained_for_review')
        require(cls.owner("select not exists(select 1 from app_private.execution_attempts e where "
            "app_private.execution_pending(e.id,'executor') or app_private.execution_pending(e.id,'arxiv_connection')) "
            "and not exists(select 1 from app_private.acquisition_steps where kind='metadata_stage_v2' "
            "and result_sha256 is null)") == b't', 'database_action_unsettled')
        for claim in cls.claims:
            cls.cleanup_action(claim)
        cls.record('database-cleanup.json', database.cleanup(cls.instance))
        database.no_source_actions()
        for number, name in reversed(cls.accounts):
            account = pwd.getpwnam(name)
            require(account.pw_uid == number and account.pw_gid == number
                    and account.pw_shell == '/usr/sbin/nologin' and account.pw_dir == '/nonexistent',
                    'fixture_account_changed')
            account_command(['userdel', name])
            try:
                group = grp.getgrnam(name)
            except KeyError:
                continue
            require(group.gr_gid == number and group.gr_mem == [], 'fixture_group_changed')
            account_command(['groupdel', name])
        require(set(path.name for path in cls.tls.iterdir()) == {'fixture.pem', 'fixture.key', 'openssl.cnf'},
                'unknown_tls_fixture_file')
        for path in cls.tls.iterdir():
            database.read_file(path, 16_384, private=True)
            path.unlink()
        cls.tls.rmdir()
        database.sync_dir(RUNS)
        cls.record('completed.json', {'schema_version': 1, 'instance': cls.instance,
            'scenario': cls.scenario, 'normal_actions': 2 if cls.scenario == 'normal' else 0,
            'completed_recoveries': 2 if cls.scenario == 'normal' else 0,
            'supervisor_deaths': 1 if cls.scenario == FAULT else 0,
            'observer_only_replays': 1 if cls.scenario == FAULT else 0,
            'accepted_loopback_connections': 2 if cls.scenario == 'normal' else 1,
            'source_units_and_action_directories_removed': True, 'database_removed': True,
            'owned_accounts_removed': True, 'retained_bundle': str(cls.bundle),
            'source_network_enabled': False, 'hosted_admitted': False})


if __name__ == '__main__':
    unittest.main(verbosity=2)

"""Exact local metadata scope provisioning/control, always outside its cgroup."""
import copy
import os
from pathlib import Path
import stat
import time
import uuid

from action_journal import ActionJournal, paths, _names
from common import canonical, require
from protocol import digest, clock_ns, envelope
from execution_contract import source_dto, grant_deadlines, validate_execution
import lifecycle
from metadata_scope import MODE, MetadataScope, units, checked_go
import witness_slots

BASE = Path('/var/lib/timestep-source')
UNIT_ROOT = Path('/run/systemd/system')
HOST = 'c1200000-0000-0000-0000-000000000001'
PROJECT = 'abcdefghijklmnopqrst'


def trusted_directory(path):
    """The host boundary includes all ancestors, not just the final leaf."""
    path = Path(path)
    require(path.is_absolute(), 'absolute_host_path_required')
    for parent in reversed((path,) + tuple(path.parents)):
        value = parent.lstat()
        require(stat.S_ISDIR(value.st_mode) and value.st_uid == value.st_gid == 0
                and not value.st_mode & 0o022, 'untrusted_host_directory')
    return path


def directory(path, mode, owner=0, group=0, *, existing=False):
    trusted_directory(path.parent)
    if not existing or not path.exists():
        path.mkdir(mode=0o700)
        os.chown(path, owner, group)
        path.chmod(mode)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and value.st_uid == owner and value.st_gid == group
            and stat.S_IMODE(value.st_mode) == mode, 'host_directory_identity')


def authority_matches(authority, manifest, boot):
    require(authority['project_ref'] == PROJECT and authority['environment'] == 'staging'
            and authority['enabled'] is True and authority['recovery_required'] is False
            and authority['admitted_host_id'] == HOST and authority['admitted_boot_id'] == boot
            and authority['admitted_deployment_id'] == 'linux-fixture-' + digest(canonical(manifest))[:32],
            'fixture_authority_mismatch')


class HostAction:
    def __init__(self, bundle, manifest, claim):
        require(os.getresuid() == (0, 0, 0) and os.getresgid() == (0, 0, 0), 'guardian_required')
        self.bundle, self.manifest, self.claim = Path(bundle), manifest, claim
        self.service, self.slice, root = lifecycle.names(claim, 'tsmetadata')
        self.root, self.layout = Path(root), paths(claim)
        self.render = lambda value: units(value, self.bundle)
        self.units = {UNIT_ROOT / name: raw for name, raw in self.render(claim).items()}
        self.boot = lifecycle.boot_id()
        self.source_bytes = manifest['source_bytes']
        require(manifest['unit_bytes'] == sum(map(len, self.units.values()))
                and manifest['payload_bytes'] + len(canonical(manifest)) + manifest['unit_bytes'] == self.source_bytes,
                'captured_source_size_mismatch')
        self.reservation = witness_slots.reservation(self.source_bytes, fixed_records=True)
        self.capacity = dict(self.reservation, bundle_sha256=digest(canonical(manifest)))
        self.journal = self.scope = None
        self.capture = self.binding = self.ready = None

    def open(self, *, fresh):
        trusted_directory(self.bundle)
        trusted_directory(UNIT_ROOT)
        if fresh:
            directory(BASE, 0o755, existing=True)
            for leaf, mode in (('attempts', 0o700), ('witnesses', 0o700), ('transport', 0o755)):
                directory(BASE / leaf, mode, existing=True)
            require(all(not os.path.lexists(path) for path in
                    (self.layout['records'], self.layout['witness'], self.root, *self.units)), 'scope_already_exists')
            # Keep unknown/partial setup after a failure. Never adopt its name.
            directory(self.layout['records'], 0o700)
            directory(self.layout['witness'], 0o700)
            directory(self.root, 0o755)
            directory(self.layout['control'], 0o750, group=62401)
            directory(self.layout['data'], 0o700, owner=62401, group=62401)
            directory(self.layout['ingress'], 0o700, owner=62401, group=62401)
            for path, raw in self.units.items():
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                try:
                    os.fchmod(fd, 0o644)
                    with os.fdopen(fd, 'wb', closefd=False) as stream:
                        stream.write(raw)
                        stream.flush()
                    os.fsync(fd)
                finally:
                    os.close(fd)
            fd = os.open(UNIT_ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        for path in self.layout.values():
            trusted_directory(path.parent)
        self.journal = ActionJournal(self.layout, self.source_bytes, self.units)
        self.journal.__enter__()
        self.scope = MetadataScope(self.manifest, self.render, journal=self.journal)
        if fresh:
            self.journal.put('capacity.json', self.capacity)
        else:
            saved = self.journal.recover('capacity.json',
                    lambda value: require(value == self.capacity, 'capacity_or_bundle_changed'))
            require(saved is not None, 'missing_action_capacity')
        return self

    def close(self):
        if self.journal is not None:
            self.journal.__exit__(None, None, None)
            self.journal = None

    def prepare(self, job, request, fixture, authority):
        authority_matches(authority, self.manifest, self.boot)
        envelope({'mode': 'loopback_fixture_v1', 'attempt_id': self.claim, 'request': request,
                  'fixture': fixture, 'useful_ms': 30_000, 'close_ms': 250})
        self.journal.put('input.json', {'schema_version': 1, 'mode': MODE, 'attempt_id': self.claim,
                                      'request': request, 'fixture': fixture})
        lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])
        lifecycle.run(['/usr/bin/systemctl', 'start', self.slice, self.service])
        deadline = clock_ns() + 5_000_000_000
        while not self.journal.exists('ready.json'):
            require(clock_ns() < deadline, 'ready_timeout')
            time.sleep(.01)
        # READY may become visible just before the producer removes its alias.
        while self.journal.inventory()['ordinary_pending']:
            require(clock_ns() < deadline, 'ready_publication_timeout')
            time.sleep(.01)
        self.ready = self.journal.producer_ready()
        self.capture, self.binding = self.scope.capture(job['id'], self.claim, request, self.ready, authority)
        self.journal.put('capture.json', self.capture)
        self.fence()
        return self.binding

    def restore(self):
        require(not any(leaf == 'data' for leaf, _ in self.journal.inventory()['ordinary_pending']),
                'producer_publication_uncertain')
        self.ready = self.journal.read('ready.json')
        self.journal.read('privileges.json')
        def validate(value):
            require(value['claim_id'] == self.claim, 'restored_scope_mismatch')
            binding = copy.deepcopy(value['binding_without_capture_sha256'])
            binding['scope']['capture_sha256'] = digest(canonical(value))
            self.scope.checked_capture(value, self.ready, binding)
            self.binding = binding
        self.capture = self.journal.recover('capture.json', validate)
        require(self.capture is not None, 'missing_capture')
        require(self.boot == self.binding['boot_id'], 'changed_boot_requires_review')

    def release(self, grant, origin, current, authority, *, cancelled=None):
        execution, job = grant['execution'], grant['job']
        validate_execution(execution, self.binding, self.capture['job_id'], self.claim)
        require(grant['granted'] is True and grant['action'] == 'perform_stage'
                and current['execution'] == execution and current['step_result'] is None
                and current['job'] == job and job['status'] == 'leased'
                and job['claim_id'] == self.claim and job['generation'] == execution['generation']
                and job['stage'] == execution['kind'], 'grant_not_current')
        require(source_dto(job, execution['kind'], execution['byte_ceiling']) == self.capture['source_request'],
                'source_changed')
        authority_matches(authority, self.manifest, self.boot)
        self.scope.recheck(self.capture, self.ready, self.binding, authority)
        useful, _ = grant_deadlines(execution, origin)
        deadline = min(useful, origin + 30_000_000_000)
        go = {'schema_version': 1, 'kind': 'linux_metadata_go_v1', 'scope_id': self.claim,
              **{key: self.ready[key] for key in ('child_id', 'bundle_sha256', 'source_sha256')},
              'execution_id': execution['id'], 'deadline_ns': str(deadline)}
        checked_go(go, self.claim, self.ready)
        self.journal.put('go-intent.json', go)
        require(cancelled is None or not cancelled(), 'cancelled_before_go')
        require(self.journal.read('stop-fence.json') == self.fence_value()
                and not self.journal.exists('stop.json') and not self.journal.exists('go.json'), 'go_already_decided')
        checked_go(go, self.claim, self.ready)
        self.journal.put('go.json', go)
        # No rewriting/retry of GO. Its original absolute deadline governs both
        # child and supervisor even if publication acknowledgement is lost.
        while clock_ns() < deadline + 1_000_000_000:
            if witness_slots.FINAL in _names(self.journal.directories['ingress'], 3):
                break
            if cancelled is not None and cancelled():
                break
            time.sleep(.01)

    def fence_value(self):
        require(self.capture is not None and self.binding is not None, 'capture_required_to_retire')
        return {'schema_version': 1, 'kind': 'linux_metadata_stop_fence_v1', 'scope_id': self.claim,
                'capture_sha256': digest(canonical(self.capture))}

    def fence(self):
        # Prevent all future activations before grant. This condition does not
        # stop the already-running paused service or prove that it is empty.
        fence = self.fence_value()
        saved = self.journal.recover('stop-fence.json',
                lambda value: require(value == fence, 'changed_stop_fence'))
        if saved is None:
            self.journal.put('stop-fence.json', fence)
        self.journal.read('capture.json')
        self.journal.read('stop-fence.json')

    def retire(self):
        self.fence()
        # The shared observer verifies exact current units/boot/group even when
        # still populated. Its fixture-shaped result is not a SQL receipt.
        base = self.scope.checked_capture(self.capture, self.ready, self.binding)
        def observe():
            return self.scope.observer.observe(base, {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                    'attempt_id': self.claim, 'capture_sha256': lifecycle.digest(base)})
        observe()
        lifecycle.run(['/usr/bin/systemctl', 'stop', '--no-block', self.service])
        deadline = clock_ns() + 3_000_000_000
        while True:
            value = observe()
            if value['owned_group_empty'] or clock_ns() >= deadline:
                return value['owned_group_empty']
            time.sleep(.02)

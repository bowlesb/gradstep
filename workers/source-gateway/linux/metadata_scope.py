"""Translate checked Linux lifecycle observations into the frozen 012 binding."""
import copy
from pathlib import Path
import re
import uuid

from common import canonical, require
from protocol import digest, target, clock_ns
import lifecycle
import uid_policy

MODE = 'linux_metadata_fixture'


def policy_hashes(manifest):
    return {name + '_sha256': digest(canonical({'bundle': digest(canonical(manifest)),
            'scope': name, 'local_fixture_only': True}))
            for name in ('runner', 'transport', 'observer', 'admission')}


def units(attempt, bundle):
    service, slice_name, root = lifecycle.names(attempt, 'tsmetadata')
    journal = '/var/lib/timestep-source/attempts/' + uuid.UUID(attempt).hex
    result = {}
    for suffix, name in (('service', service), ('slice', slice_name)):
        raw = (Path(bundle) / ('metadata.' + suffix + '.in')).read_bytes()
        require(0 < len(raw) <= 16_384, 'invalid_metadata_template')
        text = raw.decode().replace('@ATTEMPT@', attempt).replace('@SLICE@', slice_name)
        text = text.replace('@ROOT@', root).replace('@JOURNAL@', journal).replace('@BUNDLE@', str(bundle))
        require('@' not in text, 'unexpanded_metadata_template')
        result[name] = text.encode()
    return result


def checked_go(value, attempt, ready, *, now=None):
    require(type(value) is dict and set(value) == {'schema_version', 'kind', 'scope_id', 'child_id',
            'bundle_sha256', 'source_sha256', 'execution_id', 'deadline_ns'}
            and type(value['schema_version']) is int and value['schema_version'] == 1
            and value['kind'] == 'linux_metadata_go_v1' and value['scope_id'] == attempt
            and all(value[key] == ready[key] for key in ('child_id', 'bundle_sha256', 'source_sha256'))
            and type(value['execution_id']) is str and str(uuid.UUID(value['execution_id'])) == value['execution_id']
            and type(value['deadline_ns']) is str and re.fullmatch(r'[1-9][0-9]{0,19}', value['deadline_ns']),
            'metadata_go_mismatch')
    deadline = int(value['deadline_ns'])
    current = clock_ns() if now is None else now
    require(current < deadline <= current + 30_000_000_000, 'metadata_go_expired')
    return value['execution_id'], deadline


class MetadataScope:
    def __init__(self, manifest, renderer, *, observer=None, status=uid_policy.checked_status,
                 process=lifecycle.process, journal=None):
        self.manifest, self.render, self.status, self.process = manifest, renderer, status, process
        self.journal = journal

        def child(pid):
            checked = self.status(pid, uid_policy.SOURCE_UID)
            return dict(self.process(pid), uid=checked['uids'][0])

        self.observer = observer or lifecycle.Observer(current_process=child, unit_renderer=renderer,
                        expected_uid=uid_policy.SOURCE_UID, ready_mode=MODE, family='tsmetadata')

    def capture(self, job_id, claim_id, request, ready, authority):
        require(all(type(value) is str and str(uuid.UUID(value)) == value for value in (job_id, claim_id)),
                'invalid_capture_identity')
        target(request)
        lifecycle.validate_ready(ready, claim_id, MODE)
        require(ready['source_sha256'] == digest(canonical(request))
                and ready['bundle_sha256'] == digest(canonical(self.manifest)), 'capture_source_mismatch')
        require(authority['enabled'] is True and authority['recovery_required'] is False
                and authority['environment'] == 'staging'
                and authority['admitted_boot_id'] == self.observer.boot(), 'capture_authority_mismatch')
        pid = ready['controller_pid']
        self.status(pid, uid_policy.SUPERVISOR_UID)
        supervisor = self.process(pid)
        self.status(ready['identity']['process_id'], uid_policy.SOURCE_UID, parent=pid)
        observed = self.observer.capture(claim_id, ready)
        service, slice_name, _ = lifecycle.names(claim_id, 'tsmetadata')
        require(supervisor['cgroup'] == '/' + slice_name + '/' + service, 'supervisor_scope_mismatch')
        self.status(pid, uid_policy.SUPERVISOR_UID)
        require(self.process(pid)['process_start_id'] == supervisor['process_start_id'], 'supervisor_replaced')
        group = observed['group']
        binding = {'version': 2, 'project_ref': authority['project_ref'], 'environment': 'staging',
            'epoch': authority['epoch'], 'policy_id': authority['policy_id'],
            **{key: value for key, value in policy_hashes(self.manifest).items() if key != 'admission_sha256'},
            'deployment_id': authority['admitted_deployment_id'], 'host_id': authority['admitted_host_id'],
            **ready['identity'], 'child_id': ready['child_id'], 'scope': {
                'kind': 'linux-systemd-cgroup-v1', 'scope_id': claim_id, 'invocation_id': ready['invocation_id'],
                'cgroup_device': str(group['device']), 'cgroup_inode': str(group['inode'])}}
        capture = {'schema_version': 1, 'kind': 'linux_metadata_capture_v1', 'job_id': job_id,
            'claim_id': claim_id, 'binding_without_capture_sha256': binding,
            'source_request': copy.deepcopy(request), 'source_sha256': ready['source_sha256'],
            'supervisor': {'process_id': pid, 'process_start_id': supervisor['process_start_id']},
            'unit_sha256': observed['unit_sha256'], 'slice_sha256': observed['slice_sha256']}
        final = copy.deepcopy(binding)
        final['scope']['capture_sha256'] = digest(canonical(capture))
        return capture, final

    def checked_capture(self, capture, ready, binding):
        require(type(capture) is dict and set(capture) == {'schema_version', 'kind', 'job_id', 'claim_id',
                'binding_without_capture_sha256', 'source_request', 'source_sha256', 'supervisor',
                'unit_sha256', 'slice_sha256'} and type(capture['schema_version']) is int
                and capture['schema_version'] == 1 and capture['kind'] == 'linux_metadata_capture_v1',
                'invalid_metadata_capture')
        expected = copy.deepcopy(capture['binding_without_capture_sha256'])
        require(type(expected) is dict and set(expected) == {'version', 'project_ref', 'environment', 'epoch',
            'policy_id', 'runner_sha256', 'transport_sha256', 'observer_sha256', 'deployment_id', 'host_id',
            'boot_id', 'process_id', 'process_start_id', 'child_id', 'scope'} and expected['version'] == 2
            and type(expected['version']) is int and expected['environment'] == 'staging', 'invalid_metadata_binding')
        scope = expected['scope']
        require(all(type(value) is str and str(uuid.UUID(value)) == value for value in
                    (capture['job_id'], expected['epoch'], expected['policy_id'], expected['host_id']))
                and type(expected['project_ref']) is str and re.fullmatch(r'[a-z]{20}', expected['project_ref'])
                and type(expected['deployment_id']) is str
                and re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', expected['deployment_id'])
                and all(type(capture[key]) is str and re.fullmatch(r'[0-9a-f]{64}', capture[key])
                        for key in ('unit_sha256', 'slice_sha256')), 'invalid_metadata_binding')
        require(type(scope) is dict and set(scope) == {'kind', 'scope_id', 'invocation_id', 'cgroup_device', 'cgroup_inode'}
                and scope['kind'] == 'linux-systemd-cgroup-v1' and scope['scope_id'] == capture['claim_id'],
                'invalid_metadata_binding')
        require(all(type(scope[key]) is str and re.fullmatch(r'0|[1-9][0-9]{0,19}', scope[key])
                    and int(scope[key]) < 2**64 for key in ('cgroup_device', 'cgroup_inode'))
                and int(scope['cgroup_inode']) > 0, 'invalid_metadata_group')
        lifecycle.validate_ready(ready, capture['claim_id'], MODE)
        target(capture['source_request'])
        require(ready['bundle_sha256'] == digest(canonical(self.manifest))
                and capture['source_sha256'] == ready['source_sha256'] == digest(canonical(capture['source_request']))
                and ready['child_id'] == expected['child_id'] and ready['invocation_id'] == scope['invocation_id']
                and all(ready['identity'][key] == expected[key] for key in ready['identity'])
                and all(expected[key] == value for key, value in policy_hashes(self.manifest).items()
                        if key != 'admission_sha256'), 'metadata_capture_changed')
        supervisor = capture['supervisor']
        require(type(supervisor) is dict and set(supervisor) == {'process_id', 'process_start_id'}
                and type(supervisor['process_id']) is int and supervisor['process_id'] == ready['controller_pid']
                and type(supervisor['process_start_id']) is str
                and re.fullmatch(r'[0-9]{1,20}', supervisor['process_start_id']), 'invalid_supervisor_capture')
        expected['scope']['capture_sha256'] = digest(canonical(capture))
        require(expected == binding, 'metadata_capture_changed')
        service, slice_name, _ = lifecycle.names(capture['claim_id'], 'tsmetadata')
        return {'schema_version': 1, 'kind': 'fixture_slice_capture_v1', 'attempt_id': capture['claim_id'],
            'boot_id': expected['boot_id'], 'service': service, 'slice': slice_name,
            'invocation_id': scope['invocation_id'], 'group': {'path': '/' + slice_name,
                'device': int(scope['cgroup_device']), 'inode': int(scope['cgroup_inode']), 'populated': 1},
            'ready': ready, 'unit_sha256': capture['unit_sha256'], 'slice_sha256': capture['slice_sha256'],
            'source_network_enabled': False, 'hosted_admitted': False}

    def recheck(self, capture, ready, binding, authority):
        self.checked_capture(capture, ready, binding)
        fresh, actual = self.capture(capture['job_id'], capture['claim_id'], capture['source_request'], ready, authority)
        require(fresh == capture and actual == binding, 'metadata_scope_changed')

    def observe(self, capture, ready, binding, binding_sha256, fence):
        base = self.checked_capture(capture, ready, binding)
        require(type(fence) is dict and type(fence.get('schema_version')) is int and fence == {
            'schema_version': 1, 'kind': 'linux_metadata_stop_fence_v1', 'scope_id': capture['claim_id'],
            'capture_sha256': digest(canonical(capture))}, 'invalid_metadata_fence')
        require(type(binding_sha256) is str and re.fullmatch(r'[0-9a-f]{64}', binding_sha256), 'invalid_binding_digest')
        # The guardian passes its held ActionJournal. Reading it inventories
        # exact owners/modes/aliases, then fsyncs the file and its directory.
        expected_path = Path('/var/lib/timestep-source/attempts') / uuid.UUID(capture['claim_id']).hex
        require(self.journal is not None and self.journal.layout['records'] == expected_path,
                'metadata_journal_required')
        require(self.journal.read('capture.json') == capture and self.journal.read('stop-fence.json') == fence,
                'metadata_fence_not_durable')
        proof = self.observer.observe(base, {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                              'attempt_id': base['attempt_id'], 'capture_sha256': lifecycle.digest(base)})
        if not proof['owned_group_empty']:
            return None
        service = self.observer.show(base['service'], lifecycle.SERVICE_FIELDS)
        require(service['ActiveState'] in ('inactive', 'failed') and service['MainPID'] == '0'
                and service['Job'] == '' and service['InvocationID'] in ('', base['invocation_id']), 'scope_still_active')
        return {'schema_version': 1, 'kind': 'linux_metadata_scope_empty_v1', 'binding_sha256': binding_sha256,
            'capture_sha256': digest(canonical(capture)), 'fence_sha256': digest(canonical(fence)),
            'boot_id': base['boot_id'], 'scope_id': base['attempt_id'],
            'captured_invocation_id': base['invocation_id'], 'observed_invocation_id': service['InvocationID'],
            'service': {'active_state': service['ActiveState'], 'main_pid': 0, 'pending_job': False},
            'group': {'path': base['group']['path'], 'device': str(base['group']['device']),
                      'inode': str(base['group']['inode']), 'populated': 0}}

"""Guardian-only receipt settlement. No source launch, grant or metadata result RPC."""
import uuid

from action_journal import _names
from common import canonical, decode, require
from execution_contract import checked_witness, validate_execution
from protocol import digest
import witness_slots


def accepted(execution, resource):
    receipts = execution['receipts']
    pending = execution['pending_resources']
    require(type(receipts) is list and len(receipts) <= 2 and type(pending) is list
            and len(pending) <= 2 and len(set(pending)) == len(pending)
            and set(pending) <= {'executor', 'arxiv_connection'}
            and all(type(row) is dict and row.get('resource') in ('executor', 'arxiv_connection') for row in receipts)
            and len({row['resource'] for row in receipts}) == len(receipts), 'invalid_receipt_state')
    rows = [row for row in receipts if row['resource'] == resource]
    require(len(rows) <= 1, 'invalid_receipt_state')
    row = rows[0] if rows else None
    require((resource in execution['pending_resources']) == (row is None), 'invalid_receipt_state')
    if row is not None:
        require(set(row) == {'resource', 'receipt_id', 'evidence_kind', 'facts', 'accepted_at'}
                and type(row['receipt_id']) is str and str(uuid.UUID(row['receipt_id'])) == row['receipt_id']
                and row['evidence_kind'] in ('owned_child_joined', 'owned_scope_retired_v1')
                and type(row['facts']) is dict and row['facts']['binding_sha256'] == execution['binding_sha256'],
                'invalid_receipt_state')
    return row


def receipt_arguments(execution, resource, kind, facts, receipt_id=None):
    return {'p_attempt_id': execution['id'], 'p_receipt_id': receipt_id or str(uuid.uuid4()),
            'p_resource': resource, 'p_evidence_kind': kind, 'p_facts': facts}


def check_arguments(args, execution, resource):
    require(type(args) is dict and set(args) == {'p_attempt_id', 'p_receipt_id', 'p_resource',
            'p_evidence_kind', 'p_facts'} and args['p_attempt_id'] == execution['id']
            and args['p_resource'] == resource and args['p_evidence_kind'] in ('owned_child_joined', 'owned_scope_retired_v1')
            and type(args['p_receipt_id']) is str and str(uuid.UUID(args['p_receipt_id'])) == args['p_receipt_id']
            and type(args['p_facts']) is dict and args['p_facts']['binding_sha256'] == execution['binding_sha256'],
            'receipt_checkpoint_mismatch')


def check_ack(reply, execution, args, binding, job_id, claim_id):
    require(type(reply) is dict and set(reply) == {'replayed', 'receipt_id', 'execution'}
            and type(reply['replayed']) is bool, 'invalid_receipt_ack')
    actual = reply['execution']
    validate_execution(actual, binding, job_id, claim_id)
    require(actual['id'] == execution['id'], 'invalid_receipt_ack')
    row = accepted(actual, args['p_resource'])
    require(row is not None and row['receipt_id'] == reply['receipt_id']
            and row['evidence_kind'] == args['p_evidence_kind'] and row['facts'] == args['p_facts'],
            'invalid_receipt_ack')
    return actual


def checked_observation(value, capture, binding_sha256, fence):
    binding = capture['binding_without_capture_sha256']
    scope = binding['scope']
    require(type(value) is dict and set(value) == {'schema_version', 'kind', 'binding_sha256', 'capture_sha256',
            'fence_sha256', 'boot_id', 'scope_id', 'captured_invocation_id', 'observed_invocation_id', 'service', 'group'}
            and type(value['schema_version']) is int and value['schema_version'] == 1
            and value['kind'] == 'linux_metadata_scope_empty_v1' and value['binding_sha256'] == binding_sha256
            and value['capture_sha256'] == digest(canonical(capture)) and value['fence_sha256'] == digest(canonical(fence))
            and value['boot_id'] == binding['boot_id'] and value['scope_id'] == capture['claim_id']
            and value['captured_invocation_id'] == scope['invocation_id']
            and value['observed_invocation_id'] in ('', scope['invocation_id']), 'invalid_scope_observation')
    service, group = value['service'], value['group']
    require(type(service) is dict and set(service) == {'active_state', 'main_pid', 'pending_job'}
            and service['active_state'] in ('inactive', 'failed') and type(service['main_pid']) is int
            and service['main_pid'] == 0 and service['pending_job'] is False
            and type(group) is dict and group == {'path': '/tsmetadata' + uuid.UUID(capture['claim_id']).hex + '.slice',
                'device': scope['cgroup_device'], 'inode': scope['cgroup_inode'], 'populated': 0}
            and type(group['populated']) is int, 'invalid_scope_observation')
    return value


def settle(journal, observer, scope, execution, binding, capture, ready):
    """Called with the action lock held and the exact scope already stop-fenced.

    Replies expose a retained witness only when its measured body is supported
    by the accepted source receipt. No grant/result capability is invoked here.
    """
    require(observer.capability == 'observer', 'observer_required')
    require(scope.journal is journal, 'scope_journal_mismatch')
    job_id, claim_id = capture['job_id'], capture['claim_id']
    validate_execution(execution, binding, job_id, claim_id)
    require(scope.observer.boot() == binding['boot_id'], 'changed_boot_requires_review')
    scope.checked_capture(capture, ready, binding)
    fence = journal.read('stop-fence.json')
    positive = scope.observe(capture, ready, binding, execution['binding_sha256'], fence)
    if positive is None:
        return {'state': 'scope_unresolved', 'execution': execution, 'witness': None}
    checked_observation(positive, capture, execution['binding_sha256'], fence)
    saved = journal.recover('observation.json',
            lambda value: checked_observation(value, capture, execution['binding_sha256'], fence))
    if saved is None:
        journal.put('observation.json', positive)
    else:
        positive = saved
    report = None
    # An unfinished producer slot remains retained. It cannot become a body or
    # join witness; the independent empty-scope proof can still settle at full charge.
    if any(witness_slots.FINAL in _names(journal.directories[leaf], 3) for leaf in ('ingress', 'witness')):
        raw = journal.witness(lambda raw: checked_witness(decode(raw), binding, capture['source_request'], execution))
        report = checked_witness(decode(raw), binding, capture['source_request'], execution)
    joined = report is not None and report['owned_process_retired'] is True
    transport = report['result'] if joined else None
    measured = (transport is not None and transport['kind'] == 'complete' and report['returncode'] == 0
                and transport['framing'] in ('content_length', 'chunked', 'close_delimited'))
    scope_facts = {'binding_sha256': execution['binding_sha256'], 'scope_id': claim_id,
        'capture_sha256': positive['capture_sha256'], 'fence_sha256': positive['fence_sha256'],
        'observation_sha256': digest(canonical(positive))}
    joined_facts = {'binding_sha256': execution['binding_sha256'], 'disposition': report['disposition']} if joined else None
    kind = 'owned_child_joined' if joined else 'owned_scope_retired_v1'
    source_facts = dict(joined_facts if joined else scope_facts,
        framing=transport['framing'] if measured else 'unknown',
        peer_eof=transport is not None and transport['tls_peer_close'] == 'clean_tls' if joined else False,
        actual_bytes=transport['body_bytes'] if measured else None,
        body_sha256=transport['body_sha256'] if measured else None,
        status_code=transport['status'] if transport is not None else None,
        retry_after_seconds=transport['retry_after_seconds'] if transport is not None else 0)
    for resource, facts in (('executor', joined_facts if joined else scope_facts), ('arxiv_connection', source_facts)):
        canonical_row = accepted(execution, resource)
        if resource == 'arxiv_connection' and canonical_row is None and transport is not None and transport['retry_after_kind'] == 'unsupported':
            return {'state': 'retry_after_unresolved', 'execution': execution, 'witness': None}
        name = resource + '.json'
        def validate_record(record):
            require(type(record) is dict and set(record) == {'name', 'parameters'}
                    and record['name'] == 'worker_record_metadata_quiescence', 'receipt_checkpoint_mismatch')
            check_arguments(record['parameters'], execution, resource)
        record = journal.recover(name, validate_record)
        if record is not None:
            args = record['parameters']
            if canonical_row is not None:
                require(args['p_evidence_kind'] == canonical_row['evidence_kind'] and args['p_facts'] == canonical_row['facts'],
                        'accepted_receipt_conflict')
            elif args['p_evidence_kind'] != kind or args['p_facts'] != facts:
                # An attempted receipt cannot be replaced with a different
                # proof while its database outcome remains unknown.
                return {'state': 'receipt_evidence_unresolved', 'execution': execution, 'witness': None}
        else:
            # Existing authenticated evidence wins per resource. Never turn an
            # already accepted joined receipt into a new scope-only assertion.
            args = receipt_arguments(execution, resource, canonical_row['evidence_kind'] if canonical_row else kind,
                    canonical_row['facts'] if canonical_row else facts, canonical_row['receipt_id'] if canonical_row else None)
            journal.put(name, {'name': 'worker_record_metadata_quiescence', 'parameters': args})
        # Replayed flags and execution state evolve. Retain the first durable
        # acknowledgement; validate every new reply without overwriting it.
        saved_ack = journal.recover(resource + '-ack.json',
                lambda value: check_ack(value, execution, args, binding, job_id, claim_id))
        reply = observer.call('worker_record_metadata_quiescence', args)
        execution = check_ack(reply, execution, args, binding, job_id, claim_id)
        if saved_ack is None:
            journal.put(resource + '-ack.json', reply)
    require(execution['pending_resources'] == [], 'resources_unsettled')
    source = accepted(execution, 'arxiv_connection')
    usable = measured and source['evidence_kind'] == 'owned_child_joined'
    usable = usable and transport['retry_after_kind'] != 'unsupported' and source['facts'] == source_facts
    return {'state': 'settled', 'execution': execution, 'witness': report if usable else None}

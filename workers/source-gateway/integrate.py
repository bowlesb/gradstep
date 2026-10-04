"""One local PostgreSQL + loopback TLS action. Never a hosted gateway."""
import datetime
import os
from pathlib import Path
import re
import sys
import uuid

import frozen_context
from journal import Journal, MAX_BYTES, MAX_FILES
from local_postgres import LocalRPC, bounded
from paused_child import PausedChild
from frozen import executable_sha
from protocol import MAX_BODY, MAX_OUTPUT, canonical, decode, digest, require, Refused, target, clock_ns
from execution_contract import source_dto, instant, grant_deadlines, validate_execution, parser_input, checked_witness

PROJECT = 'abcdefghijklmnopqrst'  # Explicit synthetic local fixture identity.
HOST = 'c1200000-0000-0000-0000-000000000001'


def policy_hashes(manifest):
    bundle = digest(canonical(manifest))
    return {scope + '_sha256': digest(canonical({'bundle': bundle, 'scope': scope, 'local_fixture_only': True}))
            for scope in ('runner', 'transport', 'observer', 'admission')}


def deno_parser(value):
    root = frozen_context.root
    raw = canonical(value)
    require(len(raw) <= MAX_OUTPUT, 'parser_input_limit')
    manifest = frozen_context.manifest
    require(executable_sha(manifest['deno_path']) == manifest['deno_sha256'], 'parser_runtime_changed')
    command = [manifest['deno_path'], 'run', '--no-config', '--no-lock', '--no-npm', '--no-remote',
               '--cached-only', '--node-modules-dir=none', '--no-prompt',
               '--deny-net', '--deny-env', '--deny-read', '--deny-write', '--deny-run', '--deny-ffi', '--deny-sys',
               str(root / 'parser/parser.mjs')]
    return decode(bounded(command, raw, timeout=5, maximum=45_000,
                          environment={'PATH': '/usr/bin:/bin'}, cwd=root))


def run_local_action(rpc, job_id, fixture, journal_root, parser, *, cancelled=None, source_budget_ms=30_000):
    require(type(rpc) is LocalRPC and callable(parser) and str(uuid.UUID(job_id)) == job_id
            and type(source_budget_ms) is int and 1 <= source_budget_ms <= 30_000, 'local_fixture_required')
    journal = Journal(journal_root)
    session = None
    claim_id = str(uuid.uuid4())
    execution = binding = None
    committed = False
    reason = None
    result = {'schema_version': 1, 'mode': 'local_fixture_only', 'journal': str(journal.path), 'claim_id': claim_id,
              'job_id': job_id, 'state': 'reconcile_required', 'source_network_enabled': False, 'hosted_admitted': False}
    try:
        # Reserve the complete logical run envelope BEFORE a grant. Body exists
        # only once (witness.json); parser input rehydrates that checkpoint.
        size = frozen_context.manifest['source_bytes'] + MAX_OUTPUT + 8 * 65_536 + 8 * 4096
        count = len(frozen_context.manifest['files']) + 2 + 14
        require(size <= MAX_BYTES and count <= MAX_FILES, 'journal_capacity')
        journal.put('capacity.json', {'maximum_total_bytes': size, 'maximum_files': count,
                                     'body_checkpoints': 1, 'bundle_sha256': digest(canonical(frozen_context.manifest))})
        identity_args = {'p_job_id': job_id, 'p_claim_id': claim_id}
        state = rpc.call('worker_metadata_execution_state', identity_args)
        job = state['job']
        require(job['id'] == job_id and state['execution'] is None, 'invalid_job')
        request = source_dto(job)
        authority = rpc.call('worker_metadata_authority_state', {})
        require(authority['project_ref'] == PROJECT and authority['environment'] == 'staging'
                and authority['enabled'] is True and authority['recovery_required'] is False, 'fixture_disabled')
        if cancelled is not None and cancelled.is_set():
            result['state'] = 'cancelled_before_start'; return result
        session = PausedChild(request, fixture)
        binding = {'version': 1, 'project_ref': PROJECT, 'environment': 'staging', 'epoch': authority['epoch'],
                   'policy_id': authority['policy_id'], **{key: value for key, value in policy_hashes(frozen_context.manifest).items() if key != 'admission_sha256'},
                   'deployment_id': 'local-fixture-' + digest(canonical(frozen_context.manifest))[:32],
                   'host_id': HOST, **session.identity, 'child_id': session.value['attempt_id']}
        parameters = {'p_job_id': job_id, 'p_claim_id': claim_id, 'p_environment': 'staging', 'p_executor_binding': binding}
        journal.put('intent.json', {'parameters': parameters, 'request': request, 'source_sha256': digest(canonical(request)),
                                   'job': job, 'sent_go': False})
        before_rpc = clock_ns()
        try:
            grant = rpc.call('worker_claim_metadata_stage_v2', parameters)  # Exactly one call; never replay as status.
            committed = True
            journal.put('grant.json', {'response': grant, 'before_rpc_ns': str(before_rpc)})
        except (Refused, OSError):
            reason = 'grant_ack_unknown'
            report = session.stop()
            journal.put('witness.json', report)
            try:
                recovered = rpc.call('worker_metadata_execution_state', identity_args)
                journal.put('grant-status.json', recovered)
                execution = recovered['execution']
            except (Refused, OSError):
                execution = None
            if execution is None:
                result['reason'] = reason; return result
            validate_execution(execution, binding, job_id, claim_id)
            grant = {'job': job, 'execution': execution, 'granted': False}
        execution = grant.get('execution')
        if execution is None:
            report = session.stop(); journal.put('witness.json', report)
            result['state'] = grant['action']; return result
        validate_execution(execution, binding, job_id, claim_id)
        if committed and grant['granted'] is True:
            returned = grant['job']
            expected = source_dto(returned, execution['kind'], execution['byte_ceiling'])
            require(returned['id'] == job_id and returned['claim_id'] == claim_id
                    and returned['generation'] == execution['generation'] and returned['stage'] == execution['kind'], 'invalid_grant')
            useful, report_deadline = grant_deadlines(execution, before_rpc)
            deadline = min(useful, clock_ns() + source_budget_ms * 1_000_000)
            if canonical(expected) != canonical(request):
                reason = 'source_changed'
            elif deadline <= clock_ns() or cancelled is not None and cancelled.is_set():
                reason = 'expired_or_cancelled'
            else:
                job = returned
                journal.put('go-intent.json', {'execution_id': execution['id'], 'deadline_ns': str(deadline),
                                               'source_sha256': digest(canonical(request))})
                try:
                    require(cancelled is None or not cancelled.is_set(), 'cancelled')
                    session.go(execution['id'], deadline, cancelled=cancelled)
                    report = session.finish(deadline, cancelled=cancelled)
                except (Refused, OSError):
                    reason = 'control_failed'; report = session.stop()
            if reason is not None:
                report = session.stop()
            journal.put('witness.json', report)
        elif reason is None:
            reason = 'grant_status_only'
            report = session.stop(); journal.put('witness.json', report)
        return settle_local(rpc, journal, execution, binding, job_id, claim_id, request, job, parser, reason, result)
    except (Refused, KeyError, ValueError, TypeError, OSError) as error:
        result['reason'] = 'local_contract_or_checkpoint_failed'
        result['error_type'] = type(error).__name__
        # Only known local contract enums, never exception messages or bodies.
        if isinstance(error, Refused) and error.code in {
            'invalid_witness', 'witness_binding_mismatch', 'invalid_grant', 'execution_binding_mismatch',
            'immutable_checkpoint', 'journal_capacity', 'invalid_output', 'invalid_receipt_ack',
            'invalid_deadline', 'child_identity_changed', 'invalid_job', 'invalid_ready', 'deadline',
            'invalid_request', 'checkpoint_changed', 'bootstrap_changed'}:
            result['detail'] = error.code
        return result
    finally:
        if session is not None:
            final_witness = session.stop()
            try:
                if 'witness.json' not in journal._records:
                    journal.put('witness.json', final_witness)
                elif final_witness['owned_process_retired'] is True and journal.read('witness.json')['owned_process_retired'] is False:
                    # Only this exact retained Popen can produce the later
                    # witness. Do not rewrite an earlier unresolved checkpoint.
                    journal.put('terminal-witness.json', final_witness)
            except (OSError, Refused):
                pass  # No receipt may be fabricated from a failed checkpoint.
        journal.close()


def settle_local(rpc, journal, execution, binding, job_id, claim_id, request, job, parser, reason, result):
    report = checked_witness(journal.read('witness.json'), binding, request, execution)
    if 'terminal-witness.json' in journal._records:
        final = checked_witness(journal.read('terminal-witness.json'), binding, request, execution)
        require(report['owned_process_retired'] is False and final['owned_process_retired'] is True
                and final['sent_go'] == report['sent_go'] and final['result'] is None, 'invalid_witness')
        report = final
    if report['owned_process_retired'] is False:
        result['reason'] = 'child_unresolved'; return result
    transport = report['result']
    common = {'binding_sha256': execution['binding_sha256'], 'disposition': report['disposition']}
    known = transport is not None and transport['kind'] == 'complete' and report['returncode'] == 0
    known = known and transport['framing'] in ('content_length', 'chunked', 'close_delimited')
    facts = dict(common, framing=transport['framing'] if known else 'unknown',
                 peer_eof=transport is not None and transport['tls_peer_close'] == 'clean_tls',
                 actual_bytes=transport['body_bytes'] if known else None,
                 body_sha256=transport['body_sha256'] if known else None,
                 status_code=transport['status'] if transport is not None else None,
                 retry_after_seconds=transport['retry_after_seconds'] if transport is not None else 0)
    for resource, resource_facts in (('executor', common), ('arxiv_connection', facts)):
        if resource == 'arxiv_connection' and transport is not None and transport['retry_after_kind'] == 'unsupported':
            result['reason'] = 'retry_after_unresolved'; return result
        phase = resource + '.json'
        if phase in journal._records:
            checkpoint = journal.read(phase)
            args = checkpoint['parameters']
            require(checkpoint['name'] == 'worker_record_metadata_quiescence' and set(args) == {
                'p_attempt_id', 'p_receipt_id', 'p_resource', 'p_evidence_kind', 'p_facts'}
                and args['p_attempt_id'] == execution['id'] and args['p_resource'] == resource
                and args['p_evidence_kind'] == 'owned_child_joined' and args['p_facts'] == resource_facts,
                'receipt_checkpoint_mismatch')
        else:
            args = {'p_attempt_id': execution['id'], 'p_receipt_id': str(uuid.uuid4()), 'p_resource': resource,
                    'p_evidence_kind': 'owned_child_joined', 'p_facts': resource_facts}
            journal.put(phase, {'name': 'worker_record_metadata_quiescence', 'parameters': args})
        try:
            reply = rpc.call('worker_record_metadata_quiescence', args)
        except Refused:
            result['reason'] = 'receipt_ack_unknown'; return result
        validate_execution(reply['execution'], binding, job_id, claim_id)
        require(reply['execution']['id'] == execution['id'] and resource not in reply['execution']['pending_resources'], 'invalid_receipt_ack')
        receipts = [item for item in reply['execution']['receipts'] if item['resource'] == resource]
        require(len(receipts) == 1 and receipts[0]['receipt_id'] == reply['receipt_id']
                and receipts[0]['evidence_kind'] == 'owned_child_joined' and receipts[0]['facts'] == resource_facts,
                'invalid_receipt_ack')
        if resource + '-ack.json' not in journal._records:
            journal.put(resource + '-ack.json', reply)
    require(reply['execution']['pending_resources'] == [], 'resources_unsettled')
    mutation = {'p_job_id': job_id, 'p_claim_id': claim_id, 'p_generation': execution['generation'], 'p_attempt_id': execution['id']}
    status = transport['status'] if transport is not None else None
    if 'result.json' in journal._records:
        checkpoint = journal.read('result.json')
        name, stored = checkpoint['name'], checkpoint['parameters']
        require(name in ('worker_finish_metadata_stage_v2', 'worker_fail_metadata_stage_v2')
                and all(stored[key] == value for key, value in mutation.items()), 'result_checkpoint_mismatch')
        if name == 'worker_finish_metadata_stage_v2':
            require(known and stored['p_body_sha256'] == transport['body_sha256'], 'result_checkpoint_mismatch')
        mutation = stored
    elif known and status == 200:
        observed = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        parsed_input = parser_input(job, request, transport, observed)
        if 'parser-input.json' in journal._records:
            saved = journal.read('parser-input.json')
            require(saved['request'] == request and saved['body_sha256'] == transport['body_sha256'], 'parser_checkpoint_mismatch')
            parsed_input = dict(saved, body_base64=transport['body_base64'])
        else:
            journal.put('parser-input.json', {key: value for key, value in parsed_input.items() if key != 'body_base64'})
        parsed = parser(decode(canonical(parsed_input)))
        require(type(parsed) is dict and parsed['schema_version'] == 1, 'parser_rejected')
        if parsed['kind'] == 'result':
            require(parsed['body_sha256'] == transport['body_sha256'] and len(canonical(parsed['result'])) <= 40_960, 'parser_rejected')
            name = 'worker_finish_metadata_stage_v2'
            mutation.update(p_body_sha256=transport['body_sha256'], p_result=parsed['result'])
        elif parsed['kind'] == 'failure':
            require(parsed['error_code'] in ('source_not_found', 'invalid_source_metadata') and parsed['retryable'] is False, 'parser_rejected')
            name = 'worker_fail_metadata_stage_v2'
            mutation.update(p_error_code=parsed['error_code'], p_retryable=False)
        else:
            result['reason'] = 'parser_rejected'; return result
    else:
        name = 'worker_fail_metadata_stage_v2'
        mutation.update(p_error_code='source_not_found' if status == 404 else 'rate_limited' if status == 429 else 'metadata_unavailable',
                        p_retryable=status is None or status == 429 or status >= 500 or reason is not None)
    journal.put('result.json', {'name': name, 'parameters': mutation})
    try:
        final = rpc.call(name, mutation)
    except Refused:
        result['reason'] = 'result_ack_unknown'; return result
    require(final['id'] == job_id and final['source_id'] == request['source_id']
            and final['requested_revision'] == job['requested_revision'], 'invalid_result_ack')
    if 'result-ack.json' not in journal._records:
        journal.put('result-ack.json', final)
    result.update(state='completed', job=final, execution_id=execution['id'])
    return result


def recover_local_action(rpc, path, parser):
    """Replay durable checkpoints only; never start a child or invoke a grant."""
    result = {'schema_version': 1, 'mode': 'local_fixture_only', 'journal': str(path),
              'state': 'reconcile_required', 'source_network_enabled': False, 'hosted_admitted': False}
    journal = None
    try:
        journal = Journal.existing(path)
        capacity = journal.read('capacity.json')
        require(capacity['bundle_sha256'] == digest(canonical(frozen_context.manifest)), 'bundle_changed')
        intent = journal.read('intent.json')
        parameters = intent['parameters']
        job_id, claim_id = parameters['p_job_id'], parameters['p_claim_id']
        binding, request = parameters['p_executor_binding'], intent['request']
        require(str(uuid.UUID(job_id)) == job_id and str(uuid.UUID(claim_id)) == claim_id
                and intent['source_sha256'] == digest(canonical(request)), 'intent_mismatch')
        target(request)
        result.update(job_id=job_id, claim_id=claim_id)
        state = rpc.call('worker_metadata_execution_state', {'p_job_id': job_id, 'p_claim_id': claim_id})
        execution = state['execution']
        if execution is None:
            # An MVCC null does not prove the original transaction cannot
            # commit later. Retain all intent/child evidence; never re-grant.
            result['reason'] = 'grant_still_unknown'; return result
        validate_execution(execution, binding, job_id, claim_id)
        report = checked_witness(journal.read('witness.json'), binding, request, execution)
        job = journal.read('grant.json')['response']['job'] if 'grant.json' in journal._records else intent['job']
        if report['sent_go']:
            require(canonical(source_dto(job, execution['kind'], execution['byte_ceiling'])) == canonical(request), 'source_changed')
        return settle_local(rpc, journal, execution, binding, job_id, claim_id, request, job, parser,
                            None if report['sent_go'] else 'grant_ack_unknown', result)
    except (Refused, KeyError, ValueError, TypeError, OSError):
        result['reason'] = 'recovery_contract_or_checkpoint_failed'
        return result
    finally:
        if journal is not None:
            journal.close()


def main():
    raw = sys.stdin.buffer.read(24_577)
    require(len(raw) <= 24_576, 'input_limit')
    value = decode(raw)
    if 'recover_journal' in value:
        require(set(value) <= {'database', 'recover_journal', 'faults'}, 'invalid_action')
    else:
        require(set(value) <= {'database', 'job_id', 'fixture', 'journal_root', 'source_budget_ms', 'faults'}, 'invalid_action')
    rpc = LocalRPC(value['database'], faults=value.get('faults'))
    if 'recover_journal' in value:
        result = recover_local_action(rpc, value['recover_journal'], deno_parser)
    else:
        result = run_local_action(rpc, value['job_id'], value['fixture'], value['journal_root'], deno_parser,
                                  source_budget_ms=value.get('source_budget_ms', 30_000))
    result['calls'] = rpc.calls
    output = canonical(result)
    require(len(output) <= 65_536, 'output_limit')
    sys.stdout.buffer.write(output + b'\n')
    return 0

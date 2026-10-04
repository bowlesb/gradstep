"""Shared metadata source, deadline, execution and retained-witness validation."""
import datetime
import re
import uuid

from protocol import MAX_BODY, canonical, digest, require, target
from supervisor import checked_result

def source_dto(job, kind=None, ceiling=MAX_BODY):
    stage = kind or job['stage']
    require(job['kind'] == 'lookup' and stage in ('atom', 'license'), 'invalid_job')
    result = {'source_id': job['source_id'], 'revision': job['requested_revision'] if stage == 'atom' else job['source_revision'],
              'stage': stage, 'byte_ceiling': ceiling}
    target(result)
    if stage == 'license':
        require(result['revision'] is not None and job['metadata_id'] is not None, 'invalid_job')
    return result


def instant(value):
    require(type(value) is str and len(value) <= 64, 'invalid_deadline')
    match = re.fullmatch(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,6}))?(Z|[+-]\d\d:\d\d)', value)
    require(match is not None, 'invalid_deadline')
    # PostgreSQL omits trailing fractional zeroes. Python 3.9 accepts only
    # three or six fractional digits; normalize without changing the instant.
    normalized = match[1] + ('.' + match[2].ljust(6, '0') if match[2] else '') + match[3].replace('Z', '+00:00')
    result = datetime.datetime.fromisoformat(normalized)
    require(result.tzinfo is not None, 'invalid_deadline')
    return result


def grant_deadlines(execution, before_rpc):
    created = instant(execution['created_at'])
    useful = int((instant(execution['useful_deadline']) - created).total_seconds() * 1e9)
    report = int((instant(execution['report_deadline']) - created).total_seconds() * 1e9)
    require(0 < useful <= report <= 120_000_000_000, 'invalid_deadline')
    return before_rpc + useful, before_rpc + report


def validate_execution(execution, binding, job_id, claim_id):
    require(type(execution) is dict and execution['job_id'] == job_id and execution['claim_id'] == claim_id
            and execution['binding'] == binding and execution['epoch'] == binding['epoch']
            and execution['policy_id'] == binding['policy_id'] and execution['byte_ceiling'] == MAX_BODY
            and type(execution['generation']) is int and execution['generation'] > 0
            and execution['kind'] in ('atom', 'license')
            and type(execution['binding_sha256']) is str and re.fullmatch(r'[0-9a-f]{64}', execution['binding_sha256'])
            and str(uuid.UUID(execution['id'])) == execution['id'], 'execution_binding_mismatch')


def parser_input(job, request, report, observed):
    pinned = None
    if request['stage'] == 'license':
        metadata = job['metadata']
        pinned = {'sourceID': job['source_id'], 'revision': job['source_revision'], 'metadata': {
            'title': metadata['title'], 'authors': list(metadata['authors']),
            'abstract': metadata.get('abstract'), 'categories': list(metadata.get('categories', [])),
            'venue': metadata.get('venue'), 'published_at': job['atom_published_at'], 'updated_at': job['atom_updated_at']}}
    return {'schema_version': 1, 'request': request, 'pinned_record': pinned,
            'body_base64': report['body_base64'], 'body_sha256': report['body_sha256'], 'observed_at': observed}


def checked_witness(report, binding, request, execution):
    require(type(report) is dict and set(report) == {
        'schema_version', 'outcome', 'identity', 'child_id', 'source_sha256', 'execution_id',
        'sent_go', 'returncode', 'owned_process_retired', 'retirement_witness', 'disposition', 'result'}
        and type(report['schema_version']) is int and report['schema_version'] == 1
        and type(report['sent_go']) is bool and type(report['owned_process_retired']) is bool
        and report['outcome'] in ('completed', 'stopped', 'unresolved', 'invalid_output', 'child_exit', 'output_limit'),
        'invalid_witness')
    require(report['child_id'] == binding['child_id'] and report['identity'] == {
        key: binding[key] for key in ('boot_id', 'process_id', 'process_start_id')}
        and report['source_sha256'] == digest(canonical(request))
        and (report['execution_id'] == execution['id'] if report['sent_go'] else report['execution_id'] is None),
        'witness_binding_mismatch')
    if report['owned_process_retired'] is True:
        require(type(report['returncode']) is int and report['retirement_witness'] == 'parent_waitpid'
                and report['disposition'] == ('exited' if report['returncode'] >= 0 else 'killed')
                and report['outcome'] != 'unresolved', 'invalid_witness')
    else:
        require(report['returncode'] is None and report['retirement_witness'] is None
                and report['result'] is None and report['outcome'] == 'unresolved', 'invalid_witness')
    if report['result'] is not None:
        require(report['owned_process_retired'] is True and report['returncode'] == 0
                and report['sent_go'] is True and report['outcome'] == 'completed', 'invalid_witness')
        checked_result(canonical(report['result']), {'attempt_id': binding['child_id'], 'request': request})
    return report

"""One local metadata action: independent executor and guardian on bounded pipes.

Only the executor calls grant/result RPCs or runs the parser. Only the guardian
owns the action journal, source scope and observer receipts. Recovery never
starts a source scope or repeats a grant. There is no general RPC proxy here.
"""
import datetime
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import sys
import uuid

import frozen_context
from common import canonical, decode, require
from protocol import MAX_OUTPUT, Refused, clock_ns, digest
from execution_contract import source_dto, validate_execution, parser_input
from runtime_identity import executable_sha
from rpc_support import bounded
from restricted_rpc import RestrictedRPC, connection
from metadata_host import HostAction, authority_matches
from metadata_scope import checked_go
from metadata_settlement import settle
from owned_session import controller_children, subreaper, retire_controller
import lifecycle
import uid_policy

LIMIT = MAX_OUTPUT


class Channel:
    """One frame at a time, finite lifetime and bytes; no line/body logging."""
    def __init__(self, incoming, outgoing, *, lifetime=100):
        self.incoming, self.outgoing = incoming, outgoing
        self.deadline = clock_ns() + lifetime * 1_000_000_000
        self.reads = self.writes = 0
        os.set_blocking(incoming, False)
        os.set_blocking(outgoing, False)

    def transfer(self, fd, value, *, writing):
        offset = 0
        output = bytearray()
        size = len(value) if writing else value
        with selectors.DefaultSelector() as selector:
            selector.register(fd, selectors.EVENT_WRITE if writing else selectors.EVENT_READ)
            while offset < size:
                remaining = (self.deadline - clock_ns()) / 1_000_000_000
                require(remaining > 0, 'controller_deadline')
                if not selector.select(min(.05, remaining)):
                    continue
                if writing:
                    count = os.write(fd, value[offset:offset + 16_384])
                else:
                    raw = os.read(fd, min(16_384, size - offset))
                    count = len(raw)
                    output.extend(raw)
                require(count > 0, 'controller_closed')
                offset += count
        return bytes(output)

    def send(self, value):
        raw = canonical(value)
        require(self.writes < 8 and 0 < len(raw) <= LIMIT, 'controller_frame_limit')
        self.writes += 1
        self.transfer(self.outgoing, struct.pack('!I', len(raw)) + raw, writing=True)

    def receive(self, *, maximum=65_536):
        require(self.reads < 8, 'controller_frame_limit')
        self.reads += 1
        size = struct.unpack('!I', self.transfer(self.incoming, 4, writing=False))[0]
        require(0 < size <= min(maximum, LIMIT), 'controller_frame_limit')
        return decode(self.transfer(self.incoming, size, writing=False))


def message(value, step, fields):
    require(type(value) is dict and set(value) == {'step', *fields} and value['step'] == step,
            'controller_sequence_mismatch')
    return value


def configuration(value):
    require(type(value) is dict and set(value) == {'mode', 'job_id', 'claim_id', 'fixture', 'observer', 'executor'}
            and value['mode'] in ('run', 'recover')
            and all(type(value[key]) is str and str(uuid.UUID(value[key])) == value[key]
                    for key in ('job_id', 'claim_id')), 'invalid_action_configuration')
    observer, _ = connection(value['observer'])
    executor, _ = connection(value['executor'])
    require(observer['capability'] == 'observer' and executor['capability'] == 'executor'
            and all(observer[key] == executor[key] for key in
                ('instance', 'port', 'database', 'psql_sha256', 'ca_sha256')), 'action_database_mismatch')
    return value


def intent_value(job, request, binding, origin):
    return {'parameters': {'p_job_id': job['id'], 'p_claim_id': binding['scope']['scope_id'],
                'p_environment': 'staging', 'p_executor_binding': binding},
            'request': request, 'source_sha256': digest(canonical(request)), 'job': job,
            'before_rpc_ns': str(origin), 'sent_go': False}


def checked_intent(value, action, job_id):
    require(type(value) is dict and set(value) == {'parameters', 'request', 'source_sha256', 'job',
            'before_rpc_ns', 'sent_go'} and type(value['before_rpc_ns']) is str
            and re.fullmatch(r'[1-9][0-9]{0,19}', value['before_rpc_ns']), 'invalid_grant_intent')
    require(value['job']['id'] == job_id == action.capture['job_id']
            and value['request'] == action.capture['source_request'] == source_dto(value['job'])
            and value == intent_value(value['job'], value['request'], action.binding, int(value['before_rpc_ns']))
            and int(value['before_rpc_ns']) <= clock_ns(), 'invalid_grant_intent')
    return value


def checked_grant(value, action, intent):
    require(type(value) is dict and set(value) == {'response', 'before_rpc_ns'}
            and value['before_rpc_ns'] == intent['before_rpc_ns'], 'invalid_grant_checkpoint')
    grant = value['response']
    require(type(grant) is dict and type(grant['granted']) is bool and grant['job']['id'] == intent['job']['id'],
            'invalid_grant_checkpoint')
    if grant['granted'] or grant['action'] == 'reconcile':
        require(set(grant) == {'granted', 'action', 'job', 'execution'}
                and grant['action'] == ('perform_stage' if grant['granted'] else 'reconcile'),
                'invalid_grant_checkpoint')
        validate_execution(grant['execution'], action.binding, intent['job']['id'], action.claim)
    elif grant['action'] == 'wait':
        require(set(grant) == {'granted', 'action', 'job', 'reason', 'next_allowed_at'}
                and grant['reason'] in ('unsettled_execution', 'cooldown')
                and (grant['next_allowed_at'] is None or type(grant['next_allowed_at']) is str
                     and len(grant['next_allowed_at']) <= 64), 'invalid_grant_checkpoint')
    else:
        require(set(grant) == {'granted', 'action', 'job'}
                and grant['action'] in ('disabled', 'terminal', 'no_interest'), 'invalid_grant_checkpoint')
    return value


def result_record(execution, witness, parsed=None):
    parameters = {'p_job_id': execution['job_id'], 'p_claim_id': execution['claim_id'],
                  'p_generation': execution['generation'], 'p_attempt_id': execution['id']}
    transport = witness['result'] if witness is not None else None
    if transport is not None and transport['status'] == 200:
        require(type(parsed) is dict and type(parsed.get('schema_version')) is int and parsed['schema_version'] == 1,
                'invalid_parser_result')
        if parsed.get('kind') == 'result':
            require(set(parsed) == {'schema_version', 'kind', 'body_sha256', 'result'}
                    and parsed['body_sha256'] == transport['body_sha256'] and type(parsed['result']) is dict
                    and len(canonical(parsed['result'])) <= 40_960, 'invalid_parser_result')
            return {'name': 'worker_finish_metadata_stage_v2', 'parameters': dict(parameters,
                    p_body_sha256=transport['body_sha256'], p_result=parsed['result'])}
        require(set(parsed) == {'schema_version', 'kind', 'error_code', 'retryable'} and parsed['kind'] == 'failure'
                and parsed['error_code'] in ('source_not_found', 'invalid_source_metadata')
                and parsed['retryable'] is False, 'invalid_parser_result')
        error, retryable = parsed['error_code'], False
    else:
        status = transport['status'] if transport is not None else None
        error = 'source_not_found' if status == 404 else 'rate_limited' if status == 429 else 'metadata_unavailable'
        retryable = status is None or status == 429 or status >= 500
    return {'name': 'worker_fail_metadata_stage_v2',
            'parameters': dict(parameters, p_error_code=error, p_retryable=retryable)}


def checked_result_ack(value, job):
    require(type(value) is dict and value['id'] == job['id'] and value['source_id'] == job['source_id']
            and value['requested_revision'] == job['requested_revision'], 'invalid_result_ack')
    return value


def parse(value):
    manifest, root = frozen_context.manifest, frozen_context.root
    require(executable_sha(manifest['deno_path']) == manifest['deno_sha256'], 'parser_runtime_changed')
    command = [manifest['deno_path'], 'run', '--no-config', '--no-lock', '--no-npm', '--no-remote',
               '--cached-only', '--node-modules-dir=none', '--no-prompt', '--deny-net', '--deny-env',
               '--deny-read', '--deny-write', '--deny-run', '--deny-ffi', '--deny-sys', str(root / 'parser.mjs')]
    raw = canonical(value)
    require(len(raw) <= MAX_OUTPUT, 'parser_input_limit')
    return decode(bounded(command, raw, timeout=5, maximum=45_000,
                          environment={'PATH': '/usr/bin:/bin'}, cwd=root))


def executor(channel, rpc, *, parser=parse):
    """Finite trusted controller. No journal paths, service control or observer."""
    require(rpc.capability == 'executor', 'executor_required')
    value = message(channel.receive(), 'start', {'mode', 'job_id', 'claim_id'})
    identity = {'p_job_id': value['job_id'], 'p_claim_id': value['claim_id']}
    state = rpc.call('worker_metadata_execution_state', identity)
    channel.send({'step': 'prepare', 'state': state})
    answer = channel.receive(maximum=LIMIT)
    if answer.get('step') == 'grant':
        require(value['mode'] == 'run', 'recovery_cannot_grant')
        message(answer, 'grant', {'intent'})
        intent = answer['intent']
        require(intent['parameters']['p_job_id'] == value['job_id']
                and intent['parameters']['p_claim_id'] == value['claim_id'], 'grant_identity_mismatch')
        # Exactly one call. A missing acknowledgement is reported as uncertainty;
        # neither this process nor recovery uses grant as a status query.
        try:
            grant = rpc.call('worker_claim_metadata_stage_v2', intent['parameters'])
            answer = {'step': 'granted', 'response': grant}
        except (Refused, ValueError, OSError):
            answer = {'step': 'granted', 'response': None}
        channel.send(answer)
        answer = channel.receive(maximum=LIMIT)
    message(answer, 'outcome', {'state', 'result', 'parser_input'})
    if answer['state'] != 'settled':
        return answer['state']
    result = answer['result']
    if answer['parser_input'] is not None:
        parsed = parser(answer['parser_input'])
        channel.send({'step': 'parsed', 'value': parsed})
        result = message(channel.receive(), 'result', {'value'})['value']
    require(type(result) is dict and set(result) == {'name', 'parameters'}
            and result['name'] in ('worker_finish_metadata_stage_v2', 'worker_fail_metadata_stage_v2')
            and all(result['parameters'][key] == val for key, val in identity.items()), 'invalid_result_request')
    try:
        reply = rpc.call(result['name'], result['parameters'])
    except (Refused, ValueError, OSError):
        reply = None
    channel.send({'step': 'result-ack', 'value': reply})
    return message(channel.receive(), 'done', {'state'})['state']


def execution_state(observer, identity, action):
    value = observer.call('worker_metadata_execution_state', identity)
    require(type(value) is dict and set(value) == {'job', 'execution', 'step_result'}
            and value['job']['id'] == identity['p_job_id'], 'invalid_execution_state')
    if value['execution'] is not None:
        validate_execution(value['execution'], action.binding, identity['p_job_id'], action.claim)
    return value


def repair_controls(action, execution):
    """Complete saved control publication only after the fenced scope is empty.

    The permanent start fence predates the grant. A pending GO is not promoted
    while a child might still consume it, even though future starts are denied.
    """
    for name in ('go-intent.json', 'go.json'):
        def validate(value):
            checked_go(value, action.claim, action.ready, now=int(value['deadline_ns']) - 1)
            require(value['execution_id'] == execution['id'], 'go_execution_changed')
        # The caller must have already fenced/stopped the scope. Pending GO is
        # intentionally not published before that condition is established.
        action.journal.recover(name, validate)


def parser_context(action, job, execution, witness):
    journal = action.journal
    if witness is None or witness['result']['status'] != 200:
        expected = result_record(execution, witness)
        saved = journal.recover('result.json', lambda value: require(value == expected, 'result_checkpoint_mismatch'))
        if saved is None:
            journal.put('result.json', expected)
        return expected, None
    transport = witness['result']
    request = action.capture['source_request']
    def check_input(value):
        require(type(value) is dict and set(value) == {'schema_version', 'request', 'pinned_record', 'body_sha256', 'observed_at'},
                'invalid_parser_checkpoint')
        # parser_input validates pinned fields through the same captured job;
        # the actual parser additionally validates the timestamp's exact format.
        expected = parser_input(job, request, transport, value['observed_at'])
        del expected['body_base64']
        require(value == expected, 'parser_checkpoint_mismatch')
    saved = journal.recover('parser-input.json', check_input)
    if saved is None:
        observed = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        saved = parser_input(job, request, transport, observed)
        del saved['body_base64']
        journal.put('parser-input.json', saved)
    parsed = journal.recover('parser-output.json', lambda value: result_record(execution, witness, value))
    if parsed is not None:
        expected = result_record(execution, witness, parsed)
        stored = journal.recover('result.json', lambda value: require(value == expected, 'result_checkpoint_mismatch'))
        if stored is None:
            journal.put('result.json', expected)
        return expected, None
    require(not journal.exists('result.json'), 'missing_parser_output')
    return None, dict(saved, body_base64=transport['body_base64'])


def guardian(channel, observer, action, config, *, cancelled=None):
    require(observer.capability == 'observer', 'observer_required')
    identity = {'p_job_id': config['job_id'], 'p_claim_id': config['claim_id']}
    channel.send({'step': 'start', 'mode': config['mode'], 'job_id': config['job_id'], 'claim_id': config['claim_id']})
    offered = message(channel.receive(), 'prepare', {'state'})['state']
    if config['mode'] == 'run':
        state = observer.call('worker_metadata_execution_state', identity)
        require(state == offered and state['execution'] is None and state['job']['id'] == config['job_id'],
                'prepare_state_changed')
        job, request = state['job'], source_dto(state['job'])
        authority = observer.call('worker_metadata_authority_state', {})
        action.prepare(job, request, config['fixture'], authority)
        intent = intent_value(job, request, action.binding, clock_ns())
        action.journal.put('intent.json', intent)
        channel.send({'step': 'grant', 'intent': intent})
        answer = message(channel.receive(), 'granted', {'response'})['response']
        if answer is not None:
            checkpoint = {'response': answer, 'before_rpc_ns': intent['before_rpc_ns']}
            checked_grant(checkpoint, action, intent)
            action.journal.put('grant.json', checkpoint)
        current = execution_state(observer, identity, action)
        if answer is not None and answer['granted'] is True:
            authority = observer.call('worker_metadata_authority_state', {})
            try:
                action.release(answer, int(intent['before_rpc_ns']), current, authority, cancelled=cancelled)
            except (Refused, ValueError):
                pass  # No new GO; exact scope still requires independent retirement.
    else:
        action.restore()
        require(action.capture['job_id'] == config['job_id'], 'restored_job_mismatch')
        intent = action.journal.recover('intent.json', lambda value: checked_intent(value, action, config['job_id']))
        require(intent is not None, 'missing_grant_intent')
        grant = action.journal.recover('grant.json', lambda value: checked_grant(value, action, intent))
        answer = grant['response'] if grant is not None else None
        current = execution_state(observer, identity, action)
        job = grant['response']['job'] if grant is not None and grant['response']['granted'] else intent['job']
    if config['mode'] == 'run':
        job = answer['job'] if answer is not None and answer['granted'] else intent['job']
    execution = current['execution']
    declined = answer is not None and not answer['granted'] and answer['action'] != 'reconcile'
    require(not declined or execution is None, 'non_grant_execution_conflict')
    retired = action.retire()
    if execution is not None and retired:
        repair_controls(action, execution)
    # The first readback is a snapshot, not evidence that a later commit cannot
    # appear. It is preserved on every recovery regardless of evolving state.
    def check_status(value):
        require(value['job']['id'] == config['job_id'], 'status_checkpoint_mismatch')
        if value['execution'] is not None:
            validate_execution(value['execution'], action.binding, config['job_id'], config['claim_id'])
    saved = action.journal.recover('grant-status.json', check_status)
    if saved is None:
        action.journal.put('grant-status.json', current)
    if execution is not None and retired:
        closure = settle(action.journal, observer, action.scope, execution, action.binding, action.capture, action.ready)
    else:
        closure = {'state': answer['action'] if declined and retired else
                   'grant_still_unknown' if execution is None else 'scope_unresolved', 'witness': None}
    if closure['state'] != 'settled':
        channel.send({'step': 'outcome', 'state': closure['state'], 'result': None, 'parser_input': None})
        return {'state': closure['state'], 'job_id': config['job_id'], 'claim_id': config['claim_id']}
    execution, witness = closure['execution'], closure['witness']
    record, parsing = parser_context(action, job, execution, witness)
    saved_ack = action.journal.recover('result-ack.json', lambda value: checked_result_ack(value, job))
    channel.send({'step': 'outcome', 'state': 'settled', 'result': record, 'parser_input': parsing})
    if parsing is not None:
        parsed = message(channel.receive(), 'parsed', {'value'})['value']
        record = result_record(execution, witness, parsed)
        action.journal.put('parser-output.json', parsed)
        action.journal.put('result.json', record)
        channel.send({'step': 'result', 'value': record})
    reply = message(channel.receive(), 'result-ack', {'value'})['value']
    state = 'result_ack_unknown'
    if reply is not None:
        checked_result_ack(reply, job)
        if saved_ack is None:
            action.journal.put('result-ack.json', reply)
        state = 'completed'
    channel.send({'step': 'done', 'state': state})
    return {'state': state, 'job_id': config['job_id'], 'claim_id': config['claim_id'], 'execution_id': execution['id']}


def run(config):
    config = configuration(config)
    lifecycle.preflight()
    observer = RestrictedRPC(config['observer'])
    action = HostAction(frozen_context.root, frozen_context.manifest, config['claim_id'])
    child = None
    result = None
    try:
        action.open(fresh=config['mode'] == 'run')
        require(not controller_children(), 'unexpected_guardian_children')
        subreaper(True)
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B', str(frozen_context.root / 'bootstrap.py'),
                str(frozen_context.root), 'metadata_executor'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True,
                user=62403, group=62403, extra_groups=[],
                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, cwd=frozen_context.root)
        channel = Channel(child.stdout.fileno(), child.stdin.fileno())
        channel.send({'step': 'credential', 'descriptor': config['executor']})
        result = guardian(channel, observer, action, config)
        child.stdin.close()
    finally:
        try:
            if child is not None:
                code = retire_controller(child, grace=2 if result is not None else 0)
                subreaper(False)
                require(result is None or code == 0, 'controller_exit_unknown')
        finally:
            if child is not None:
                for pipe in (child.stdin, child.stdout):
                    if not pipe.closed:
                        pipe.close()
            if action.capture is not None:
                try:
                    action.retire()
                except (Refused, ValueError, KeyError, OSError):
                    pass  # Retain journal/units/holds; cleanup is a separate confirmed operation.
            action.close()
    return result


def executor_main():
    try:
        require(len(sys.argv) == 3 and os.getresuid() == (62403,) * 3 and os.getresgid() == (62403,) * 3
                and os.getgroups() == [], 'executor_identity_mismatch')
        uid_policy.prctl(38, 1)
        uid_policy.prctl(4, 0)
        channel = Channel(0, 1)
        value = message(channel.receive(), 'credential', {'descriptor'})
        executor(channel, RestrictedRPC(value['descriptor']))
        return 0
    except (Refused, ValueError, KeyError, TypeError, OSError):
        return 2


def main():
    try:
        require(len(sys.argv) == 3, 'invalid_arguments')
        raw = sys.stdin.buffer.read(24_577)
        require(0 < len(raw) <= 24_576, 'action_input_limit')
        result = run(decode(raw))
        print(canonical(dict(result, source_network_enabled=False, hosted_admitted=False)).decode())
        return 0 if result['state'] == 'completed' else 2
    except (Refused, ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
        print('{"state":"reconcile_required","source_network_enabled":false,"hosted_admitted":false}')
        return 2

"""Only a disposable loopback PostgreSQL fixture; no hosted connection option."""
import os
from pathlib import Path
import re
import selectors
import subprocess
import time
import uuid

from protocol import canonical, decode, require, Refused

EXECUTOR = 'science_reader_metadata_executor'
OBSERVER = 'science_reader_execution_observer'
ADMITTER = 'science_reader_executor_admitter'
BIN = Path('/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin')
BASE = ['-h', '127.0.0.1', '-p', '55431']
ENV = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
RPCS = {
    'worker_metadata_authority_state': (EXECUTOR, ()),
    'worker_metadata_execution_state': (EXECUTOR, ('p_job_id', 'p_claim_id')),
    'worker_claim_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_environment', 'p_executor_binding')),
    'worker_record_metadata_quiescence': (OBSERVER, ('p_attempt_id', 'p_receipt_id', 'p_resource', 'p_evidence_kind', 'p_facts')),
    'worker_finish_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_generation', 'p_attempt_id', 'p_body_sha256', 'p_result')),
    'worker_fail_metadata_stage_v2': (EXECUTOR, ('p_job_id', 'p_claim_id', 'p_generation', 'p_attempt_id', 'p_error_code', 'p_retryable')),
}


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def bounded(command, raw, *, timeout=5, maximum=65536, environment=None, cwd=None):
    """Bound actual pipe bytes; expose output only after exact subprocess exit."""
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             close_fds=True, env=environment or ENV, cwd=cwd)
    sent = 0
    output, errors = bytearray(), bytearray()
    failed = False
    deadline = time.monotonic() + timeout
    stop_deadline = None
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, mode, label in ((child.stdin, selectors.EVENT_WRITE, 'in'),
                                      (child.stdout, selectors.EVENT_READ, 'out'),
                                      (child.stderr, selectors.EVENT_READ, 'err')):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, mode, label)
            while selector.get_map() or child.poll() is None:
                now = time.monotonic()
                if stop_deadline is None and (now >= deadline or failed):
                    failed = True
                    if child.poll() is None:
                        child.kill()
                    stop_deadline = now + .5
                if stop_deadline is not None and now >= stop_deadline:
                    break
                for key, _ in selector.select(.02):
                    if key.data == 'in':
                        try:
                            sent += os.write(key.fileobj.fileno(), raw[sent:sent + 4096])
                        except BrokenPipeError:
                            sent = len(raw)
                        if sent == len(raw):
                            selector.unregister(key.fileobj); key.fileobj.close()
                    else:
                        part = os.read(key.fileobj.fileno(), 16384)
                        if not part:
                            selector.unregister(key.fileobj); key.fileobj.close(); continue
                        target, limit = (output, maximum) if key.data == 'out' else (errors, 4096)
                        if len(target) + len(part) > limit:
                            failed = True
                        elif not failed:
                            target.extend(part)
        code = child.wait(timeout=0)
        require(not failed and code == 0, 'subprocess_ack_unknown')
        return bytes(output)
    except (subprocess.TimeoutExpired, OSError):
        raise Refused('subprocess_ack_unknown') from None
    finally:
        if child.poll() is None:
            child.kill()
        try:
            child.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            # No subprocess result/commit acknowledgement is exposed.
            pass
        for pipe in (child.stdin, child.stdout, child.stderr):
            if not pipe.closed:
                pipe.close()


class LocalRPC:
    def __init__(self, database, *, faults=None):
        require(type(database) is str and re.fullmatch(r'science_reader_gateway_[0-9a-f]{12}', database), 'local_database_required')
        self.database = database
        self.faults = dict(faults or {})
        self.calls = []

    def call(self, name, parameters):
        require(name in RPCS and set(parameters) == set(RPCS[name][1]), 'invalid_fixture_rpc')
        role, fields = RPCS[name]
        require(len(canonical(parameters)) <= 49_152, 'rpc_input_limit')
        args = []
        for field in fields:
            value = parameters[field]
            if field == 'p_body_sha256':
                require(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), 'invalid_body_hash')
                expression = 'decode(' + quoted(value) + ",'hex')"
            elif type(value) in (dict, list):
                expression = quoted(canonical(value).decode()) + '::jsonb'
            elif value is None:
                expression = 'null'
            elif type(value) is bool:
                expression = 'true' if value else 'false'
            elif type(value) is int:
                expression = str(value)
            else:
                require(type(value) is str and len(value) <= 2048, 'invalid_fixture_rpc')
                expression = quoted(value)
            args.append(field + '=>' + expression)
        self.calls.append(name)
        require(len(self.calls) <= 16, 'rpc_action_limit')
        marker = 'committed_' + uuid.uuid4().hex
        sql = "begin;set local statement_timeout='2s';set local lock_timeout='1500ms';set local role " + role + ';select public.' + name + '(' + ','.join(args) + ');'
        fault = self.faults.pop(name, None)
        if fault == 'commit_failure':
            sql += 'insert into public.fixture_deferred_failure values(1);'
        sql += 'commit;select ' + quoted(marker) + ';'
        raw = bounded([str(BIN / 'psql'), *BASE, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', self.database], sql.encode())
        if fault == 'lost_ack':
            raise Refused('rpc_ack_unknown')
        lines = raw.decode('utf8').splitlines()
        require(len(lines) == 2 and lines[-1] == marker, 'rpc_ack_unknown')
        return decode(lines[0].encode())

"""Only a disposable loopback PostgreSQL fixture; no hosted connection option."""
import os
from pathlib import Path
import re
import uuid

from protocol import canonical, decode, require, Refused
from rpc_support import RPCS, EXECUTOR, OBSERVER, ADMITTER, quoted, bounded as bounded_process

BIN = Path('/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin')
BASE = ['-h', '127.0.0.1', '-p', '55431']
ENV = {key: value for key, value in os.environ.items() if not key.startswith('PG')}


def bounded(command, raw, *, timeout=5, maximum=65536, environment=None, cwd=None):
    return bounded_process(command, raw, timeout=timeout, maximum=maximum,
                           environment=ENV if environment is None else environment, cwd=cwd)


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

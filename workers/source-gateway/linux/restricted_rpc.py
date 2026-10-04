"""Capability-specific PostgreSQL caller for the isolated Linux fixture.

No owner login, hosted address, password argument or inherited PG configuration.
The descriptor is private local configuration, never an application request.
"""
import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import uuid

from rpc_support import RPCS, EXECUTOR, OBSERVER, ADMITTER, bounded, quoted
from protocol import canonical, decode, require
from frozen import executable_sha

PSQL = '/usr/lib/postgresql/17/bin/psql'
CAPABILITIES = {'executor': (EXECUTOR, 62403), 'observer': (OBSERVER, 0), 'admitter': (ADMITTER, 0)}
ADMISSION_RPCS = {
    'worker_install_metadata_executor_policy': ('p_id', 'p_canonical_policy'),
    'worker_activate_metadata_executor_v2': ('p_expected_revision', 'p_project_ref', 'p_policy_id',
        'p_host_id', 'p_boot_id', 'p_deployment_id', 'p_recovery_evidence_sha256'),
}


def private_file(path, owner, *, maximum, digest=None):
    """Reject redirected or nonprivate credential/configuration files."""
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'invalid_connection_file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == owner
                and before.st_nlink == 1 and not before.st_mode & 0o077
                and 0 < before.st_size <= maximum, 'invalid_connection_file')
        data = bytearray()
        while len(data) <= maximum:
            part = os.read(fd, min(4096, maximum + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        require(len(data) == before.st_size and len(data) <= maximum
                and (before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'connection_file_changed')
        if digest is not None:
            require(hashlib.sha256(data).hexdigest() == digest, 'connection_file_changed')
        return bytes(data)
    finally:
        os.close(fd)


def connection(value):
    require(type(value) is dict and set(value) == {'schema_version', 'mode', 'instance', 'capability',
            'port', 'database', 'login', 'psql_sha256', 'ca_sha256'}, 'invalid_connection_descriptor')
    require(type(value['schema_version']) is int and value['schema_version'] == 1
            and value['mode'] == 'linux_metadata_fixture_db'
            and type(value['instance']) is str and re.fullmatch(r'[0-9a-f]{12}', value['instance'])
            and type(value['capability']) is str and value['capability'] in CAPABILITIES
            and type(value['port']) is int
            and 1024 <= value['port'] <= 65535, 'invalid_connection_descriptor')
    instance, capability = value['instance'], value['capability']
    require(value['database'] == 'science_reader_linux_' + instance
            and value['login'] == 'ts_' + capability + '_' + instance
            and all(type(value[key]) is str and re.fullmatch(r'[0-9a-f]{64}', value[key])
                    for key in ('psql_sha256', 'ca_sha256')), 'invalid_connection_descriptor')
    base = Path('/var/lib/timestep-metadata-fixture-db') / instance / 'clients' / capability
    return dict(value), base


def arguments(name, parameters, capability):
    require(type(capability) is str and capability in CAPABILITIES
            and type(name) is str, 'rpc_capability_denied')
    if name == 'worker_metadata_authority_state' or (name == 'worker_metadata_execution_state'
            and capability in ('executor', 'observer')):
        fields = RPCS[name][1]
    elif capability == 'admitter':
        require(name in ADMISSION_RPCS, 'rpc_capability_denied')
        fields = ADMISSION_RPCS[name]
    else:
        require(name in RPCS and RPCS[name][0] == CAPABILITIES[capability][0], 'rpc_capability_denied')
        fields = RPCS[name][1]
    require(type(parameters) is dict and set(parameters) == set(fields)
            and len(canonical(parameters)) <= 49_152, 'invalid_rpc_parameters')
    result = []
    for field in fields:
        value = parameters[field]
        if field in ('p_body_sha256', 'p_recovery_evidence_sha256'):
            require(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), 'invalid_rpc_digest')
            expression = 'decode(' + quoted(value) + ",'hex')"
        elif type(value) in (dict, list):
            expression = quoted(canonical(value).decode()) + '::jsonb'
        elif value is None:
            expression = 'null'
        elif type(value) is bool:
            expression = 'true' if value else 'false'
        elif type(value) is int:
            require(-(2**63) <= value < 2**63, 'invalid_rpc_integer')
            expression = str(value)
        else:
            maximum = 8192 if field == 'p_canonical_policy' else 2048
            require(type(value) is str and len(value.encode('utf8')) <= maximum
                    and '\0' not in value, 'invalid_rpc_parameters')
            expression = quoted(value)
        result.append(field + '=>' + expression)
    return ','.join(result)


class RestrictedRPC:
    def __init__(self, descriptor):
        require(sys.platform == 'linux', 'linux_fixture_required')
        self.descriptor, self.base = connection(descriptor)
        self.capability = self.descriptor['capability']
        self.role, self.uid = CAPABILITIES[self.capability]
        self.calls = 0
        self._check_files()

    def _check_files(self):
        require(os.getresuid() == (self.uid,) * 3 and os.getresgid() == (self.uid,) * 3,
                'caller_identity_mismatch')
        require(self.base.resolve() == self.base, 'invalid_connection_directory')
        info = self.base.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == self.uid and not info.st_mode & 0o077,
                'invalid_connection_directory')
        require(executable_sha(PSQL) == self.descriptor['psql_sha256'], 'database_runtime_changed')
        private_file(self.base / 'ca.pem', self.uid, maximum=16_384, digest=self.descriptor['ca_sha256'])
        password = private_file(self.base / 'password', self.uid, maximum=1024)
        # One exact tuple only. No wildcard credentials or libpq escape syntax.
        prefix = ('127.0.0.1:' + str(self.descriptor['port']) + ':' + self.descriptor['database']
                  + ':' + self.descriptor['login'] + ':').encode()
        require(password.startswith(prefix) and re.fullmatch(rb'[0-9a-f]{64}\n', password[len(prefix):]),
                'invalid_password_file')

    def call(self, name, parameters):
        args = arguments(name, parameters, self.capability)
        require(self.calls < 16, 'rpc_action_limit')
        self.calls += 1
        self._check_files()
        login = self.descriptor['login']
        marker = 'committed_' + uuid.uuid4().hex
        # These checks precede the mutation in the same connection. No owner
        # session, pre-selected role, privileged login or plaintext connection
        # can reach the RPC. Only the post-COMMIT marker exposes its result.
        check = ("session_user=" + quoted(login) + " and current_user=session_user and "
                 "current_database()=" + quoted(self.descriptor['database']) + " and "
                 "current_setting('standard_conforming_strings')='on' and "
                 "exists(select 1 from pg_roles where rolname=session_user and rolcanlogin "
                 "and not rolsuper and not rolinherit and not rolcreaterole and not rolcreatedb "
                 "and not rolreplication and not rolbypassrls) and "
                 "(select count(*) from pg_auth_members where member=(select oid from pg_roles "
                 "where rolname=session_user))=1 and "
                 "exists(select 1 from pg_auth_members m join pg_roles r on r.oid=m.roleid "
                 "where m.member=(select oid from pg_roles where rolname=session_user) "
                 "and r.rolname=" + quoted(self.role) + " and not m.admin_option "
                 "and not m.inherit_option and m.set_option and not r.rolcanlogin "
                 "and not r.rolsuper and not r.rolinherit and not r.rolcreaterole and not r.rolcreatedb "
                 "and not r.rolreplication and not r.rolbypassrls "
                 "and not exists(select 1 from pg_auth_members where member=r.oid)) and "
                 "not exists(select 1 from pg_database d join pg_roles r on r.oid=d.datdba "
                 "where d.datname=current_database() and r.rolname in (session_user," + quoted(self.role) + ")) and "
                 "exists(select 1 from pg_stat_ssl where pid=pg_backend_pid() and ssl)")
        sql = ("begin;set local standard_conforming_strings=on;set local statement_timeout='2s';"
               "set local lock_timeout='1500ms';"
               "select 1/coalesce((" + check + ")::int,0);set local role " + self.role + ";"
               "select public." + name + '(' + args + ');commit;select ' + quoted(marker) + ';')
        env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'PGPASSFILE': str(self.base / 'password'),
               'PGSSLROOTCERT': str(self.base / 'ca.pem'), 'PGSSLMODE': 'verify-full',
               'PGSSLCERTMODE': 'disable',
               'PGGSSENCMODE': 'disable', 'PGCONNECT_TIMEOUT': '3', 'PGCLIENTENCODING': 'UTF8'}
        argv = [PSQL, '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1',
                '-p', str(self.descriptor['port']), '-U', login, '-d', self.descriptor['database']]
        raw = bounded(argv, sql.encode(), environment=env, cwd=self.base)
        # Only LF is a psql record boundary. Unicode metadata may legitimately
        # contain NEL/line/paragraph separators inside a JSON string.
        lines = raw.split(b'\n')
        require(len(lines) == 4 and lines[0] == b'1' and lines[2] == marker.encode()
                and lines[3] == b'', 'rpc_ack_unknown')
        return decode(lines[1])

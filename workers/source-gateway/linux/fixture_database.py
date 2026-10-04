"""Disposable, marked-Linux-only PostgreSQL 17 fixture; never a hosted client.

Setup is deliberately separate from the action runtime. The harness supplies a
reviewed source/tool hash manifest and has already provisioned locked UID/GID
62403. No account/package installation, activation, source request, repair or
automatic cleanup follows a failed operation. stdout contains finite evidence,
never SQL, passwords, server errors or private keys.

PG17 contracts: /docs/17/app-initdb.html, /sql-grant.html, /libpq-ssl.html.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import selectors
import shutil
import socket
import stat
import subprocess
import sys
import time

import owned_session

BASE = Path('/var/lib/timestep-metadata-fixture-db')
PG = Path('/usr/lib/postgresql/17/bin')
SYSTEMCTL = '/usr/bin/systemctl'
OPENSSL = '/usr/bin/openssl'
EXECUTOR_UID = 62403
CAPABILITIES = {'executor': 'science_reader_metadata_executor',
                'observer': 'science_reader_execution_observer',
                'admitter': 'science_reader_executor_admitter'}
MIGRATIONS = ('202610020001_catalog.sql', '202610020002_encrypted_sync.sql',
              '202610020003_metering_jobs.sql', '202610020004_support_admin.sql',
              '202610020005_processing_integrity.sql', '202610020006_key_rotation.sql',
              '202610020007_subscription_projection.sql', '202610020008_support_storage.sql',
              '202610030009_encrypted_history_limits.sql', '202610030010_library_import_contract.sql',
              '202610030011_acquisition.sql', '202610030012_metadata_execution.sql.pending')
SOURCES = ('tests/database/bootstrap.sql',) + tuple('supabase/migrations/' + x for x in MIGRATIONS)
TOOLS = tuple(str(PG / x) for x in ('initdb', 'postgres', 'psql')) + (OPENSSL, SYSTEMCTL)
ENV = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC'}
MARKER = {'schema_version': 1, 'mode': 'loopback_lifecycle_fixture',
          'source_network_enabled': False, 'hosted_admitted': False}
MAX_TREE_BYTES = 512 * 1024 * 1024


def require(ok, code):
    if not ok:
        raise ValueError(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf8')


def decode(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, 'duplicate_key')
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False, 'nonfinite_json'))


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def identity(instance, port=None):
    require(type(instance) is str and re.fullmatch('[0-9a-f]{12}', instance), 'invalid_instance')
    if port is not None:
        require(type(port) is int and 1024 <= port <= 65535, 'invalid_port')
    return BASE / instance, 'tsmetadata-db-' + instance + '.service', 'science_reader_linux_' + instance


def login(instance, capability):
    identity(instance)
    require(capability in CAPABILITIES, 'invalid_capability')
    return 'ts_' + capability + '_' + instance


def quote(value):
    require(type(value) is str and '\0' not in value, 'invalid_sql_literal')
    return "'" + value.replace("'", "''") + "'"


def read_file(path, maximum=65536, *, uid=0, private=False):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'redirected_fixture_file')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == uid and before.st_nlink == 1
                and not before.st_mode & (0o077 if private else 0o022)
                and 0 < before.st_size <= maximum, 'invalid_fixture_file')
        raw = bytearray()
        while len(raw) <= maximum:
            part = os.read(fd, min(65536, maximum + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(fd)
        require(len(raw) == before.st_size and (before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'fixture_file_changed')
        return bytes(raw)
    finally:
        os.close(fd)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def create_file(path, raw, *, uid=0, gid=0, mode=0o600):
    require(type(raw) is bytes and 0 < len(raw) <= 2_097_152, 'fixture_file_limit')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(raw):
            written = os.write(fd, raw[offset:offset + 65536])
            require(written > 0, 'fixture_write_failed')
            offset += written
        os.fsync(fd)
    finally:
        os.close(fd)
    sync_dir(Path(path).parent)


def directory(path, uid=0, gid=0, mode=0o700):
    path.mkdir(mode=mode)
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    sync_dir(path.parent)


def run(argv, raw=b'', *, uid=0, gid=0, env=None, timeout=30, maximum=131072, owned_tree=False):
    """Bound pipes and retire the helper before returning any acknowledgement.

    initdb alone owns a non-detaching helper tree. Its leader remains unreaped
    until the sole group signal; simple clients keep their existing direct wait.
    """
    require(type(owned_tree) is bool, 'invalid_helper_ownership')
    child, tree_enabled, code = None, False, None
    output, errors, sent = bytearray(), bytearray(), 0
    deadline = time.monotonic() + timeout
    try:
        if owned_tree:
            require(not owned_session.controller_children(), 'unexpected_fixture_children')
            owned_session.subreaper(True)
            tree_enabled = True
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 user=uid, group=gid, extra_groups=[], umask=0o077,
                                 close_fds=True, env=ENV if env is None else env, cwd='/',
                                 **({'start_new_session': True} if owned_tree else {}))

        def leader_exited():
            if owned_tree:
                return os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
            return child.poll() is not None

        with selectors.DefaultSelector() as selector:
            for stream, events, kind in ((child.stdin, selectors.EVENT_WRITE, 'in'),
                                         (child.stdout, selectors.EVENT_READ, 'out'),
                                         (child.stderr, selectors.EVENT_READ, 'err')):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, events, kind)
            while selector.get_map() or not leader_exited():
                require(time.monotonic() < deadline, 'fixture_helper_timeout')
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
                        destination, cap = (output, maximum) if key.data == 'out' else (errors, 16384)
                        require(len(destination) + len(part) <= cap, 'fixture_helper_output_limit')
                        destination.extend(part)
        if not owned_tree:
            code = child.wait(timeout=1)
    finally:
        try:
            if tree_enabled:
                if child is not None:
                    code = owned_session.retire_controller(child, grace=0)
                else:
                    require(not owned_session.controller_children(), 'fixture_helper_unresolved')
                # Keep subreaping active after any unresolved retirement.
                owned_session.subreaper(False)
            elif child is not None:
                if child.poll() is None:
                    child.kill()  # Simple helper/client only; the database is owned by systemd.
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    raise ValueError('fixture_helper_unresolved') from None
        finally:
            if child is not None:
                for stream in (child.stdin, child.stdout, child.stderr):
                    if not stream.closed:
                        stream.close()
    return code, bytes(output), bytes(errors)


def checked(argv, raw=b'', **kwargs):
    code, output, _ = run(argv, raw, **kwargs)
    require(code == 0, 'fixture_helper_failed')
    return output


def preflight(*, reserve=False):
    require(sys.platform == 'linux' and os.getresuid() == (0, 0, 0)
            and os.getresgid() == (0, 0, 0), 'linux_root_fixture_required')
    require(decode(read_file('/etc/timestep-source-lifecycle-fixture.json')) == MARKER, 'unmarked_host')
    require(Path('/proc/1/comm').read_bytes().strip() == b'systemd', 'systemd_required')
    account = pwd.getpwnam('postgres')
    executor = pwd.getpwuid(EXECUTOR_UID)
    require(account.pw_uid > 0 and account.pw_gid > 0 and executor.pw_gid == EXECUTOR_UID
            and executor.pw_shell in ('/usr/sbin/nologin', '/bin/false'), 'fixture_accounts_required')
    # The harness owns executor-account creation/locking and its later removal.
    if reserve:
        require(shutil.disk_usage('/var/lib').free >= 2 * 1024**3, 'fixture_disk_reserve')
    return account


def sources(source_root, manifest):
    require(type(manifest) is dict and set(manifest) == {'schema_version', 'mode', 'sources', 'tools'}
            and manifest['schema_version'] == 1 and manifest['mode'] == 'linux_metadata_fixture_inputs'
            and set(manifest['sources']) == set(SOURCES) and set(manifest['tools']) == set(TOOLS),
            'invalid_fixture_manifest')
    result = []
    for name in SOURCES:
        raw = read_file(Path(source_root) / name, 2_097_152)
        require(sha(raw) == manifest['sources'][name], 'migration_source_changed')
        result.append((name, raw))
    require(sum(len(raw) for _, raw in result) <= 2_097_152, 'migration_source_limit')
    for name in TOOLS:
        require(re.fullmatch('[0-9a-f]{64}', manifest['tools'][name]), 'invalid_tool_digest')
        # Executables may legitimately use an installed symlink (/usr/bin/openssl).
        path = Path(name).resolve()
        require(sha(read_file(path, 32 * 1024**2)) == manifest['tools'][name], 'fixture_tool_changed')
    return result


def configurations(instance, port):
    root, unit, database = identity(instance, port)
    hba = ('local all postgres peer\nlocal all all reject\n' + ''.join(
        'hostssl ' + database + ' ' + login(instance, cap) + ' 127.0.0.1/32 scram-sha-256\n'
        for cap in CAPABILITIES) + 'host all all 0.0.0.0/0 reject\nhost all all ::0/0 reject\n')
    config = {
        'listen_addresses': "'127.0.0.1'", 'port': str(port), 'timezone': "'UTC'",
        'cluster_name': quote('tsmetadata-db-' + instance),
        'unix_socket_directories': quote(str(root / 'socket')), 'unix_socket_permissions': '0700',
        'hba_file': quote(str(root / 'config/pg_hba.conf')), 'ident_file': quote(str(root / 'config/pg_ident.conf')),
        'ssl': 'on', 'ssl_cert_file': quote(str(root / 'server-tls/server.pem')),
        'ssl_key_file': quote(str(root / 'server-tls/server.key')), 'ssl_min_protocol_version': "'TLSv1.2'",
        'password_encryption': "'scram-sha-256'", 'fsync': 'on', 'full_page_writes': 'on',
        'synchronous_commit': 'on', 'max_connections': '12', 'shared_buffers': "'16MB'",
        'work_mem': "'1MB'", 'maintenance_work_mem': "'16MB'", 'temp_file_limit': "'16MB'",
        'min_wal_size': "'32MB'", 'max_wal_size': "'64MB'", 'archive_mode': 'off',
        'shared_preload_libraries': "''", 'logging_collector': 'off', 'log_statement': "'none'",
        'log_min_error_statement': "'panic'", 'log_connections': 'off', 'log_disconnections': 'off',
    }
    return { 'postgresql.conf': ''.join(k + '=' + v + '\n' for k, v in config.items()).encode(),
             'pg_hba.conf': hba.encode(), 'pg_ident.conf': b'# No peer remapping.\n'}


def unit_bytes(instance, postgres):
    root, _, _ = identity(instance)
    return (f'[Unit]\nDescription=Timestep disposable metadata database {instance}\n'
            f'ConditionPathExists=!{root}/stop.json\n'
            '[Service]\nType=simple\n'
            f'User={postgres.pw_uid}\nGroup={postgres.pw_gid}\n'
            f'ExecStart={PG}/postgres -D {root}/data -c config_file={root}/config/postgresql.conf\n'
            'Restart=no\nKillSignal=SIGINT\nKillMode=mixed\nTimeoutStopSec=30s\nSendSIGKILL=no\n'
            'UMask=0077\nNoNewPrivileges=yes\nCapabilityBoundingSet=\nProtectSystem=strict\n'
            'ProtectHome=yes\nPrivateTmp=yes\nPrivateDevices=yes\nRestrictNamespaces=yes\n'
            'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6\nIPAddressDeny=any\nIPAddressAllow=localhost\n'
            f'ReadWritePaths={root}/data {root}/socket\n'
            'TasksMax=64\nMemoryMax=256M\nLimitNOFILE=1024\nLimitCORE=0\n'
            'StandardOutput=null\nStandardError=null\n').encode()


def require_unit_absent(unit):
    # A file in /etc can override our /run unit. No existing definition, mask
    # or per-unit drop-in belongs to this newly named fixture.
    for directory in ('/etc/systemd/system', '/run/systemd/system', '/run/systemd/transient',
                      '/usr/lib/systemd/system', '/lib/systemd/system'):
        for name in (unit, unit + '.d'):
            path = Path(directory) / name
            require(not path.exists() and not path.is_symlink(), 'fixture_unit_collision')


def owner_sql(instance, sql, *, database=None, timeout=30):
    root, _, selected = identity(instance)
    record = decode(read_file(root / 'fixture.json', private=True))
    require(record['instance'] == instance and record['database'] == selected, 'fixture_identity_changed')
    identity(instance, record['port'])
    account = pwd.getpwnam('postgres')
    return checked([str(PG / 'psql'), '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1',
                    '-h', str(root / 'socket'), '-p', str(record['port']), '-U', 'postgres', '-d', database or selected],
                   sql.encode() if type(sql) is str else sql, uid=account.pw_uid, gid=account.pw_gid,
                   timeout=timeout)


def role_sql(instance, passwords, expires):
    _, _, database = identity(instance)
    require(set(passwords) == set(CAPABILITIES) and all(re.fullmatch('[0-9a-f]{64}', x)
            for x in passwords.values()), 'invalid_fixture_passwords')
    return ('begin;set local password_encryption=\'scram-sha-256\';' + ''.join(
        f'create role {login(instance, cap)} login noinherit nosuperuser nobypassrls nocreatedb '
        f'nocreaterole noreplication connection limit 2 password {quote(passwords[cap])} valid until {quote(expires)};'
        f'grant {role} to {login(instance, cap)} with inherit false, set true, admin false;'
        f'grant connect on database {database} to {login(instance, cap)};'
        for cap, role in CAPABILITIES.items()) + 'commit;')


def snapshot(instance):
    root, unit, database = identity(instance)
    value = decode(read_file(root / 'fixture.json', private=True))
    require(value['instance'] == instance and value['database'] == database and value['unit'] == unit
            and value['mode'] == 'linux_metadata_fixture_db' and value['source_network_enabled'] is False,
            'fixture_identity_changed')
    require(read_file('/run/systemd/system/' + unit) == unit_bytes(instance, pwd.getpwnam('postgres'))
            and sha(read_file('/run/systemd/system/' + unit)) == value['unit_sha256'], 'fixture_unit_changed')
    for name, raw in configurations(instance, value['port']).items():
        require(read_file(root / 'config' / name) == raw, 'fixture_configuration_changed')
    return root, value


def provision(instance, port, source_root, manifest):
    account = preflight(reserve=True)
    root, unit, database = identity(instance, port)
    inputs = sources(source_root, manifest)
    require(checked([str(PG / 'postgres'), '--version'], uid=account.pw_uid, gid=account.pw_gid)
            .startswith(b'postgres (PostgreSQL) 17.'), 'postgres_17_required')
    require(not root.exists() and not root.is_symlink(), 'fixture_already_exists')
    require_unit_absent(unit)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', port))  # No listener, source request or port reuse.
    if not BASE.exists():
        directory(BASE, mode=0o755)
    base_info = BASE.lstat()
    require(BASE.resolve() == BASE and stat.S_ISDIR(base_info.st_mode) and base_info.st_uid == 0
            and stat.S_IMODE(base_info.st_mode) == 0o755, 'fixture_base_changed')
    directory(root, mode=0o755)
    for name in ('setup', 'config', 'clients'):
        directory(root / name, mode=0o700 if name == 'setup' else 0o755)
    for name in ('data', 'socket', 'server-tls'):
        directory(root / name, account.pw_uid, account.pw_gid)
    unit_raw = unit_bytes(instance, account)
    value = {'schema_version': 1, 'mode': 'linux_metadata_fixture_db', 'instance': instance,
             'port': port, 'database': database, 'unit': unit, 'unit_sha256': sha(unit_raw),
             'postgres_uid': account.pw_uid, 'postgres_gid': account.pw_gid,
             'input_manifest_sha256': sha(canonical(manifest)), 'tools': manifest['tools'],
             'source_network_enabled': False, 'hosted_admitted': False}
    create_file(root / 'fixture.json', canonical(value))
    create_file(root / 'setup/inputs.json', canonical(manifest))
    checked([str(PG / 'initdb'), '-D', str(root / 'data'), '--username=postgres', '--encoding=UTF8',
             '--locale=C.UTF-8', '--data-checksums', '--auth-local=peer', '--auth-host=reject', '--no-clean'],
            uid=account.pw_uid, gid=account.pw_gid, timeout=60, owned_tree=True)
    for name, raw in configurations(instance, port).items():
        create_file(root / 'config' / name, raw, mode=0o644)
    setup, tls = root / 'setup', root / 'server-tls'
    checked([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=Timestep local fixture CA', '-keyout', str(setup / 'ca.key'),
             '-out', str(setup / 'ca.pem'), '-addext', 'basicConstraints=critical,CA:TRUE'])
    checked([OPENSSL, 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1',
             '-keyout', str(tls / 'server.key'), '-out', str(setup / 'server.csr')])
    create_file(setup / 'server.ext', b'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n')
    checked([OPENSSL, 'x509', '-req', '-in', str(setup / 'server.csr'), '-CA', str(setup / 'ca.pem'),
             '-CAkey', str(setup / 'ca.key'), '-set_serial', '1', '-days', '1',
             '-extfile', str(setup / 'server.ext'), '-out', str(tls / 'server.pem')])
    checked([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=Untrusted local fixture CA', '-keyout', str(setup / 'wrong-ca.key'),
             '-out', str(setup / 'wrong-ca.pem'), '-addext', 'basicConstraints=critical,CA:TRUE'])
    for path in tls.iterdir():
        os.chown(path, account.pw_uid, account.pw_gid); os.chmod(path, 0o600)
    create_file(Path('/run/systemd/system') / unit, unit_raw, mode=0o644)
    checked([SYSTEMCTL, 'daemon-reload'])
    state = unit_state(instance)
    require(state['ActiveState'] == 'inactive' and state['MainPID'] == '0'
            and state['Job'] == '', 'fixture_unit_not_fresh')
    checked([SYSTEMCTL, 'start', unit])
    # The only retries are read-only readiness probes; mutations are never retried.
    for attempt in range(8):
        try:
            require(owner_sql(instance, 'select 1;', database='postgres', timeout=3).strip() == b'1', 'database_not_ready')
            break
        except ValueError:
            if attempt == 7:
                raise
            time.sleep(.1)
    owner_sql(instance, f'create database {database} owner postgres template template0 encoding \'UTF8\' locale \'C.UTF-8\';', database='postgres')
    owner_sql(instance, f'revoke all on database {database} from public;alter database {database} set timezone=\'UTC\';')
    for name, raw in inputs:
        owner_sql(instance, raw, timeout=60)
    expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=2)).isoformat()
    passwords = {cap: secrets.token_hex(32) for cap in CAPABILITIES}
    owner_sql(instance, role_sql(instance, passwords, expires))
    ca = read_file(setup / 'ca.pem', 16384, private=True)
    descriptors = {}
    for cap in CAPABILITIES:
        uid = EXECUTOR_UID if cap == 'executor' else 0
        target = root / 'clients' / cap
        directory(target, uid, uid)
        descriptor = {'schema_version': 1, 'mode': 'linux_metadata_fixture_db', 'instance': instance,
                      'capability': cap, 'port': port, 'database': database, 'login': login(instance, cap),
                      'psql_sha256': manifest['tools'][str(PG / 'psql')], 'ca_sha256': sha(ca)}
        for filename, raw in (('ca.pem', ca), ('descriptor.json', canonical(descriptor)),
                              ('password', f'127.0.0.1:{port}:{database}:{login(instance, cap)}:{passwords[cap]}\n'.encode())):
            create_file(target / filename, raw, uid=uid, gid=uid)
        # Wrong CA is public but private to each caller for the negative check.
        create_file(target / 'wrong-ca.pem', read_file(setup / 'wrong-ca.pem', 16384, private=True), uid=uid, gid=uid)
        descriptors[cap] = descriptor
    del passwords
    settings = decode(owner_sql(instance, "select json_build_object('directory',current_setting('data_directory'),"
        "'checksums',current_setting('data_checksums'),'fsync',current_setting('fsync'),'full_page_writes',"
        "current_setting('full_page_writes'),'sync',current_setting('synchronous_commit'),'timezone',current_setting('timezone'),"
        "'listen',current_setting('listen_addresses'),'version',current_setting('server_version_num'),"
        "'system_identifier',(select system_identifier::text from pg_control_system()));"))
    require(settings['directory'] == str(root / 'data') and all(settings[x] == 'on' for x in ('checksums','fsync','full_page_writes','sync'))
            and settings['timezone'] == 'UTC' and settings['listen'] == '127.0.0.1'
            and re.fullmatch(r'17[0-9]{4}', settings['version']), 'database_settings_changed')
    create_file(root / 'setup/ready.json', canonical({'settings': settings, 'descriptors': descriptors}))
    return {'instance': instance, 'state': 'ready_for_permission_checks', 'descriptors': descriptors,
            'source_network_enabled': False, 'hosted_admitted': False}


def client_sql(instance, capability, sql, *, tls=True, wrong_ca=False, database=None):
    root, value = snapshot(instance)
    uid = EXECUTOR_UID if capability == 'executor' else 0
    target = root / 'clients' / capability
    env = dict(ENV, PGPASSFILE=str(target / 'password'), PGSSLROOTCERT=str(target / ('wrong-ca.pem' if wrong_ca else 'ca.pem')),
               PGSSLMODE='verify-full' if tls else 'disable', PGSSLCERTMODE='disable', PGGSSENCMODE='disable',
               PGCONNECT_TIMEOUT='2', PGCLIENTENCODING='UTF8')
    return run([str(PG / 'psql'), '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate',
                '-h', '127.0.0.1', '-p', str(value['port']), '-U', login(instance, capability),
                '-d', database or value['database']], sql.encode(), uid=uid, gid=uid, env=env, timeout=5)


def verify_caller_reply(raw, expected_login, expected_role):
    """Two observations from one psql transaction, with no stats privilege grant."""
    require(type(raw) is bytes and 0 < len(raw) <= 4096 and raw.endswith(b'\n'), 'caller_identity_or_tls')
    lines = raw.split(b'\n')
    require(len(lines) == 3 and lines[-1] == b'' and all(0 < len(line) <= 2048 for line in lines[:2]),
            'caller_identity_or_tls')
    try:
        before, after = (decode(line) for line in lines[:2])
    except (ValueError, UnicodeError, RecursionError):
        raise ValueError('caller_identity_or_tls') from None
    require(type(before) is dict and set(before) == {'login', 'role', 'backend_pid', 'tls'}
            and type(after) is dict and set(after) == {'login', 'role', 'backend_pid', 'restricted'},
            'caller_identity_or_tls')
    require(before['login'] == after['login'] == expected_login
            and before['role'] == expected_login and after['role'] == expected_role
            and type(before['backend_pid']) is int and 0 < before['backend_pid'] <= 2_147_483_647
            and type(after['backend_pid']) is int and after['backend_pid'] == before['backend_pid']
            and before['tls'] is True and after['restricted'] is True, 'caller_identity_or_tls')


def verify_callers(instance):
    preflight(); root, _ = snapshot(instance)
    proofs = []
    for cap, role in CAPABILITIES.items():
        restrictions = (
            "exists(select 1 from pg_roles where rolname=session_user and rolcanlogin "
            "and not rolsuper and not rolinherit and not rolcreaterole and not rolcreatedb "
            "and not rolreplication and not rolbypassrls and rolconnlimit=2 "
            "and rolvaliduntil>clock_timestamp()) and "
            "(select count(*) from pg_auth_members where member=(select oid from pg_roles "
            "where rolname=session_user))=1 and "
            "exists(select 1 from pg_auth_members m join pg_roles r on r.oid=m.roleid "
            "where m.member=(select oid from pg_roles where rolname=session_user) "
            "and r.rolname=" + quote(role) + " and not m.admin_option and not m.inherit_option "
            "and m.set_option and not r.rolcanlogin and not r.rolsuper and not r.rolinherit "
            "and not r.rolcreaterole and not r.rolcreatedb and not r.rolreplication "
            "and not r.rolbypassrls and not exists(select 1 from pg_auth_members where member=r.oid)) and "
            "not exists(select 1 from pg_database d join pg_roles r on r.oid=d.datdba "
            "where d.datname=current_database() and r.rolname in (session_user," + quote(role) + "))")
        sql = ("begin;select json_build_object('login',session_user,'role',current_user,'backend_pid',pg_backend_pid(),"
               "'tls',(select ssl from pg_stat_ssl where pid=pg_backend_pid()));"
               f"set local role {role};select json_build_object('login',session_user,'role',current_user,"
               "'backend_pid',pg_backend_pid(),'restricted'," + restrictions + ");commit;")
        code, raw, _ = client_sql(instance, cap, sql)
        require(code == 0, 'caller_identity_or_tls')
        verify_caller_reply(raw, login(instance, cap), role)
        forbidden = [f'set role {other}' for other in (*CAPABILITIES.values(), 'postgres', 'service_role') if other != role]
        forbidden += [f'set local role {role};select * from app_private.executor_authority',
                      f'set local role {role};create table public.fixture_must_not_exist(x int)',
                      f'alter database {identity(instance)[2]} owner to {login(instance, cap)}',
                      'select public.worker_metadata_authority_state()']
        for statement in forbidden:
            code, _, errors = client_sql(instance, cap, 'begin;' + statement + ';rollback;')
            require(code != 0 and re.search(rb'\b42501\b', errors), 'caller_forbidden_operation_not_denied')
        for options, marker in (({'tls': False}, b'pg_hba.conf rejects connection'),
                                ({'wrong_ca': True}, b'certificate verify failed'),
                                ({'database': 'postgres'}, b'pg_hba.conf rejects connection')):
            code, _, errors = client_sql(instance, cap, 'select 1;', **options)
            require(code != 0 and marker in errors, 'caller_tls_or_hba_denial_missing')
        proofs.append({'capability': cap, 'identity_tls_restrictions': True,
                       'permission_denials': len(forbidden), 'connection_denials': 3})
    create_file(root / 'setup/permissions.json', canonical({'checks': proofs}))
    return {'instance': instance, 'checks': proofs, 'source_network_enabled': False}


def retire_admitter(instance):
    preflight(); root, _ = snapshot(instance)
    require((root / 'setup/permissions.json').is_file(), 'permission_checks_required')
    name = login(instance, 'admitter')
    sql = ("begin;do $$begin if not exists(select 1 from app_private.executor_authority where enabled and not recovery_required "
           "and admitted_host_id is not null and admitted_boot_id is not null and admitted_deployment_id is not null) "
           "or exists(select 1 from pg_stat_activity where usename=" + quote(name) + ") then raise exception 'admission_not_ready';end if;end$$;"
           f'alter role {name} nologin password null;commit;')
    owner_sql(instance, sql)
    require(owner_sql(instance, f'select not rolcanlogin and rolpassword is null and not exists('
                      f'select 1 from pg_stat_activity where usename={quote(name)}) '
                      f'from pg_authid where rolname={quote(name)};').strip() == b't', 'admitter_retirement_unknown')
    path = root / 'clients/admitter/password'
    try:
        read_file(path, 1024, private=True)
    except FileNotFoundError:
        pass  # A prior positive proof may have removed it before checkpointing.
    else:
        path.unlink()
    sync_dir(path.parent)
    create_file(root / 'setup/admitter-retired.json', canonical({'instance': instance, 'admitter_login': name, 'retired': True}))
    return {'instance': instance, 'admitter_retired': True}


def unit_state(instance):
    _, unit, _ = identity(instance)
    fields = ('Id', 'LoadState', 'ActiveState', 'SubState', 'MainPID', 'Job', 'FragmentPath',
              'DropInPaths', 'Result', 'ExecMainStatus')
    raw = checked([SYSTEMCTL, 'show', unit, '--no-pager', '--property=' + ','.join(fields)])
    values = dict(line.split('=', 1) for line in raw.decode().splitlines())
    require(set(values) == set(fields) and values['Id'] == unit and values['LoadState'] == 'loaded'
            and values['FragmentPath'] == '/run/systemd/system/' + unit and values['DropInPaths'] == '',
            'fixture_unit_identity')
    return values


def stop_retaining(instance):
    preflight(); root, _ = snapshot(instance)
    fence = root / 'stop.json'
    expected = canonical({'instance': instance, 'kind': 'fixture_database_stop_v1'})
    if fence.exists():
        require(read_file(fence, private=True) == expected, 'fixture_stop_changed')
        sync_dir(root)
    else:
        create_file(fence, expected)
    unit_state(instance)
    checked([SYSTEMCTL, 'stop', '--no-block', identity(instance)[1]])
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        value = unit_state(instance)
        if value['ActiveState'] == 'inactive' and value['SubState'] == 'dead' and value['MainPID'] == '0' and value['Job'] == '':
            require(value['Result'] == 'success' and value['ExecMainStatus'] == '0', 'database_exit_uncertain')
            require(not (root / 'data/postmaster.pid').exists()
                    and not any((root / 'socket').iterdir()), 'database_socket_or_pid_retained')
            return {'instance': instance, 'state': 'stopped_retained'}
        time.sleep(.1)
    raise ValueError('database_stop_unresolved')


def clean_tree(root, postgres_uid):
    """Inventory before deletion. No symlinks, mounts, aliases or unknown owners."""
    device = root.lstat().st_dev
    count = total = 0
    stack = [root]
    fixed = {'': {'fixture.json', 'stop.json', 'setup', 'config', 'clients', 'data', 'socket', 'server-tls'},
             'setup': {'inputs.json', 'ready.json', 'permissions.json', 'admitter-retired.json', 'ca.key', 'ca.pem',
                       'wrong-ca.key', 'wrong-ca.pem', 'server.csr', 'server.ext'},
             'config': {'postgresql.conf', 'pg_hba.conf', 'pg_ident.conf'},
             'clients': set(CAPABILITIES), 'server-tls': {'server.key', 'server.pem'}, 'socket': set()}
    fixed.update({'clients/' + cap: {'ca.pem', 'wrong-ca.pem', 'descriptor.json', 'password'} for cap in CAPABILITIES})
    while stack:
        folder = stack.pop()
        relative = folder.relative_to(root).as_posix()
        if relative == '.': relative = ''
        require(len(folder.relative_to(root).parts) <= 16, 'fixture_tree_depth')
        with os.scandir(folder) as entries:
          for entry in entries:
            require(relative == 'data' or relative.startswith('data/') or relative in fixed and entry.name in fixed[relative], 'unknown_fixture_name')
            info = entry.stat(follow_symlinks=False)
            count += 1
            require(count <= 20000 and info.st_dev == device and info.st_uid in (0, postgres_uid, EXECUTOR_UID)
                    and (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))
                    and (stat.S_ISDIR(info.st_mode) or info.st_nlink == 1), 'unknown_fixture_tree')
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
            else:
                stack.append(Path(entry.path))
            require(total <= MAX_TREE_BYTES, 'fixture_tree_limit')
    return {'files_and_directories': count, 'bytes': total}


def no_source_actions():
    # This helper never decides whether a transport journal can be discarded.
    for name in ('attempts', 'witnesses', 'transport'):
        parent = Path('/var/lib/timestep-source') / name
        require(not parent.exists() or next(parent.iterdir(), None) is None, 'retained_source_action')
    require(not any(Path('/run/systemd/system').glob('tsmetadata[0-9a-f]*.*')), 'retained_source_unit')
    for path in Path('/proc').iterdir():
        if path.name.isdecimal():
            try:
                with (path / 'status').open('rb') as stream:
                    raw = stream.read(16385)
                require(len(raw) <= 16384, 'process_inventory_limit')
                match = re.search(rb'^Uid:\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)$', raw, re.M)
                require(match is not None and not any(int(x) in (62401, 62402, 62403) for x in match.groups()),
                        'source_runtime_still_present')
            except FileNotFoundError:
                continue


def cleanup(instance):
    preflight(); root, value = snapshot(instance)
    no_source_actions()
    roles = ','.join(quote(login(instance, x)) for x in CAPABILITIES)
    sql = ("begin;select singleton from app_private.executor_authority where singleton for update;"
           "do $$begin if exists(select 1 from app_private.execution_attempts e where "
           "app_private.execution_pending(e.id,'executor') or app_private.execution_pending(e.id,'arxiv_connection')) "
           "or exists(select 1 from app_private.acquisition_steps where kind='metadata_stage_v2' and result_sha256 is null) "
           "or exists(select 1 from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid()) "
           "then raise exception 'fixture_unsettled';end if;end$$;"
           "update app_private.executor_authority set enabled=false,recovery_required=true;" +
           ''.join(f'alter role {login(instance, cap)} nologin password null;' for cap in CAPABILITIES) + 'commit;')
    owner_sql(instance, sql)
    require(owner_sql(instance, f'select count(*) from pg_stat_activity where usename in ({roles});').strip() == b'0', 'fixture_sessions_retained')
    stop_retaining(instance)
    counts = clean_tree(root, value['postgres_uid'])
    # Only the now-stopped, exact private instance tree and pinned unit are removed.
    Path('/run/systemd/system', value['unit']).unlink()
    sync_dir('/run/systemd/system')
    checked([SYSTEMCTL, 'daemon-reload'])
    shutil.rmtree(root)
    sync_dir(BASE)
    return {'instance': instance, 'state': 'removed', **counts, 'source_network_enabled': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('provision', 'verify-callers', 'retire-admitter', 'stop-retaining', 'cleanup'))
    parser.add_argument('instance')
    parser.add_argument('--port', type=int)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'provision':
            require(args.port is not None and args.source_root is not None and args.manifest is not None, 'fixture_inputs_required')
            result = provision(args.instance, args.port, args.source_root, decode(read_file(args.manifest, private=True)))
        else:
            result = {'verify-callers': verify_callers, 'retire-admitter': retire_admitter,
                      'stop-retaining': stop_retaining, 'cleanup': cleanup}[args.operation](args.instance)
        print(canonical(result).decode())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        print('{"state":"refused_or_unknown","retained":true}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

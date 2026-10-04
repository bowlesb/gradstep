"""Offline-only recipe/guard tests. Never invokes PG, systemd, OpenSSL or a VM."""
import datetime
from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, call, patch

import fixture_database as db
import owned_session

INSTANCE = 'a123456789bc'
POSTGRES = types.SimpleNamespace(pw_uid=999, pw_gid=998)


def caller_rows(capability='executor'):
    login = db.login(INSTANCE, capability)
    return ({'login': login, 'role': login, 'backend_pid': 4242, 'tls': True},
            {'login': login, 'role': db.CAPABILITIES[capability], 'backend_pid': 4242, 'restricted': True})


def caller_bytes(rows):
    return b'\n'.join(db.canonical(row) for row in rows) + b'\n'


class RecipeTests(unittest.TestCase):
    def test_namespace_and_port_cannot_select_another_path(self):
        root, unit, name = db.identity(INSTANCE, 55432)
        self.assertEqual(str(root), '/var/lib/timestep-metadata-fixture-db/' + INSTANCE)
        self.assertEqual(unit, 'tsmetadata-db-' + INSTANCE + '.service')
        self.assertEqual(name, 'science_reader_linux_' + INSTANCE)
        for bad in ('../postgres', 'abc', INSTANCE.upper(), '', 'a' * 13):
            with self.subTest(bad=bad), self.assertRaises(ValueError): db.identity(bad)
        for port in (True, 0, 543, 65536, '5432'):
            with self.subTest(port=port), self.assertRaises(ValueError): db.identity(INSTANCE, port)

    def test_hba_has_three_exact_tls_logins_and_only_private_owner_peer(self):
        config = db.configurations(INSTANCE, 55432)
        lines = config['pg_hba.conf'].decode().splitlines()
        self.assertEqual(lines[:2], ['local all postgres peer', 'local all all reject'])
        self.assertEqual(len(lines), 7)
        for cap, line in zip(db.CAPABILITIES, lines[2:5]):
            self.assertEqual(line, 'hostssl science_reader_linux_' + INSTANCE + ' ' + db.login(INSTANCE, cap)
                             + ' 127.0.0.1/32 scram-sha-256')
        self.assertEqual(lines[-2:], ['host all all 0.0.0.0/0 reject', 'host all all ::0/0 reject'])
        text = config['postgresql.conf'].decode()
        for expected in ("listen_addresses='127.0.0.1'", 'port=55432', "timezone='UTC'", 'fsync=on',
                         'full_page_writes=on', 'synchronous_commit=on', 'unix_socket_permissions=0700',
                         "password_encryption='scram-sha-256'", "log_min_error_statement='panic'"):
            self.assertIn(expected + '\n', text)
        self.assertNotIn('include', text)

    def test_unit_has_exact_owner_data_and_start_fence_without_boot_enablement(self):
        raw = db.unit_bytes(INSTANCE, POSTGRES).decode()
        self.assertIn('User=999\nGroup=998\n', raw)
        self.assertIn('ConditionPathExists=!/var/lib/timestep-metadata-fixture-db/' + INSTANCE + '/stop.json', raw)
        self.assertIn('/usr/lib/postgresql/17/bin/postgres -D ', raw)
        self.assertIn('KillSignal=SIGINT\nKillMode=mixed\nTimeoutStopSec=30s\nSendSIGKILL=no', raw)
        self.assertIn('IPAddressDeny=any\nIPAddressAllow=localhost', raw)
        self.assertNotIn('[Install]', raw)
        self.assertNotIn('pg_ctl', raw)

    def test_unit_dropin_or_changed_fragment_is_not_a_fixture_unit(self):
        unit = db.identity(INSTANCE)[1]
        values = {'Id': unit, 'LoadState': 'loaded', 'ActiveState': 'inactive', 'SubState': 'dead',
                  'MainPID': '0', 'Job': '', 'FragmentPath': '/run/systemd/system/' + unit,
                  'DropInPaths': '', 'Result': 'success', 'ExecMainStatus': '0'}
        def output(*_):
            return ''.join(key + '=' + value + '\n' for key, value in values.items()).encode()
        with patch.object(db, 'checked', side_effect=output):
            self.assertEqual(db.unit_state(INSTANCE), values)
            values['DropInPaths'] = '/etc/systemd/system/service.d/override.conf'
            with self.assertRaisesRegex(ValueError, 'fixture_unit_identity'): db.unit_state(INSTANCE)
            values['DropInPaths'] = ''; values['FragmentPath'] = '/etc/systemd/system/' + unit
            with self.assertRaisesRegex(ValueError, 'fixture_unit_identity'): db.unit_state(INSTANCE)

    def test_existing_mask_or_dropin_blocks_new_fixture_definition(self):
        unit = db.identity(INSTANCE)[1]
        for occupied in ('/etc/systemd/system/' + unit, '/run/systemd/system/' + unit + '.d'):
            with self.subTest(occupied=occupied), patch.object(Path, 'exists', lambda path: str(path) == occupied), \
                 patch.object(Path, 'is_symlink', return_value=False):
                with self.assertRaisesRegex(ValueError, 'fixture_unit_collision'): db.require_unit_absent(unit)

    def test_three_logins_are_nonprivileged_and_have_one_set_only_membership(self):
        passwords = {cap: str(i) * 64 for i, cap in enumerate(db.CAPABILITIES, 1)}
        sql = db.role_sql(INSTANCE, passwords, '2026-10-05T00:00:00+00:00')
        self.assertEqual(sql.count('create role '), 3)
        self.assertEqual(sql.count('login noinherit nosuperuser nobypassrls nocreatedb nocreaterole noreplication'), 3)
        self.assertEqual(sql.count('with inherit false, set true, admin false'), 3)
        self.assertEqual(sql.count('grant connect on database science_reader_linux_' + INSTANCE), 3)
        self.assertNotIn('grant all', sql)
        passwords['executor'] = "x';create role injected;--"
        with self.assertRaises(ValueError): db.role_sql(INSTANCE, passwords, 'expiry')

    def test_source_manifest_binds_exact_bootstrap_and_001_through_012(self):
        self.assertEqual(len(db.SOURCES), 13)
        self.assertTrue(db.SOURCES[-1].endswith('202610030012_metadata_execution.sql.pending'))
        payloads = {str(Path('/captured') / x): ('source:' + x).encode() for x in db.SOURCES}
        payloads.update({str(Path(x).resolve()): ('tool:' + x).encode() for x in db.TOOLS})
        manifest = {'schema_version': 1, 'mode': 'linux_metadata_fixture_inputs',
                    'sources': {x: db.sha(payloads[str(Path('/captured') / x)]) for x in db.SOURCES},
                    'tools': {x: db.sha(payloads[str(Path(x).resolve())]) for x in db.TOOLS}}
        with patch.object(db, 'read_file', side_effect=lambda p, *a, **k: payloads[str(p)]), \
             patch.object(db, 'run') as run:
            result = db.sources(Path('/captured'), manifest)
            self.assertEqual([x[0] for x in result], list(db.SOURCES))
            run.assert_not_called()
            payloads[str(Path('/captured') / db.SOURCES[4])] += b'changed'
            with self.assertRaisesRegex(ValueError, 'migration_source_changed'): db.sources(Path('/captured'), manifest)
        manifest['sources']['extra.sql'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'invalid_fixture_manifest'): db.sources(Path('/captured'), manifest)

    def test_owner_bootstrap_uses_private_socket_exact_port_and_postgres_identity(self):
        value = {'instance': INSTANCE, 'database': db.identity(INSTANCE)[2], 'port': 55432}
        with patch.object(db, 'read_file', return_value=db.canonical(value)), \
             patch.object(db.pwd, 'getpwnam', return_value=POSTGRES), patch.object(db, 'checked', return_value=b'1') as run:
            self.assertEqual(db.owner_sql(INSTANCE, 'select 1;'), b'1')
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], '/usr/lib/postgresql/17/bin/psql')
        self.assertEqual(argv[argv.index('-h') + 1], str(db.identity(INSTANCE)[0] / 'socket'))
        self.assertEqual(argv[argv.index('-p') + 1], '55432')
        self.assertEqual(run.call_args.kwargs['uid'], 999)
        self.assertEqual(run.call_args.kwargs['gid'], 998)
        self.assertEqual(run.call_args.args[1], b'select 1;')

    def test_client_uses_actual_separate_uid_and_small_explicit_tls_environment(self):
        root = db.identity(INSTANCE)[0]
        value = {'port': 55432, 'database': db.identity(INSTANCE)[2]}
        with patch.object(db, 'snapshot', return_value=(root, value)), patch.object(db, 'run', return_value=(0,b'1',b'')) as run:
            db.client_sql(INSTANCE, 'executor', 'select 1;')
        args = run.call_args
        self.assertEqual(args.kwargs['uid'], 62403)
        self.assertEqual(args.kwargs['gid'], 62403)
        env = args.kwargs['env']
        self.assertEqual(env['PGSSLMODE'], 'verify-full')
        self.assertEqual(env['PGSSLCERTMODE'], 'disable')
        self.assertEqual(env['PGGSSENCMODE'], 'disable')
        self.assertTrue(env['PGPASSFILE'].endswith('/clients/executor/password'))
        self.assertNotIn('PGPASSWORD', env)
        self.assertNotIn('HOME', env)
        self.assertNotIn('PGSERVICE', env)
        self.assertNotIn('PGOPTIONS', env)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_file_identity_rejects_alias_symlink_and_change_and_does_not_overwrite(self):
        path = self.root / 'record'
        db.create_file(path, b'owned', uid=os.getuid(), gid=os.getgid())
        self.assertEqual(db.read_file(path, uid=os.getuid(), private=True), b'owned')
        with self.assertRaises(FileExistsError): db.create_file(path, b'changed', uid=os.getuid(), gid=os.getgid())
        link = self.root / 'link'; os.link(path, link)
        with self.assertRaisesRegex(ValueError, 'invalid_fixture_file'): db.read_file(path, uid=os.getuid())
        link.unlink(); link.symlink_to(path)
        with self.assertRaisesRegex(ValueError, 'redirected_fixture_file'): db.read_file(link, uid=os.getuid())

    def test_oversized_file_refuses_before_reading(self):
        path = self.root / 'large'; path.write_bytes(b'x' * 17); path.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'invalid_fixture_file'): db.read_file(path, 16, uid=os.getuid())

    def test_helper_has_finite_output_and_never_exposes_error_text(self):
        kwargs = {'uid': os.getuid(), 'gid': os.getgid(), 'timeout': 2}
        native = subprocess.Popen
        def current_user_child(*args, **options):
            # Host-only transport test, not Linux UID-drop evidence. Preserve
            # assertions on the requested boundary but avoid privileged setgroups.
            self.assertEqual(options.pop('user'), os.getuid())
            self.assertEqual(options.pop('group'), os.getgid())
            self.assertEqual(options.pop('extra_groups'), [])
            return native(*args, **options)
        with patch.object(db.subprocess, 'Popen', side_effect=current_user_child):
            self.assertEqual(db.run([sys.executable, '-I', '-S', '-B', '-c', 'print("ok")'], **kwargs), (0,b'ok\n',b''))
            with self.assertRaisesRegex(ValueError, '^fixture_helper_output_limit$'):
                db.run([sys.executable, '-I', '-S', '-B', '-c', 'print("x"*1024)'], maximum=32, **kwargs)
            with self.assertRaisesRegex(ValueError, '^fixture_helper_failed$'):
                db.checked([sys.executable, '-I', '-S', '-B', '-c', 'import sys;sys.stderr.write("do not expose");sys.exit(2)'], **kwargs)

    def test_foreign_action_blocks_cleanup_before_any_sql_or_unit_mutation(self):
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'no_source_actions', side_effect=ValueError('retained_source_action')), \
             patch.object(db, 'owner_sql') as sql, patch.object(db, 'checked') as command:
            with self.assertRaisesRegex(ValueError, 'retained_source_action'): db.cleanup(INSTANCE)
            sql.assert_not_called(); command.assert_not_called()

    def test_observed_role_drift_cannot_publish_permission_success(self):
        rows = caller_rows()
        rows[1]['restricted'] = False
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'client_sql', return_value=(0, caller_bytes(rows), b'')) as sql, \
             patch.object(db, 'create_file') as publish:
            with self.assertRaisesRegex(ValueError, 'caller_identity_or_tls'): db.verify_callers(INSTANCE)
            self.assertEqual(sql.call_count, 1); publish.assert_not_called()
            query = sql.call_args.args[2]
            for expected in ('not rolsuper', 'not rolinherit', 'rolconnlimit=2', 'not m.admin_option',
                             'not m.inherit_option', 'm.set_option', 'pg_auth_members', 'pg_database'):
                self.assertIn(expected, query)

    def test_tls_before_role_probe_keeps_same_transaction_and_all_denials(self):
        probes = []
        def reply(instance, capability, query, **options):
            self.assertEqual(instance, INSTANCE)
            if query.startswith('begin;select json_build_object'):
                probes.append(query)
                return 0, caller_bytes(caller_rows(capability)), b''
            if options:
                marker = b'certificate verify failed' if options.get('wrong_ca') else b'pg_hba.conf rejects connection'
                return 2, b'', marker
            return 3, b'', b'42501'
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'client_sql', side_effect=reply), patch.object(db, 'create_file') as publish:
            result = db.verify_callers(INSTANCE)
        self.assertEqual(len(probes), 3)
        self.assertEqual(len(result['checks']), 3)
        self.assertTrue(all(row['identity_tls_restrictions'] is True and row['permission_denials'] == 8
                            and row['connection_denials'] == 3 for row in result['checks']))
        for query, role in zip(probes, db.CAPABILITIES.values()):
            before, after = query.split('set local role ' + role + ';')
            self.assertTrue(before.startswith('begin;'))
            self.assertEqual(before.count('pg_stat_ssl'), 1)
            self.assertNotIn('pg_stat_ssl', after)
            self.assertEqual(before.count('pg_backend_pid()'), 2)
            self.assertEqual(after.count('pg_backend_pid()'), 1)
            self.assertIn("'restricted'", after)
            self.assertTrue(after.endswith(';commit;'))
        publish.assert_called_once_with(self.root / 'setup/permissions.json', db.canonical({'checks': result['checks']}))

    def test_missing_or_wrong_tls_session_and_malformed_lines_never_publish(self):
        cases = []
        for field, value in (('tls', None), ('tls', False), ('tls', 1), ('login', 'other'),
                             ('role', db.CAPABILITIES['executor']), ('backend_pid', True)):
            rows = caller_rows(); rows[0][field] = value
            cases.append(caller_bytes(rows))
        for field, value in (('login', 'other'), ('role', 'postgres'), ('backend_pid', 4243),
                             ('backend_pid', True), ('restricted', 1)):
            rows = caller_rows(); rows[1][field] = value
            cases.append(caller_bytes(rows))
        valid = caller_bytes(caller_rows())
        cases.extend((valid[:-1], valid + b'\n', valid + b'{}\n', b'{}\n', b'null\nnull\n',
                      b'x' * 4097, b'{}' + b' ' * 2047 + b'\n{}\n', b'{broken}\n{}\n',
                      b'{"tls":true,"tls":true}\n{}\n'))
        for raw in cases:
            with self.subTest(raw_bytes=len(raw)), patch.object(db, 'preflight'), \
                 patch.object(db, 'snapshot', return_value=(self.root, {})), \
                 patch.object(db, 'client_sql', return_value=(0, raw, b'')) as sql, \
                 patch.object(db, 'create_file') as publish:
                with self.assertRaisesRegex(ValueError, '^caller_identity_or_tls$'):
                    db.verify_callers(INSTANCE)
                self.assertEqual(sql.call_count, 1)
                publish.assert_not_called()
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'client_sql', return_value=(1, valid, b'')), patch.object(db, 'create_file') as publish:
            with self.assertRaisesRegex(ValueError, '^caller_identity_or_tls$'):
                db.verify_callers(INSTANCE)
            publish.assert_not_called()

    def test_unsettled_database_blocks_stop_and_delete(self):
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'no_source_actions'), patch.object(db, 'owner_sql', side_effect=ValueError('fixture_helper_failed')) as sql, \
             patch.object(db, 'stop_retaining') as stop, patch.object(db.shutil, 'rmtree') as remove:
            with self.assertRaises(ValueError): db.cleanup(INSTANCE)
            self.assertIn("execution_pending(e.id,'executor')", sql.call_args.args[1])
            self.assertIn("kind='metadata_stage_v2' and result_sha256 is null", sql.call_args.args[1])
            self.assertIn("backend_type='client backend'", sql.call_args.args[1])
            stop.assert_not_called(); remove.assert_not_called()

    def test_admitter_unknown_outcome_retains_private_credential(self):
        private = self.root / 'clients/admitter'; private.mkdir(parents=True)
        (private / 'password').write_bytes(b'fixture password')
        (self.root / 'setup').mkdir(); (self.root / 'setup/permissions.json').write_bytes(b'{}')
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'owner_sql', side_effect=[b'', b'f']) as sql:
            with self.assertRaisesRegex(ValueError, 'admitter_retirement_unknown'): db.retire_admitter(INSTANCE)
        self.assertTrue((private / 'password').exists())
        self.assertIn('nologin password null', sql.call_args_list[0].args[1])
        self.assertIn('pg_stat_activity', sql.call_args_list[1].args[1])

    def test_admitter_retry_after_password_unlink_reproves_before_checkpoint(self):
        private = self.root / 'clients/admitter'; private.mkdir(parents=True)
        password = private / 'password'
        password.write_bytes(b'fixture password'); password.chmod(0o600)
        (self.root / 'setup').mkdir(); (self.root / 'setup/permissions.json').write_bytes(b'{}')
        original = db.read_file
        def local_read(path, maximum, **options):
            return original(path, maximum, uid=os.getuid(), **options)
        with patch.object(db, 'preflight'), patch.object(db, 'snapshot', return_value=(self.root, {})), \
             patch.object(db, 'owner_sql', side_effect=[b'', b't', b'', b't']) as sql, \
             patch.object(db, 'read_file', side_effect=local_read) as read, \
             patch.object(db, 'create_file', side_effect=[OSError('checkpoint interrupted'), None]) as checkpoint:
            with self.assertRaisesRegex(OSError, 'checkpoint interrupted'):
                db.retire_admitter(INSTANCE)
            self.assertFalse(password.exists())
            self.assertEqual(db.retire_admitter(INSTANCE), {'instance': INSTANCE, 'admitter_retired': True})
        self.assertEqual(sql.call_count, 4)
        self.assertEqual(sql.call_args_list[1], sql.call_args_list[3])
        self.assertEqual(read.call_args_list, [call(password, 1024, private=True)] * 2)
        self.assertEqual(checkpoint.call_args_list[0], checkpoint.call_args_list[1])

    def test_cleanup_tree_refuses_unknown_file_or_link_without_deleting(self):
        path = self.root / 'notes'; path.write_text('unrelated')
        with self.assertRaisesRegex(ValueError, 'unknown_fixture_name'): db.clean_tree(self.root, os.getuid())
        self.assertTrue(path.exists()); path.unlink()
        data = self.root / 'data'; data.mkdir(); (data / 'external').symlink_to('/tmp')
        with self.assertRaisesRegex(ValueError, 'unknown_fixture_tree'): db.clean_tree(self.root, os.getuid())
        self.assertTrue((data / 'external').is_symlink())


class OwnedHelperTests(unittest.TestCase):
    """Portable ownership schedules; no kernel subreaping or process launch."""
    def setUp(self):
        self.scope = ExitStack()
        self.addCleanup(self.scope.close)
        self.child = types.SimpleNamespace(pid=4242, returncode=None)
        for name in ('stdin', 'stdout', 'stderr'):
            pipe = Mock(closed=False)
            pipe.fileno.return_value = 50
            pipe.close.side_effect = lambda pipe=pipe: setattr(pipe, 'closed', True)
            setattr(self.child, name, pipe)
        for name in ('poll', 'wait', 'kill'):
            setattr(self.child, name, Mock(side_effect=AssertionError('must not reap or signal direct helper')))
        def replace(owner, name, **options):
            return self.scope.enter_context(patch.object(owner, name, **options))
        self.children = replace(owned_session, 'controller_children', return_value=[])
        self.reaper = replace(owned_session, 'subreaper')
        self.spawn = replace(db.subprocess, 'Popen', return_value=self.child)
        self.selector = replace(db.selectors, 'DefaultSelector').return_value.__enter__.return_value
        self.selector.get_map.return_value = {}
        replace(db.os, 'set_blocking')
        self.waitid = replace(db.os, 'waitid', return_value=object(), create=True)
        for name, value in (('P_PID', 1), ('WNOWAIT', 0x1000000), ('WEXITED', 4)):
            replace(db.os, name, new=value, create=True)
        replace(owned_session.os, 'getpgid', return_value=4242)
        replace(owned_session.os, 'getsid', return_value=4242)
        self.kill = replace(owned_session.os, 'killpg')
        self.waitpid = replace(owned_session.os, 'waitpid', side_effect=[(4242, 0), ChildProcessError()])
        self.clock = replace(owned_session, 'clock_ns', return_value=0)

    def test_owned_success_observes_without_reaping_then_signals_and_joins(self):
        self.assertEqual(db.run(['fixture'], owned_tree=True), (0, b'', b''))
        self.assertTrue(self.spawn.call_args.kwargs['start_new_session'])
        self.assertEqual(self.waitid.call_count, 2)
        for observed in self.waitid.call_args_list:
            self.assertEqual(observed, call(db.os.P_PID, 4242, db.os.WEXITED | db.os.WNOHANG | db.os.WNOWAIT))
        self.kill.assert_called_once_with(4242, owned_session.signal.SIGKILL)
        self.assertEqual(self.reaper.call_args_list, [call(True), call(False)])
        self.assertEqual(self.child.returncode, 0)
        for name in ('poll', 'wait', 'kill'):
            getattr(self.child, name).assert_not_called()

    def test_timeout_keeps_unknown_tree_and_never_signals_after_anchor_loss(self):
        self.selector.get_map.return_value = {'open': True}
        self.children.side_effect = [[], [4242], [4243]]
        self.waitpid.side_effect = [(4242, 9), (0, 0)]
        self.clock.side_effect = [0, 0, 0, 3_000_000_000]
        with self.assertRaisesRegex(ValueError, 'controller_children_unresolved'):
            db.run(['fixture'], timeout=0, owned_tree=True)
        self.assertEqual(self.child.returncode, -9)
        with self.assertRaisesRegex(ValueError, 'anchor_already_reaped'):
            owned_session.retire_controller(self.child, grace=0)
        self.kill.assert_called_once_with(4242, owned_session.signal.SIGKILL)
        self.reaper.assert_called_once_with(True)
        for name in ('poll', 'wait', 'kill'):
            getattr(self.child, name).assert_not_called()
        self.assertTrue(all(getattr(self.child, name).closed for name in ('stdin', 'stdout', 'stderr')))

    def test_existing_child_refuses_before_spawn_or_subreaper_change(self):
        self.children.return_value = [8888]
        with self.assertRaisesRegex(ValueError, 'unexpected_fixture_children'):
            db.run(['fixture'], owned_tree=True)
        self.spawn.assert_not_called(); self.reaper.assert_not_called(); self.kill.assert_not_called()

    def test_spawn_failure_with_unknown_child_does_not_clear_subreaping(self):
        self.children.side_effect = [[], [8888]]
        self.spawn.side_effect = OSError('spawn failed')
        with self.assertRaisesRegex(ValueError, 'fixture_helper_unresolved'):
            db.run(['fixture'], owned_tree=True)
        self.reaper.assert_called_once_with(True)
        self.kill.assert_not_called(); self.waitpid.assert_not_called()


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0
                     and os.environ.get('TIMESTEP_LINUX_FIXTURE_RUN') == '1',
                     'requires opt-in as root inside the isolated Linux guest')
class OwnedHelperLinuxTests(unittest.TestCase):
    def test_timeout_retires_helper_and_live_grandchild(self):
        script = '''
import os,sys,tempfile
from pathlib import Path
import fixture_database as db
import owned_session
with tempfile.TemporaryDirectory() as temporary:
    pidfile=Path(temporary)/'grandchild'
    program="import os,sys,time\\nfrom pathlib import Path\\npid=os.fork()\\nif pid==0: time.sleep(4); os._exit(0)\\nPath(sys.argv[1]).write_text(str(pid))\\ntime.sleep(4)"
    try:
        db.run([sys.executable,'-I','-S','-B','-c',program,str(pidfile)],timeout=.3,owned_tree=True)
    except ValueError as error:
        assert str(error)=='fixture_helper_timeout'
    else:
        raise AssertionError('missing timeout')
    grand=int(pidfile.read_text())
    assert not owned_session.controller_children()
    try: os.kill(grand,0)
    except ProcessLookupError: pass
    else: raise AssertionError('live grandchild')
print('retired')
'''
        result = subprocess.run([sys.executable, '-B', '-c', script], capture_output=True, timeout=8,
            env={'PATH': '/usr/bin:/bin', 'PYTHONPATH': str(Path(__file__).parent)})
        self.assertEqual(result.returncode, 0, result.stderr[:2048])
        self.assertEqual(result.stdout, b'retired\n')


if __name__ == '__main__':
    unittest.main()

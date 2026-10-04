"""Offline caller contract tests; no database, credentials or source requests."""
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

from protocol import Refused, canonical, digest
from rpc_support import RPCS, bounded
import restricted_rpc as rpc


def descriptor(capability='executor'):
    instance = '0123456789ab'
    return {'schema_version': 1, 'mode': 'linux_metadata_fixture_db', 'instance': instance,
            'capability': capability, 'port': 55432, 'database': 'science_reader_linux_' + instance,
            'login': 'ts_' + capability + '_' + instance, 'psql_sha256': '1' * 64, 'ca_sha256': '2' * 64}


class CallerTests(unittest.TestCase):
    def caller(self, capability='executor'):
        # This permits testing the SQL/protocol on macOS. It is not evidence
        # for the real Linux identity, TLS, ACL or credential-file gates.
        with patch.object(rpc.sys, 'platform', 'linux'), patch.object(rpc.RestrictedRPC, '_check_files'):
            result = rpc.RestrictedRPC(descriptor(capability))
        return result

    def invoke(self, output, *, capability='executor', name='worker_metadata_authority_state', parameters=None):
        caller = self.caller(capability)

        def transport(command, raw, **kwargs):
            marker = re.search(rb"commit;select '(committed_[0-9a-f]{32})';$", raw)[1]
            return output(marker)

        with patch.object(caller, '_check_files'), patch.object(rpc, 'bounded', side_effect=transport) as run:
            value = caller.call(name, parameters or {})
        return value, run

    def test_descriptor_cannot_select_host_path_runtime_or_other_login(self):
        for capability in rpc.CAPABILITIES:
            value, path = rpc.connection(descriptor(capability))
            self.assertEqual(path, Path('/var/lib/timestep-metadata-fixture-db/0123456789ab/clients') / capability)
            self.assertEqual(value['capability'], capability)
        changes = ({'host': 'example.com'}, {'capability': []}, {'capability': 'owner'}, {'port': True},
                   {'port': 543}, {'instance': '../bad'}, {'database': 'postgres'}, {'login': 'postgres'},
                   {'psql_sha256': 'A' * 64}, {'schema_version': True}, {'mode': 'hosted'})
        for change in changes:
            with self.subTest(change=change), self.assertRaises(Refused):
                rpc.connection(dict(descriptor(), **change))

    def test_each_capability_has_only_its_finite_rpc_set(self):
        expected = {
            'executor': {name for name, (role, _) in RPCS.items() if role == rpc.EXECUTOR},
            'observer': {'worker_metadata_authority_state', 'worker_metadata_execution_state',
                         'worker_record_metadata_quiescence'},
            'admitter': {'worker_metadata_authority_state', *rpc.ADMISSION_RPCS},
        }
        for capability, allowed in expected.items():
            for name in {*RPCS, *rpc.ADMISSION_RPCS, 'worker_prepare_original', 'arbitrary_sql'}:
                fields = (rpc.ADMISSION_RPCS.get(name) or RPCS.get(name, (None, ()))[1])
                parameters = {field: ('0' * 64 if field.endswith('_sha256') else None) for field in fields}
                with self.subTest(capability=capability, name=name):
                    if name in allowed:
                        rpc.arguments(name, parameters, capability)
                    else:
                        with self.assertRaises(Refused):
                            rpc.arguments(name, parameters, capability)

    def test_wrong_parameter_set_and_oversize_arguments_refuse_before_call(self):
        for parameters in ({'extra': 1}, [], None):
            with self.subTest(parameters=parameters), self.assertRaises(Refused):
                rpc.arguments('worker_metadata_authority_state', parameters, 'executor')
        fields = RPCS['worker_finish_metadata_stage_v2'][1]
        parameters = dict.fromkeys(fields)
        parameters.update(p_body_sha256='a' * 64, p_result={'title': 'x' * 49_152})
        with self.assertRaises(Refused):
            rpc.arguments('worker_finish_metadata_stage_v2', parameters, 'executor')
        for capability in ([], 'owner'):
            with self.assertRaises(Refused):
                rpc.arguments('worker_metadata_authority_state', {}, capability)

    def test_policy_canonical_text_is_preserved_not_reencoded_as_jsonb(self):
        policy = canonical({'label': "x'\\y", 'sha256': '0' * 64}).decode()
        sql = rpc.arguments('worker_install_metadata_executor_policy',
                            {'p_id': '00000000-0000-0000-0000-000000000001',
                             'p_canonical_policy': policy}, 'admitter')
        self.assertIn('p_canonical_policy=>' + rpc.quoted(policy), sql)
        self.assertNotIn('::jsonb', sql)
        with self.assertRaises(Refused):
            rpc.arguments('worker_install_metadata_executor_policy',
                          {'p_id': None, 'p_canonical_policy': 'é' * 4097}, 'admitter')

    def test_valid_json_unicode_separators_do_not_destroy_commit_ack(self):
        expected = {'title': 'A\u0085B\u2028C\u2029D', 'equation': "\\alpha + 'beta'", 'lines': 'one\ntwo'}
        value, _ = self.invoke(lambda marker: b'1\n' + canonical(expected) + b'\n' + marker + b'\n')
        self.assertEqual(value, expected)

    def test_ambiguous_or_malformed_ack_never_returns_selected_json(self):
        for raw in (b'1\n{}\n', b'1\n{}\nwrong\n', b'1\n{}\n%s', b'0\n{}\n%s\n',
                    b'1\n{}\n%s\nextra\n', b'1\n{"x":1,"x":2}\n%s\n', b'1\n\xff\n%s\n'):
            with self.subTest(raw=raw), self.assertRaises(Refused):
                self.invoke(lambda marker: raw.replace(b'%s', marker))

    def test_connection_environment_is_explicit_and_cannot_use_default_certificate(self):
        with patch.dict(os.environ, {'PGHOST': 'not-used.invalid', 'PGOPTIONS': 'not-used',
                                     'PGSERVICE': 'not-used', 'PGPASSWORD': 'test-sentinel'}):
            _, run = self.invoke(lambda marker: b'1\n{}\n' + marker + b'\n')
        argv, query = run.call_args.args
        env = run.call_args.kwargs['environment']
        self.assertEqual(argv[0], rpc.PSQL)
        self.assertEqual(argv[argv.index('-h') + 1], '127.0.0.1')
        self.assertIn('-X', argv)
        self.assertIn('-w', argv)
        self.assertEqual(env['PGSSLMODE'], 'verify-full')
        self.assertEqual(env['PGSSLCERTMODE'], 'disable')
        self.assertFalse({'PGHOST', 'PGOPTIONS', 'PGSERVICE', 'PGPASSWORD', 'HOME'} & set(env))
        self.assertNotIn(b'test-sentinel', query)
        self.assertNotIn('test-sentinel', ' '.join(argv))
        self.assertLess(query.index(b'set local standard_conforming_strings=on'), query.index(b'session_user='))
        self.assertLess(query.index(b'select 1/coalesce'), query.index(b'set local role'))
        self.assertLess(query.index(b'set local role'), query.index(b'select public.'))

    def test_denied_call_never_starts_process_and_failed_call_is_not_retried(self):
        caller = self.caller('observer')
        with patch.object(caller, '_check_files'), patch.object(rpc, 'bounded') as run:
            with self.assertRaises(Refused):
                caller.call('worker_claim_metadata_stage_v2', {})
            run.assert_not_called()
            self.assertEqual(caller.calls, 0)
            run.side_effect = Refused('subprocess_ack_unknown')
            with self.assertRaises(Refused):
                caller.call('worker_metadata_authority_state', {})
            self.assertEqual(run.call_count, 1)
            self.assertEqual(caller.calls, 1)

    def test_action_call_limit_includes_ambiguous_calls(self):
        caller = self.caller()
        with patch.object(caller, '_check_files'), patch.object(rpc, 'bounded', side_effect=Refused('subprocess_ack_unknown')) as run:
            for _ in range(17):
                with self.assertRaises(Refused):
                    caller.call('worker_metadata_authority_state', {})
            self.assertEqual(run.call_count, 16)


class PrivateFileTests(unittest.TestCase):
    def test_private_bytes_and_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / 'credential'
            path.write_bytes(b'fixture-data')
            path.chmod(0o600)
            self.assertEqual(rpc.private_file(path, os.getuid(), maximum=12, digest=digest(b'fixture-data')), b'fixture-data')
            with self.assertRaises(Refused):
                rpc.private_file(path, os.getuid(), maximum=12, digest='0' * 64)

    def test_links_public_permissions_owner_and_size_are_rejected(self):
        for mode in ('symlink', 'hardlink', 'public', 'owner', 'size', 'empty', 'fifo'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary).resolve() / 'credential'
                if mode == 'fifo':
                    os.mkfifo(path, 0o600)
                else:
                    path.write_bytes(b'' if mode == 'empty' else b'fixture-data')
                    path.chmod(0o600)
                if mode == 'symlink':
                    alias = path.with_name('alias')
                    alias.symlink_to(path)
                    path = alias
                elif mode == 'hardlink':
                    os.link(path, path.with_name('alias'))
                elif mode == 'public':
                    path.chmod(0o644)
                with self.assertRaises(Refused):
                    rpc.private_file(path, os.getuid() + (mode == 'owner'), maximum=1 if mode == 'size' else 1024)


class PipeTests(unittest.TestCase):
    def run_child(self, program, **options):
        return bounded([sys.executable, '-I', '-S', '-c', program], b'', environment={'LC_ALL': 'C'}, **options)

    def test_nonzero_exit_discards_even_complete_looking_output(self):
        with self.assertRaises(Refused):
            self.run_child("import sys;print('1\\n{}\\ncommitted_fake',flush=True);sys.exit(1)")

    def test_success_waits_for_complete_process_exit(self):
        self.assertEqual(self.run_child("print('result')"), b'result\n')

    def test_output_error_and_time_bounds_discard_output(self):
        cases = (("print('x'*1024)", {'maximum': 32}),
                 ("import sys;sys.stderr.write('x'*5000);print('result')", {}),
                 ("import time;print('result',flush=True);time.sleep(2)", {'timeout': .1}))
        for program, options in cases:
            with self.subTest(program=program), self.assertRaises(Refused):
                self.run_child(program, **options)


if __name__ == '__main__':
    unittest.main()

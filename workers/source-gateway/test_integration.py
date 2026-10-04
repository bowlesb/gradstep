"""Real disposable PG001--012 and loopback TLS; never hosted/source traffic."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

import frozen
import local_postgres as pg
from protocol import canonical, decode, digest, clock_ns
import test_gateway as tls_fixtures

ROOT = Path(__file__).resolve().parents[2]
SOURCE = '2403.81001'


def atom():
    return ('<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/' + SOURCE +
            'v1</id><title>Local fixture paper</title><published>2024-03-01T00:00:00Z</published>'
            '<updated>2024-03-02T00:00:00Z</updated><author><name>Ada Example</name></author>'
            '<summary>Fixture only.</summary><category term="cs.LG"/></entry></feed>').encode()


def license_xml(license_uri='https://creativecommons.org/licenses/by/4.0/'):
    return ('<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><GetRecord><record><header>'
            '<identifier>oai:arXiv.org:' + SOURCE + '</identifier></header><metadata>'
            '<arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/"><id>' + SOURCE + '</id>'
            '<version version="v1"><date>Sat, 02 Mar 2024 00:00:00 GMT</date></version>'
            '<license>' + license_uri + '</license></arXivRaw></metadata></record></GetRecord></OAI-PMH>').encode()


def response_for(body):
    return b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body


# Explicit test instrumentation around unchanged captured coordinator modules.
# These fixture hooks are not part of a deployable/admitted runner identity.
DRIVER = '''
module=__import__(entry)
import threading,stat,journal,paused_child,local_postgres,subprocess,select,atexit,time
value=module.decode(sys.stdin.buffer.readline(24577)); mode=value.pop('instrumentation')
cancelled=threading.Event(); put=journal.Journal.put; joined=paused_child._joined
pending=[]
def cleanup_pending():
 for child in pending:
  if child.poll() is None: child.kill()
  child.wait(timeout=1)
atexit.register(cleanup_pending)
def checkpoint(self,name,value):
 result=put(self,name,value)
 if mode=='cancel_after_go_checkpoint' and name=='go-intent.json': cancelled.set()
 if mode=='pause_after_grant' and name=='go-intent.json':
  sys.stdout.buffer.write(b'fixture-paused\\n');sys.stdout.buffer.flush();time.sleep(3);cancelled.set()
 return result
journal.Journal.put=checkpoint
if mode=='hide_first_join':
 def first_join(child):
  result=joined(child)
  if not getattr(first_join,'hidden',False): first_join.hidden=True; return None
  return result
 paused_child._joined=first_join
if mode in ('fail_receipt_fsync','fail_reopen_fsync'):
 actual_fsync=os.fsync
 def failing_fsync(fd):
  if stat.S_ISDIR(os.fstat(fd).st_mode):
   names=os.listdir(fd)
   if 'executor.json' in names and 'executor-ack.json' not in names: raise OSError('fixture directory fsync failure')
  return actual_fsync(fd)
 journal.os.fsync=failing_fsync
rpc=module.LocalRPC(value['database'],faults=value.get('faults'))
if mode=='late_original_commit':
 call=local_postgres.LocalRPC.call
 def deferred(self,name,parameters):
  if name!='worker_claim_metadata_stage_v2': return call(self,name,parameters)
  self.calls.append(name)
  args=','.join(field+'=>'+local_postgres.quoted(module.canonical(item).decode() if type(item) is dict else item)+('::jsonb' if type(item) is dict else '') for field,item in parameters.items())
  child=subprocess.Popen([str(local_postgres.BIN/'psql'),*local_postgres.BASE,'-X','-qAt','-v','ON_ERROR_STOP=1','-d',self.database],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=local_postgres.ENV,close_fds=True)
  pending.append(child)
  sql="begin;set local idle_in_transaction_session_timeout='8s';set local statement_timeout='2s';set local role science_reader_metadata_executor;select public.worker_claim_metadata_stage_v2("+args+");\\n"
  child.stdin.write(sql.encode());child.stdin.flush()
  module.require(select.select([child.stdout],[],[],4)[0],'fixture_select_timeout')
  row=child.stdout.readline(65537)
  module.require(len(row)<=65536 and module.decode(row)['granted'] is True,'fixture_no_grant')
  # SELECT has run in this exact transaction, but COMMIT has not happened.
  raise module.Refused('rpc_ack_unknown')
 local_postgres.LocalRPC.call=deferred
if mode=='source_stage_changed':
 call=local_postgres.LocalRPC.call
 def stage_change(self,name,parameters):
  if name=='worker_claim_metadata_stage_v2':
   sql="update app_private.acquisition_jobs set stage='license' where id="+local_postgres.quoted(parameters['p_job_id'])+';'
   local_postgres.bounded([str(local_postgres.BIN/'psql'),*local_postgres.BASE,'-X','-qAt','-v','ON_ERROR_STOP=1','-d',self.database],sql.encode())
  return call(self,name,parameters)
 local_postgres.LocalRPC.call=stage_change
if 'recover_journal' in value:
 result=module.recover_local_action(rpc,value['recover_journal'],module.deno_parser)
else:
 result=module.run_local_action(rpc,value['job_id'],value['fixture'],value['journal_root'],module.deno_parser,cancelled=cancelled,source_budget_ms=1500)
result['calls']=rpc.calls
sys.stdout.buffer.write(module.canonical(result)+b'\\n')
sys.stdout.buffer.flush()
if mode=='late_original_commit':
 module.require(select.select([sys.stdin.buffer],[],[],5)[0],'fixture_commit_timeout')
 module.require(sys.stdin.buffer.readline(64)==b'commit\\n','fixture_commit_command')
 child=pending[0];child.stdin.write(b"commit;select 'fixture_committed';\\n");child.stdin.flush();child.stdin.close()
 module.require(select.select([child.stdout],[],[],4)[0],'fixture_commit_timeout')
 module.require(child.stdout.readline(128)==b'fixture_committed\\n','fixture_commit_ack')
 module.require(child.wait(timeout=2)==0,'fixture_database_exit')
 sys.stdout.buffer.write(b'{"fixture_committed":true}\\n');sys.stdout.buffer.flush()
'''


class IntegrationTests(unittest.TestCase):
    @classmethod
    def sql(cls, database, text):
        return pg.bounded([str(pg.BIN / 'psql'), *pg.BASE, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database],
                          text.encode(), timeout=20, maximum=2_097_152).decode().strip()

    @classmethod
    def setUpClass(cls):
        tls_fixtures.GatewayTests.setUpClass()
        cls.temp = tempfile.TemporaryDirectory(prefix='source-gateway-integration-')
        cls.root = Path(cls.temp.name)
        parser = cls.root / 'parser'
        pg.bounded([sys.executable, str(ROOT / 'scripts/build-metadata-parser.py'), str(parser)], b'', timeout=30)
        cls.bundle, cls.manifest = frozen.capture(cls.root, parser)
        print('fixture_bundle_manifest=' + canonical(cls.manifest).decode(), file=sys.stderr)
        cls.template = 'science_reader_gateway_' + uuid.uuid4().hex[:12]
        pg.bounded([str(pg.BIN / 'createdb'), *pg.BASE, cls.template], b'')
        cls.sql('postgres', 'alter database ' + cls.template + " set timezone='UTC';")
        sources = [ROOT / 'tests/database/bootstrap.sql', *sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
        pending = ROOT / 'supabase/migrations/202610030012_metadata_execution.sql.pending'
        if pending.exists():
            sources.append(pending)
        try:
            for source in sources:
                cls.sql(cls.template, source.read_text())
            # A genuine deferred COMMIT error after SELECT has produced a grant.
            cls.sql(cls.template, "create table public.fixture_deferred_failure(x integer);"
                    "create function public.fixture_reject_commit() returns trigger language plpgsql as $$begin raise exception 'fixture_commit_failure';end$$;"
                    "create constraint trigger fixture_commit_failure after insert on public.fixture_deferred_failure "
                    "deferrable initially deferred for each row execute function public.fixture_reject_commit();"
                    "grant insert on public.fixture_deferred_failure to science_reader_metadata_executor;")
        except BaseException:
            pg.bounded([str(pg.BIN / 'dropdb'), *pg.BASE, cls.template], b'')
            cls.temp.cleanup(); tls_fixtures.GatewayTests.tearDownClass(); raise

    @classmethod
    def tearDownClass(cls):
        pg.bounded([str(pg.BIN / 'dropdb'), *pg.BASE, cls.template], b'')
        cls.temp.cleanup()
        tls_fixtures.GatewayTests.tearDownClass()

    def setUp(self):
        self.database = 'science_reader_gateway_' + uuid.uuid4().hex[:12]
        pg.bounded([str(pg.BIN / 'createdb'), *pg.BASE, '-T', self.template, self.database], b'')
        self.sql('postgres', 'alter database ' + self.database + " set timezone='UTC';")
        self.journals = self.root / uuid.uuid4().hex
        self.journals.mkdir(mode=0o700)
        self.job = str(uuid.uuid4())
        account, imported, policy = (str(uuid.uuid4()) for _ in range(3))
        bundle_sha = digest(canonical(self.manifest))
        hashes = {scope + '_sha256': digest(canonical({'bundle': bundle_sha, 'scope': scope, 'local_fixture_only': True}))
                  for scope in ('runner', 'transport', 'observer', 'admission')}
        definition = {'version': 1, 'kind': 'metadata-owned-child-v1', 'connection_model': 'direct-owned-socket-v1',
                      'max_executors': 1, **hashes, 'max_useful_seconds': 30, 'max_report_seconds': 60}
        self.sql(self.database, "begin;set local role science_reader_executor_admitter;select public.worker_install_metadata_executor_policy(" +
                 pg.quoted(policy) + ',' + pg.quoted(canonical(definition).decode()) + ');select public.worker_activate_metadata_executor(1,' +
                 pg.quoted('abcdefghijklmnopqrst') + ',' + pg.quoted(policy) + ",decode(repeat('a',64),'hex'));commit;")
        self.sql(self.database, 'insert into auth.users values(' + pg.quoted(account) + ');select set_config(\'request.jwt.claim.sub\',' +
                 pg.quoted(account) + ',false);select public.v2_begin_import(' + pg.quoted(imported) + ',' + pg.quoted(SOURCE) + ',0,1);' +
                 'begin;set local role science_reader_metadata_executor;select public.worker_prepare_acquisition(' + pg.quoted(self.job) + ',' +
                 pg.quoted(SOURCE) + ',1);select public.worker_link_import_acquisition(' + pg.quoted(account) + ',' + pg.quoted(imported) + ',1,1,' +
                 pg.quoted(self.job) + ');commit;')

    def tearDown(self):
        pg.bounded([str(pg.BIN / 'dropdb'), *pg.BASE, self.database], b'')

    def command(self, instrumentation=None):
        command = frozen.command(self.bundle, 'integrate')
        if instrumentation:
            self.assertIn(instrumentation, ('cancel_after_go_checkpoint', 'hide_first_join',
                                           'fail_receipt_fsync', 'fail_reopen_fsync', 'source_stage_changed',
                                           'late_original_commit', 'pause_after_grant'))
            command[5] = command[5].replace("module=__import__(entry);raise SystemExit(module.main())", DRIVER)
        return command

    def run_action(self, response, *, ending='clean', faults=None, instrumentation=None):
        with tls_fixtures.TLSServer(tls_fixtures.GatewayTests.cert, tls_fixtures.GatewayTests.key, response, ending=ending) as server:
            value = {'database': self.database, 'job_id': self.job, 'journal_root': str(self.journals),
                     'fixture': {'address': '127.0.0.1', 'port': server.port, 'ca_pem': tls_fixtures.GatewayTests.ca},
                     'source_budget_ms': 1500, 'faults': faults or {}}
            if instrumentation:
                value['instrumentation'] = instrumentation
            raw = pg.bounded(self.command(instrumentation), canonical(value), timeout=15,
                             environment={'LC_ALL': 'C'}, maximum=65536)
            result = decode(raw)
            if result.get('reason') == 'local_contract_or_checkpoint_failed':
                path = Path(result['journal'])
                result['fixture_checkpoints'] = sorted(p.name for p in path.iterdir())
                witness = path / 'witness.json'
                if witness.exists():
                    result['fixture_witness'] = {key: value for key, value in decode(witness.read_bytes()).items() if key != 'result'}
        return result, server

    def recover(self, path, *, faults=None, instrumentation=None):
        value = {'database': self.database, 'recover_journal': str(path), 'faults': faults or {}}
        if instrumentation:
            value['instrumentation'] = instrumentation
        return decode(pg.bounded(self.command(instrumentation), canonical(value), timeout=15,
                                 environment={'LC_ALL': 'C'}, maximum=65536))

    def wait_gate(self):
        delay = float(self.sql(self.database, 'select greatest(0,extract(epoch from next_allowed_at-clock_timestamp())) from app_private.arxiv_network_gate;'))
        self.assertLessEqual(delay, 3)
        time.sleep(delay + .03)

    def test_real_atom_transport_commit_join_parser_and_catalog_result(self):
        body = atom()
        result, server = self.run_action(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(result['job']['stage'], 'license')
        self.assertEqual(result['job']['metadata']['title'], 'Local fixture paper')
        self.assertEqual(result['job']['atom_updated_at'], '2024-03-02T00:00:00.000Z')
        self.assertEqual(server.connections, 1)
        self.assertEqual(result['calls'].count('worker_claim_metadata_stage_v2'), 1)
        self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '2')
        self.assertEqual(self.sql(self.database, "select charged from app_private.acquisition_transfer_windows where kind='source_bytes';"), str(len(body)))

    def test_commit_failure_and_lost_ack_never_send_go(self):
        for fault in ('commit_failure', 'lost_ack'):
            with self.subTest(fault=fault):
                result, server = self.run_action(b'', faults={'worker_claim_metadata_stage_v2': fault})
                self.assertEqual(server.connections, 0)
                self.assertEqual(result['calls'].count('worker_claim_metadata_stage_v2'), 1)
                if fault == 'commit_failure':
                    self.assertEqual(result['reason'], 'grant_ack_unknown', result)
                    self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_attempts;'), '0')
                else:
                    self.assertEqual(result['state'], 'completed', result)
                    self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '2')
                    self.assertEqual(self.sql(self.database, "select charged from app_private.acquisition_transfer_windows where kind='source_bytes';"), '1048576')

    def test_incomplete_429_preserves_delay_without_refund(self):
        result, server = self.run_action(b'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 90\r\nContent-Length: 100\r\n\r\nshort', ending='abrupt')
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(result['job']['error_code'], 'rate_limited')
        self.assertEqual(self.sql(self.database, "select facts->>'retry_after_seconds' from app_private.execution_quiescence where resource='arxiv_connection';"), '90')
        self.assertEqual(self.sql(self.database, "select charged from app_private.acquisition_transfer_windows where kind='source_bytes';"), '1048576')

    def test_unsupported_retry_after_keeps_database_source_hold(self):
        result, _ = self.run_action(b'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 90000\r\nContent-Length: 0\r\n\r\n')
        self.assertEqual(result['reason'], 'retry_after_unresolved', result)
        self.assertEqual(self.sql(self.database, "select resource from app_private.execution_quiescence;"), 'executor')
        self.assertEqual(self.sql(self.database, 'select token is not null from app_private.arxiv_network_gate;'), 't')

    def test_lost_receipt_ack_reopens_exact_checkpoint_without_new_grant(self):
        body = atom()
        result, server = self.run_action(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body,
                                         faults={'worker_record_metadata_quiescence': 'lost_ack'})
        self.assertEqual(result['reason'], 'receipt_ack_unknown', result)
        checkpoint = Path(result['journal']) / 'executor.json'
        original = checkpoint.read_bytes()
        recovered = self.recover(result['journal'])
        self.assertEqual(recovered['state'], 'completed', recovered)
        self.assertNotIn('worker_claim_metadata_stage_v2', recovered['calls'])
        self.assertEqual(checkpoint.read_bytes(), original)
        self.assertEqual(server.connections, 1)
        self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_attempts;'), '1')
        self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '2')

    def test_lost_result_ack_replays_frozen_observed_at_and_result(self):
        first, _ = self.run_action(response_for(atom()))
        self.assertEqual(first['state'], 'completed', first)
        self.wait_gate()
        result, server = self.run_action(response_for(license_xml()),
                                         faults={'worker_finish_metadata_stage_v2': 'lost_ack'})
        self.assertEqual(result['reason'], 'result_ack_unknown', result)
        checkpoint = Path(result['journal']) / 'result.json'
        original = checkpoint.read_bytes()
        observed = decode(original)['parameters']['p_result']['evidence']['observed_at']
        self.assertRegex(observed, r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')
        recovered = self.recover(result['journal'])
        self.assertEqual(recovered['state'], 'completed', recovered)
        self.assertNotIn('worker_claim_metadata_stage_v2', recovered['calls'])
        self.assertEqual(checkpoint.read_bytes(), original)
        self.assertEqual(server.connections, 1)
        self.assertEqual(recovered['job']['eligibility'], 'eligible')
        self.assertEqual(recovered['job']['evidence']['observed_at'], observed)

    def test_lost_grant_no_row_stays_unknown_and_never_claims_again(self):
        result, server = self.run_action(b'', faults={'worker_claim_metadata_stage_v2': 'commit_failure'})
        intent = (Path(result['journal']) / 'intent.json').read_bytes()
        recovered = self.recover(result['journal'])
        self.assertEqual(recovered['reason'], 'grant_still_unknown', recovered)
        self.assertEqual(recovered['calls'], ['worker_metadata_execution_state'])
        self.assertEqual((Path(result['journal']) / 'intent.json').read_bytes(), intent)
        self.assertEqual(server.connections, 0)

    def test_full_body_fits_pregranted_checkpoint_envelope(self):
        body = atom()
        body += b' ' * (1_048_576 - len(body))
        result, server = self.run_action(b'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n' + body)
        self.assertEqual(result['state'], 'completed', result)
        path = Path(result['journal'])
        capacity = decode((path / 'capacity.json').read_bytes())
        self.assertLessEqual(sum(p.stat().st_size for p in path.iterdir()) + self.manifest['source_bytes'], capacity['maximum_total_bytes'])
        self.assertLessEqual(capacity['maximum_total_bytes'], 4 * 1024 * 1024)
        self.assertNotIn('body_base64', decode((path / 'parser-input.json').read_bytes()))
        self.assertEqual(server.connections, 1)

    def assert_http_failure(self, response, code, retryable, *, frame='content_length', charged=0):
        result, server = self.run_action(response)
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual((result['job']['error_code'], result['job']['retryable']), (code, retryable))
        self.assertEqual(server.connections, 1)
        self.assertEqual(self.sql(self.database, "select facts->>'framing' from app_private.execution_quiescence where resource='arxiv_connection';"), frame)
        self.assertEqual(self.sql(self.database, "select charged from app_private.acquisition_transfer_windows where kind='source_bytes';"), str(charged))

    def test_not_found_is_nonretryable_with_complete_body_accounting(self):
        self.assert_http_failure(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n', 'source_not_found', False)

    def test_server_failure_is_retryable_after_retirement(self):
        self.assert_http_failure(b'HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n', 'metadata_unavailable', True)

    def test_malformed_success_xml_cannot_become_metadata(self):
        self.assert_http_failure(response_for(b'<feed'), 'invalid_source_metadata', False, charged=5)

    def test_204_explicit_length_settles_without_catalog_success(self):
        self.assert_http_failure(b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n', 'metadata_unavailable', False)

    def test_204_no_body_has_no_invented_length_or_refund(self):
        self.assert_http_failure(b'HTTP/1.1 204 No Content\r\n\r\n', 'metadata_unavailable', False,
                                 frame='unknown', charged=1048576)

    def test_unsupported_license_finishes_source_only(self):
        first, _ = self.run_action(response_for(atom()))
        self.assertEqual(first['state'], 'completed', first)
        self.wait_gate()
        result, server = self.run_action(response_for(license_xml('http://arxiv.org/licenses/nonexclusive-distrib/1.0/')))
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(result['job']['eligibility'], 'source_only')
        self.assertEqual(result['job']['source_detail'], 'license_not_supported')
        self.assertEqual(result['job']['stage'], 'complete')
        self.assertEqual(server.connections, 1)

    def test_unicode_metadata_survives_atom_grant_pinned_parser_and_license_result(self):
        abstract = 'é' * 11000
        body = atom().replace(b'Fixture only.', abstract.encode('utf8'))
        first, server = self.run_action(response_for(body))
        self.assertEqual(first['state'], 'completed', first)
        self.assertEqual(first['job']['metadata']['abstract'], abstract)
        self.assertEqual(server.connections, 1)
        self.wait_gate()
        result, server = self.run_action(response_for(license_xml()))
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(result['job']['eligibility'], 'eligible')
        self.assertEqual(result['job']['metadata']['abstract'], abstract)
        self.assertEqual(server.connections, 1)
        parser_input = decode((Path(result['journal']) / 'parser-input.json').read_bytes())
        self.assertEqual(parser_input['pinned_record']['metadata']['abstract'], abstract)
        self.assertEqual(parser_input['pinned_record']['metadata']['updated_at'], '2024-03-02T00:00:00.000Z')

    def test_cancel_after_durable_go_checkpoint_opens_no_socket(self):
        result, server = self.run_action(b'', instrumentation='cancel_after_go_checkpoint')
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(server.connections, 0)
        witness = decode((Path(result['journal']) / 'witness.json').read_bytes())
        self.assertFalse(witness['sent_go'])
        self.assertEqual(self.sql(self.database, "select facts->>'framing' from app_private.execution_quiescence where resource='arxiv_connection';"), 'unknown')

    def test_source_stage_change_before_commit_opens_no_socket(self):
        first, _ = self.run_action(response_for(atom()))
        self.assertEqual(first['state'], 'completed', first)
        self.wait_gate()
        # Fixture reconstruction of the stale pre-completion snapshot; the
        # instrumented grant boundary restores the actual completed stage.
        self.sql(self.database, "update app_private.acquisition_jobs set stage='atom' where id=" + pg.quoted(self.job) + ';')
        result, server = self.run_action(b'', instrumentation='source_stage_changed')
        self.assertEqual(result['state'], 'completed', result)
        self.assertEqual(server.connections, 0)
        path = Path(result['journal'])
        self.assertEqual(decode((path / 'intent.json').read_bytes())['request']['stage'], 'atom')
        self.assertEqual(decode((path / 'grant.json').read_bytes())['response']['execution']['kind'], 'license')
        self.assertFalse(decode((path / 'witness.json').read_bytes())['sent_go'])

    def test_late_exact_join_is_saved_and_can_settle_without_fetch(self):
        result, server = self.run_action(response_for(atom()), instrumentation='hide_first_join')
        self.assertEqual(result['reason'], 'child_unresolved', result)
        path = Path(result['journal'])
        self.assertFalse(decode((path / 'witness.json').read_bytes())['owned_process_retired'])
        self.assertTrue(decode((path / 'terminal-witness.json').read_bytes())['owned_process_retired'])
        recovered = self.recover(path)
        self.assertEqual(recovered['state'], 'completed', recovered)
        self.assertEqual(server.connections, 1)
        self.assertEqual(self.sql(self.database, "select charged from app_private.acquisition_transfer_windows where kind='source_bytes';"), '1048576')

    def test_visible_checkpoint_fsync_failure_blocks_rpc_until_durable_reopen(self):
        result, server = self.run_action(response_for(atom()), instrumentation='fail_receipt_fsync')
        self.assertEqual(result['reason'], 'local_contract_or_checkpoint_failed', result)
        path = Path(result['journal'])
        frozen_receipt = (path / 'executor.json').read_bytes()
        self.assertNotIn('worker_record_metadata_quiescence', result['calls'])
        blocked = self.recover(path, instrumentation='fail_reopen_fsync')
        self.assertEqual(blocked['reason'], 'recovery_contract_or_checkpoint_failed', blocked)
        self.assertEqual(blocked['calls'], [])
        recovered = self.recover(path)
        self.assertEqual(recovered['state'], 'completed', recovered)
        self.assertEqual((path / 'executor.json').read_bytes(), frozen_receipt)
        self.assertEqual(server.connections, 1)

    def test_changed_restored_witness_cannot_issue_another_receipt(self):
        result, _ = self.run_action(response_for(atom()), faults={'worker_record_metadata_quiescence': 'lost_ack'})
        self.assertEqual(result['reason'], 'receipt_ack_unknown', result)
        path = Path(result['journal']) / 'witness.json'
        witness = decode(path.read_bytes())
        witness['owned_process_retired'] = 'false'
        path.write_bytes(canonical(witness))
        recovered = self.recover(path.parent)
        self.assertEqual(recovered['reason'], 'recovery_contract_or_checkpoint_failed', recovered)
        self.assertEqual(recovered['calls'], ['worker_metadata_execution_state'])
        self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '1')

    def test_null_status_then_original_transaction_commits_recovery_never_regrants(self):
        with tls_fixtures.TLSServer(tls_fixtures.GatewayTests.cert, tls_fixtures.GatewayTests.key, b'') as server:
            value = {'database': self.database, 'job_id': self.job, 'journal_root': str(self.journals),
                     'fixture': {'address': '127.0.0.1', 'port': server.port, 'ca_pem': tls_fixtures.GatewayTests.ca},
                     'instrumentation': 'late_original_commit'}
            child = subprocess.Popen(self.command('late_original_commit'), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True, env={'LC_ALL': 'C'})
            try:
                child.stdin.write(canonical(value) + b'\n'); child.stdin.flush()
                self.assertTrue(select.select([child.stdout], [], [], 6)[0])
                result = decode(child.stdout.readline(65537))
                self.assertEqual(result['reason'], 'grant_ack_unknown', result)
                self.assertEqual(result['calls'].count('worker_claim_metadata_stage_v2'), 1)
                saved = decode((Path(result['journal']) / 'grant-status.json').read_bytes())
                self.assertIsNone(saved['execution'])
                self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_attempts;'), '0')
                child.stdin.write(b'commit\n'); child.stdin.flush(); child.stdin.close()
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(decode(child.stdout.readline(1024)), {'fixture_committed': True})
                self.assertEqual(child.wait(timeout=2), 0)
                self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_attempts;'), '1')
                recovered = self.recover(result['journal'])
                self.assertEqual(recovered['state'], 'completed', recovered)
                self.assertNotIn('worker_claim_metadata_stage_v2', recovered['calls'])
                self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '2')
                self.assertEqual(server.connections, 0)
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=2)
                for pipe in (child.stdin, child.stdout, child.stderr):
                    if not pipe.closed: pipe.close()

    def test_expired_partial_or_duplicate_go_never_opens_fixture_socket(self):
        for mode in ('expired', 'partial', 'duplicate'):
            with self.subTest(mode=mode), tls_fixtures.TLSServer(tls_fixtures.GatewayTests.cert, tls_fixtures.GatewayTests.key, b'') as server:
                request = {'source_id': SOURCE, 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1048576}
                value = {'mode': 'loopback_fixture_v1', 'attempt_id': str(uuid.uuid4()), 'request': request,
                         'fixture': {'address': '127.0.0.1', 'port': server.port, 'ca_pem': tls_fixtures.GatewayTests.ca},
                         'useful_ms': 1000, 'close_ms': 0}
                child = subprocess.Popen(frozen.command(self.bundle, 'child'), stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True, env={'LC_ALL': 'C'})
                try:
                    child.stdin.write(canonical(value) + b'\n'); child.stdin.flush()
                    self.assertTrue(select.select([child.stdout], [], [], 3)[0])
                    self.assertEqual(decode(child.stdout.readline(2048))['kind'], 'ready')
                    command = {'schema_version': 1, 'kind': 'go', 'child_id': value['attempt_id'],
                               'source_sha256': digest(canonical(request)), 'execution_id': str(uuid.uuid4()),
                               'deadline_ns': str(clock_ns() + (-1 if mode == 'expired' else 1_000_000_000))}
                    raw = canonical(command)
                    final = raw[:len(raw)//2] if mode == 'partial' else (raw + b'\n') * (2 if mode == 'duplicate' else 1)
                    out, err = child.communicate(final, timeout=3)
                    self.assertEqual(child.returncode, 2)
                    self.assertEqual((out, err), (b'', b''))
                    self.assertEqual(server.connections, 0)
                finally:
                    if child.poll() is None: child.kill()
                    child.wait(timeout=1)
                    for pipe in (child.stdin, child.stdout, child.stderr):
                        if not pipe.closed: pipe.close()

    def test_parent_death_after_grant_has_no_reconstructed_join_receipt(self):
        with tls_fixtures.TLSServer(tls_fixtures.GatewayTests.cert, tls_fixtures.GatewayTests.key, b'') as server:
            value = {'database': self.database, 'job_id': self.job, 'journal_root': str(self.journals),
                     'fixture': {'address': '127.0.0.1', 'port': server.port, 'ca_pem': tls_fixtures.GatewayTests.ca},
                     'instrumentation': 'pause_after_grant'}
            child = subprocess.Popen(self.command('pause_after_grant'), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True, env={'LC_ALL': 'C'})
            try:
                child.stdin.write(canonical(value) + b'\n'); child.stdin.flush(); child.stdin.close()
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(child.stdout.readline(128), b'fixture-paused\n')
                child.kill(); child.wait(timeout=2)
                paths = list(self.journals.iterdir())
                self.assertEqual(len(paths), 1)
                self.assertFalse((paths[0] / 'witness.json').exists())
                recovered = self.recover(paths[0])
                self.assertEqual(recovered['reason'], 'recovery_contract_or_checkpoint_failed', recovered)
                self.assertEqual(recovered['calls'], ['worker_metadata_execution_state'])
                self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_attempts;'), '1')
                self.assertEqual(self.sql(self.database, 'select count(*) from app_private.execution_quiescence;'), '0')
                self.assertEqual(self.sql(self.database, 'select token is not null from app_private.arxiv_network_gate;'), 't')
                self.assertEqual(server.connections, 0)
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=2)
                for pipe in (child.stdin, child.stdout, child.stderr):
                    if not pipe.closed: pipe.close()


if __name__ == '__main__':
    unittest.main()

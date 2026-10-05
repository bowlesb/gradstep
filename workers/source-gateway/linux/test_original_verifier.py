"""Actual frozen-parser/FD checks; local fixtures are not SQL/host admission.

Spool predecessor requests and guardian callbacks below are authored fixtures.
No source/Storage credentials, VM, DB or provider request is used. Adversarial
wrappers are new test-owned captures, never mutations of the real parser build.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

import original_verifier as receiver
import original_verifier_bundle as packaging
import original_session as transfer
import original_spool as spool
from original_tls_fixture import OriginalServer, certificate
from original_transport import spool_facts
from protocol import Refused, canonical, clock_ns, digest
from test_original_session import transfer_input, allow_fixture

ROOT = Path(__file__).resolve().parents[3]
BUILD = '39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610'
DENO = Path(os.environ.get('TIMESTEP_VERIFIER_DENO',
                          str(ROOT / '.artifacts/pdf-verifier/tools/deno-2.9.6-darwin-arm64/deno')))
FIXTURES = ROOT / '.artifacts/pdf-verifier/fixtures'


def fixture_input(bundle, raw_descriptor):
    """Closed SQL-shaped request; no claim of a database-generated grant."""
    sealed = spool.descriptor(raw_descriptor)
    request = {'version': 1, 'kind': 'original_verify', 'job_id': str(uuid.uuid4()),
               'reservation_id': sealed['reservation_id'], 'source_id': '1706.03762', 'source_revision': 1,
               'bucket': 'paper-assets', 'path': 'originals/' + sealed['reservation_id'] + '/original.pdf',
               'predecessor_operation_id': sealed['claim_id'], 'predecessor_result_sha256': '1' * 64,
               'candidate_sha256': sealed['sha256'], 'candidate_bytes': sealed['bytes'],
               'input_spool_sha256': digest(raw_descriptor), 'byte_ceiling': sealed['bytes'],
               'verification_profile_id': str(uuid.uuid4()), 'stage_recipe_sha256': '2' * 64,
               'build_sha256': bundle.build_identity_sha256, 'parser_profile_sha256': bundle.profile_sha256,
               'verifier_host_policy_sha256': '3' * 64, 'storage_policy_sha256': '4' * 64,
               'spool_policy_sha256': '5' * 64}
    return {'format': 'original-verifier-input-v1', 'local_fixture_only': True, 'claim_id': str(uuid.uuid4()),
            'request': request, 'request_sha256': '6' * 64, 'spool_descriptor': raw_descriptor.decode('utf8')}


FAKE_PREFIX = r'''
const enc=new TextEncoder(),dec=new TextDecoder();
function canonical(v){return JSON.stringify(v,(_,x)=>x&&typeof x==='object'&&!Array.isArray(x)?Object.fromEntries(Object.keys(x).sort().map(k=>[k,x[k]])):x)}
async function sha(s){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(s))),x=>x.toString(16).padStart(2,'0')).join('')}
async function emit(x){await Deno.stdout.write(enc.encode(canonical(x)+'\n'))}
const pipe=await Deno.open((Deno.build.os==='darwin'?'/dev/fd/':'/proc/self/fd/')+Deno.args[0],{read:true});
async function line(){let raw='';while(!raw.endsWith('\n')){let b=new Uint8Array(1);if(await pipe.read(b)===null)throw Error();raw+=dec.decode(b)}return JSON.parse(raw)}
const value=await line(),inputHash=await sha(canonical(value));
await emit({format:'original-verifier-ready-v1',claim_id:value.claim_id,input_sha256:inputHash,bundle_sha256:Deno.args[1],process_id:Deno.pid});
const go=await line();if(await pipe.read(new Uint8Array(1))!==null)Deno.exit(2);pipe.close();
'''
FAKE_VALID = r'''
let count=0,part=new Uint8Array(65536);for(;;){let n=await Deno.stdin.read(part);if(n===null)break;count+=n}
const result={format:'original-verifier-result-v1',local_fixture_only:true,claim_id:value.claim_id,
 execution_id:go.execution_id,request_sha256:value.request_sha256,input_sha256:inputHash,
 bundle_sha256:Deno.args[1],go_sha256:await sha(canonical(go)),kind:'parsed',reason:null,
 parser_result:{outcome:'verified',pages:1,bytes:count,sha256:value.request.candidate_sha256,
 profileID:'qpdf-wasm-pilot-v1',profileSHA256:value.request.parser_profile_sha256,
 wasmSHA256:'a868862bb5a6879e93d2d0ea41ba38186ce0418a7990a7109fecdd6505467d1b',elapsedMS:1}};
'''


@unittest.skipUnless(DENO.is_file() and (ROOT / '.artifacts/pdf-verifier/builds' / BUILD).is_dir(),
                     'requires retained frozen3998 and pinned local Deno')
class OriginalVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix='.timestep-verifier-shared-', dir=Path.home())
        cls.bundle = packaging.capture_verifier_bundle(cls.shared.name, BUILD, DENO)
        cls.manifest = json.loads((FIXTURES / 'manifest.json').read_text())
        cls.unresolved = False

    @classmethod
    def tearDownClass(cls):
        if cls.unresolved:
            cls.shared._finalizer.detach()
        else:
            os.chmod(cls.bundle.root, 0o700)
            cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.timestep-verifier-', dir=Path.home())
        self.root = Path(self.temp.name)
        self.children, self.bundles, self.fds = [], [], []

    def tearDown(self):
        for child in self.children:
            report = child.stop()
            if not report['child_retired']:
                type(self).unresolved = True
                self.temp._finalizer.detach()
                raise AssertionError('unresolved exact child: keep test spool and capture')
        for fd in self.fds:
            os.close(fd)
        for bundle in self.bundles:
            os.chmod(bundle.root, 0o700)
        self.temp.cleanup()

    def fixture(self, name):
        entry = next(item for item in self.manifest if item['file'] == name)
        raw = (FIXTURES / name).read_bytes()
        self.assertEqual((len(raw), digest(raw)), (entry['bytes'], entry['sha256']))
        return raw

    def input_file(self, body, *, unlinked=False):
        path = self.root / (uuid.uuid4().hex + '.pdf')
        path.write_bytes(body)
        path.chmod(0o600)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        self.fds.append(fd)
        info = os.fstat(fd)
        guardian = {'device': str(info.st_dev), 'inode': str(info.st_ino)}
        record = {'format': 'original-spool-v1', 'purpose': 'stored_readback', 'reservation_id': str(uuid.uuid4()),
                  'claim_id': str(uuid.uuid4()), 'attempt_id': str(uuid.uuid4()), 'request_sha256': '7' * 64,
                  'binding_sha256': '8' * 64, 'capture_sha256': '9' * 64, 'bytes': len(body), 'sha256': digest(body),
                  'guardian': guardian, 'producer': {'device': guardian['device'], 'inode': str(info.st_ino + 1)}}
        if unlinked:
            path.unlink()
        return fixture_input(self.bundle, canonical(record) + b'\n'), fd, path

    def start(self, value, fd, bundle=None):
        try:
            child = receiver.VerifierSession(bundle or self.bundle, value, input_fd=fd)
        except receiver.VerifierStartError as error:
            self.children.append(error.session)
            raise
        self.children.append(child)
        return child

    def go(self, child, milliseconds=5000):
        child.go(str(uuid.uuid4()), 'a' * 64, clock_ns() + milliseconds * 1_000_000)

    def fake_bundle(self, code):
        root = self.root / ('fake-' + uuid.uuid4().hex)
        root.mkdir(mode=0o700)
        manifest = self.bundle.manifest
        for name in manifest['files']:
            raw = code.encode() if name == 'original_verifier.mjs' else (self.bundle.root / name).read_bytes()
            (root / name).write_bytes(raw)
            (root / name).chmod(0o400)
            manifest['files'][name] = {'bytes': len(raw), 'sha256': digest(raw)}
        manifest['payload_bytes'] = sum(x['bytes'] for x in manifest['files'].values())
        raw = canonical(manifest)
        (root / 'bundle.json').write_bytes(raw)
        (root / 'bundle.json').chmod(0o400)
        root.chmod(0o500)
        info = root.stat()
        bundle = packaging.FrozenVerifierBundle(root, raw, (info.st_dev, info.st_ino))
        self.bundles.append(bundle)
        return bundle

    def test_unlinked_readonly_pdf_pauses_then_exact_wait4_actual_parser(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'), unlinked=True)
        expected = copy.deepcopy(value)
        child = self.start(value, fd)
        self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)
        self.assertFalse(child.sent_go)
        value['request']['candidate_sha256'] = 'f' * 64
        self.assertEqual(child.value, expected)
        self.go(child)
        report = child.finish()
        self.assertTrue(report['verified'], report)
        self.assertEqual(report['result']['parser_result']['pages'], 1)
        self.assertEqual(report['retirement']['returncode'], 0)
        self.assertEqual(report['retirement']['pid'], child.child.pid)
        self.assertIsNone(report['retirement']['metrics_error'])
        self.assertGreater(report['retirement']['metrics']['peak_process_bytes'], 0)
        self.assertGreater(report['spawn_to_wait_wall_ms'], report['result']['parser_result']['elapsedMS'])
        self.assertTrue(report['ipc_cleanup_complete'])
        self.assertEqual(child.finish(), report)
        with self.assertRaisesRegex(Refused, 'session_consumed'):
            self.go(child)
        # Deno cache may not add writable state to this immutable file set.
        self.bundle.verify()

    def test_frozen_parser_outcomes_and_fresh_heap_after_resource_refusal(self):
        cases = [('pages-50.pdf', 'verified'), ('pages-51.pdf', 'page_limit'),
                 ('corrupt-flate.pdf', 'malformed'), ('job-json-encrypt-40.pdf', 'encrypted'),
                 ('unsupported-filter.pdf', 'unsupported'), ('stream-budget.pdf', 'parser_resource_limit'),
                 ('object-stream-oom.pdf', 'resource_limit'), ('pages-1.pdf', 'verified')]
        for name, outcome in cases:
            with self.subTest(name=name):
                value, fd, _ = self.input_file(self.fixture(name))
                child = self.start(value, fd)
                self.go(child)
                report = child.finish()
                self.assertTrue(report['complete'], report)
                measured = report['result']['parser_result']
                self.assertEqual(measured['outcome'], outcome)
                self.assertEqual('pages' in measured, outcome == 'verified')

    def test_retained_real_paper_and_near_limit_refusal(self):
        manifest = json.loads((ROOT / 'workers/pdf-verifier/corpus/manifest.json').read_text())
        for filename, outcome, pages in [('v139-radford21a.pdf', 'verified', 16),
                                         ('v162-dao22a.pdf', 'parser_resource_limit', None)]:
            with self.subTest(filename=filename):
                body = (ROOT / '.artifacts/pdf-verifier/corpus/pdf' / filename).read_bytes()
                entry = next(item for item in manifest['papers'] if item['id'] == filename[:-4])
                self.assertEqual((len(body), digest(body)), (entry['bytes'], entry['sha256']))
                value, fd, _ = self.input_file(body)
                child = self.start(value, fd)
                self.go(child)
                report = child.finish()
                self.assertTrue(report['complete'], report)
                self.assertEqual(report['result']['parser_result']['outcome'], outcome)
                self.assertEqual(report['result']['parser_result'].get('pages'), pages)

    def test_wrong_fd_modes_sizes_offsets_inode_and_build_refuse_before_spawn(self):
        body = self.fixture('pages-1.pdf')
        for fault in ('readwrite', 'offset', 'length', 'inode', 'build', 'profile', 'predecessor',
                      'descriptor_hash', 'descriptor_limit'):
            with self.subTest(fault=fault):
                value, fd, path = self.input_file(body)
                if fault == 'readwrite':
                    fd = os.open(path, os.O_RDWR)
                    self.fds.append(fd)
                elif fault == 'offset':
                    os.lseek(fd, 1, os.SEEK_SET)
                elif fault == 'length':
                    path.write_bytes(body[:-1])
                elif fault == 'inode':
                    other = self.root / 'other.pdf'
                    other.write_bytes(body)
                    fd = os.open(other, os.O_RDONLY)
                    self.fds.append(fd)
                elif fault == 'build':
                    value['request']['build_sha256'] = 'f' * 64
                elif fault == 'profile':
                    value['request']['parser_profile_sha256'] = 'f' * 64
                elif fault == 'predecessor':
                    value['request']['predecessor_operation_id'] = str(uuid.uuid4())
                elif fault == 'descriptor_limit':
                    value['spool_descriptor'] = 'x' * 4097
                else:
                    value['request']['input_spool_sha256'] = 'f' * 64
                with patch.object(receiver.Wait4Child, 'spawn') as spawn:
                    with self.assertRaises((Refused, ValueError)):
                        self.start(value, fd)
                    spawn.assert_not_called()

    def test_same_length_wrong_hash_refuses_before_runtime_import(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        raw = json.loads(value['spool_descriptor'])
        raw['sha256'] = 'f' * 64
        value = fixture_input(self.bundle, canonical(raw) + b'\n')
        child = self.start(value, fd)
        self.go(child)
        report = child.finish()
        self.assertTrue(report['complete'], report)
        self.assertEqual(report['result']['kind'], 'refused')
        self.assertEqual(report['result']['reason'], 'input_mismatch')
        self.assertIsNone(report['result']['parser_result'])
        self.assertFalse(report['verified'])

    def test_pre_go_cancel_expiry_and_changed_input_read_nothing(self):
        value, fd, path = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        cancelled = threading.Event()
        cancelled.set()
        with self.assertRaisesRegex(Refused, 'cancelled'):
            child.go(str(uuid.uuid4()), 'b' * 64, clock_ns() + 1_000_000_000, cancelled=cancelled)
        with self.assertRaisesRegex(Refused, 'deadline'):
            child.go(str(uuid.uuid4()), 'b' * 64, clock_ns() - 1)
        path.write_bytes(path.read_bytes())  # Same bytes but changed sealed-file metadata.
        with self.assertRaisesRegex(Refused, 'input_changed'):
            self.go(child)
        self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)
        self.assertFalse(child.sent_go)
        self.assertTrue(child.stop()['child_retired'])

    def test_bad_go_and_missing_control_eof_never_read_payload(self):
        for fault in ('wrong_claim', 'wrong_input', 'duplicate_go', 'no_eof'):
            with self.subTest(fault=fault):
                value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
                child = self.start(value, fd)
                go = {'format': 'original-verifier-go-v1', 'claim_id': value['claim_id'], 'execution_id': str(uuid.uuid4()),
                      'binding_sha256': 'a' * 64, 'input_sha256': child.input_sha256, 'bundle_sha256': self.bundle.sha256,
                      'deadline_ns': str(clock_ns() + 200_000_000), 'budget_ms': 200}
                if fault == 'wrong_claim':
                    go['claim_id'] = str(uuid.uuid4())
                if fault == 'wrong_input':
                    go['input_sha256'] = 'f' * 64
                child.sent_go, child._go, child._deadline_ns = True, go, int(go['deadline_ns'])
                raw = canonical(go) + b'\n'
                child._write(raw + (raw if fault == 'duplicate_go' else b''), receiver.clock() + .1)
                if fault != 'no_eof':
                    child._control.close()
                report = child.finish()
                self.assertFalse(report['verified'])
                self.assertTrue(report['child_retired'], report)
                self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)

    def test_malformed_initial_control_retains_waited_owner_and_never_reads_pdf(self):
        write = receiver.VerifierSession._write
        for fault in ('bom', 'duplicate_key', 'utf8', 'oversize'):
            with self.subTest(fault=fault):
                value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
                def corrupted(child, raw, deadline, cancelled=None):
                    if fault == 'bom':
                        raw = b'\xef\xbb\xbf' + raw
                    elif fault == 'duplicate_key':
                        raw = raw.replace(b'"local_fixture_only":true', b'"local_fixture_only":true,"local_fixture_only":true')
                    elif fault == 'utf8':
                        raw = b'\xff' + raw
                    else:
                        raw = b'x' * receiver.MAX_INPUT + b'\n'
                    return write(child, raw, deadline, cancelled)
                with patch.object(receiver.VerifierSession, '_write', new=corrupted):
                    with self.assertRaises(receiver.VerifierStartError) as refused:
                        self.start(value, fd)
                report = refused.exception.session.stop()
                self.assertTrue(report['child_retired'], report)
                self.assertFalse(report['verified'])
                self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)

    def test_postspawn_control_close_failure_exposes_exact_owner_and_cleans_others(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        spawn = receiver.Wait4Child.spawn
        close = os.close
        control = []
        injected = []
        def spawned(*args, **kwargs):
            owner = spawn(*args, **kwargs)
            control.append(kwargs['pass_fds'][0])
            return owner
        def closed_then_error(number):
            close(number)
            if control and number == control[0] and not injected:
                injected.append(number)
                raise OSError('injected postspawn close failure')
        with patch.object(receiver.Wait4Child, 'spawn', side_effect=spawned), \
                patch.object(receiver.os, 'close', side_effect=closed_then_error):
            with self.assertRaises(receiver.VerifierStartError) as refused:
                self.start(value, fd)
        child = refused.exception.session
        report = child.stop()
        self.assertTrue(report['child_retired'], report)
        self.assertFalse(report['verified'] or report['ipc_cleanup_complete'])
        self.assertIsNone(child._input_fd)
        self.assertTrue(child._control.closed and child.child.stdout.closed and child.child.stderr.closed)
        self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)

    def test_valid_result_still_needs_exact_exit_and_watchdog_runs_while_caller_idle(self):
        bundle = self.fake_bundle(FAKE_PREFIX + FAKE_VALID + "await emit(result); while(true) {}")
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd, bundle)
        self.go(child, 150)
        time.sleep(.25)  # Deliberately do not drive finish's selector/watchdog.
        report = child.finish()
        self.assertFalse(report['verified'])
        self.assertEqual(report['reason'], 'deadline')
        self.assertTrue(report['child_retired'], report)
        self.assertEqual(report['retirement']['returncode'], -9)

    def test_result_eof_exit_and_output_shape_failures_are_not_success(self):
        endings = {'eof': 'Deno.exit(0);', 'bad_json': "await Deno.stdout.write(enc.encode('garbage\\n'));",
                   'output_limit': "await Deno.stdout.write(new Uint8Array(8192).fill(120));",
                   'stderr': "await Deno.stderr.write(enc.encode('fixture'));",
                   'nonzero': FAKE_VALID + 'await emit(result); Deno.exit(2);',
                   'bad_type': FAKE_VALID + 'result.parser_result.elapsedMS=true; await emit(result);',
                   'duplicate_key': FAKE_VALID + '''await Deno.stdout.write(enc.encode(canonical(result).replace('"elapsedMS":1','"elapsedMS":1,"elapsedMS":1')+'\\n'));''',
                   'extra_field': FAKE_VALID + 'result.unexpected=true; await emit(result);'}
        for label, suffix in endings.items():
            with self.subTest(label=label):
                bundle = self.fake_bundle(FAKE_PREFIX + suffix)
                value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
                child = self.start(value, fd, bundle)
                self.go(child)
                report = child.finish()
                self.assertFalse(report['verified'], report)
                self.assertTrue(report['child_retired'], report)

    def test_valid_javascript_float_spelling_need_not_match_python_encoder(self):
        bundle = self.fake_bundle(FAKE_PREFIX + FAKE_VALID + 'result.parser_result.elapsedMS=0.00001; await emit(result);')
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd, bundle)
        self.go(child)
        report = child.finish()
        self.assertTrue(report['complete'], report)
        self.assertEqual(report['result']['parser_result']['elapsedMS'], 0.00001)

    def test_missing_rusage_does_not_erase_retirement_or_accept_result(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        import wait4_child
        with patch.object(wait4_child, '_usage', side_effect=ValueError('injected missing usage')):
            self.go(child)
            report = child.finish()
        self.assertFalse(report['verified'])
        self.assertTrue(report['child_retired'])
        self.assertEqual(report['reason'], 'rusage_missing')
        self.assertEqual(report['retirement']['returncode'], 0)

    def test_watchdog_start_failure_still_retires_and_closes_exact_child(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        with patch.object(threading.Thread, 'start', side_effect=RuntimeError('injected thread refusal')):
            with self.assertRaises(RuntimeError):
                self.go(child)
        report = child.stop()
        self.assertFalse(report['verified'])
        self.assertTrue(report['child_retired'] and report['ipc_cleanup_complete'], report)
        self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)

    def test_cancellation_after_wait_during_result_validation_cannot_accept(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        cancelled = threading.Event()
        checked = receiver.checked_result
        def cancel_at_validation(*args):
            self.assertIsNotNone(child.child.retirement)
            result = checked(*args)
            cancelled.set()
            return result
        self.go(child)
        with patch.object(receiver, 'checked_result', side_effect=cancel_at_validation):
            report = child.finish(cancelled=cancelled)
        self.assertTrue(report['child_retired'] and report['ipc_cleanup_complete'], report)
        self.assertFalse(report['verified'])
        self.assertEqual(report['reason'], 'cancelled')
        self.assertIsNone(report['result'])

    def test_watchdog_join_error_does_not_skip_independent_ipc_cleanup(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        self.go(child)
        actual_join = threading.Thread.join
        def joined_then_error(thread, timeout=None):
            actual_join(thread, timeout)
            raise RuntimeError('injected after actual join')
        with patch.object(threading.Thread, 'join', new=joined_then_error):
            report = child.finish()
        self.assertTrue(report['child_retired'])
        self.assertFalse(report['verified'] or report['ipc_cleanup_complete'])
        self.assertTrue(child.child.stdout.closed and child.child.stderr.closed and child._control.closed)
        self.assertIsNone(child._input_fd)

    def test_final_ipc_close_error_detaches_reused_fd_and_retains_uncertainty(self):
        value, fd, _ = self.input_file(self.fixture('pages-1.pdf'))
        child = self.start(value, fd)
        child_fd = child._input_fd
        actual_close = os.close
        reused = []
        def close_then_error(number):
            actual_close(number)
            if number == child_fd and not reused:
                replacement = os.open('/dev/null', os.O_RDONLY)
                if replacement != number:
                    os.dup2(replacement, number)
                    actual_close(replacement)
                reused.append(number)
                raise OSError('injected after real descriptor close')
        self.go(child)
        try:
            with patch.object(receiver.os, 'close', side_effect=close_then_error):
                report = child.finish()
            self.assertTrue(report['child_retired'])
            self.assertFalse(report['verified'] or report['ipc_cleanup_complete'])
            self.assertIsNone(child._input_fd)
            again = child.stop()
            self.assertFalse(again['ipc_cleanup_complete'])
            self.assertEqual(os.read(reused[0], 1), b'')  # The reused integer was never closed again.
        finally:
            for number in reused:
                actual_close(number)

    def test_stored_readback_spool_to_actual_parser_retains_lock_until_wait(self):
        body = self.fixture('pages-1.pdf')
        cert, key = certificate(self.root)
        transfer_bundle = transfer.capture_bundle(self.root)
        self.bundles.append(transfer_bundle)
        base = self.root / 'spools'
        base.mkdir(mode=0o700)
        options = dict(guardian_uid=os.getuid(), guardian_gid=os.getgid(), producer_uid=os.getuid(), producer_gid=os.getgid())
        reservation = str(uuid.uuid4())
        claims = [str(uuid.uuid4()) for _ in range(3)]
        source_identity = dict(reservation_id=reservation, claim_id=claims[0], purpose='source_download')
        read_identity = dict(reservation_id=reservation, claim_id=claims[2], purpose='stored_readback')

        def transfer_action(value, *, fd=None, producer=None):
            try:
                child = transfer.OriginalSession(transfer_bundle, value, input_fd=fd)
            except transfer.SessionStartError as error:
                self.children.append(error.session)
                raise
            self.children.append(child)
            try:
                child.go(clock_ns() + 5_000_000_000)
                report = child.finish(producer=producer)
                self.assertTrue(report['complete'], report)
                return report
            finally:
                if not child.stop()['child_retired']:
                    type(self).unresolved = True
                    self.temp._finalizer.detach()
                    raise AssertionError('unresolved transfer child')

        with OriginalServer(cert, key, body=body) as server:
            value = transfer_input(server.fixture, reservation=reservation)
            binding = dict(source_identity, attempt_id=value['attempt_id'], request_sha256=value['request_sha256'],
                           binding_sha256='c' * 64, capture_sha256='d' * 64)
            with spool.OriginalSpool(base, source_identity, **options) as source:
                directory = source.prepare(allow_fixture)
                try:
                    with spool.Producer(directory, binding) as producer:
                        download = transfer_action(value, producer=producer)
                        completion = producer.finish(spool_facts(download['result']))
                    source_descriptor = source.seal(binding, completion, allow_fixture)
                finally:
                    os.close(directory)
                upload = transfer_input(server.fixture, 'original_upload', body, reservation)
                upload['request']['input_spool_sha256'] = digest(source_descriptor)
                with source.open_sealed(source_descriptor, allow_fixture) as fd:
                    transfer_action(upload, fd=fd)
                inventory = source.capture_cleanup(binding, allow_fixture)
                source.retire_slots(inventory, allow_fixture)
            reread = transfer_input(server.fixture, 'original_readback', body, reservation)
            binding = dict(read_identity, attempt_id=reread['attempt_id'], request_sha256=reread['request_sha256'],
                           binding_sha256='e' * 64, capture_sha256='f' * 64)
            with spool.OriginalSpool(base, read_identity, **options) as readback:
                directory = readback.prepare(allow_fixture)
                try:
                    with spool.Producer(directory, binding) as producer:
                        report = transfer_action(reread, producer=producer)
                        completion = producer.finish(spool_facts(report['result']))
                    stored_descriptor = readback.seal(binding, completion, allow_fixture)
                finally:
                    os.close(directory)
                with readback.open_sealed(stored_descriptor, allow_fixture) as fd:
                    child = self.start(fixture_input(self.bundle, stored_descriptor), fd)
                    self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)
                    with self.assertRaisesRegex(ValueError, 'spool_reader_open'):
                        readback.capture_cleanup(binding, allow_fixture)
                    self.go(child)
                    result = child.finish()
                    self.assertTrue(result['verified'], result)
                    self.assertEqual(result['result']['parser_result']['sha256'], digest(body))
                    self.assertEqual(result['result']['parser_result']['pages'], 1)
                    self.assertNotEqual(json.loads(stored_descriptor)['claim_id'], json.loads(source_descriptor)['claim_id'])
                # Fixture retirement only after exact verifier wait and release
                # of the caller's still-held reader context.
                inventory = readback.capture_cleanup(binding, allow_fixture)
                readback.retire_slots(inventory, allow_fixture)
            self.assertEqual(server.connections, 3)


if __name__ == '__main__':
    unittest.main()

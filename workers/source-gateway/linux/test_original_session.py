"""Portable loopback/pipe tests, not SQL or Linux retirement admission evidence.

Production sources are never edited. Adversarial children below are separately
captured test-owned module bytes, and synthetic spool validators are explicit.
The parent test operator runs this suite; it opens no non-loopback destination.
"""
import copy
import fcntl
import hashlib
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

import original_session as session
import original_spool as spool
from original_tls_fixture import OriginalServer, certificate
from original_transport import spool_facts
from protocol import Refused, canonical, clock_ns, digest


def allow_fixture(*_args):
    """Injected trusted boundary for portable mechanics; not real evidence."""


def transfer_input(fixture, stage='original_download', body=None, reservation=None):
    reservation = reservation or str(uuid.uuid4())
    uploading = stage == 'original_upload'
    request = {'version': 1, 'kind': stage, 'job_id': str(uuid.uuid4()), 'reservation_id': reservation,
               'source_id': '1706.03762', 'source_revision': 1, 'bucket': 'paper-assets',
               'path': 'originals/' + reservation + '/original.pdf',
               'predecessor_operation_id': str(uuid.uuid4()), 'predecessor_result_sha256': '1' * 64,
               'candidate_sha256': None if body is None else digest(body),
               'candidate_bytes': None if body is None else len(body),
               'input_spool_sha256': '2' * 64 if uploading else None,
               'byte_ceiling': len(body) if uploading else session.MAX_BINARY,
               'verification_profile_id': str(uuid.uuid4()), 'stage_recipe_sha256': '3' * 64,
               'build_sha256': '4' * 64, 'parser_profile_sha256': '5' * 64,
               'verifier_host_policy_sha256': '6' * 64, 'storage_policy_sha256': '7' * 64,
               'spool_policy_sha256': '8' * 64}
    return {'format': 'original-transfer-input-v1', 'local_fixture_only': True,
            'attempt_id': str(uuid.uuid4()), 'request': request, 'request_sha256': '9' * 64,
            'fixture': dict(fixture), 'useful_ms': 5000, 'close_ms': 0}


class Sink:
    def __init__(self):
        self.count, self.hasher, self.largest = 0, hashlib.sha256(), 0

    def append(self, raw):
        if type(raw) is not bytes or not 0 < len(raw) <= session.CHUNK:
            raise AssertionError('invalid binary callback chunk')
        self.count += len(raw)
        self.hasher.update(raw)
        self.largest = max(self.largest, len(raw))


# Deliberately finite fake result used only by adversarial captured children.
FAKE_START = '''import os,sys,time
import frozen_context
from protocol import canonical,decode,digest
def emit(value): os.write(1,canonical(value)+b'\\n')
def main():
 value=decode(sys.stdin.buffer.readline())
 ready={'format':'original-transfer-ready-v1','attempt_id':value['attempt_id'],
  'input_sha256':digest(canonical(value)),'bundle_sha256':frozen_context.bundle_sha256,'process_id':os.getpid()}
 emit(ready)
 go=decode(sys.stdin.buffer.readline()); assert sys.stdin.buffer.read()==b''
'''
FAKE_RESULT = '''
 result={'format':'original-transfer-result-v1','local_fixture_only':True,'attempt_id':value['attempt_id'],
  'request_sha256':value['request_sha256'],'input_sha256':digest(canonical(value)),'stage':value['request']['kind'],
  'kind':'complete','reason':None,'status':200,'framing':'content_length','framing_complete':True,
  'body_bytes':len(body),'body_sha256':digest(body),'binary_bytes':len(body),'sent_bytes':0,'upload_ack_sha256':None,
  'protocol_bytes_received':len(body)+100,'tls_peer_close':'not_observed','retry_after_seconds':0,
  'retry_after_kind':'absent','local_cleanup':{'http_file_closed':True,'socket_closed':True},'elapsed_ms':0}
'''


class OriginalSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.unresolved_child = False
        cls.shared = tempfile.TemporaryDirectory(prefix='.timestep-original-session-shared-', dir=Path.home())
        cls.cert, cls.key = certificate(cls.shared.name)
        cls.bundle = session.capture_bundle(cls.shared.name)

    @classmethod
    def tearDownClass(cls):
        if cls.unresolved_child:
            cls.shared._finalizer.detach()
            return
        os.chmod(cls.bundle.root, 0o700)
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.timestep-original-session-', dir=Path.home())
        self.root = Path(self.temp.name)
        (self.root / 'spools').mkdir(mode=0o700)
        self.children, self.bundles = [], []
        self.body = b'%PDF-1.7\n' + b'original portable fixture\n' * 3000

    def tearDown(self):
        for child in self.children:
            report = child.stop()
            if not report['child_retired']:
                # A failure must not unlink bytes while a retained child may
                # still own them. Leave the exact test-owned directory behind.
                type(self).unresolved_child = True
                self.temp._finalizer.detach()
                raise AssertionError('unresolved exact fixture child; files retained')
        for bundle in self.bundles:
            os.chmod(bundle.root, 0o700)
        self.temp.cleanup()

    def start(self, value, *, bundle=None, input_fd=None):
        try:
            child = session.OriginalSession(bundle or self.bundle, value, input_fd=input_fd)
        except session.SessionStartError as error:
            self.children.append(error.session)
            raise
        self.children.append(child)
        return child

    def go(self, child, milliseconds=None):
        child.go(clock_ns() + (milliseconds or child.value['useful_ms']) * 1_000_000)

    def fake_bundle(self, child_source):
        """Capture adversarial test bytes without mutating real source/bundles."""
        sources = self.root / ('source-' + uuid.uuid4().hex)
        linux = sources / 'linux'
        linux.mkdir(parents=True, mode=0o700)
        original = Path(session.__file__).resolve().parent
        for name in session.FILES:
            parent = original.parent if name in ('protocol.py', 'transport.py') else original
            destination = sources if name in ('protocol.py', 'transport.py') else linux
            (destination / name).write_bytes(child_source.encode() if name == 'original_child.py' else (parent / name).read_bytes())
        with patch.object(session, '__file__', str(linux / 'original_session.py')):
            bundle = session.capture_bundle(self.root)
        self.bundles.append(bundle)
        return bundle, sources

    def test_maximum_download_ready_owns_input_binary_is_bounded_and_waited(self):
        body = b'p' * session.MAX_BINARY
        with OriginalServer(self.cert, self.key, body=body) as server:
            value = transfer_input(server.fixture)
            expected = copy.deepcopy(value)
            child = self.start(value)
            self.assertEqual(server.connections, 0)
            self.assertFalse(child.sent_go)
            value['request']['source_id'] = 'changed'
            value['fixture']['port'] = 1
            self.assertEqual(child.value, expected)
            self.go(child)
            sink = Sink()
            report = child.finish(producer=sink)
            self.assertTrue(report['complete'], report)
            self.assertTrue(report['binary_eof'] and report['child_retired'])
            self.assertEqual(report['returncode'], 0)
            self.assertEqual(report['retirement_witness'], 'exact_child_wait')
            self.assertEqual(report['binary_bytes'], len(body))
            self.assertEqual(report['binary_sha256'], digest(body))
            self.assertEqual((sink.count, sink.hasher.hexdigest()), (len(body), digest(body)))
            self.assertLessEqual(sink.largest, 65536)
            self.assertEqual(server.connections, 1)
            self.assertEqual(child.finish(producer=sink), report)
            self.assertEqual(sink.count, len(body))
            with self.assertRaises(Refused):
                self.go(child)

    def test_bundle_graph_runtime_pins_and_workspace_changes_are_not_child_imports(self):
        self.assertEqual(set(self.bundle.manifest['files']), set(session.FILES))
        self.assertEqual(len(self.bundle.manifest['python_sha256']), 64)
        self.assertEqual(self.bundle.manifest['shared_clock'], session.clock_name())
        self.assertEqual(set(path.name for path in self.bundle.root.iterdir()), set(session.FILES) | {'bundle.json', 'bootstrap.py'})
        self.assertEqual(self.bundle.root.stat().st_mode & 0o777, 0o500)
        for name, facts in self.bundle.manifest['files'].items():
            raw = (self.bundle.root / name).read_bytes()
            self.assertEqual(facts, {'bytes': len(raw), 'sha256': digest(raw)})
            self.assertEqual((self.bundle.root / name).stat().st_mode & 0o777, 0o400)
        original_child = Path(session.__file__).with_name('original_child.py').read_text()
        bundle, source = self.fake_bundle(original_child)
        for path in source.rglob('*.py'):
            path.write_text('raise RuntimeError("mutable workspace must never execute")\n')
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            child = self.start(transfer_input(server.fixture), bundle=bundle)
            self.go(child)
            self.assertTrue(child.finish(producer=Sink())['complete'])

    def test_tampered_captured_module_refuses_before_process_spawn(self):
        bundle, _ = self.fake_bundle(Path(session.__file__).with_name('original_child.py').read_text())
        path = bundle.root / 'original_child.py'
        path.chmod(0o600)
        path.write_bytes(path.read_bytes() + b'\n# changed after capture\n')
        path.chmod(0o400)
        with OriginalServer(self.cert, self.key, body=self.body) as server, patch.object(session.subprocess, 'Popen') as spawn:
            with self.assertRaisesRegex(Refused, 'bundle_changed'):
                self.start(transfer_input(server.fixture), bundle=bundle)
            spawn.assert_not_called()
            self.assertEqual(server.connections, 0)

    def test_pre_go_cancellation_expiry_and_identity_change_never_connect(self):
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            child = self.start(transfer_input(server.fixture))
            cancelled = threading.Event()
            cancelled.set()
            with self.assertRaisesRegex(Refused, 'cancelled'):
                child.go(clock_ns() + 1_000_000_000, cancelled=cancelled)
            with self.assertRaisesRegex(Refused, 'deadline'):
                child.go(clock_ns() - 1)
            with patch.object(session, 'process_identity', return_value=dict(child.identity, process_start_id='changed')):
                with self.assertRaisesRegex(Refused, 'child_identity_changed'):
                    self.go(child)
            self.assertFalse(child.sent_go)
            self.assertTrue(child.stop()['child_retired'])
            self.assertEqual(server.connections, 0)

    def test_wrong_execution_or_trailing_go_bytes_refuse_before_network(self):
        for wrong_id, extra in ((True, b''), (False, b'{}\n')):
            with self.subTest(wrong_id=wrong_id), OriginalServer(self.cert, self.key, body=self.body) as server:
                child = self.start(transfer_input(server.fixture))
                deadline = clock_ns() + 1_000_000_000
                message = {'format': 'original-transfer-go-v1', 'execution_id': str(uuid.uuid4()) if wrong_id else child.value['attempt_id'],
                           'input_sha256': child.input_sha256, 'bundle_sha256': self.bundle.sha256, 'deadline_ns': str(deadline)}
                # Test-owned protocol corruption; the production go() never
                # emits either variant or exposes arbitrary execution IDs.
                child.sent_go, child._deadline_ns = True, deadline
                child._write(canonical(message) + b'\n' + extra, session.clock() + 1)
                child.child.stdin.close()
                report = child.finish(producer=Sink())
                self.assertFalse(report['complete'])
                self.assertTrue(report['child_retired'])
                self.assertEqual(server.connections, 0)

    def test_upload_then_stored_read_exact_ack_no_binary_upload(self):
        path = self.root / 'candidate.pdf'
        path.write_bytes(self.body)
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            value = transfer_input(server.fixture, 'original_upload', self.body)
            with path.open('rb') as payload:
                child = self.start(value, input_fd=payload.fileno())
                self.assertEqual(server.connections, 0)
                self.go(child)
                uploaded = child.finish()
                self.assertTrue(uploaded['complete'], uploaded)
                self.assertEqual(uploaded['binary_bytes'], 0)
                self.assertEqual(uploaded['result']['sent_bytes'], len(self.body))
                self.assertEqual(uploaded['result']['status'], 201)
                self.assertEqual(uploaded['result']['upload_ack_sha256'], uploaded['result']['body_sha256'])
                self.assertEqual(payload.tell(), 0)
            self.assertEqual(server.objects[value['request']['path']], self.body)
            reread = self.start(transfer_input(server.fixture, 'original_readback', self.body, value['request']['reservation_id']))
            self.go(reread)
            stored = reread.finish(producer=Sink())
            self.assertTrue(stored['complete'], stored)
            self.assertEqual(stored['binary_sha256'], digest(self.body))
            self.assertEqual(server.connections, 2)

    def test_upload_input_is_not_read_until_go_and_writable_descriptors_refuse(self):
        path = self.root / 'candidate.pdf'
        path.write_bytes(b'x' * len(self.body))  # Same length, intentionally wrong hash.
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            value = transfer_input(server.fixture, 'original_upload', self.body)
            with path.open('rb') as payload:
                child = self.start(value, input_fd=payload.fileno())
                self.assertTrue(child._ready)
                self.assertEqual(server.connections, 0)
                self.go(child)
                report = child.finish()
                self.assertFalse(report['complete'])
                self.assertEqual(report['result']['reason'], 'input_mismatch')
                self.assertTrue(report['child_retired'])
                self.assertEqual(server.connections, 0)
            with path.open('r+b') as payload, patch.object(session.subprocess, 'Popen') as spawn:
                with self.assertRaisesRegex(Refused, 'invalid_descriptor'):
                    self.start(value, input_fd=payload.fileno())
                spawn.assert_not_called()

    def test_committed_upload_with_lost_or_wrong_ack_is_not_completion_or_retry(self):
        path = self.root / 'candidate.pdf'
        path.write_bytes(self.body)
        for fault in ('commit_then_drop_ack', 'wrong_ack_hash'):
            with self.subTest(fault=fault), OriginalServer(self.cert, self.key, body=self.body, fault=fault) as server:
                value = transfer_input(server.fixture, 'original_upload', self.body)
                with path.open('rb') as payload:
                    child = self.start(value, input_fd=payload.fileno())
                    self.go(child)
                    report = child.finish()
                self.assertFalse(report['complete'], report)
                self.assertTrue(report['child_retired'])
                self.assertEqual(report['result']['kind'], 'uncertain')
                self.assertIsNone(report['result']['upload_ack_sha256'])
                self.assertEqual(server.objects[value['request']['path']], self.body)
                self.assertEqual(server.connections, 1)
                self.assertEqual(child.finish(), report)

    def test_truncated_stored_read_retains_partial_bytes_and_unknown_body(self):
        body = b'%PDF-1.7\n' + b'p' * (4 * session.CHUNK)
        path = self.root / 'candidate.pdf'
        path.write_bytes(body)
        with OriginalServer(self.cert, self.key, body=body, fault='truncated_readback') as server:
            value = transfer_input(server.fixture, 'original_upload', body)
            with path.open('rb') as payload:
                upload = self.start(value, input_fd=payload.fileno())
                self.go(upload)
                self.assertTrue(upload.finish()['complete'])
            read = self.start(transfer_input(server.fixture, 'original_readback', body, value['request']['reservation_id']))
            self.go(read)
            sink = Sink()
            report = read.finish(producer=sink)
            self.assertFalse(report['complete'], report)
            self.assertTrue(report['child_retired'] and report['binary_eof'])
            self.assertGreater(sink.count, 0)
            self.assertLess(sink.count, len(body))
            self.assertEqual(report['binary_bytes'], sink.count)
            self.assertEqual(report['result']['kind'], 'uncertain')
            self.assertIsNone(report['result']['body_bytes'])
            self.assertIsNone(report['result']['body_sha256'])
            self.assertEqual(server.connections, 2)

    def test_framed_non_200_retains_status_but_cannot_finish_a_spool(self):
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            read = self.start(transfer_input(server.fixture, 'original_readback', self.body))
            self.go(read)
            sink = Sink()
            report = read.finish(producer=sink)
            self.assertFalse(report['complete'])
            self.assertEqual(report['outcome'], 'http_status')
            self.assertEqual(report['result']['status'], 404)
            self.assertTrue(report['result']['framing_complete'])
            self.assertTrue(report['child_retired'] and report['binary_eof'])
            self.assertEqual(sink.count, 0)
            with self.assertRaises(Refused):
                spool_facts(report['result'])

    def test_real_producer_partial_and_cancellation_never_seal_or_cleanup(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel), OriginalServer(self.cert, self.key, body=self.body) as server:
                value = transfer_input(server.fixture)
                identity = {'reservation_id': value['request']['reservation_id'], 'claim_id': str(uuid.uuid4()), 'purpose': 'source_download'}
                binding = dict(identity, attempt_id=value['attempt_id'], request_sha256=value['request_sha256'],
                               binding_sha256='a' * 64, capture_sha256='b' * 64)
                action = spool.OriginalSpool(self.root / 'spools', identity, guardian_uid=os.getuid(), guardian_gid=os.getgid(),
                                             producer_uid=os.getuid(), producer_gid=os.getgid())
                with action:
                    directory = action.prepare(allow_fixture)
                    try:
                        with spool.Producer(directory, binding) as producer:
                            child = self.start(value)
                            self.go(child)
                            cancelled = threading.Event()
                            append = producer.append
                            def interrupted(raw):
                                append(raw[:100])
                                if cancel:
                                    cancelled.set()
                                else:
                                    raise OSError('synthetic disk-full text must not reach report')
                            with patch.object(producer, 'append', side_effect=interrupted):
                                report = child.finish(producer=producer, cancelled=cancelled)
                            self.assertFalse(report['complete'])
                            self.assertEqual(report['outcome'], 'cancelled' if cancel else 'append_failed')
                            self.assertTrue(report['child_retired'])
                            self.assertGreater(producer.count, 0)
                            self.assertFalse(producer.finished)
                            self.assertNotIn('disk-full', canonical(report).decode())
                        self.assertGreater(os.stat('payload.pending', dir_fd=directory).st_size, 0)
                        with self.assertRaises(FileNotFoundError):
                            os.stat('payload', dir_fd=directory)
                    finally:
                        os.close(directory)

    def test_complete_real_producer_requires_explicit_finish_after_join(self):
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            value = transfer_input(server.fixture)
            identity = {'reservation_id': value['request']['reservation_id'], 'claim_id': str(uuid.uuid4()), 'purpose': 'source_download'}
            binding = dict(identity, attempt_id=value['attempt_id'], request_sha256=value['request_sha256'],
                           binding_sha256='a' * 64, capture_sha256='b' * 64)
            with spool.OriginalSpool(self.root / 'spools', identity, guardian_uid=os.getuid(), guardian_gid=os.getgid(),
                                     producer_uid=os.getuid(), producer_gid=os.getgid()) as action:
                directory = action.prepare(allow_fixture)
                try:
                    with spool.Producer(directory, binding) as producer:
                        child = self.start(value)
                        self.go(child)
                        report = child.finish(producer=producer)
                        self.assertTrue(report['complete'], report)
                        self.assertFalse(producer.finished)
                        with self.assertRaises(FileNotFoundError):
                            os.stat('payload', dir_fd=directory)
                        completion = producer.finish(spool_facts(report['result']))
                        self.assertIn(b'original-transfer-complete-v1', completion)
                    self.assertEqual(os.stat('payload', dir_fd=directory).st_size, len(self.body))
                finally:
                    os.close(directory)

    def test_download_seal_upload_cleanup_then_fresh_stored_readback(self):
        """Actual portable process/file chain, with synthetic guardian gates.

        Request hashes and predecessor IDs here are authored fixtures, not SQL
        grants. Exact child waits do not assert cgroup or remote write closure.
        """
        body = b'%PDF-1.7\n' + b'p' * (session.MAX_BINARY - 9)
        reservation = str(uuid.uuid4())
        claims = [str(uuid.uuid4()) for _ in range(3)]
        source_identity = {'reservation_id': reservation, 'claim_id': claims[0], 'purpose': 'source_download'}
        read_identity = {'reservation_id': reservation, 'claim_id': claims[2], 'purpose': 'stored_readback'}
        options = {'guardian_uid': os.getuid(), 'guardian_gid': os.getgid(),
                   'producer_uid': os.getuid(), 'producer_gid': os.getgid()}
        base = self.root / 'workflow-spools'
        base.mkdir(mode=0o700)
        def action(identity):
            return spool.OriginalSpool(base, identity, **options)
        with OriginalServer(self.cert, self.key, body=body) as server:
            source_value = transfer_input(server.fixture, reservation=reservation)
            source_binding = dict(source_identity, attempt_id=source_value['attempt_id'],
                                  request_sha256=source_value['request_sha256'], binding_sha256='a' * 64,
                                  capture_sha256='b' * 64)
            with action(source_identity) as source:
                directory = source.prepare(allow_fixture)
                try:
                    with spool.Producer(directory, source_binding) as producer:
                        download = self.start(source_value)
                        self.go(download)
                        downloaded = download.finish(producer=producer)
                        self.assertTrue(downloaded['complete'] and downloaded['child_retired'], downloaded)
                        completion = producer.finish(spool_facts(downloaded['result']))
                    source_descriptor = source.seal(source_binding, completion, allow_fixture)
                    candidate = spool.descriptor(source_descriptor)
                    self.assertEqual((candidate['bytes'], candidate['sha256']), (len(body), digest(body)))
                finally:
                    os.close(directory)

            # The first guardian has released its lock; this refuses because
            # the source slots actually remain, not merely lock contention.
            with self.assertRaisesRegex(ValueError, 'spool_reservation_occupied'):
                with action(read_identity):
                    self.fail('readback allocated before source-slot retirement')

            upload_value = transfer_input(server.fixture, 'original_upload', body, reservation)
            upload_value['request_sha256'] = 'a' * 64
            upload_value['request'].update(job_id=source_value['request']['job_id'],
                                           predecessor_operation_id=claims[0],
                                           input_spool_sha256=digest(source_descriptor))
            with action(source_identity) as source:
                with source.open_sealed(source_descriptor, allow_fixture) as fd:
                    self.assertEqual(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY)
                    upload = self.start(upload_value, input_fd=fd)
                    self.go(upload)
                    uploaded = upload.finish()
                    self.assertTrue(uploaded['complete'] and uploaded['child_retired'], uploaded)
                    self.assertEqual(uploaded['result']['status'], 201)
                    self.assertEqual(uploaded['result']['sent_bytes'], candidate['bytes'])
                    self.assertEqual(server.objects[upload_value['request']['path']], body)
                    with self.assertRaisesRegex(ValueError, 'spool_reader_open'):
                        source.capture_cleanup(source_binding, allow_fixture)
                captured = source.capture_cleanup(source_binding, allow_fixture)
                # This durable checkpoint records only the local synthetic
                # fixture's cleanup intent. It is not a database receipt.
                checkpoint = self.root / 'workflow-source-cleanup.json'
                fd = os.open(checkpoint, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                try:
                    with os.fdopen(fd, 'wb', closefd=False) as output:
                        output.write(captured)
                        output.flush()
                        os.fsync(fd)
                finally:
                    os.close(fd)
                parent = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(parent)
                finally:
                    os.close(parent)
                def fixture_settled(_inventory):
                    self.assertEqual(checkpoint.read_bytes(), captured)
                    self.assertTrue(downloaded['child_retired'] and uploaded['child_retired'])
                    self.assertTrue(uploaded['complete'])
                    self.assertIsNotNone(uploaded['result']['upload_ack_sha256'])
                source.retire_slots(captured, fixture_settled)
                self.assertEqual(set(os.listdir(source.reservation)), {'publication.lock'})

            read_value = transfer_input(server.fixture, 'original_readback', body, reservation)
            read_value['request_sha256'] = 'b' * 64
            read_value['request'].update(job_id=source_value['request']['job_id'], predecessor_operation_id=claims[1])
            read_binding = dict(read_identity, attempt_id=read_value['attempt_id'],
                                request_sha256=read_value['request_sha256'], binding_sha256='c' * 64,
                                capture_sha256='d' * 64)
            with action(read_identity) as readback:
                directory = readback.prepare(allow_fixture)
                try:
                    with spool.Producer(directory, read_binding) as producer:
                        read = self.start(read_value)
                        self.go(read)
                        reread = read.finish(producer=producer)
                        self.assertTrue(reread['complete'] and reread['child_retired'], reread)
                        completion = producer.finish(spool_facts(reread['result']))
                    verified_descriptor = readback.seal(read_binding, completion, allow_fixture)
                    actual = spool.descriptor(verified_descriptor)
                    self.assertEqual((actual['bytes'], actual['sha256']), (candidate['bytes'], candidate['sha256']))
                    self.assertEqual((actual['bytes'], actual['sha256']), (len(body), digest(body)))
                    self.assertNotEqual(actual['claim_id'], candidate['claim_id'])
                    self.assertNotEqual(actual['attempt_id'], candidate['attempt_id'])
                finally:
                    os.close(directory)
            self.assertEqual(len(set(claims)), 3)
            self.assertEqual(len({child.value['attempt_id'] for child in (download, upload, read)}), 3)
            self.assertEqual(len({tuple(sorted(child.identity.items())) for child in (download, upload, read)}), 3)
            self.assertEqual(server.connections, 3)

    def test_binary_eof_without_result_and_result_without_join_are_not_success(self):
        behaviors = (
            " body=b'partial'; os.write(frozen_context.data_fd,body); os.close(frozen_context.data_fd); return 0\n",
            " body=b'complete'; os.write(frozen_context.data_fd,body); os.close(frozen_context.data_fd)\n"
            + FAKE_RESULT + " emit(result); time.sleep(60); return 0\n",
        )
        for i, behavior in enumerate(behaviors):
            with self.subTest(kind=i), OriginalServer(self.cert, self.key, body=self.body) as server:
                bundle, _ = self.fake_bundle(FAKE_START + behavior)
                value = transfer_input(server.fixture)
                value['useful_ms'] = 250
                child = self.start(value, bundle=bundle)
                self.go(child)
                sink = Sink()
                report = child.finish(producer=sink)
                self.assertFalse(report['complete'])
                self.assertTrue(report['binary_eof'] and report['child_retired'])
                self.assertEqual(report['outcome'], 'invalid_output' if i == 0 else 'deadline')
                self.assertGreater(sink.count, 0)
                self.assertEqual(server.connections, 0)

    def test_result_hash_mismatch_and_stderr_never_publish_raw_diagnostics(self):
        behaviors = (
            " body=b'bytes'; os.write(frozen_context.data_fd,body); os.close(frozen_context.data_fd)\n"
            + FAKE_RESULT + " result['body_sha256']='0'*64; emit(result); return 0\n",
            " os.write(2,b'private-provider-text'); os.close(frozen_context.data_fd); return 0\n",
        )
        for i, behavior in enumerate(behaviors):
            with self.subTest(kind=i), OriginalServer(self.cert, self.key, body=self.body) as server:
                bundle, _ = self.fake_bundle(FAKE_START + behavior)
                child = self.start(transfer_input(server.fixture), bundle=bundle)
                self.go(child)
                report = child.finish(producer=Sink())
                self.assertFalse(report['complete'])
                self.assertEqual(report['outcome'], 'invalid_output' if i == 0 else 'child_stderr')
                self.assertTrue(report['child_retired'])
                self.assertNotIn('private-provider-text', canonical(report).decode())
                self.assertIsNone(report['result'])

    def test_setup_failure_keeps_exact_handle_until_waited(self):
        original_set = os.set_blocking
        calls = []
        def fail_after_spawn(fd, blocking):
            calls.append(fd)
            # First two calls set the binary pipe. Third is live child stdin.
            if len(calls) == 4:
                raise OSError('injected child pipe setup failure')
            return original_set(fd, blocking)
        with OriginalServer(self.cert, self.key, body=self.body) as server:
            with patch.object(session.os, 'set_blocking', side_effect=fail_after_spawn):
                with self.assertRaises(session.SessionStartError) as caught:
                    self.start(transfer_input(server.fixture))
            child = caught.exception.session
            self.assertFalse(child.sent_go)
            self.assertTrue(child.stop()['child_retired'])
            self.assertEqual(server.connections, 0)

    def test_postspawn_data_close_error_preserves_child_and_never_recloses_reused_fd(self):
        actual_spawn, actual_close = session.subprocess.Popen, os.close
        captured = {}
        def spawn(*args, **kwargs):
            child = actual_spawn(*args, **kwargs)
            captured.update(child=child, data_fd=kwargs['pass_fds'][0])
            return child
        def close_after_release(fd):
            if fd == captured.get('data_fd') and 'reused' not in captured:
                actual_close(fd)
                reused = os.open('/dev/null', os.O_RDONLY)
                if reused != fd:
                    os.dup2(reused, fd)
                    actual_close(reused)
                captured['reused'] = fd
                raise OSError('synthetic error after raw descriptor release')
            return actual_close(fd)
        try:
            with OriginalServer(self.cert, self.key, body=self.body) as server:
                with patch.object(session.subprocess, 'Popen', side_effect=spawn), patch.object(session.os, 'close', side_effect=close_after_release):
                    with self.assertRaises(session.SessionStartError) as caught:
                        self.start(transfer_input(server.fixture))
                child = caught.exception.session
                self.assertIs(child.child, captured['child'])
                self.assertFalse(child.sent_go)
                report = child.stop()
                self.assertTrue(report['child_retired'])
                self.assertFalse(report['complete'] or report['ipc_cleanup_complete'])
                self.assertTrue(all(pipe.closed for pipe in (child.child.stdin, child.child.stdout, child.child.stderr)))
                self.assertIsNone(child._binary)
                # This integer now names a different, test-owned FD. Neither
                # setup cleanup nor repeated stop may close it as the old pipe.
                os.fstat(captured['reused'])
                child.stop()
                os.fstat(captured['reused'])
                self.assertEqual(server.connections, 0)
        finally:
            if 'reused' in captured:
                actual_close(captured['reused'])

    def test_all_pipe_closes_attempted_and_cached_wait_does_not_skip_held_object(self):
        events, reused = [], []
        child = stderr = None
        class CloseFault:
            def __init__(self, underlying, label, mode):
                self.underlying, self.label, self.mode = underlying, label, mode
                self.allow_close = False

            @property
            def closed(self):
                return self.underlying.closed

            def fileno(self):
                return self.underlying.fileno()

            def close(self):
                events.append(self.label)
                if self.mode == 'before' and not self.allow_close:
                    raise OSError('synthetic still-owned file object')
                old_fd = self.underlying.fileno()
                self.underlying.close()
                if self.mode == 'after':
                    fd = os.open('/dev/null', os.O_RDONLY)
                    if fd != old_fd:
                        os.dup2(fd, old_fd)
                        os.close(fd)
                    reused.append(old_fd)
                    raise OSError('synthetic error after file object release')
        try:
            with OriginalServer(self.cert, self.key, body=self.body) as server:
                child = self.start(transfer_input(server.fixture))
                stdout = CloseFault(child.child.stdout, 'stdout', 'after')
                stderr = CloseFault(child.child.stderr, 'stderr', 'before')
                child.child.stdout, child.child.stderr = stdout, stderr
                self.go(child)
                report = child.finish(producer=Sink())
                self.assertTrue(report['child_retired'])
                self.assertFalse(report['complete'] or report['ipc_cleanup_complete'])
                self.assertEqual(report['outcome'], 'ipc_cleanup_failed')
                self.assertIn('stdout', events)
                self.assertIn('stderr', events)
                self.assertTrue(stdout.closed)
                self.assertFalse(stderr.closed)
                self.assertEqual(events.count('stdout'), 1)
                for fd in reused:
                    os.fstat(fd)
                attempts = events.count('stderr')
                stderr.allow_close = True
                retried = child.stop()
                self.assertTrue(stderr.closed)
                self.assertGreater(events.count('stderr'), attempts)
                self.assertTrue(retried['child_retired'])
                # Later known-object cleanup cannot erase earlier ambiguity.
                self.assertFalse(retried['ipc_cleanup_complete'] or retried['complete'])
                self.assertEqual(events.count('stdout'), 1)
                for fd in reused:
                    os.fstat(fd)
        finally:
            if stderr is not None:
                stderr.allow_close = True
            if child is not None:
                child.stop()
            for fd in reused:
                os.close(fd)


if __name__ == '__main__':
    unittest.main()

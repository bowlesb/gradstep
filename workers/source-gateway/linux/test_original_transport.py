"""Actual loopback TLS/pipe tests; no live Storage or execution admission."""
import copy
import hashlib
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import original_transport as transfer
from original_tls_fixture import OriginalServer, certificate
from protocol import Refused, canonical, clock_ns, digest
from test_gateway import TLSServer


RESERVATION = 'bbbbbbbb-0000-4000-8000-000000000001'
ATTEMPT = 'bbbbbbbb-0000-4000-8000-000000000003'


def fixture_input(fixture, *, stage='original_download', body=None, ceiling=None):
    request = {
        'version': 1, 'kind': stage, 'job_id': 'bbbbbbbb-0000-4000-8000-000000000002',
        'reservation_id': RESERVATION, 'source_id': '1706.03762', 'source_revision': 1,
        'bucket': 'paper-assets', 'path': 'originals/' + RESERVATION + '/original.pdf',
        'predecessor_operation_id': 'bbbbbbbb-0000-4000-8000-000000000004',
        'predecessor_result_sha256': '1' * 64,
        'candidate_sha256': digest(body) if body is not None else None,
        'candidate_bytes': len(body) if body is not None else None,
        'input_spool_sha256': '2' * 64 if stage == 'original_upload' else None,
        'byte_ceiling': ceiling if ceiling is not None else len(body) if stage == 'original_upload' else transfer.MAX_BODY,
        'verification_profile_id': 'bbbbbbbb-0000-4000-8000-000000000005',
        'stage_recipe_sha256': '3' * 64, 'build_sha256': '4' * 64,
        'parser_profile_sha256': '5' * 64, 'verifier_host_policy_sha256': '6' * 64,
        'storage_policy_sha256': '7' * 64, 'spool_policy_sha256': '8' * 64,
    }
    return {'format': 'original-transfer-input-v1', 'local_fixture_only': True,
            'attempt_id': ATTEMPT, 'request': request, 'request_sha256': '9' * 64,
            'fixture': dict(fixture), 'useful_ms': 3000, 'close_ms': 100}


class OriginalTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='original-transfer-tests-')
        cls.root = Path(cls.temp.name)
        cls.cert, cls.key = certificate(cls.root)
        cls.ca = cls.cert.read_text()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def validate_report(self, result, value):
        raw = canonical(result)
        self.assertLessEqual(len(raw), transfer.MAX_OUTPUT)
        self.assertNotIn(b'body_base64', raw)
        self.assertEqual(transfer.checked_result(raw, value), result)
        self.assertTrue(all(result['local_cleanup'].values()))

    def receive(self, value, **options):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        received = {'count': 0, 'sha256': None, 'largest': 0, 'error': None, 'eof': False}

        def drain():
            hasher = hashlib.sha256()
            try:
                while True:
                    raw = os.read(read_fd, transfer.CHUNK)
                    if not raw:
                        received['eof'] = True
                        break
                    hasher.update(raw)
                    received['count'] += len(raw)
                    received['largest'] = max(received['largest'], len(raw))
                received['sha256'] = hasher.hexdigest()
            except BaseException as error:
                received['error'] = type(error).__name__
            finally:
                os.close(read_fd)

        reader = threading.Thread(target=drain, daemon=False)
        reader.start()
        try:
            result = transfer.perform(value, output_fd=write_fd, **options)
        finally:
            os.close(write_fd)
            reader.join(5)
        self.assertFalse(reader.is_alive())
        self.assertIsNone(received['error'])
        self.assertTrue(received['eof'])
        self.assertLessEqual(received['largest'], transfer.CHUNK)
        self.assertEqual(received['count'], result['binary_bytes'])
        self.validate_report(result, value)
        return result, received

    def raw_response(self, response, *, ceiling=transfer.MAX_BODY, ending='clean', useful_ms=3000, **options):
        with TLSServer(self.cert, self.key, response, ending=ending, **options) as server:
            value = fixture_input({'address': '127.0.0.1', 'port': server.port, 'ca_pem': self.ca}, ceiling=ceiling)
            value['useful_ms'] = useful_ms
            result, received = self.receive(value)
            self.assertEqual(server.connections, 1)
        return result, received

    def upload(self, server, body, *, value=None, seek=0):
        value = value or fixture_input(server.fixture, stage='original_upload', body=body)
        # Keep a test-owned path and pass ONLY its read-only descriptor.
        with tempfile.NamedTemporaryFile(dir=self.root) as named:
            named.write(body)
            named.flush()
            fd = os.open(named.name, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.lseek(fd, seek, os.SEEK_SET)
                result = transfer.perform(value, input_fd=fd)
                self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), seek)
                self.assertEqual(os.fstat(fd).st_size, len(body))
            finally:
                os.close(fd)
        self.validate_report(result, value)
        return result

    def test_maximum_download_streams_over_old_metadata_wire_ceiling(self):
        body = b'%PDF-1.7\n' + b'x' * (transfer.MAX_BODY - 9)
        with OriginalServer(self.cert, self.key, body=body) as server:
            value = fixture_input(server.fixture)
            result, received = self.receive(value)
            self.assertEqual(result['kind'], 'complete')
            self.assertEqual(received['sha256'], digest(body))
            self.assertEqual(received['count'], transfer.MAX_BODY)
            self.assertGreater(result['protocol_bytes_received'], 2_097_152)
            self.assertEqual(transfer.spool_facts(result), {'status': 200, 'framing': 'content-length',
                             'framing_complete': True, 'bytes': len(body), 'sha256': digest(body)})
            self.assertEqual([(r['method'], r['path']) for r in server.requests], [('GET', '/pdf/1706.03762v1')])

    def test_empty_200_is_complete_http_but_never_a_spool_candidate(self):
        result, received = self.raw_response(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(received['count'], 0)
        with self.assertRaises(Refused):
            transfer.spool_facts(result)

    def test_non_200_body_is_accounted_without_forwarding_pdf_bytes(self):
        result, received = self.raw_response(b'HTTP/1.1 429 Busy\r\nContent-Length: 4\r\nRetry-After: 5\r\n\r\nslow')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(result['body_sha256'], digest(b'slow'))
        self.assertEqual(result['retry_after_seconds'], 5)
        self.assertEqual(received['count'], 0)
        with self.assertRaises(Refused):
            transfer.spool_facts(result)

    def test_unsupported_retry_after_never_becomes_a_numeric_cooldown(self):
        result, _ = self.raw_response(b'HTTP/1.1 429 Busy\r\nContent-Length: 0\r\n'
                                      b'Retry-After: Fri, 31 Dec 2099 23:59:59 GMT\r\n\r\n')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(result['retry_after_kind'], 'unsupported')
        self.assertEqual(result['retry_after_seconds'], 0)

    def test_truncated_content_length_after_multiple_chunks_is_never_complete(self):
        body = b'x' * (3 * transfer.CHUNK + 17)
        for ending in ('clean', 'abrupt'):
            with self.subTest(ending=ending):
                response = f'HTTP/1.1 200 OK\r\nContent-Length: {len(body) + 1}\r\n\r\n'.encode() + body
                result, received = self.raw_response(response, ending=ending)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertIn(result['reason'], ('http_truncated', 'tls_truncated'))
                self.assertIsNone(result['body_sha256'])
                self.assertGreater(received['count'], transfer.CHUNK)

    def test_exact_ceiling_chunked_requires_terminal_chunk(self):
        body = b'x' * transfer.MAX_BODY
        head = b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        chunk = f'{len(body):x}\r\n'.encode() + body + b'\r\n'
        for terminal in (b'0\r\n\r\n', b''):
            with self.subTest(terminal=bool(terminal)):
                result, received = self.raw_response(head + chunk + terminal)
                self.assertEqual(received['count'], len(body))
                self.assertEqual(result['kind'], 'complete' if terminal else 'uncertain')
                if terminal:
                    self.assertEqual(transfer.spool_facts(result)['framing'], 'chunked')
                else:
                    self.assertIsNone(result['body_sha256'])

    def test_close_delimited_requires_clean_tls_and_honors_limit_plus_one(self):
        for ending, body, success in (('clean', b'x' * 1024, True), ('abrupt', b'x' * 1024, False),
                                      ('clean', b'x' * 1025, False)):
            with self.subTest(ending=ending, size=len(body)):
                result, _ = self.raw_response(b'HTTP/1.0 200 OK\r\n\r\n' + body, ceiling=1024, ending=ending)
                self.assertEqual(result['kind'], 'complete' if success else 'uncertain')
                if success:
                    self.assertEqual(transfer.spool_facts(result)['framing'], 'tls-close')
                else:
                    self.assertIsNone(result['body_sha256'])

    def test_declared_overflow_refuses_before_binary_delivery(self):
        result, received = self.raw_response(b'HTTP/1.1 200 OK\r\nContent-Length: 1025\r\n\r\n', ceiling=1024)
        self.assertEqual(result['reason'], 'body_limit')
        self.assertEqual(received['count'], 0)

    def test_redirect_encoding_ambiguous_framing_and_chunk_extensions_refuse(self):
        cases = (
            b'HTTP/1.1 302 Found\r\nLocation: https://other.invalid/\r\nContent-Length: 0\r\n\r\n',
            b'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nxx',
            b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nxx',
            b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n',
            b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;ext=1\r\nxx\r\n0\r\n\r\n',
            b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nxx\r\n0\r\nTrailer: no\r\n\r\n',
        )
        for response in cases:
            with self.subTest(prefix=response[:80]):
                result, _ = self.raw_response(response)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertIsNone(result['body_sha256'])

    def test_header_and_chunk_syntax_limits_remain_independent(self):
        cases = (
            b'HTTP/1.1 200 OK\r\n' + b'X: y\r\n' * 65 + b'\r\n',
            b'HTTP/1.1 200 OK\r\nX: ' + b'x' * 8192 + b'\r\n\r\n',
            b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + b'1\r\nx\r\n' * 22_000 + b'0\r\n\r\n',
        )
        for response in cases:
            with self.subTest(size=len(response)):
                result, _ = self.raw_response(response)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertIn(result['reason'], ('header_limit', 'protocol_limit'))

    def test_trailing_plaintext_is_rejected(self):
        result, _ = self.raw_response(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokextra')
        self.assertEqual(result['reason'], 'extra_protocol_data')
        self.assertIsNone(result['body_sha256'])

    def test_slow_tls_and_body_obey_the_same_absolute_deadline(self):
        for options in ({'handshake_delay': True}, {'body_delay': True}):
            with self.subTest(options=options):
                started = time.monotonic()
                result, _ = self.raw_response(b'', useful_ms=120, **options)
                self.assertEqual(result['reason'], 'deadline')
                self.assertLess(time.monotonic() - started, 1)

    def test_shared_absolute_deadline_shortens_a_longer_transport_allowance(self):
        with TLSServer(self.cert, self.key, b'', body_delay=True) as server:
            value = fixture_input({'address': '127.0.0.1', 'port': server.port, 'ca_pem': self.ca})
            result, _ = self.receive(value, absolute_deadline_ns=clock_ns() + 120_000_000)
            self.assertEqual(result['reason'], 'deadline')
            self.assertLess(result['elapsed_ms'], 750)

    def test_blocked_sink_stops_and_retains_exact_partial_pipe_count(self):
        body = b'x' * (3 * transfer.CHUNK)
        with OriginalServer(self.cert, self.key, body=body) as server:
            value = fixture_input(server.fixture)
            value['useful_ms'] = 150
            read_fd, write_fd = os.pipe()
            os.set_blocking(write_fd, False)
            try:
                result = transfer.perform(value, output_fd=write_fd)
                os.close(write_fd)
                write_fd = None
                count = 0
                while True:
                    raw = os.read(read_fd, transfer.CHUNK)
                    if not raw:
                        break
                    count += len(raw)
                self.assertEqual(result['reason'], 'deadline')
                self.assertEqual(result['binary_bytes'], count)
                self.assertGreater(count, 0)
                self.assertLess(count, len(body))
                self.validate_report(result, value)
            finally:
                os.close(read_fd)
                if write_fd is not None:
                    os.close(write_fd)

    def test_broken_sink_never_returns_complete_body(self):
        with OriginalServer(self.cert, self.key, body=b'pdf') as server:
            value = fixture_input(server.fixture)
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            os.set_blocking(write_fd, False)
            try:
                result = transfer.perform(value, output_fd=write_fd)
            finally:
                os.close(write_fd)
            self.assertEqual(result['kind'], 'uncertain')
            self.assertEqual(result['binary_bytes'], 0)
            self.validate_report(result, value)

    def test_invalid_pipe_modes_refuse_without_constructing_socket(self):
        read_fd, write_fd = os.pipe()
        with tempfile.TemporaryFile(dir=self.root) as file:
            try:
                value = fixture_input({'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca})
                for fd in (read_fd, write_fd, file.fileno()):
                    with self.subTest(fd=fd), patch.object(transfer.socket, 'socket') as socket:
                        with self.assertRaises(Refused):
                            transfer.perform(value, output_fd=fd)
                        socket.assert_not_called()
            finally:
                os.close(read_fd)
                os.close(write_fd)

    def test_request_rejects_nonloopback_unknown_fields_and_noncanonical_identity(self):
        base = fixture_input({'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca})
        changes = [('fixture', 'address', '192.0.2.1'), ('fixture', 'port', True),
                   ('request', 'source_id', '../../etc/passwd'), ('request', 'source_revision', True),
                   ('request', 'byte_ceiling', transfer.MAX_BODY + 1), ('request', 'version', True),
                   ('request', 'path', 'originals/other.pdf'), ('request', 'candidate_bytes', 1),
                   ('request', 'stage_recipe_sha256', 'A' * 64), ('request', 'kind', []),
                   ('request', 'extra', 'rejected')]
        for group, key, content in changes:
            value = copy.deepcopy(base)
            value[group][key] = content
            with self.subTest(group=group, key=key), patch.object(transfer.socket, 'socket') as socket:
                with self.assertRaises(Refused):
                    transfer.perform(value, output_fd=0)
                socket.assert_not_called()

    def test_no_proxy_or_resolver_is_used_and_sql_hash_is_opaque(self):
        with OriginalServer(self.cert, self.key, body=b'pdf') as server:
            value = fixture_input(server.fixture)
            self.assertNotEqual(value['request_sha256'], digest(canonical(value['request'])))
            with patch.dict(os.environ, {'HTTPS_PROXY': 'http://other.invalid:1', 'ALL_PROXY': 'http://other.invalid:1'}), \
                    patch.object(transfer.socket, 'getaddrinfo', side_effect=AssertionError('resolver called')):
                result, _ = self.receive(value)
            self.assertEqual(result['kind'], 'complete')
            self.assertEqual(result['request_sha256'], '9' * 64)

    def test_readonly_upload_uses_offset_independent_reads_and_exact_ack(self):
        body = b'%PDF-1.7\n' + b'x' * (transfer.MAX_BODY - 9)
        with OriginalServer(self.cert, self.key, body=b'') as server:
            result = self.upload(server, body, seek=73)
            self.assertEqual(result['kind'], 'complete')
            self.assertEqual(result['status'], 201)
            self.assertEqual(result['sent_bytes'], len(body))
            self.assertEqual(result['body_sha256'], result['upload_ack_sha256'])
            self.assertEqual(server.objects, {'originals/' + RESERVATION + '/original.pdf': body})
            self.assertEqual(len(server.requests), 1)
            self.assertEqual(server.requests[0]['method'], 'POST')

    def test_writable_or_nonregular_upload_fd_refuses_before_socket(self):
        read_fd, write_fd = os.pipe()
        try:
            with tempfile.TemporaryFile(dir=self.root) as file:
                value = fixture_input({'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca}, stage='original_upload', body=b'pdf')
                for fd in (file.fileno(), read_fd):
                    with self.subTest(fd=fd), patch.object(transfer.socket, 'socket') as socket:
                        with self.assertRaises(Refused):
                            transfer.perform(value, input_fd=fd)
                        socket.assert_not_called()
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_upload_wrong_length_and_hash_fail_before_connection(self):
        with OriginalServer(self.cert, self.key, body=b'') as server:
            for candidate in (b'longer', b'bad'):
                with self.subTest(candidate=candidate):
                    value = fixture_input(server.fixture, stage='original_upload', body=candidate)
                    result = self.upload(server, b'pdf', value=value)
                    self.assertEqual(result['reason'], 'input_mismatch')
                    self.assertEqual(result['sent_bytes'], 0)
            self.assertEqual(server.connections, 0)
            self.assertEqual(server.objects, {})

    def test_upload_changed_after_prehash_never_accepts_a_commit_ack(self):
        body = b'pdf' * transfer.CHUNK
        with OriginalServer(self.cert, self.key, body=b'') as server, tempfile.NamedTemporaryFile(dir=self.root) as named:
            named.write(body)
            named.flush()
            fd = os.open(named.name, os.O_RDONLY | os.O_NOFOLLOW)
            value = fixture_input(server.fixture, stage='original_upload', body=body)
            original = transfer._checked_file

            def mutate_after_prehash(input_fd, request, deadline):
                info = original(input_fd, request, deadline)
                os.pwrite(named.fileno(), b'X', 0)
                return info

            try:
                with patch.object(transfer, '_checked_file', side_effect=mutate_after_prehash):
                    result = transfer.perform(value, input_fd=fd)
            finally:
                os.close(fd)
            self.assertEqual(result['reason'], 'input_changed')
            self.assertEqual(result['sent_bytes'], len(body))
            self.assertIsNone(result['upload_ack_sha256'])
            self.validate_report(result, value)

    def test_cleanup_error_clears_previously_complete_body_and_upload_ack(self):
        original = transfer.StrictResponse.close
        for stage in ('original_download', 'original_upload'):
            failed = []

            def close_then_error(response):
                # HTTPResponse closes its input file while reading framed EOF.
                # Its explicit close() runs later, in perform's finally block,
                # after complete-body/ACK facts have already been assigned.
                original(response)
                if not failed:
                    failed.append(True)
                    raise OSError('synthetic final close failure')

            with self.subTest(stage=stage), OriginalServer(self.cert, self.key, body=b'pdf') as server:
                with patch.object(transfer.StrictResponse, 'close', close_then_error):
                    if stage == 'original_download':
                        result, _ = self.receive(fixture_input(server.fixture))
                    else:
                        result = self.upload(server, b'pdf')
                self.assertEqual(result['kind'], 'uncertain')
                self.assertEqual(result['reason'], 'transport')
                self.assertIsNone(result['body_sha256'])
                self.assertIsNone(result['upload_ack_sha256'])
                self.assertEqual(failed, [True])

    def test_upload_never_retries_or_probes_after_commit_without_ack(self):
        for fault in ('commit_then_drop_ack', 'wrong_ack_hash'):
            with self.subTest(fault=fault), OriginalServer(self.cert, self.key, body=b'', fault=fault) as server:
                result = self.upload(server, b'pdf')
                self.assertEqual(result['kind'], 'uncertain')
                self.assertIsNone(result['upload_ack_sha256'])
                self.assertIsNone(result['body_sha256'])
                self.assertEqual(result['sent_bytes'], 3)
                self.assertTrue(server.committed.is_set())
                self.assertEqual(list(server.objects.values()), [b'pdf'])
                self.assertEqual([(r['method'], r['committed']) for r in server.requests], [('POST', True)])
                self.assertEqual(server.connections, 1)

    def test_repeated_post_is_not_a_second_success_or_overwrite(self):
        with OriginalServer(self.cert, self.key, body=b'') as server:
            first = self.upload(server, b'pdf')
            second = self.upload(server, b'new')
            self.assertEqual(first['kind'], 'complete')
            self.assertEqual(second['kind'], 'uncertain')
            self.assertEqual(second['status'], 409)
            self.assertEqual(second['reason'], 'upload_unacknowledged')
            self.assertEqual(list(server.objects.values()), [b'pdf'])

    def test_ack_requires_exact_binding_types_and_fields(self):
        value = fixture_input({'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca}, stage='original_upload', body=b'x')
        ack = {'format': 'original-upload-ack-v1', 'attempt_id': ATTEMPT, 'request_sha256': '9' * 64,
               'bucket': 'paper-assets', 'path': value['request']['path'], 'sha256': digest(b'x'),
               'byte_count': 1, 'committed': True}
        for change in ({'attempt_id': RESERVATION}, {'request_sha256': '0' * 64}, {'path': 'other'},
                       {'sha256': '0' * 64}, {'byte_count': True}, {'committed': 1}, {'extra': 1}):
            with self.subTest(change=change), self.assertRaises(Refused):
                transfer._ack(canonical(dict(ack, **change)), value)
        with self.assertRaises(Refused):
            transfer._ack(b'{"committed":true,"committed":true}', value)

    def test_actual_post_response_cannot_exceed_the_separate_ack_limit(self):
        response = b'HTTP/1.1 201 Created\r\nContent-Length: 4097\r\n\r\n'
        with TLSServer(self.cert, self.key, response) as server:
            value = fixture_input({'address': '127.0.0.1', 'port': server.port, 'ca_pem': self.ca},
                                  stage='original_upload', body=b'pdf')
            result = self.upload(server, b'pdf', value=value)
            self.assertEqual(result['reason'], 'body_limit')
            self.assertIsNone(result['upload_ack_sha256'])
            self.assertEqual(server.connections, 1)
            self.assertTrue(server.request.startswith(b'POST /objects/paper-assets/'))

    def test_readback_reports_actual_bytes_and_never_assumes_candidate_matches(self):
        body = b'pdf' * transfer.CHUNK
        for fault in (None, 'wrong_readback_bytes', 'truncated_readback'):
            with self.subTest(fault=fault), OriginalServer(self.cert, self.key, body=b'', fault=fault) as server:
                self.assertEqual(self.upload(server, body)['kind'], 'complete')
                value = fixture_input(server.fixture, stage='original_readback', body=body)
                value['attempt_id'] = 'bbbbbbbb-0000-4000-8000-000000000006'
                result, received = self.receive(value)
                if fault == 'truncated_readback':
                    self.assertEqual(result['kind'], 'uncertain')
                    self.assertIsNone(result['body_sha256'])
                else:
                    self.assertEqual(result['kind'], 'complete')
                    self.assertEqual(result['body_sha256'], received['sha256'])
                    self.assertEqual(result['body_sha256'] == digest(body), fault is None)
                self.assertEqual([r['method'] for r in server.requests], ['POST', 'GET'])

    def test_result_rejects_mutated_binding_false_completion_and_unbounded_fields(self):
        with OriginalServer(self.cert, self.key, body=b'pdf') as server:
            value = fixture_input(server.fixture)
            result, _ = self.receive(value)
        changes = ({'attempt_id': RESERVATION}, {'input_sha256': '0' * 64}, {'request_sha256': '0' * 64},
                   {'binary_bytes': True}, {'binary_bytes': 2}, {'body_bytes': True},
                   {'framing_complete': False}, {'protocol_bytes_received': 2}, {'sent_bytes': 1},
                   {'local_cleanup': {'http_file_closed': True, 'socket_closed': False}},
                   {'elapsed_ms': True}, {'elapsed_ms': 10**400}, {'elapsed_ms': []},
                   {'framing': 'no_body'}, {'body_base64': 'cGRm'}, {'status': 302},
                   {'framing': 'close_delimited', 'tls_peer_close': 'not_observed'})
        for change in changes:
            with self.subTest(change=change), self.assertRaises(Refused):
                transfer.checked_result(canonical(dict(result, **change)), value)

    def test_no_body_response_has_empty_hash_and_consistent_status(self):
        with TLSServer(self.cert, self.key, b'HTTP/1.1 204 No Content\r\n\r\n') as server:
            value = fixture_input({'address': '127.0.0.1', 'port': server.port, 'ca_pem': self.ca})
            result, _ = self.receive(value)
        self.assertEqual(result['framing'], 'no_body')
        self.assertEqual(result['body_sha256'], digest(b''))
        transfer.checked_result(canonical(result), value)
        for change in ({'status': 200}, {'body_bytes': 1}, {'body_sha256': '0' * 64},
                       {'binary_bytes': 1}, {'framing': 'chunked'}):
            with self.subTest(change=change), self.assertRaises(Refused):
                transfer.checked_result(canonical(dict(result, **change)), value)
        for reason in ([], {}, None, True):
            uncertain = dict(result, kind='uncertain', reason=reason, body_bytes=None, body_sha256=None)
            with self.subTest(reason=reason), self.assertRaises(Refused):
                transfer.checked_result(canonical(uncertain), value)


if __name__ == '__main__':
    unittest.main()

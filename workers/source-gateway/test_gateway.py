import base64
import copy
import json
import os
from pathlib import Path
import queue
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import protocol
import supervisor
import transport

REQUEST = {'source_id': '1706.03762', 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1024}


class TLSServer:
    """One local connection; no listener/resolver can target another host."""
    def __init__(self, certificate, key, response, *, ending='clean', handshake_delay=False, body_delay=False):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(certificate, key)
        self.context.set_alpn_protocols(['http/1.1'])
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(3)
        self.port = self.listener.getsockname()[1]
        self.response = response
        self.ending = ending
        self.handshake_delay = handshake_delay
        self.body_delay = body_delay
        self.request = b''
        self.connections = 0
        self.accepted = threading.Event()
        self.requested = threading.Event()
        self.peer_ended = threading.Event()
        self.stop = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def _serve(self):
        connection = tls = None
        try:
            connection, _ = self.listener.accept()
            self.connections += 1
            self.accepted.set()
            connection.settimeout(2)
            if self.handshake_delay:
                self.stop.wait(1)
                return
            tls = self.context.wrap_socket(connection, server_side=True, suppress_ragged_eofs=False)
            while not self.request.endswith(b'\r\n\r\n'):
                part = tls.recv(1)
                if not part:
                    return
                self.request += part
                if len(self.request) > 4096:
                    raise AssertionError('fixture request bound')
            self.requested.set()
            if self.body_delay:
                tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n')
                self.stop.wait(1)
            else:
                tls.sendall(self.response)
            if self.ending == 'clean':
                # Peer close-notify is emitted before waiting for the client.
                # The client deliberately does not claim TCP closure from it.
                try:
                    plain = tls.unwrap()
                    plain.close()
                    self.peer_ended.set()
                except (ssl.SSLError, OSError):
                    self.peer_ended.set()
            elif self.ending == 'abrupt':
                os.close(tls.detach())
                self.peer_ended.set()
            elif self.ending == 'hold':
                try:
                    if tls.recv(1) == b'':
                        self.peer_ended.set()
                except (ssl.SSLError, ConnectionResetError):
                    self.peer_ended.set()
        except (ssl.SSLError, BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
            pass  # Expected refusal/timeout scenarios, never raw diagnostic logs.
        except Exception as error:
            if not (isinstance(error, OSError) and self.stop.is_set()):
                self.error = error
        finally:
            if tls is not None:
                tls.close()
            if connection is not None:
                connection.close()

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        self.thread.join(3)
        if self.thread.is_alive():
            raise AssertionError('fixture thread did not finish')
        if self.error:
            raise self.error


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='source-gateway-tls-tests-')
        root = Path(cls.temp.name)
        cls.cert = root / 'fixture.pem'
        cls.key = root / 'fixture.key'
        config = root / 'openssl.cnf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                          '[dn]\nCN=export.arxiv.org\n[ext]\nsubjectAltName=DNS:export.arxiv.org,DNS:oaipmh.arxiv.org\n'
                          'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-keyout', str(cls.key), '-out', str(cls.cert), '-config', str(config)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=15, check=True)
        cls.ca = cls.cert.read_text()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def fixture(self, server):
        return {'address': '127.0.0.1', 'port': server.port, 'ca_pem': self.ca}

    def execute(self, response, *, ending='clean', request=None, useful_ms=1500, close_ms=100):
        with TLSServer(self.cert, self.key, response, ending=ending) as server:
            report = supervisor.run_fixture(request or REQUEST, self.fixture(server), useful_ms=useful_ms, close_ms=close_ms)
            self.assertEqual(report['outcome'], 'completed', report)
            self.assertTrue(report['owned_process_retired'])
            self.assertEqual(report['retirement_witness'], 'parent_waitpid')
            self.assertEqual(report['child']['returncode'], 0)
            self.assertEqual(server.connections, 1)
            self.assertFalse(report['source_network_enabled'])
            self.assertFalse(report['hosted_admitted'])
            self.assertEqual(report['result']['local_cleanup'], {'http_file_closed': True, 'socket_closed': True})
            return report['result'], server

    def test_canonical_routes_match_shared_contract(self):
        atom = protocol.target(REQUEST)
        self.assertEqual(atom['url'], 'https://export.arxiv.org/api/query?id_list=1706.03762v1&max_results=1')
        historic = dict(REQUEST, source_id='cs/0701001', revision=None, stage='license')
        self.assertEqual(protocol.target(historic)['url'],
                         'https://oaipmh.arxiv.org/oai?verb=GetRecord&identifier=oai%3AarXiv.org%3Acs%2F0701001&metadataPrefix=arXivRaw')
        for source in ('https://evil.invalid/x', '1700.00001', '1401.00001', '0703.1234', 'cs.AI/0701001', 'cs/0704001'):
            with self.assertRaises(protocol.Refused):
                protocol.target(dict(REQUEST, source_id=source))

    def test_live_and_nonloopback_routes_refuse_before_child_or_dns(self):
        with patch.object(supervisor.subprocess, 'Popen') as popen, patch('socket.getaddrinfo') as resolver:
            with self.assertRaisesRegex(protocol.Refused, 'source_network_disabled'):
                protocol.live_transport(REQUEST)
            with self.assertRaisesRegex(protocol.Refused, 'source_network_disabled'):
                supervisor.run_fixture(REQUEST, {'address': 'export.arxiv.org', 'port': 443, 'ca_pem': self.ca})
            popen.assert_not_called()
            resolver.assert_not_called()

    def test_complete_content_length_and_clean_tls_close(self):
        result, server = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(result['framing'], 'content_length')
        self.assertEqual(result['tls_peer_close'], 'clean_tls')
        self.assertEqual(base64.b64decode(result['body_base64']), b'hello')
        self.assertIn(b'Host: export.arxiv.org\r\n', server.request)
        self.assertIn(b'Connection: close\r\n', server.request)
        self.assertIn(b'Accept-Encoding: identity\r\n', server.request)

    def test_framed_body_survives_abrupt_tls_close_without_fake_clean_eof(self):
        result, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello', ending='abrupt')
        self.assertEqual(result['kind'], 'complete')
        self.assertTrue(result['framing_complete'])
        self.assertEqual(result['tls_peer_close'], 'abrupt')

    def test_content_length_truncation_is_not_parser_eof_success(self):
        for ending in ('clean', 'abrupt'):
            with self.subTest(ending=ending):
                result, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nhello', ending=ending)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertFalse(result['framing_complete'])
                self.assertIsNone(result['body_sha256'])

    def test_chunked_complete_and_missing_terminal_crlf(self):
        result, _ = self.execute(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(result['framing'], 'chunked')
        self.assertEqual(base64.b64decode(result['body_base64']), b'abc')
        for body in (b'3\r\nabcXX0\r\n\r\n', b'3\r\nab\r\n0\r\n\r\n', b'3\r\nabc\r\n0\r\n'):
            with self.subTest(body=body):
                failed, _ = self.execute(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + body)
                self.assertEqual(failed['kind'], 'uncertain')
                self.assertIsNone(failed['body_bytes'])

    def test_close_delimited_body_requires_clean_tls_eof(self):
        clean, _ = self.execute(b'HTTP/1.0 200 OK\r\n\r\nhello')
        self.assertEqual(clean['kind'], 'complete')
        self.assertEqual(clean['framing'], 'close_delimited')
        abrupt, _ = self.execute(b'HTTP/1.0 200 OK\r\n\r\nhello', ending='abrupt')
        self.assertEqual(abrupt['kind'], 'uncertain')
        self.assertEqual(abrupt['tls_peer_close'], 'abrupt')

    def test_no_auto_proxy_redirect_or_decompression(self):
        with patch.dict(os.environ, {'HTTPS_PROXY': 'http://unreachable.invalid:1', 'ALL_PROXY': 'http://unreachable.invalid:1'}):
            complete, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
        self.assertEqual(complete['kind'], 'complete')
        redirect, _ = self.execute(b'HTTP/1.1 302 Found\r\nLocation: https://export.arxiv.org/other\r\nContent-Length: 0\r\n\r\n')
        self.assertEqual(redirect['reason'], 'redirect')
        compressed, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nxx')
        self.assertEqual(compressed['reason'], 'unsupported_encoding')

    def test_ambiguous_framing_and_folded_headers_are_rejected(self):
        for headers in (b'Content-Length: 2\r\nContent-Length: 2\r\n',
                        b'Content-Length: 2\r\nTransfer-Encoding: chunked\r\n',
                        b'Content-Length: -1\r\n', b'X-Field: a\r\n b\r\n',
                        b'Content-Length: 2\n'):
            with self.subTest(headers=headers):
                result, _ = self.execute(b'HTTP/1.1 200 OK\r\n' + headers + b'\r\nok')
                self.assertEqual(result['kind'], 'uncertain')

    def test_body_and_header_limits_reject_without_complete_hash(self):
        for response in (b'HTTP/1.1 200 OK\r\nContent-Length: 1025\r\n\r\n',
                         b'HTTP/1.1 200 OK\r\nX: ' + b'x' * 8192 + b'\r\n\r\n',
                         b'HTTP/1.1 200 OK\r\n' + b'X: y\r\n' * 65 + b'\r\n',
                         b'HTTP/1.1 200 OK\r\n' + (b'X: ' + b'x' * 4000 + b'\r\n') * 5 + b'\r\n',
                         b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n401\r\n',
                         b'HTTP/1.0 200 OK\r\n\r\n' + b'x' * 1025):
            with self.subTest(prefix=response[:60]):
                result, _ = self.execute(response)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertIsNone(result['body_sha256'])

    def test_maximum_body_uses_bounded_ipc_and_chunk_overhead_has_its_own_cap(self):
        body = b'x' * protocol.MAX_BODY
        result, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n' + body,
                                 request=dict(REQUEST, byte_ceiling=protocol.MAX_BODY))
        self.assertEqual(result['body_bytes'], protocol.MAX_BODY)
        self.assertEqual(result['body_sha256'], protocol.digest(body))
        overhead, _ = self.execute(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' +
                                  b'1\r\nx\r\n' * 22_000 + b'0\r\n\r\n',
                                  request=dict(REQUEST, byte_ceiling=protocol.MAX_BODY), useful_ms=5000)
        self.assertEqual(overhead['kind'], 'uncertain')
        self.assertEqual(overhead['reason'], 'protocol_limit')

    def test_extra_application_data_after_framing_is_rejected(self):
        result, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokextra')
        self.assertEqual(result['reason'], 'extra_protocol_data')
        self.assertIsNone(result['body_base64'])

    def test_late_generic_tls_failure_cannot_leave_success_payload(self):
        # Inject only the client's optional post-framing receive. Handshake and
        # HTTP parsing still use an actual loopback TLS connection.
        receive = ssl.SSLSocket.recv
        for failure in (ssl.SSLError('fixture'), OSError('fixture')):
            with self.subTest(failure=type(failure).__name__):
                def failing_receive(connection, *args, **kwargs):
                    if not connection.server_side:
                        raise failure
                    return receive(connection, *args, **kwargs)
                with TLSServer(self.cert, self.key, b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', ending='hold') as server:
                    value = {'mode': 'loopback_fixture_v1', 'attempt_id': '00000000-0000-0000-0000-000000000001',
                             'request': REQUEST, 'fixture': self.fixture(server), 'useful_ms': 1500, 'close_ms': 100}
                    with patch.object(ssl.SSLSocket, 'recv', failing_receive):
                        result = transport.perform(value)
                self.assertEqual(result['kind'], 'uncertain')
                self.assertEqual(result['reason'], 'transport')
                self.assertTrue(result['framing_complete'])
                self.assertTrue(all(result[key] is None for key in ('body_base64', 'body_sha256', 'body_bytes')))
                self.assertEqual(supervisor.checked_result(protocol.canonical(result), value), result)

    def test_close_failure_still_attempts_remaining_reference_cleanup(self):
        close = transport.StrictResponse.close
        def failing_close(response):
            close(response)
            raise OSError('fixture close failure')
        with TLSServer(self.cert, self.key, b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', ending='hold') as server:
            value = {'mode': 'loopback_fixture_v1', 'attempt_id': '00000000-0000-0000-0000-000000000001',
                     'request': REQUEST, 'fixture': self.fixture(server), 'useful_ms': 1500, 'close_ms': 0}
            with patch.object(transport.StrictResponse, 'close', failing_close):
                result = transport.perform(value)
        self.assertTrue(server.peer_ended.is_set())
        self.assertEqual(result['kind'], 'uncertain')
        self.assertEqual(result['reason'], 'transport')
        self.assertEqual(result['local_cleanup'], {'http_file_closed': True, 'socket_closed': True})
        self.assertIsNone(result['body_sha256'])
        self.assertEqual(supervisor.checked_result(protocol.canonical(result), value), result)

    def test_unclosed_peer_does_not_become_tls_close_and_all_file_refs_retire(self):
        result, server = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', ending='hold')
        self.assertEqual(result['kind'], 'complete')
        self.assertEqual(result['tls_peer_close'], 'not_observed')
        self.assertTrue(server.peer_ended.is_set(), 'retained HTTP file/socket reference kept peer alive')

    def test_slow_handshake_and_body_obey_child_deadline(self):
        for mode in ('handshake', 'body'):
            with self.subTest(mode=mode), TLSServer(self.cert, self.key, b'', handshake_delay=mode == 'handshake', body_delay=mode == 'body') as server:
                report = supervisor.run_fixture(REQUEST, self.fixture(server), useful_ms=150, close_ms=0)
                self.assertEqual(report['outcome'], 'completed')
                self.assertEqual(report['result']['reason'], 'deadline')
                self.assertTrue(report['owned_process_retired'])
                self.assertLess(report['elapsed_ms'], 1150)

    def test_cancellation_kills_and_joins_exclusive_child(self):
        cancel = threading.Event()
        result = queue.Queue(maxsize=1)
        with TLSServer(self.cert, self.key, b'', body_delay=True) as server:
            task = threading.Thread(target=lambda: result.put(supervisor.run_fixture(REQUEST, self.fixture(server),
                                                                                     useful_ms=3000, cancelled=cancel)))
            task.start()
            self.assertTrue(server.requested.wait(2))
            cancel.set()
            task.join(2)
            self.assertFalse(task.is_alive())
            report = result.get_nowait()
            self.assertEqual(report['outcome'], 'cancelled')
            self.assertTrue(report['owned_process_retired'])
            self.assertIsNone(report['result'])

    def test_watchdog_reaps_a_stopped_child_and_crash_has_no_body(self):
        for child_signal, expected in ((signal.SIGSTOP, 'watchdog'), (signal.SIGKILL, 'child_exit')):
            with self.subTest(signal=child_signal):
                started, result = queue.Queue(maxsize=1), queue.Queue(maxsize=1)
                fixture = {'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca}
                task = threading.Thread(target=lambda: result.put(supervisor.run_fixture(REQUEST, fixture, useful_ms=100,
                                                                                         close_ms=0, started=started)))
                task.start()
                owned = started.get(timeout=1)
                os.kill(owned['pid'], child_signal)
                task.join(3)
                self.assertFalse(task.is_alive())
                report = result.get_nowait()
                self.assertEqual(report['outcome'], expected)
                self.assertTrue(report['owned_process_retired'])
                self.assertEqual(report['child']['returncode'], -signal.SIGKILL)
                self.assertIsNone(report['result'])

    def test_unconfirmed_kill_bounds_drain_and_blocks_successor_until_exact_join(self):
        complete, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')

        class RestrictedChild:
            """Only a local fake process: kill fails to retire its retained pipes."""
            def __init__(self):
                self.pid = 999_999_999  # Never used with os.kill or a real child API.
                self.returncode = None
                self.kills = 0
                source_read, source_write = os.pipe()
                output_read, output_write = os.pipe()
                error_read, error_write = os.pipe()
                self.stdin = os.fdopen(source_write, 'wb', buffering=0)
                self.stdout = os.fdopen(output_read, 'rb', buffering=0)
                self.stderr = os.fdopen(error_read, 'rb', buffering=0)
                self.source = os.fdopen(source_read, 'rb', buffering=0)
                self.output = os.fdopen(output_write, 'wb', buffering=0)
                self.error = os.fdopen(error_write, 'wb', buffering=0)
                self.written = threading.Event()
                self.thread = threading.Thread(target=self.respond)
                self.thread.start()

            def respond(self):
                value = protocol.decode(self.source.read(protocol.MAX_INPUT + 1))
                result = dict(complete, attempt_id=value['attempt_id'])
                self.output.write(protocol.canonical(result))
                self.written.set()
                # Hold both output handles even after a complete valid result.

            def poll(self):
                return self.returncode

            def kill(self):
                self.kills += 1

            def wait(self, timeout=None):
                if self.returncode is not None:
                    return self.returncode
                if timeout:
                    time.sleep(timeout)
                raise subprocess.TimeoutExpired('restricted_fixture_child', timeout)

            def close(self):
                self.thread.join(1)
                for pipe in (self.source, self.output, self.error):
                    pipe.close()

        child = RestrictedChild()
        fixture = {'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca}
        try:
            with patch.object(supervisor.subprocess, 'Popen', return_value=child), patch.object(supervisor, 'CLEANUP_MS', 60):
                started = time.monotonic()
                report = supervisor.run_fixture(REQUEST, fixture, useful_ms=100, close_ms=0)
                self.assertLess(time.monotonic() - started, 0.5)
                self.assertTrue(child.written.is_set())
                self.assertEqual(report['outcome'], 'unresolved')
                self.assertIsNone(report['result'])
                self.assertFalse(report['owned_process_retired'])
                self.assertIsNone(report['retirement_witness'])
                self.assertGreater(child.kills, 0)
                retained_identity = {key: report[key] for key in ('attempt_id', 'request_sha256', 'child_recipe_sha256')}
                report.update(attempt_id='00000000-0000-0000-0000-000000000002',
                              request_sha256='0' * 64, child_recipe_sha256='0' * 64)
                report['child']['pid'] = 1
                with self.assertRaisesRegex(protocol.Refused, 'fixture_busy'):
                    supervisor.run_fixture(REQUEST, fixture)
                still_pending = supervisor.reconcile_fixture()
                self.assertEqual(still_pending['outcome'], 'unresolved')
                self.assertFalse(still_pending['owned_process_retired'])
                self.assertIs(supervisor._UNRESOLVED['child'], child)
                child.returncode = -signal.SIGKILL
                retired = supervisor.reconcile_fixture()
                self.assertEqual(retired['outcome'], 'retired_after_reconciliation')
                self.assertTrue(retired['owned_process_retired'])
                self.assertEqual(retired['retirement_witness'], 'parent_waitpid')
                self.assertEqual({key: retired[key] for key in retained_identity}, retained_identity)
                self.assertEqual(retired['child']['pid'], child.pid)
                self.assertIsNone(retired['result'])
                self.assertIsNone(supervisor._UNRESOLVED)
                self.assertFalse(supervisor._ACTIVE.locked())
        finally:
            child.returncode = -signal.SIGKILL
            if supervisor._UNRESOLVED is not None:
                supervisor.reconcile_fixture()
            child.close()

    def test_cancel_before_start_and_overlapping_local_invocations(self):
        cancel = threading.Event()
        cancel.set()
        with patch.object(supervisor.subprocess, 'Popen') as popen:
            value = supervisor.run_fixture(REQUEST, {'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca}, cancelled=cancel)
            self.assertEqual(value['outcome'], 'cancelled_before_start')
            self.assertFalse(value['owned_process_retired'])
            popen.assert_not_called()
        with supervisor._ACTIVE:
            with self.assertRaisesRegex(protocol.Refused, 'fixture_busy'):
                supervisor.run_fixture(REQUEST, {'address': '127.0.0.1', 'port': 1, 'ca_pem': self.ca})

    def test_parent_crash_produces_no_retirement_witness(self):
        # The outer test observes only fixture peer shutdown. It must not turn
        # that into the killed supervisor's nonexistent waitpid receipt.
        source = str(Path(__file__).resolve().parent)
        bootstrap = ('import sys,json,threading,queue;sys.path.insert(0,sys.argv[1]);import supervisor;'
                     'v=json.load(sys.stdin);q=queue.Queue(1);'
                     't=threading.Thread(target=lambda:supervisor.run_fixture(v["request"],v["fixture"],'
                     'useful_ms=300,close_ms=0,started=q));t.start();'
                     'print(json.dumps(q.get(timeout=2)),flush=True);t.join();print("unexpected_parent_result",flush=True)')
        with TLSServer(self.cert, self.key, b'', body_delay=True) as server:
            parent = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', bootstrap, source],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      close_fds=True, env={'LC_ALL': 'C', 'TMPDIR': self.temp.name})
            try:
                parent.stdin.write(protocol.canonical({'request': REQUEST, 'fixture': self.fixture(server)}))
                parent.stdin.close()
                self.assertTrue(server.requested.wait(2))
                parent.kill()
                parent.wait(timeout=1)
                output = parent.stdout.read(1024)
                self.assertNotIn(b'unexpected_parent_result', output)
                self.assertNotIn(b'retirement_witness', output)
                self.assertLess(len(output), 1024)
                self.assertEqual(parent.returncode, -signal.SIGKILL)
            finally:
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=1)
                parent.stdout.close()

    def test_child_owns_request_snapshot_while_caller_changes_its_copy(self):
        request = dict(REQUEST)
        outputs = queue.Queue(maxsize=1)
        with TLSServer(self.cert, self.key, b'', body_delay=True) as server:
            task = threading.Thread(target=lambda: outputs.put(supervisor.run_fixture(request, self.fixture(server),
                                                                                       useful_ms=150, close_ms=0)))
            task.start()
            self.assertTrue(server.requested.wait(2))
            request['source_id'] = '2201.00001'
            task.join(2)
            report = outputs.get_nowait()
            self.assertEqual(report['outcome'], 'completed')
            self.assertEqual(report['request_sha256'], protocol.digest(protocol.canonical(REQUEST)))
            self.assertEqual(report['result']['target'], protocol.target(REQUEST))

    def test_result_binding_hash_and_duplicate_keys_fail_closed(self):
        result, _ = self.execute(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
        value = {'attempt_id': result['attempt_id'], 'request': REQUEST}
        self.assertEqual(supervisor.checked_result(protocol.canonical(result), value), result)
        for key, changed in (('attempt_id', '00000000-0000-0000-0000-000000000000'), ('body_sha256', '0' * 64),
                             ('framing', 'close_delimited'), ('source_network_enabled', True)):
            corrupted = copy.deepcopy(result)
            corrupted[key] = changed
            if key == 'framing':
                corrupted['tls_peer_close'] = 'abrupt'
            with self.assertRaises(protocol.Refused):
                supervisor.checked_result(protocol.canonical(corrupted), value)
        with self.assertRaises(protocol.Refused):
            protocol.decode(b'{"mode":"a","mode":"b"}')


if __name__ == '__main__':
    unittest.main()

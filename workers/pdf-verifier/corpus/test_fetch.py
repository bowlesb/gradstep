#!/usr/bin/env python3
"""Offline failure schedules for the bounded publisher downloader; no sockets."""
import email.message
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.request

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('corpus_fetch', Path(__file__).with_name('fetch.py'))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)
URL = 'https://proceedings.mlr.press/v139/tan21a/tan21a.pdf'
PDF = b'%PDF-1.5\nunchanged test bytes\n%%EOF\n'


class Response:
    def __init__(self, body=PDF, *, length=None, encoding=None, url=URL, media='application/pdf'):
        self.stream = io.BytesIO(body)
        self.status, self.url = 200, url
        self.headers = email.message.Message()
        self.headers['Content-Type'] = media
        if length is not None: self.headers['Content-Length'] = str(length)
        if encoding is not None: self.headers['Content-Encoding'] = encoding
        self.read_sizes = []
        self.closed = False
    def __enter__(self): return self
    def __exit__(self, *_): self.closed = True
    def read(self, size):
        self.read_sizes.append(size)
        return self.stream.read(size)


class Opener:
    def __init__(self, response): self.response, self.calls = response, []
    def open(self, request, timeout):
        self.calls.append((request, timeout))
        return self.response


class DownloaderContracts(unittest.TestCase):
    def setUp(self):
        fetch.OUT.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='offline-test-', dir=fetch.OUT)
        self.out = Path(self.temporary.name)
        self.patches = [patch.object(fetch, 'OUT', self.out), patch.object(fetch, 'SPACING', 0)]
        for item in self.patches: item.start()
        self.addCleanup(self.temporary.cleanup)
        for item in self.patches: self.addCleanup(item.stop)
    def downloader(self, response=None):
        downloader = fetch.Downloader()
        downloader.opener = Opener(response or Response())
        return downloader
    def assert_unpublished(self, downloader, received):
        self.assertFalse((self.out/'pdf/test.pdf').exists())
        self.assertFalse((self.out/'pdf/test.pdf.part').exists())
        saved = json.loads((self.out/'download-receipts.json').read_text())
        self.assertEqual(saved['received_bytes'], received)
        self.assertEqual(saved['files'], {})
        self.assertTrue(downloader.opener.response.closed)
    def test_exact_bytes_and_hash_bound_cache_never_refetch(self):
        downloader = self.downloader()
        first, receipt = downloader.get(URL, 'pdf/test.pdf', 1024, fetch.sha(PDF))
        second, reused = downloader.get(URL, 'pdf/test.pdf', 1024, fetch.sha(PDF))
        self.assertEqual(first, PDF)
        self.assertEqual(second, PDF)
        self.assertEqual(receipt, reused)
        self.assertEqual((self.out/'pdf/test.pdf').read_bytes(), PDF)
        self.assertEqual(downloader.receipts['received_bytes'], len(PDF))
        self.assertEqual(len(downloader.opener.calls), 1)
        request, timeout = downloader.opener.calls[0]
        self.assertEqual(request.get_header('Accept-encoding'), 'identity')
        self.assertEqual(request.get_header('Connection'), 'close')
        self.assertEqual(timeout, 10)
    def test_tampered_cache_cannot_bypass_manifest(self):
        downloader = self.downloader()
        downloader.get(URL, 'pdf/test.pdf', 1024)
        (self.out/'pdf/test.pdf').write_bytes(b'%PDF-altered')
        with self.assertRaisesRegex(RuntimeError, 'artifact_hash_mismatch'):
            downloader.get(URL, 'pdf/test.pdf', 1024, fetch.sha(PDF))
        self.assertEqual(len(downloader.opener.calls), 1)
    def test_unbound_existing_file_is_not_adopted(self):
        (self.out/'unbound.pdf').write_bytes(PDF)
        downloader = self.downloader()
        with self.assertRaisesRegex(RuntimeError, 'unbound_existing_artifact'):
            downloader.get(URL, 'unbound.pdf', 1024)
        self.assertEqual(downloader.opener.calls, [])
    def test_foreign_http_credential_and_queried_urls_refused_before_open(self):
        for url in ('http://proceedings.mlr.press/p.pdf', 'https://arxiv.org/a.pdf',
                    'https://u@proceedings.mlr.press/a.pdf', URL+'?download=1',
                    'https://creativecommons.org/unapproved.html'):
            with self.subTest(url=url):
                downloader = self.downloader()
                with self.assertRaisesRegex(RuntimeError, 'unapproved_'):
                    downloader.get(url, 'pdf/test.pdf', 1024)
                self.assertEqual(downloader.opener.calls, [])
    def test_traversal_and_symlink_refused_before_open(self):
        (self.out/'target.pdf').write_bytes(PDF)
        (self.out/'linked.pdf').symlink_to(self.out/'target.pdf')
        for relative in ('../outside.pdf', 'linked.pdf'):
            with self.subTest(relative=relative):
                downloader = self.downloader()
                with self.assertRaisesRegex(RuntimeError, 'unsafe_artifact_path'):
                    downloader.get(URL, relative, 1024)
                self.assertEqual(downloader.opener.calls, [])
    def test_declared_file_limit_refuses_body_and_cleans_partial(self):
        downloader = self.downloader(Response(length=100))
        with self.assertRaisesRegex(RuntimeError, 'declared_transfer_limit'):
            downloader.get(URL, 'pdf/test.pdf', 20)
        self.assertEqual(downloader.opener.response.read_sizes, [])
        self.assert_unpublished(downloader, 0)
    def test_unknown_length_never_reads_detection_byte_beyond_cap(self):
        downloader = self.downloader(Response(body=b'x'*100))
        with self.assertRaisesRegex(RuntimeError, 'stream_transfer_limit'):
            downloader.get(URL, 'pdf/test.pdf', 20)
        self.assertEqual(downloader.opener.response.read_sizes, [20])
        self.assert_unpublished(downloader, 20)
    def test_aggregate_remaining_bound_is_persisted_on_failure(self):
        downloader = self.downloader(Response(body=b'x'*100))
        downloader.receipts['received_bytes'] = 90
        with patch.object(fetch, 'MAX_TOTAL', 100):
            with self.assertRaisesRegex(RuntimeError, 'stream_transfer_limit'):
                downloader.get(URL, 'pdf/test.pdf', 1024)
        self.assertEqual(downloader.opener.response.read_sizes, [10])
        self.assert_unpublished(downloader, 100)
    def test_declared_aggregate_overflow_refuses_body(self):
        downloader = self.downloader(Response(length=len(PDF)))
        downloader.receipts['received_bytes'] = 90
        with patch.object(fetch, 'MAX_TOTAL', 100):
            with self.assertRaisesRegex(RuntimeError, 'declared_transfer_limit'):
                downloader.get(URL, 'pdf/test.pdf', 1024)
        self.assertEqual(downloader.opener.response.read_sizes, [])
        self.assert_unpublished(downloader, 90)
    def test_compressed_http_representation_is_refused(self):
        downloader = self.downloader(Response(encoding='gzip'))
        with self.assertRaisesRegex(RuntimeError, 'encoded_response_refused'):
            downloader.get(URL, 'pdf/test.pdf', 1024)
        self.assert_unpublished(downloader, 0)
    def test_short_body_cannot_be_published(self):
        downloader = self.downloader(Response(length=len(PDF)+10))
        with self.assertRaisesRegex(RuntimeError, 'truncated_download'):
            downloader.get(URL, 'pdf/test.pdf', 1024)
        self.assert_unpublished(downloader, len(PDF))
    def test_publisher_change_never_rewrites_pinned_artifact(self):
        downloader = self.downloader()
        with self.assertRaisesRegex(RuntimeError, 'publisher_bytes_changed'):
            downloader.get(URL, 'pdf/test.pdf', 1024, '0'*64)
        self.assert_unpublished(downloader, len(PDF))
    def test_wrong_media_type_and_redirected_final_url_refused(self):
        for response, expected, received in ((Response(media='text/html'), 'not_a_pdf_response', len(PDF)),
                                             (Response(url=URL+'.other'), 'unexpected_response', 0)):
            with self.subTest(expected=expected):
                downloader = self.downloader(response)
                before = downloader.receipts['received_bytes']
                with self.assertRaisesRegex(RuntimeError, expected):
                    downloader.get(URL, 'pdf/test.pdf', 1024)
                self.assert_unpublished(downloader, before+received)
    def test_redirect_handler_never_creates_second_request(self):
        handler = fetch.NoRedirect()
        request = urllib.request.Request(URL)
        headers = email.message.Message()
        headers['Location'] = 'https://example.invalid/other.pdf'
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                with self.assertRaisesRegex(RuntimeError, 'redirect_refused'):
                    getattr(handler, 'http_error_'+str(code))(request, None, code, 'redirect', headers)
    def test_restart_cannot_reset_exhausted_transfer_envelope(self):
        fetch.json_write(self.out/'download-receipts.json', {'received_bytes':100,'files':{}})
        with patch.object(fetch, 'MAX_TOTAL', 100):
            downloader = self.downloader()
            with self.assertRaisesRegex(RuntimeError, 'aggregate_transfer_limit'):
                downloader.get(URL, 'pdf/test.pdf', 1024)
            self.assertEqual(downloader.opener.calls, [])


if __name__ == '__main__': unittest.main()

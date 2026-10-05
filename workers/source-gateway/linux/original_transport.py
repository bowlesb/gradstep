"""Finite original-PDF transfers to loopback TLS fixtures only.

This is a transport component, not SQL/GO, process-retirement, Storage or host
admission authority. The enclosing owner validates the committed grant and
sealed input before invoking it, and reconciles actual retirement afterward.
GET bytes leave only through a nonblocking binary pipe. POST reads one borrowed
readonly regular FD; it never opens a caller path. No retry, redirect, resolver,
proxy, parser, credential or live destination is available here.
"""
import fcntl
import hashlib
import http.client
import os
import re
import select
import socket
import ssl
import stat

from protocol import (Refused, canonical, clock, clock_ns, decode, digest,
                      require, target as metadata_target)
from transport import (BoundedFile, FileOwner, StrictResponse, header_policy,
                       retry_after, retry_classification)

MAX_BODY = 5_242_880
MAX_PROTOCOL = 6_291_456  # Received HTTP plaintext, not TLS/kernel byte usage.
CHUNK = 65_536
MAX_INPUT = 24_576
MAX_OUTPUT = 4_096
MAX_ACK = 4_096
MAX_USEFUL_MS = 120_000
MAX_CLOSE_MS = 250
OBJECT_HOST = 'objects.timestep.invalid'
STAGES = {'original_download', 'original_upload', 'original_readback'}
REQUEST_KEYS = {
    'version', 'kind', 'job_id', 'reservation_id', 'source_id', 'source_revision',
    'bucket', 'path', 'predecessor_operation_id', 'predecessor_result_sha256',
    'candidate_sha256', 'candidate_bytes', 'input_spool_sha256', 'byte_ceiling',
    'verification_profile_id', 'stage_recipe_sha256', 'build_sha256',
    'parser_profile_sha256', 'verifier_host_policy_sha256', 'storage_policy_sha256',
    'spool_policy_sha256',
}
INPUT_KEYS = {'format', 'local_fixture_only', 'attempt_id', 'request',
              'request_sha256', 'fixture', 'useful_ms', 'close_ms'}
RESULT_KEYS = {
    'format', 'local_fixture_only', 'attempt_id', 'request_sha256', 'input_sha256',
    'stage', 'kind', 'reason', 'status', 'framing', 'framing_complete', 'body_bytes',
    'body_sha256', 'binary_bytes', 'sent_bytes', 'upload_ack_sha256',
    'protocol_bytes_received', 'tls_peer_close', 'retry_after_seconds',
    'retry_after_kind', 'local_cleanup', 'elapsed_ms',
}
REASONS = {
    'transport', 'deadline', 'tls_identity', 'http_truncated', 'protocol_error',
    'body_limit', 'header_limit', 'protocol_limit', 'unsupported_status',
    'unsupported_encoding', 'ambiguous_framing', 'redirect',
    'unsupported_chunk_syntax', 'tls_truncated', 'extra_protocol_data',
    'socket_ownership', 'invalid_request', 'binary_pipe', 'input_changed',
    'input_mismatch', 'invalid_upload_ack', 'upload_unacknowledged',
}


def _uuid(value):
    require(type(value) is str and re.fullmatch(
        r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value), 'invalid_request')


def _sha(value, code='invalid_request'):
    require(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), code)


def validate_input(value):
    require(type(value) is dict and set(value) == INPUT_KEYS, 'invalid_request')
    require(value['format'] == 'original-transfer-input-v1'
            and value['local_fixture_only'] is True, 'source_network_disabled')
    _uuid(value['attempt_id'])
    _sha(value['request_sha256'])  # Opaque PostgreSQL hash; never re-encode it.
    request = value['request']
    require(type(request) is dict and set(request) == REQUEST_KEYS, 'invalid_request')
    require(type(request['version']) is int and request['version'] == 1
            and type(request['kind']) is str and request['kind'] in STAGES, 'invalid_request')
    for key in ('job_id', 'reservation_id', 'predecessor_operation_id', 'verification_profile_id'):
        _uuid(request[key])
    for key in ('predecessor_result_sha256', 'stage_recipe_sha256', 'build_sha256',
                'parser_profile_sha256', 'verifier_host_policy_sha256',
                'storage_policy_sha256', 'spool_policy_sha256'):
        _sha(request[key])
    require(type(request['source_revision']) is int and request['source_revision'] > 0, 'invalid_request')
    # Reuse canonical source-ID validation without widening metadata's ceiling.
    metadata_target({'source_id': request['source_id'], 'revision': request['source_revision'],
                     'stage': 'atom', 'byte_ceiling': 1})
    require(request['bucket'] == 'paper-assets'
            and request['path'] == 'originals/' + request['reservation_id'] + '/original.pdf', 'invalid_request')
    require(type(request['byte_ceiling']) is int and 1 <= request['byte_ceiling'] <= MAX_BODY, 'invalid_request')
    if request['kind'] == 'original_download':
        require(all(request[k] is None for k in ('candidate_sha256', 'candidate_bytes', 'input_spool_sha256')), 'invalid_request')
    else:
        _sha(request['candidate_sha256'])
        require(type(request['candidate_bytes']) is int
                and 1 <= request['candidate_bytes'] <= request['byte_ceiling'], 'invalid_request')
        if request['kind'] == 'original_upload':
            _sha(request['input_spool_sha256'])
            require(request['candidate_bytes'] == request['byte_ceiling'], 'invalid_request')
        else:
            require(request['input_spool_sha256'] is None, 'invalid_request')
    require(len(canonical(request)) <= 2048, 'invalid_request')
    fixture = value['fixture']
    require(type(fixture) is dict and set(fixture) == {'address', 'port', 'ca_pem'}, 'invalid_request')
    require(fixture['address'] == '127.0.0.1' and type(fixture['port']) is int
            and 1 <= fixture['port'] <= 65535, 'source_network_disabled')
    require(type(fixture['ca_pem']) is str and 1 <= len(fixture['ca_pem']) <= 16_384
            and fixture['ca_pem'].startswith('-----BEGIN CERTIFICATE-----'), 'invalid_request')
    require(type(value['useful_ms']) is int and 1 <= value['useful_ms'] <= MAX_USEFUL_MS
            and type(value['close_ms']) is int and 0 <= value['close_ms'] <= MAX_CLOSE_MS, 'invalid_request')
    encoded = canonical(value)
    require(len(encoded) <= MAX_INPUT, 'invalid_request')
    return decode(encoded)  # Own the request before any asynchronous handoff.


def destination(request):
    if request['kind'] == 'original_download':
        return 'arxiv.org', '/pdf/' + request['source_id'] + 'v' + str(request['source_revision'])
    return OBJECT_HOST, '/objects/' + request['bucket'] + '/' + request['path']


def _fd(fd, *, pipe=False):
    require(type(fd) is int and fd >= 0, 'binary_pipe' if pipe else 'input_mismatch')
    info = os.fstat(fd)
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    if pipe:
        require(stat.S_ISFIFO(info.st_mode) and flags & os.O_ACCMODE == os.O_WRONLY
                and flags & os.O_NONBLOCK, 'binary_pipe')
    else:
        require(stat.S_ISREG(info.st_mode) and flags & os.O_ACCMODE == os.O_RDONLY,
                'input_mismatch')
    return info


def _stable(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def _file_chunks(fd, amount, deadline):
    offset = 0
    while offset < amount:
        require(clock() < deadline, 'deadline')
        raw = os.pread(fd, min(CHUNK, amount - offset), offset)
        require(raw, 'input_mismatch')
        offset += len(raw)
        yield raw


def _checked_file(fd, request, deadline):
    info = _fd(fd)
    require(info.st_size == request['candidate_bytes'], 'input_mismatch')
    hasher = hashlib.sha256()
    for raw in _file_chunks(fd, info.st_size, deadline):
        hasher.update(raw)
    require(hasher.hexdigest() == request['candidate_sha256'], 'input_mismatch')
    require(_stable(_fd(fd)) == _stable(info), 'input_changed')
    return info


def _write_pipe(fd, expected, raw, deadline, result):
    sent = 0
    while sent < len(raw):
        remaining = deadline - clock()
        require(remaining > 0, 'deadline')
        info = _fd(fd, pipe=True)
        require((info.st_dev, info.st_ino) == (expected.st_dev, expected.st_ino), 'binary_pipe')
        require(select.select([], [fd], [], remaining)[1], 'deadline')
        try:
            count = os.write(fd, raw[sent:])
        except BlockingIOError:
            continue
        require(count > 0, 'binary_pipe')
        sent += count
        result['binary_bytes'] += count


def _ack(raw, value):
    try:
        received = decode(raw)
    except (Refused, ValueError, TypeError):
        raise Refused('invalid_upload_ack') from None
    request = value['request']
    expected = {'format': 'original-upload-ack-v1', 'attempt_id': value['attempt_id'],
                'request_sha256': value['request_sha256'], 'bucket': request['bucket'],
                'path': request['path'], 'sha256': request['candidate_sha256'],
                'byte_count': request['candidate_bytes'], 'committed': True}
    require(type(received) is dict and received == expected
            and type(received.get('byte_count')) is int and received.get('committed') is True,
            'invalid_upload_ack')
    return digest(raw)


def perform(value, *, output_fd=None, input_fd=None, absolute_deadline_ns=None):
    value = validate_input(value)
    request = value['request']
    uploading = request['kind'] == 'original_upload'
    require((output_fd is None and input_fd is not None) if uploading
            else (input_fd is None and output_fd is not None), 'invalid_request')
    # Descriptor kind/mode failure refuses before even constructing a socket.
    info = _fd(input_fd) if uploading else _fd(output_fd, pipe=True)
    started = clock()
    deadline = started + value['useful_ms'] / 1000
    if absolute_deadline_ns is not None:
        require(type(absolute_deadline_ns) is int and absolute_deadline_ns > clock_ns(), 'deadline')
        deadline = min(deadline, absolute_deadline_ns / 1e9)
    result = {'format': 'original-transfer-result-v1', 'local_fixture_only': True,
              'attempt_id': value['attempt_id'], 'request_sha256': value['request_sha256'],
              'input_sha256': digest(canonical(value)), 'stage': request['kind'],
              'kind': 'uncertain', 'reason': 'transport', 'status': None, 'framing': None,
              'framing_complete': False, 'body_bytes': None, 'body_sha256': None,
              'binary_bytes': 0, 'sent_bytes': 0, 'upload_ack_sha256': None,
              'protocol_bytes_received': 0, 'tls_peer_close': 'not_observed',
              'retry_after_seconds': 0, 'retry_after_kind': 'absent',
              'local_cleanup': {'http_file_closed': True, 'socket_closed': True}, 'elapsed_ms': 0}
    raw_socket = tls = file = response = None

    def arm(connection):
        remaining = deadline - clock()
        require(remaining > 0, 'deadline')
        connection.settimeout(remaining)

    def fail(code):
        result.update(kind='uncertain', reason=code, body_bytes=None, body_sha256=None,
                      upload_ack_sha256=None)

    def close_owned(resource):
        if resource is not None:
            try:
                resource.close()
            except (OSError, ValueError):
                fail('transport')

    try:
        if uploading:
            info = _checked_file(input_fd, request, deadline)
        host, path = destination(request)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_verify_locations(cadata=value['fixture']['ca_pem'])
        context.set_alpn_protocols(['http/1.1'])
        raw_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        require(not raw_socket.get_inheritable(), 'socket_ownership')
        arm(raw_socket)
        raw_socket.connect(('127.0.0.1', value['fixture']['port']))
        tls = context.wrap_socket(raw_socket, server_hostname=host,
                                  suppress_ragged_eofs=False, do_handshake_on_connect=False)
        arm(tls)
        tls.do_handshake()
        require(not tls.get_inheritable() and tls.selected_alpn_protocol() in (None, 'http/1.1'), 'protocol_error')
        headers = [('Host', host), ('Accept', 'application/json' if uploading else 'application/pdf'),
                   ('Accept-Encoding', 'identity'), ('Connection', 'close'),
                   ('User-Agent', 'timestep-original-loopback-fixture/1')]
        if uploading:
            headers.extend([('Content-Type', 'application/pdf'), ('Content-Length', str(info.st_size)),
                            ('x-upsert', 'false'), ('X-Timestep-Attempt', value['attempt_id']),
                            ('X-Timestep-Request-Sha256', value['request_sha256']),
                            ('X-Timestep-Candidate-Sha256', request['candidate_sha256'])])
        encoded = (('POST' if uploading else 'GET') + ' ' + path + ' HTTP/1.1\r\n'
                   + ''.join(k + ': ' + v + '\r\n' for k, v in headers) + '\r\n').encode('ascii')
        require(len(encoded) <= 2048, 'invalid_request')
        arm(tls)
        tls.sendall(encoded)
        if uploading:
            sent_hash = hashlib.sha256()
            for raw in _file_chunks(input_fd, info.st_size, deadline):
                arm(tls)
                tls.sendall(raw)
                sent_hash.update(raw)
                # Diagnostic lower bound: a failed sendall may already have
                # sent part of its chunk. Zero never proves a POST did not run.
                result['sent_bytes'] += len(raw)
            require(_stable(_fd(input_fd)) == _stable(info), 'input_changed')
            require(sent_hash.hexdigest() == request['candidate_sha256'], 'input_mismatch')
        ceiling = MAX_ACK if uploading else request['byte_ceiling']
        file = BoundedFile(tls, deadline, ceiling, protocol_limit=MAX_PROTOCOL)
        response = StrictResponse(FileOwner(file), ceiling)
        response.begin()
        result['status'] = response.status
        result['retry_after_kind'] = retry_classification(response)
        result['retry_after_seconds'] = retry_after(response) if result['retry_after_kind'] == 'delta_seconds' else 0
        result['framing'] = header_policy(response, ceiling)
        expected_length = response.length  # Bounded read(amt) may silently end early.
        count, hasher, ack = 0, hashlib.sha256(), bytearray()
        while True:
            require(clock() < deadline, 'deadline')
            raw = response.read(min(CHUNK, ceiling - count + 1))
            if not raw:
                break
            count += len(raw)
            require(count <= ceiling, 'body_limit')
            hasher.update(raw)
            if uploading:
                ack.extend(raw)
            elif response.status == 200:
                _write_pipe(output_fd, info, raw, deadline, result)
        require(expected_length is None or count == expected_length, 'http_truncated')
        require(result['framing'] != 'chunked' or response.isclosed(), 'http_truncated')
        require(result['framing'] != 'close_delimited' or file.peer_close == 'clean_tls', 'tls_truncated')
        require(clock() < deadline, 'deadline')
        result['framing_complete'] = True
        if uploading:
            require(response.status == 201, 'upload_unacknowledged')
            result['upload_ack_sha256'] = _ack(bytes(ack), value)
        result.update(kind='complete', reason=None, body_bytes=count, body_sha256=hasher.hexdigest())
        # A short, bounded observation can reject already visible trailing data.
        # It is not required peer/TCP retirement and gets no extra deadline.
        if file.peer_close == 'not_observed' and value['close_ms']:
            remaining = min(value['close_ms'] / 1000, deadline - clock())
            require(remaining > 0, 'deadline')
            tls.settimeout(remaining)
            try:
                extra = tls.recv(1)
                if extra:
                    file.received += len(extra)
                    raise Refused('extra_protocol_data')
                file.peer_close = 'clean_tls'
            except (ssl.SSLEOFError, ConnectionResetError, ConnectionAbortedError):
                file.peer_close = 'abrupt'
            except socket.timeout:
                pass
    except Refused as error:
        fail(error.code)
    except socket.timeout:
        fail('deadline')
    except ssl.SSLCertVerificationError:
        fail('tls_identity')
    except http.client.IncompleteRead:
        fail('http_truncated')
    except (ssl.SSLError, OSError):
        fail('transport')
    except (http.client.HTTPException, ValueError):
        fail('protocol_error')
    finally:
        close_owned(response)
        if file is not None:
            close_owned(file)
            result['protocol_bytes_received'] = file.received
            result['tls_peer_close'] = file.peer_close
            result['local_cleanup']['http_file_closed'] = file.closed
        close_owned(tls)
        close_owned(raw_socket)
        result['local_cleanup']['socket_closed'] = all(
            item is None or item.fileno() == -1 for item in (tls, raw_socket))
        result['elapsed_ms'] = round((clock() - started) * 1000, 3)
    require(len(canonical(result)) <= MAX_OUTPUT, 'output_limit')
    return result


def checked_result(raw, value):
    value = validate_input(value)
    require(type(raw) is bytes and len(raw) <= MAX_OUTPUT, 'invalid_output')
    result = decode(raw)
    require(type(result) is dict and set(result) == RESULT_KEYS, 'invalid_output')
    require(result['format'] == 'original-transfer-result-v1' and result['local_fixture_only'] is True
            and result['attempt_id'] == value['attempt_id'] and result['request_sha256'] == value['request_sha256']
            and result['input_sha256'] == digest(canonical(value)) and result['stage'] == value['request']['kind'], 'invalid_output')
    require(result['status'] is None or type(result['status']) is int and 200 <= result['status'] <= 599, 'invalid_output')
    require(result['framing'] in (None, 'content_length', 'chunked', 'close_delimited', 'no_body')
            and type(result['framing_complete']) is bool
            and result['tls_peer_close'] in ('not_observed', 'clean_tls', 'abrupt'), 'invalid_output')
    for key, maximum in (('binary_bytes', MAX_BODY), ('sent_bytes', MAX_BODY),
                         ('protocol_bytes_received', MAX_PROTOCOL + 1), ('retry_after_seconds', 86_400)):
        require(type(result[key]) is int and 0 <= result[key] <= maximum, 'invalid_output')
    require(result['retry_after_kind'] in ('absent', 'delta_seconds', 'unsupported')
            and (result['retry_after_kind'] == 'delta_seconds' or result['retry_after_seconds'] == 0), 'invalid_output')
    cleanup = result['local_cleanup']
    require(type(cleanup) is dict and set(cleanup) == {'http_file_closed', 'socket_closed'}
            and all(type(v) is bool for v in cleanup.values()), 'invalid_output')
    # Range comparisons also reject nonfinite floats, without converting a
    # bounded-JSON but enormous integer to float (which can overflow).
    require(type(result['elapsed_ms']) in (int, float)
            and 0 <= result['elapsed_ms'] <= MAX_USEFUL_MS + 1000, 'invalid_output')
    uploading = value['request']['kind'] == 'original_upload'
    require(result['binary_bytes'] == 0 if uploading else result['sent_bytes'] == 0, 'invalid_output')
    require(result['binary_bytes'] <= value['request']['byte_ceiling']
            and result['sent_bytes'] <= (value['request']['candidate_bytes'] if uploading else 0), 'invalid_output')
    if result['kind'] == 'complete':
        ceiling = MAX_ACK if uploading else value['request']['byte_ceiling']
        require(result['reason'] is None and result['framing_complete'] and result['status'] is not None
                and result['framing'] is not None and not 300 <= result['status'] <= 399
                and all(cleanup.values()), 'invalid_output')
        require(type(result['body_bytes']) is int and 0 <= result['body_bytes'] <= ceiling
                and result['protocol_bytes_received'] >= result['body_bytes'], 'invalid_output')
        _sha(result['body_sha256'], 'invalid_output')
        require(result['body_bytes'] != 0 or result['body_sha256'] == digest(b''), 'invalid_output')
        require(result['framing'] != 'no_body' or result['status'] == 204, 'invalid_output')
        if result['status'] == 204:
            require(result['framing'] in ('no_body', 'content_length')
                    and result['body_bytes'] == 0 and result['binary_bytes'] == 0, 'invalid_output')
        require(result['framing'] != 'close_delimited' or result['tls_peer_close'] == 'clean_tls', 'invalid_output')
        if uploading:
            require(result['status'] == 201 and result['body_bytes'] > 0
                    and result['sent_bytes'] == value['request']['candidate_bytes']
                    and result['upload_ack_sha256'] == result['body_sha256'], 'invalid_output')
        else:
            require(result['upload_ack_sha256'] is None
                    and result['binary_bytes'] == (result['body_bytes'] if result['status'] == 200 else 0), 'invalid_output')
    else:
        require(result['kind'] == 'uncertain' and type(result['reason']) is str and result['reason'] in REASONS
                and all(result[k] is None for k in ('body_bytes', 'body_sha256', 'upload_ack_sha256')), 'invalid_output')
    return result


def spool_facts(result):
    """Map complete HTTP body facts only; caller still needs EOF/join/sealing."""
    require(result['stage'] in ('original_download', 'original_readback') and result['kind'] == 'complete'
            and result['status'] == 200 and result['framing_complete'] is True
            and type(result['body_bytes']) is int and 0 < result['body_bytes'] <= MAX_BODY,
            'spool_incomplete_transfer')
    _sha(result['body_sha256'], 'spool_incomplete_transfer')
    mapping = {'content_length': 'content-length', 'chunked': 'chunked', 'close_delimited': 'tls-close'}
    require(result['framing'] in mapping, 'spool_incomplete_transfer')
    return {'status': 200, 'framing': mapping[result['framing']], 'framing_complete': True,
            'bytes': result['body_bytes'], 'sha256': result['body_sha256']}
